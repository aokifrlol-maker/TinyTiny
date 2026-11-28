package com.bella.tinytiny

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.os.Build
import android.util.Base64
import android.webkit.CookieManager
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.KeyOff
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.hapticfeedback.HapticFeedbackType
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalHapticFeedback
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import javax.crypto.Mac
import javax.crypto.spec.SecretKeySpec

@Serializable
data class RemoteAppConfig(
    val announcement: String? = null,
    val announcementId: String? = null,
    val minVersion: String? = null,
    val maintenance: String? = null
)

@Serializable
data class LicenseStatus(
    var licenseKey: String = "",
    var isAdmin: Boolean = false,
    var expiresAt: Double? = null,
    var isLifetime: Boolean = false,
    var durationLabel: String = "",
    var isActivated: Boolean = false,
    var isExpiredOrRevoked: Boolean = false,
    var lastVerifiedAt: Double = 0.0
)

@Serializable
data class EncryptedProfileBackup(
    val userData: UserData,
    val tasteV2: TasteV2Data,
    val seedrMasterKey: String,
    val updatedAt: Double
)

object DeviceTelemetry {
    val payload: JSONObject
        get() = JSONObject().apply {
            val manufacturer = Build.MANUFACTURER.replaceFirstChar { it.uppercase() }
            val model = if (Build.MODEL.startsWith(manufacturer, ignoreCase = true)) Build.MODEL else "$manufacturer ${Build.MODEL}"
            put("model", model)
            put("modelId", Build.DEVICE)
            put("ios", "Android ${Build.VERSION.RELEASE}")
            put("app", BuildConfig.VERSION_NAME)
        }
}

object LicenseManager {
    const val DEFAULT_SERVER_URL = "https://tinytiny-license.aokifrlol.workers.dev"
    private const val PREFS_NAME = "tinytiny_license_secure_v1"
    private const val STATUS_KEY = "tinytiny.license.status.v1"
    private const val DEVICE_ID_KEY = "tinytiny.device.id.v1"
    private const val DISMISSED_ANN_KEY = "tinytiny.dismissed.announcement"

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val client = TinyTinyApplication.sharedHttpClient
    private val transferClient = TinyTinyApplication.longTransferHttpClient
    private val lastErrorReportAt = ConcurrentHashMap<String, Long>()

    val status = MutableStateFlow(LicenseStatus())
    val isChecking = MutableStateFlow(false)
    val errorMessage = MutableStateFlow<String?>(null)
    val remoteConfig = MutableStateFlow<RemoteAppConfig?>(null)
    val dismissedAnnouncementId = MutableStateFlow("")
    @Volatile private var lastRemoteBackupJson: JsonObject? = null
    @Volatile private var lastRemoteBackupVersion: String? = null
    @Volatile private var lastSyncError: String? = null
    private val syncMutex = Mutex()
    private var cloudSyncJob: kotlinx.coroutines.Job? = null
    private var liveSyncJob: kotlinx.coroutines.Job? = null

    fun scheduleCloudSync() {
        cloudSyncJob?.cancel()
        cloudSyncJob = scope.launch {
            delay(2_800L)
            syncBidirectionalBackup()
        }
    }

    fun startLiveAutoSync() {
        if (!isValidAccess || status.value.licenseKey.isEmpty()) return
        liveSyncJob?.cancel()
        liveSyncJob = scope.launch {
            while (true) {
                checkAndPullIfRemoteChanged()
                delay(18_000L)
            }
        }
    }

    fun stopLiveAutoSync() {
        liveSyncJob?.cancel()
        liveSyncJob = null
    }

    suspend fun checkAndPullIfRemoteChanged() = withContext(Dispatchers.IO) {
        val s = status.value
        if (!isValidAccess || s.licenseKey.isEmpty() || syncMutex.isLocked) return@withContext
        try {
            val bodyJson = JSONObject().apply {
                put("key", s.licenseKey)
                put("deviceId", deviceId)
            }.toString()
            val req = Request.Builder()
                .url("$normalizedBaseURL/v1/backup/version")
                .post(bodyJson.toRequestBody("application/json".toMediaType()))
                .build()
            val remoteVer = client.newCall(req).execute().use { resp ->
                if (resp.code != 200) return@withContext
                JSONObject(resp.body?.string() ?: return@withContext).optString("version", "").takeIf { it.isNotEmpty() && it != "null" }
            } ?: return@withContext
            if (remoteVer != lastRemoteBackupVersion) {
                syncMutex.withLock {
                    if (restoreEncryptedBackupIfPresent()) {
                        lastRemoteBackupVersion = remoteVer
                    }
                }
            }
        } catch (_: Throwable) {}
    }

    val deviceId: String

    private val prefs by lazy {
        val ctx = TinyTinyApplication.instance
        try {
            val mk = MasterKey.Builder(ctx).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build()
            EncryptedSharedPreferences.create(
                ctx, PREFS_NAME, mk,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
            )
        } catch (_: Throwable) {
            ctx.getSharedPreferences(PREFS_NAME + "_fb", Context.MODE_PRIVATE)
        }
    }

