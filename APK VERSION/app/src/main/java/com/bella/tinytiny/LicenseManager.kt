package com.bella.tinytiny

import android.content.Context
import android.os.Build
import android.util.Base64
import android.webkit.CookieManager
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Key
import androidx.compose.material.icons.filled.KeyOff
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
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
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
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
    private val lastErrorReportAt = ConcurrentHashMap<String, Long>()

    val status = MutableStateFlow(LicenseStatus())
    val isChecking = MutableStateFlow(false)
    val errorMessage = MutableStateFlow<String?>(null)
    val remoteConfig = MutableStateFlow<RemoteAppConfig?>(null)
    val dismissedAnnouncementId = MutableStateFlow("")

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
            val exp = s.expiresAt ?: return true
            return (System.currentTimeMillis() / 1000.0) < exp
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
                    errorMessage.value = "Server error (HTTP ${resp.code})."
                    return@withContext false
                }
                if (json.optBoolean("valid", false)) {
                    applyRemoteConfig(json)
                    val next = LicenseStatus(
                        licenseKey = cleanKey,
                        isAdmin = json.optBoolean("admin", false),
                        isActivated = true,
                        isExpiredOrRevoked = false,
                        isLifetime = json.optBoolean("lifetime", json.isNull("expiresAt")),
                        expiresAt = if (json.isNull("expiresAt")) null else json.optDouble("expiresAt"),
                        durationLabel = json.optString("durationLabel", ""),
                        lastVerifiedAt = System.currentTimeMillis() / 1000.0
                    )
                    saveStatus(next)
                    restoreEncryptedBackupIfPresent()
                    true
                } else {
                    errorMessage.value = json.optString("error", "Invalid, expired, or device-locked key.")
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
                if (resp.code != 200) return@withContext
                val json = JSONObject(resp.body?.string() ?: return@withContext)
                applyRemoteConfig(json)
                val valid = json.optBoolean("valid", true)
                val next = s.copy(
                    lastVerifiedAt = System.currentTimeMillis() / 1000.0,
                    isExpiredOrRevoked = !valid,
                    isAdmin = if (valid) json.optBoolean("admin", s.isAdmin) else s.isAdmin,
                    isLifetime = if (valid) json.optBoolean("lifetime", json.isNull("expiresAt")) else s.isLifetime,
                    expiresAt = if (valid && !json.isNull("expiresAt")) json.optDouble("expiresAt") else s.expiresAt,
                    durationLabel = if (valid && json.optString("durationLabel").isNotEmpty()) json.optString("durationLabel") else s.durationLabel
                )
                saveStatus(next)
            }
        } catch (_: Throwable) {}
    }

    suspend fun verifyPasscodeRecovery(rawKey: String): Boolean {
        val entered = rawKey.trim().uppercase()
        if (entered.isEmpty()) return false
        return activate(entered)
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

    suspend fun syncEncryptedBackupNow() = withContext(Dispatchers.IO) {
        val s = status.value
        if (!isValidAccess || s.licenseKey.isEmpty()) return@withContext
        try {
            val snapshot = EncryptedProfileBackup(
                userData = UserStore.shared.exportSnapshotForBackup(),
                tasteV2 = SmartTasteEngine.shared.state.value,
                seedrMasterKey = CryptoBox.exportSeedrMasterKeyString(),
                updatedAt = System.currentTimeMillis() / 1000.0
            )
            val rawJson = CryptoBox.json.encodeToString(snapshot).toByteArray(Charsets.UTF_8)
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
            client.newCall(req).execute().close()
        } catch (_: Throwable) {}
    }

    suspend fun restoreEncryptedBackupIfPresent(): Boolean = withContext(Dispatchers.IO) {
        val s = status.value
        if (s.licenseKey.isEmpty()) return@withContext false
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
                if (resp.code != 200) return@withContext false
                val b64 = JSONObject(resp.body?.string() ?: return@withContext false).optString("blob")
                if (b64.isEmpty()) return@withContext false
                val cipher = Base64.decode(b64, Base64.DEFAULT)
                val plain = try {
                    CryptoBox.open(cipher, backupKeyV2(s.licenseKey))
                } catch (_: Throwable) {
                    CryptoBox.open(cipher, legacyBackupKeyV1(s.licenseKey))
                }
                val backup = CryptoBox.json.decodeFromString<EncryptedProfileBackup>(String(plain, Charsets.UTF_8))
                val local = UserStore.shared.data.value
                val isTrulyEmpty = local.liked.isEmpty() && local.downloaded.isEmpty() &&
                    !local.xSession.isConnected && !local.igSession.isConnected &&
                    local.followedUsers.isEmpty() && local.followedXUsers.isEmpty() &&
                    local.followedIGUsers.isEmpty() && local.followedSubreddits.isEmpty() &&
                    local.followedOFCreators.isEmpty()
                if (isTrulyEmpty && backup.userData.liked.isNotEmpty()) {
                    UserStore.shared.replaceWithBackup(backup.userData)
                } else {
                    val mergedLikes = (local.liked + backup.userData.liked).distinctBy { it.id }
                    val mergedDl = (local.downloaded + backup.userData.downloaded).distinctBy { it.id }
                    val mergedU = (local.followedUsers + backup.userData.followedUsers).distinct()
                    val mergedSub = (local.followedSubreddits + backup.userData.followedSubreddits).distinct()
                    val mergedX = (local.followedXUsers + backup.userData.followedXUsers).distinct()
                    val mergedIG = (local.followedIGUsers + backup.userData.followedIGUsers).distinct()
                    val mergedOF = (local.followedOFCreators + backup.userData.followedOFCreators).distinctBy { it.id }
                    UserStore.shared.replaceWithBackup(
                        local.copy(
                            liked = mergedLikes,
                            downloaded = mergedDl,
                            followedUsers = mergedU,
                            followedSubreddits = mergedSub,
                            followedXUsers = mergedX,
                            followedIGUsers = mergedIG,
                            followedOFCreators = mergedOF,
                            xSession = if (!local.xSession.isConnected && backup.userData.xSession.isConnected) backup.userData.xSession else local.xSession,
                            igSession = if (!local.igSession.isConnected && backup.userData.igSession.isConnected) backup.userData.igSession else local.igSession,
                            seenIDs = (UserStore.shared.exportSnapshotForBackup().seenIDs + backup.userData.seenIDs).distinct().takeLast(12_000)
                        )
                    )
                }
                SmartTasteEngine.shared.applyImportedBackup(backup.tasteV2)
                CryptoBox.restoreSeedrMasterKeyIfMissing(backup.seedrMasterKey)
                injectRestoredSocialCookies()
                true
            }
        } catch (_: Throwable) {
            false
        }
    }

    private suspend fun injectRestoredSocialCookies() = withContext(Dispatchers.Main) {
        val cm = CookieManager.getInstance()
        cm.setAcceptCookie(true)
        val x = UserStore.shared.data.value.xSession
        if (x.isConnected) {
            for ((k, v) in listOf("auth_token" to x.authToken, "ct0" to x.ct0)) {
                if (v.isNotEmpty()) {
                    cm.setCookie("https://x.com", "$k=$v; Path=/; Secure")
                    cm.setCookie("https://twitter.com", "$k=$v; Path=/; Secure")
                }
            }
        }
        val ig = UserStore.shared.data.value.igSession
        if (ig.isConnected) {
            for ((k, v) in listOf("sessionid" to ig.sessionId, "csrftoken" to ig.csrfToken, "ds_user_id" to ig.userId)) {
                if (v.isNotEmpty()) {
                    cm.setCookie("https://www.instagram.com", "$k=$v; Path=/; Secure")
                }
            }
        }
        cm.flush()
    }

    suspend fun syncBidirectionalBackup(): String {
        val ok = restoreEncryptedBackupIfPresent()
        if (!ok) return "Sync paused: couldn't restore cloud backup (kept cloud data safe)."
        val d = UserStore.shared.data.value
        val hasData = d.liked.isNotEmpty() || d.downloaded.isNotEmpty() || d.xSession.isConnected ||
            d.igSession.isConnected || d.followedUsers.isNotEmpty() || d.followedXUsers.isNotEmpty() ||
            d.followedIGUsers.isNotEmpty() || d.followedSubreddits.isNotEmpty() || d.followedOFCreators.isNotEmpty()
        if (hasData) syncEncryptedBackupNow()
        val parts = mutableListOf("${d.liked.size} likes", "${d.downloaded.size} saved")
        if (d.xSession.isConnected) parts.add("X login")
        if (d.igSession.isConnected) parts.add("IG login")
        return "Synced: ${parts.joinToString(" · ")}"
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
                client.newCall(req).execute().use { resp ->
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
    val status by LicenseManager.status.collectAsState()
    val isChecking by LicenseManager.isChecking.collectAsState()
    val errMsg by LicenseManager.errorMessage.collectAsState()
    val scope = rememberCoroutineScope()
    var keyInput by remember { mutableStateOf(status.licenseKey) }

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
                            if (LicenseManager.activate(keyInput)) {
                                onActivated()
                            }
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
            }
        }
    }
}