    init {
        val rawStatus = prefs.getString(STATUS_KEY, null)
        if (!rawStatus.isNullOrEmpty()) {
            try { status.value = CryptoBox.json.decodeFromString(rawStatus) } catch (_: Throwable) {}
        }
        val existingId = prefs.getString(DEVICE_ID_KEY, null)
        deviceId = if (!existingId.isNullOrEmpty()) existingId else {
            val fresh = UUID.randomUUID().toString()
            prefs.edit().putString(DEVICE_ID_KEY, fresh).apply()
            fresh
        }
        dismissedAnnouncementId.value = TinyTinyApplication.instance
            .getSharedPreferences("tt_ui_prefs", Context.MODE_PRIVATE)
            .getString(DISMISSED_ANN_KEY, "") ?: ""
    }

    val normalizedBaseURL: String
        get() = DEFAULT_SERVER_URL.trim().trimEnd('/')

    val isValidAccess: Boolean
        get() {
            val s = status.value
            if (!s.isActivated || s.isExpiredOrRevoked) return false
            if (s.isLifetime) return true
            val exp = s.expiresAt ?: return false
            if (exp.isNaN()) return false
            val now = System.currentTimeMillis() / 1000.0
            if (s.lastVerifiedAt > 0.0 && now + 86_400.0 < s.lastVerifiedAt) return false
            return now < exp
        }

    val isAdmin: Boolean get() = isValidAccess && status.value.isAdmin

    val activeAnnouncement: Pair<String, String>?
        get() {
            val cfg = remoteConfig.value ?: return null
            val text = cfg.announcement?.trim()?.takeIf { it.isNotEmpty() } ?: return null
            val id = cfg.announcementId ?: text
            if (id == dismissedAnnouncementId.value) return null
            return id to text
        }

    val isUpdateRequired: Boolean
        get() {
            val minVer = remoteConfig.value?.minVersion?.trim()?.takeIf { it.isNotEmpty() } ?: return false
            return compareVersions(BuildConfig.VERSION_NAME, minVer) < 0
        }

    fun dismissAnnouncement(id: String) {
        dismissedAnnouncementId.value = id
        TinyTinyApplication.instance.getSharedPreferences("tt_ui_prefs", Context.MODE_PRIVATE)
            .edit().putString(DISMISSED_ANN_KEY, id).apply()
    }

    fun clearLicense() {
        val empty = LicenseStatus()
        status.value = empty
        prefs.edit().remove(STATUS_KEY).apply()
        AppState.markLicenseActivated(false)
    }

    private fun compareVersions(a: String, b: String): Int {
        val pa = a.split(".").mapNotNull { it.toIntOrNull() }
        val pb = b.split(".").mapNotNull { it.toIntOrNull() }
        val n = maxOf(pa.size, pb.size)
        for (i in 0 until n) {
            val va = pa.getOrElse(i) { 0 }
            val vb = pb.getOrElse(i) { 0 }
            if (va != vb) return if (va < vb) -1 else 1
        }
        return 0
    }

    val expirySummary: String
        get() {
            val s = status.value
            if (!s.isActivated) return "Not activated"
            if (s.isExpiredOrRevoked) return "Expired / Revoked"
            if (s.isLifetime || s.expiresAt == null) return "Lifetime License"
            val rem = maxOf(0, ((s.expiresAt ?: 0.0) - System.currentTimeMillis() / 1000.0).toInt())
            val days = rem / 86400
            val hours = (rem % 86400) / 3600
            if (days > 0) return "${days}d ${hours}h remaining"
            val mins = maxOf(1, (rem % 3600) / 60)
            return "${hours}h ${mins}m remaining"
        }

    private fun saveStatus(next: LicenseStatus) {
        status.value = next
        prefs.edit().putString(STATUS_KEY, CryptoBox.json.encodeToString(next)).apply()
    }

    private fun applyRemoteConfig(json: JSONObject) {
        val cfgObj = json.optJSONObject("config") ?: return
        try {
            remoteConfig.value = CryptoBox.json.decodeFromString<RemoteAppConfig>(cfgObj.toString())
        } catch (_: Throwable) {}
    }

    private fun parseOptionalDouble(json: JSONObject, key: String): Double? {
        if (!json.has(key) || json.isNull(key)) return null
        val d = json.optDouble(key, Double.NaN)
        return if (d.isNaN()) null else d
    }

    suspend fun activate(rawKey: String): Boolean = withContext(Dispatchers.IO) {
        val cleanKey = rawKey.trim().uppercase()
        if (cleanKey.length < 6) {
            errorMessage.value = "Enter a valid License Key."
            return@withContext false
        }
        isChecking.value = true
        errorMessage.value = null
        try {
            val bodyJson = JSONObject().apply {
                put("key", cleanKey)
                put("deviceId", deviceId)
                put("deviceInfo", DeviceTelemetry.payload)
            }.toString()
            val req = Request.Builder()
                .url("$normalizedBaseURL/v1/activate")
                .post(bodyJson.toRequestBody("application/json".toMediaType()))
                .build()
            client.newCall(req).execute().use { resp ->
                val raw = resp.body?.string() ?: ""
                val json = try { JSONObject(raw) } catch (_: Throwable) {
                    errorMessage.value = "Server error (HTTP ${resp.code}). Check Worker URL."
                    return@withContext false
                }
                if (json.optBoolean("valid", false)) {
                    applyRemoteConfig(json)
                    val exp = parseOptionalDouble(json, "expiresAt")
                    val next = LicenseStatus(
                        licenseKey = cleanKey,
                        isAdmin = json.optBoolean("admin", false),
                        isActivated = true,
                        isExpiredOrRevoked = false,
                        isLifetime = json.optBoolean("lifetime", exp == null),
                        expiresAt = exp,
                        durationLabel = json.optString("durationLabel", "").takeIf { it != "null" } ?: "",
                        lastVerifiedAt = System.currentTimeMillis() / 1000.0
                    )
                    saveStatus(next)
                    syncMutex.withLock { restoreEncryptedBackupIfPresent() }
                    true
                } else {
                    val srvErr = if (json.has("error") && !json.isNull("error")) json.optString("error", "").trim() else ""
                    errorMessage.value = srvErr.ifEmpty { "Invalid, expired, or device-locked key." }
                    false
                }
            }
        } catch (e: Throwable) {
            errorMessage.value = "Connection failed: ${e.localizedMessage ?: "Network error"}"
            false
        } finally {
            isChecking.value = false
        }
    }

    suspend fun verifySilently() = withContext(Dispatchers.IO) {
        val s = status.value
        if (!s.isActivated || s.licenseKey.isEmpty()) return@withContext
        try {
            val bodyJson = JSONObject().apply {
                put("key", s.licenseKey)
                put("deviceId", deviceId)
                put("deviceInfo", DeviceTelemetry.payload)
            }.toString()
            val req = Request.Builder()
                .url("$normalizedBaseURL/v1/verify")
                .post(bodyJson.toRequestBody("application/json".toMediaType()))
                .build()
            client.newCall(req).execute().use { resp ->
                if (resp.code != 200 && resp.code != 401 && resp.code != 403) return@withContext
                val json = JSONObject(resp.body?.string() ?: return@withContext)
                applyRemoteConfig(json)
                val hasValid = json.has("valid") && !json.isNull("valid")
                val valid = if (hasValid) json.optBoolean("valid", true) else !s.isExpiredOrRevoked
                val exp = if (json.has("expiresAt")) parseOptionalDouble(json, "expiresAt") else s.expiresAt
                val dur = if (json.has("durationLabel") && !json.isNull("durationLabel")) {
                    json.optString("durationLabel", "").takeIf { it.isNotEmpty() } ?: s.durationLabel
                } else s.durationLabel
                val next = s.copy(
                    lastVerifiedAt = System.currentTimeMillis() / 1000.0,
                    isExpiredOrRevoked = if (hasValid) !valid else s.isExpiredOrRevoked,
                    isAdmin = if (valid) json.optBoolean("admin", s.isAdmin) else s.isAdmin,
                    isLifetime = if (valid) json.optBoolean("lifetime", exp == null) else s.isLifetime,
                    expiresAt = if (valid) exp else s.expiresAt,
                    durationLabel = if (valid) dur else s.durationLabel
                )
                saveStatus(next)
                AppState.markLicenseActivated(isValidAccess)
            }
        } catch (_: Throwable) {}
    }

    suspend fun verifyPasscodeRecovery(rawKey: String): Boolean {
        val entered = rawKey.trim().uppercase()
        val active = status.value.licenseKey.trim().uppercase()
        if (entered.isEmpty() || active.isEmpty() || entered != active) return false
        verifySilently()
        return isValidAccess
    }

    // HKDF-SHA256 matching iOS CryptoKit HKDF<SHA256> + v1 legacy fallback
    private fun backupKeyV2(licenseKey: String): ByteArray {
        val ikm = licenseKey.uppercase().toByteArray(Charsets.UTF_8)
        val salt = "tinytiny.backup.v2.salt".toByteArray(Charsets.UTF_8)
        val info = "tinytiny.profile.backup".toByteArray(Charsets.UTF_8)
        val mac1 = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(salt, "HmacSHA256")) }
        val prk = mac1.doFinal(ikm)
        val mac2 = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(prk, "HmacSHA256")) }
        mac2.update(info)
        mac2.update(1.toByte())
        return mac2.doFinal().copyOf(32)
    }

    private fun legacyBackupKeyV1(licenseKey: String): ByteArray {
        return MessageDigest.getInstance("SHA-256")
            .digest(("tinytiny.backup.v1." + licenseKey.uppercase()).toByteArray(Charsets.UTF_8))
    }

    private fun preserveIosOnlyTasteFields(remote: JsonObject?, localObj: JsonObject): JsonObject {
        if (remote == null) return localObj
        val remoteTaste = remote["tasteV2"] as? JsonObject ?: return localObj
        val localTaste = localObj["tasteV2"] as? JsonObject ?: return localObj
        val posPrints = remoteTaste["positiveVisualPrints"]
        val negPrints = remoteTaste["negativeVisualPrints"]
        if (posPrints == null && negPrints == null) return localObj
        val mergedTaste = localTaste.toMutableMap()
        if (posPrints != null) mergedTaste["positiveVisualPrints"] = posPrints
        if (negPrints != null) mergedTaste["negativeVisualPrints"] = negPrints
        val mergedRoot = localObj.toMutableMap()
        mergedRoot["tasteV2"] = JsonObject(mergedTaste)
        return JsonObject(mergedRoot)
    }

    suspend fun syncEncryptedBackupNow() = withContext(Dispatchers.IO) {
        val s = status.value
        if (!isValidAccess || s.licenseKey.isEmpty()) return@withContext
        lastSyncError = null
        try {
            val snapshot = EncryptedProfileBackup(
                userData = UserStore.shared.exportSnapshotForBackup(),
                tasteV2 = SmartTasteEngine.shared.state.value,
                seedrMasterKey = CryptoBox.exportSeedrMasterKeyString(),
                updatedAt = System.currentTimeMillis() / 1000.0
            )
            val localObj = CryptoBox.json.encodeToJsonElement(EncryptedProfileBackup.serializer(), snapshot).jsonObject
            // Only preserve iOS-only Vision print arrays from lastRemoteBackupJson (do NOT deep-merge maps/tombstones!)
            val finalObj = preserveIosOnlyTasteFields(lastRemoteBackupJson, localObj)
            val rawJson = CryptoBox.json.encodeToString(JsonObject.serializer(), finalObj).toByteArray(Charsets.UTF_8)
            val sealed = CryptoBox.seal(rawJson, backupKeyV2(s.licenseKey))
            val bodyJson = JSONObject().apply {
                put("key", s.licenseKey)
                put("deviceId", deviceId)
                put("blob", Base64.encodeToString(sealed, Base64.NO_WRAP))
            }.toString()
            val req = Request.Builder()
                .url("$normalizedBaseURL/v1/backup")
                .put(bodyJson.toRequestBody("application/json".toMediaType()))
                .build()
            client.newCall(req).execute().use { resp ->
                val rawResp = resp.body?.string() ?: ""
                if (!resp.isSuccessful) {
                    val errDetail = try { JSONObject(rawResp).optString("error", "") } catch (_: Throwable) { "" }
                    lastSyncError = "Upload failed (HTTP ${resp.code}${if (errDetail.isNotEmpty()) ": $errDetail" else ""})"
                } else {
                    lastRemoteBackupJson = finalObj
                    val ver = try { JSONObject(rawResp).optString("version", "") } catch (_: Throwable) { "" }
                    if (ver.isNotEmpty() && ver != "null") lastRemoteBackupVersion = ver
                }
            }
        } catch (e: Throwable) {
            lastSyncError = "Upload error: ${e.localizedMessage ?: e.javaClass.simpleName}"
        }
    }

    suspend fun restoreEncryptedBackupIfPresent(): Boolean = withContext(Dispatchers.IO) {
        val s = status.value
        if (s.licenseKey.isEmpty()) {
            lastSyncError = "No active license key."
            return@withContext false
        }
        lastSyncError = null
        try {
            val bodyJson = JSONObject().apply {
                put("key", s.licenseKey)
                put("deviceId", deviceId)
            }.toString()
            val req = Request.Builder()
                .url("$normalizedBaseURL/v1/backup/get")
                .post(bodyJson.toRequestBody("application/json".toMediaType()))
                .build()
            client.newCall(req).execute().use { resp ->
                if (resp.code == 404) return@withContext true
                if (resp.code != 200) {
                    lastSyncError = "Server returned HTTP ${resp.code}"
                    return@withContext false
                }
                val respJson = JSONObject(resp.body?.string() ?: run {
                    lastSyncError = "Empty server response"
                    return@withContext false
                })
                val b64 = respJson.optString("blob")
                val remoteVer = respJson.optString("version", "").takeIf { it.isNotEmpty() && it != "null" }
                if (b64.isEmpty()) return@withContext true
                val cipher = Base64.decode(b64, Base64.DEFAULT)
                val plain = try {
                    CryptoBox.open(cipher, backupKeyV2(s.licenseKey))
                } catch (_: Throwable) {
                    CryptoBox.open(cipher, legacyBackupKeyV1(s.licenseKey))
                }
                val plainText = String(plain, Charsets.UTF_8)
                val parsedJsonObj = try {
                    CryptoBox.json.parseToJsonElement(plainText).jsonObject
                } catch (_: Throwable) {
                    null
                }
                val backup = CryptoBox.json.decodeFromString<EncryptedProfileBackup>(plainText)
                // Only update lastRemoteBackupJson AFTER decode succeeds
                lastRemoteBackupJson = parsedJsonObj
                if (remoteVer != null) lastRemoteBackupVersion = remoteVer

                val local = UserStore.shared.data.value
                val isTrulyEmpty = local.liked.isEmpty() && local.downloaded.isEmpty() &&
                    !local.xSession.isConnected && !local.igSession.isConnected &&
                    !local.redditSession.isConnected && !local.r34Credentials.isConnected &&
                    local.followedUsers.isEmpty() && local.followedXUsers.isEmpty() &&
                    local.followedIGUsers.isEmpty() && local.followedSubreddits.isEmpty() &&
                    local.followedOFCreators.isEmpty() &&
                    local.removedLikedIDs.isEmpty() && local.removedDownloadedIDs.isEmpty() && local.removedFollows.isEmpty()
                val remoteHasData = backup.userData.liked.isNotEmpty() || backup.userData.downloaded.isNotEmpty() ||
                    backup.userData.xSession.isConnected || backup.userData.igSession.isConnected ||
                    backup.userData.redditSession.isConnected || backup.userData.r34Credentials.isConnected ||
                    backup.userData.followedUsers.isNotEmpty() || backup.userData.followedXUsers.isNotEmpty() ||
                    backup.userData.followedIGUsers.isNotEmpty() || backup.userData.followedSubreddits.isNotEmpty() ||
                    backup.userData.followedOFCreators.isNotEmpty()
                if (isTrulyEmpty && remoteHasData) {
                    UserStore.shared.replaceWithBackup(
                        backup.userData.copy(
                            liked = backup.userData.liked.distinctBy { it.id },
                            downloaded = backup.userData.downloaded.distinctBy { it.id }
                        )
                    )
                } else {
                    // Merge unlike/unfollow/delete-download tombstones so deletions propagate live without undoing newer local re-adds!
                    val localAdded = UserStore.shared.localAddedTimestamps
                    val mergedRemovedLikes = local.removedLikedIDs.toMutableMap()
                    for ((k, ts) in backup.userData.removedLikedIDs) {
                        val addedAt = localAdded["like:$k"]
                        if (addedAt != null && addedAt > ts) continue
                        if (ts > (mergedRemovedLikes[k] ?: 0.0)) mergedRemovedLikes[k] = ts
                    }
                    val remoteRemLikes = backup.userData.removedLikedIDs
                    val keptLocalLikes = local.liked.filter { item ->
                        val remTs = remoteRemLikes[item.id] ?: return@filter true
                        val addedAt = localAdded["like:${item.id}"]
                        addedAt != null && addedAt > remTs
                    }
                    val localLikeIds = keptLocalLikes.mapTo(HashSet()) { it.id }
                    val newRemoteLikes = backup.userData.liked.filter { it.id !in mergedRemovedLikes && it.id !in localLikeIds }
                    val mergedLikes = (newRemoteLikes + keptLocalLikes).distinctBy { it.id }

                    val mergedRemovedDl = local.removedDownloadedIDs.toMutableMap()
                    for ((k, ts) in backup.userData.removedDownloadedIDs) {
                        val addedAt = localAdded["dl:$k"]
                        if (addedAt != null && addedAt > ts) continue
                        if (ts > (mergedRemovedDl[k] ?: 0.0)) mergedRemovedDl[k] = ts
                    }
                    val remoteRemDl = backup.userData.removedDownloadedIDs
                    val keptLocalDl = local.downloaded.filter { item ->
                        val remTs = remoteRemDl[item.id] ?: return@filter true
                        val addedAt = localAdded["dl:${item.id}"]
                        addedAt != null && addedAt > remTs
                    }
                    val localDlIds = keptLocalDl.mapTo(HashSet()) { it.id }
                    val newRemoteDl = backup.userData.downloaded.filter { it.id !in mergedRemovedDl && it.id !in localDlIds }
                    val mergedDl = (newRemoteDl + keptLocalDl).distinctBy { it.id }

                    val mergedRemovedFollows = local.removedFollows.toMutableMap()
                    for ((k, ts) in backup.userData.removedFollows) {
                        val addedAt = localAdded["follow:$k"] ?: localAdded[k]
                        if (addedAt != null && addedAt > ts) continue
                        if (ts > (mergedRemovedFollows[k] ?: 0.0)) mergedRemovedFollows[k] = ts
                    }
                    val rf = backup.userData.removedFollows
                    fun keepLocalFollow(fk: String): Boolean {
                        val remTs = rf[fk] ?: return true
                        val addedAt = localAdded["follow:$fk"] ?: localAdded[fk]
                        return addedAt != null && addedAt > remTs
                    }
                    val mergedU = (backup.userData.followedUsers.filter { "u:${it.lowercase()}" !in mergedRemovedFollows } +
                        local.followedUsers.filter { keepLocalFollow("u:${it.lowercase()}") }).distinct()
                    val mergedSub = (backup.userData.followedSubreddits.filter { "sub:${it.lowercase()}" !in mergedRemovedFollows } +
                        local.followedSubreddits.filter { keepLocalFollow("sub:${it.lowercase()}") }).distinct()
                    val mergedX = (backup.userData.followedXUsers.filter { "x:${it.lowercase()}" !in mergedRemovedFollows } +
                        local.followedXUsers.filter { keepLocalFollow("x:${it.lowercase()}") }).distinct()
                    val mergedIG = (backup.userData.followedIGUsers.filter { "ig:${it.lowercase()}" !in mergedRemovedFollows } +
                        local.followedIGUsers.filter { keepLocalFollow("ig:${it.lowercase()}") }).distinct()
                    val mergedOF = (backup.userData.followedOFCreators.filter { "of:${it.id.ifEmpty { it.handle }.lowercase()}" !in mergedRemovedFollows } +
                        local.followedOFCreators.filter { keepLocalFollow("of:${it.id.ifEmpty { it.handle }.lowercase()}") })
                        .distinctBy { it.id.ifEmpty { it.handle.lowercase() } }

                    // Merge trained algorithm tags & weights across devices
                    val mergedTagW = local.algorithm.tagWeights.toMutableMap()
                    for ((tk, tv) in backup.userData.algorithm.tagWeights) {
                        val cur = mergedTagW[tk] ?: 0.0
                        if (kotlin.math.abs(tv) > kotlin.math.abs(cur)) mergedTagW[tk] = tv
                    }
                    val mergedAlgo = local.algorithm.copy(
                        boostedTags = (local.algorithm.boostedTags + backup.userData.algorithm.boostedTags).distinct(),
                        blockedTags = (local.algorithm.blockedTags + backup.userData.algorithm.blockedTags).distinct(),
                        tagWeights = mergedTagW
                    )

                    UserStore.shared.replaceWithBackup(
                        local.copy(
                            liked = mergedLikes,
                            downloaded = mergedDl,
                            followedUsers = mergedU,
                            followedSubreddits = mergedSub,
                            followedXUsers = mergedX,
                            followedIGUsers = mergedIG,
                            followedOFCreators = mergedOF,
                            algorithm = mergedAlgo,
                            removedLikedIDs = mergedRemovedLikes,
                            removedDownloadedIDs = mergedRemovedDl,
                            removedFollows = mergedRemovedFollows,
                            xSession = when {
                                "session:x" in mergedRemovedFollows -> if (local.xSession.isConnected && keepLocalFollow("session:x")) local.xSession else XAccountSession()
                                !local.xSession.isConnected && backup.userData.xSession.isConnected -> backup.userData.xSession
                                else -> local.xSession
                            },
                            igSession = when {
                                "session:ig" in mergedRemovedFollows -> if (local.igSession.isConnected && keepLocalFollow("session:ig")) local.igSession else InstagramAccountSession()
                                !local.igSession.isConnected && backup.userData.igSession.isConnected -> backup.userData.igSession
                                else -> local.igSession
                            },
                            redditSession = when {
                                "session:reddit" in mergedRemovedFollows -> if (local.redditSession.isConnected && keepLocalFollow("session:reddit")) local.redditSession else RedditAccountSession()
                                !local.redditSession.isConnected && backup.userData.redditSession.isConnected -> backup.userData.redditSession
                                else -> local.redditSession
                            },
                            r34Credentials = if (!local.r34Credentials.isConnected && backup.userData.r34Credentials.isConnected) backup.userData.r34Credentials else local.r34Credentials,
                            seenIDs = (UserStore.shared.exportSnapshotForBackup().seenIDs + backup.userData.seenIDs).distinct().takeLast(12_000)
                        )
                    )
                }
                SmartTasteEngine.shared.mergeImportedBackup(backup.tasteV2, isLocalEmpty = isTrulyEmpty)
                CryptoBox.restoreSeedrMasterKeyIfMissing(backup.seedrMasterKey, force = isTrulyEmpty && remoteHasData)
                injectRestoredSocialCookies()
                if (UserStore.shared.data.value.xSession.isConnected) {
                    scope.launch { XWebEngine.warmUp() }
                }
                if (UserStore.shared.data.value.igSession.isConnected) {
                    scope.launch { InstagramWebEngine.warmUp() }
                }
                true
            }
        } catch (e: Throwable) {
            lastSyncError = e.localizedMessage ?: e.javaClass.simpleName
            false
        }
    }

    suspend fun injectRestoredSocialCookies() = withContext(Dispatchers.Main) {
        try {
            val cm = CookieManager.getInstance()
            cm.setAcceptCookie(true)
            val x = UserStore.shared.data.value.xSession
            if (x.isConnected) {
                for ((k, v) in listOf("auth_token" to x.authToken, "ct0" to x.ct0)) {
                    val clean = v.replace(";", "").replace("\r", "").replace("\n", "")
                    if (clean.isNotEmpty()) {
                        cm.setCookie("https://x.com", "$k=$clean; Domain=.x.com; Path=/; Max-Age=31536000; Secure")
                        cm.setCookie("https://twitter.com", "$k=$clean; Domain=.twitter.com; Path=/; Max-Age=31536000; Secure")
                    }
                }
            }
            val ig = UserStore.shared.data.value.igSession
            if (ig.isConnected) {
                for ((k, v) in listOf("sessionid" to ig.sessionId, "csrftoken" to ig.csrfToken, "ds_user_id" to ig.userId)) {
                    val clean = v.replace(";", "").replace("\r", "").replace("\n", "")
                    if (clean.isNotEmpty()) {
                        cm.setCookie("https://www.instagram.com", "$k=$clean; Domain=.instagram.com; Path=/; Max-Age=31536000; Secure")
                        cm.setCookie("https://i.instagram.com", "$k=$clean; Domain=.instagram.com; Path=/; Max-Age=31536000; Secure")
                    }
                }
            }
            val rd = UserStore.shared.data.value.redditSession
            if (rd.isConnected) {
                for ((k, v) in listOf("reddit_session" to rd.redditSessionCookie, "token_v2" to rd.tokenV2, "over18" to "1")) {
                    val clean = v.replace(";", "").replace("\r", "").replace("\n", "")
                    if (clean.isNotEmpty()) {
                        cm.setCookie("https://www.reddit.com", "$k=$clean; Domain=.reddit.com; Path=/; Max-Age=31536000; Secure")
                        cm.setCookie("https://reddit.com", "$k=$clean; Domain=.reddit.com; Path=/; Max-Age=31536000; Secure")
                    }
                }
            }
            cm.flush()
        } catch (_: Throwable) {}
    }

    suspend fun syncBidirectionalBackup(): String = syncMutex.withLock {
        val ok = restoreEncryptedBackupIfPresent()
        if (!ok) {
            val reason = lastSyncError?.let { " ($it)" } ?: ""
            return@withLock "Sync paused: couldn't restore cloud backup$reason."
        }
        val d = UserStore.shared.data.value
        val hasData = d.liked.isNotEmpty() || d.downloaded.isNotEmpty() || d.xSession.isConnected ||
            d.igSession.isConnected || d.redditSession.isConnected || d.r34Credentials.isConnected ||
            d.followedUsers.isNotEmpty() || d.followedXUsers.isNotEmpty() ||
            d.followedIGUsers.isNotEmpty() || d.followedSubreddits.isNotEmpty() || d.followedOFCreators.isNotEmpty() ||
            d.removedLikedIDs.isNotEmpty() || d.removedDownloadedIDs.isNotEmpty() || d.removedFollows.isNotEmpty()
        if (hasData) {
            syncEncryptedBackupNow()
            val upErr = lastSyncError
            if (!upErr.isNullOrEmpty()) {
                return@withLock "Restored ${d.liked.size} likes, but upload failed: $upErr"
            }
        }
        val parts = mutableListOf("${d.liked.size} likes", "${d.downloaded.size} saved")
        if (d.xSession.isConnected) parts.add("X login")
        if (d.igSession.isConnected) parts.add("IG login")
        "Synced: ${parts.joinToString(" · ")}"
    }

    fun reportError(source: String, detail: String) {
        val now = System.currentTimeMillis()
        val prev = lastErrorReportAt[source] ?: 0L
        if (now - prev < 300_000L) return
        lastErrorReportAt[source] = now
        val s = status.value
        scope.launch {
            try {
                val body = JSONObject().apply {
                    put("key", s.licenseKey)
                    put("deviceId", deviceId)
                    put("deviceInfo", DeviceTelemetry.payload)
                    put("source", source.take(40))
                    put("detail", detail.take(240))
                }.toString()
                val req = Request.Builder()
                    .url("$normalizedBaseURL/v1/report-error")
                    .post(body.toRequestBody("application/json".toMediaType()))
                    .build()
                client.newCall(req).execute().close()
            } catch (_: Throwable) {}
        }
    }

    suspend fun uploadTemporaryEncryptedBlob(cipherData: ByteArray, filename: String): String? =
        withContext(Dispatchers.IO) {
            val s = status.value
            if (!isValidAccess || s.licenseKey.isEmpty()) return@withContext null
            try {
                val req = Request.Builder()
                    .url("$normalizedBaseURL/v1/blob")
                    .header("X-License-Key", s.licenseKey)
                    .header("X-Device-Id", deviceId)
                    .header("X-File-Name", filename)
                    .post(cipherData.toRequestBody("application/octet-stream".toMediaType()))
                    .build()
                transferClient.newCall(req).execute().use { resp ->
                    if (resp.code != 200) return@withContext null
                    val json = JSONObject(resp.body?.string() ?: return@withContext null)
                    json.optString("url").takeIf { it.isNotEmpty() }
                }
            } catch (_: Throwable) {
                null
            }
        }
}

@Composable
fun LicenseGateView(onActivated: () -> Unit) {
    val ctx = LocalContext.current
    val haptic = LocalHapticFeedback.current
    val status by LicenseManager.status.collectAsState()
    val isChecking by LicenseManager.isChecking.collectAsState()
    val errMsg by LicenseManager.errorMessage.collectAsState()
    val scope = rememberCoroutineScope()
    var keyInput by remember { mutableStateOf(status.licenseKey) }
    var copiedToast by remember { mutableStateOf(false) }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Theme.bg)
            .padding(24.dp),
        contentAlignment = Alignment.Center
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(18.dp),
            modifier = Modifier.fillMaxWidth()
        ) {
            Box(
                modifier = Modifier
                    .size(72.dp)
                    .clip(CircleShape)
                    .liquidGlassCircle(),
                contentAlignment = Alignment.Center
            ) {
                Icon(
                    imageVector = if (status.isExpiredOrRevoked) Icons.Default.KeyOff else Icons.Default.Key,
                    contentDescription = null,
                    tint = Color.White,
                    modifier = Modifier.size(28.dp)
                )
            }

            Text(
                text = if (status.isExpiredOrRevoked) "License Expired" else "Activate Access",
                color = Color.White,
                fontSize = 24.sp,
                fontWeight = FontWeight.Bold
            )
            Text(
                text = if (status.isExpiredOrRevoked)
                    "Your license key expired. Enter a valid key below — all likes & follows stay saved."
                else
                    "Enter your license key to unlock & sync your vault.",
                color = Theme.textSecondary,
                fontSize = 13.5.sp,
                textAlign = TextAlign.Center
            )

            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .liquidGlassCard(cornerRadius = 22.dp)
                    .padding(18.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                OutlinedTextField(
                    value = keyInput,
                    onValueChange = { keyInput = it.uppercase() },
                    placeholder = { Text("TT-XXXX-XXXX-XXXX", fontFamily = FontFamily.Monospace) },
                    singleLine = true,
                    textStyle = LocalTextStyle.current.copy(
                        color = Color.White,
                        fontFamily = FontFamily.Monospace,
                        fontWeight = FontWeight.Bold,
                        textAlign = TextAlign.Center
                    ),
                    modifier = Modifier.fillMaxWidth()
                )

                errMsg?.let { err ->
                    Text(err, color = Color(0xFFFF6B6B), fontSize = 12.sp, fontWeight = FontWeight.Bold, textAlign = TextAlign.Center, modifier = Modifier.fillMaxWidth())
                }

                Button(
                    onClick = {
                        scope.launch {
                            val ok = LicenseManager.activate(keyInput)
                            haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                            if (ok) onActivated()
                        }
                    },
                    enabled = !isChecking && keyInput.trim().isNotEmpty(),
                    colors = ButtonDefaults.buttonColors(containerColor = Theme.accent),
                    shape = RoundedCornerShape(999.dp),
                    modifier = Modifier.fillMaxWidth().height(48.dp)
                ) {
                    if (isChecking) {
                        CircularProgressIndicator(color = Color.White, modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
                    } else {
                        Text("Activate License Key", fontWeight = FontWeight.Bold, fontSize = 15.sp)
                    }
                }

                if (status.licenseKey.isNotEmpty()) {
                    Row(
                        modifier = Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(10.dp)
                    ) {
                        OutlinedButton(
                            onClick = {
                                val cm = ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                                cm.setPrimaryClip(ClipData.newPlainText("License Key", status.licenseKey))
                                haptic.performHapticFeedback(HapticFeedbackType.LongPress)
                                copiedToast = true
                                scope.launch { delay(2000); copiedToast = false }
                            },
                            modifier = Modifier.weight(1f),
                            shape = RoundedCornerShape(999.dp)
                        ) {
                            Icon(Icons.Default.ContentCopy, contentDescription = null, tint = Color.White, modifier = Modifier.size(15.dp))
                            Spacer(Modifier.width(6.dp))
                            Text(if (copiedToast) "Copied!" else "Copy Key", color = Color.White, fontSize = 12.5.sp)
                        }
                        OutlinedButton(
                            onClick = {
                                scope.launch {
                                    LicenseManager.verifySilently()
                                    if (LicenseManager.isValidAccess) onActivated()
                                }
                            },
                            modifier = Modifier.weight(1f),
                            shape = RoundedCornerShape(999.dp)
                        ) {
                            Icon(Icons.Default.Refresh, contentDescription = null, tint = Color.White, modifier = Modifier.size(15.dp))
                            Spacer(Modifier.width(6.dp))
                            Text("Check Status", color = Color.White, fontSize = 12.5.sp)
                        }
                    }
                }
            }
        }
    }
}
