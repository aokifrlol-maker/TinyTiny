package com.bella.tinytiny

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.TimeUnit

@Serializable
data class LicenseStatus(
    val licenseKey: String = "",
    val expiresAt: Long? = null,
    val isLifetime: Boolean = false,
    val durationLabel: String = "",
    val isActivated: Boolean = false,
    val isExpiredOrRevoked: Boolean = false,
    val lastVerifiedAt: Long = 0L
)

object LicenseManager {
    private const val DEFAULT_SERVER_URL = "https://tinytiny-license.aokifrlol.workers.dev"
    private const val PREFS_NAME = "tinytiny_license_v1"
    private const val KEY_STATUS = "status_json"
    private const val KEY_DEVICE_ID = "device_id"

    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val client = OkHttpClient.Builder()
        .connectTimeout(12, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS)
        .build()

    private val _status = MutableStateFlow(LicenseStatus())
    val status = _status.asStateFlow()

    private val _isChecking = MutableStateFlow(false)
    val isChecking = _isChecking.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage = _errorMessage.asStateFlow()

    private lateinit var appContext: Context
    lateinit var deviceId: String
        private set

    val normalizedBaseURL: String
        get() = DEFAULT_SERVER_URL

    val isValidAccess: Boolean
        get() {
            val s = _status.value
            if (!s.isActivated || s.isExpiredOrRevoked) return false
            if (s.isLifetime) return true
            val exp = s.expiresAt ?: return true
            return (System.currentTimeMillis() / 1000L) < exp
        }

    fun init(context: Context) {
        appContext = context.applicationContext
        val prefs = appContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val existingId = prefs.getString(KEY_DEVICE_ID, null)
        deviceId = if (!existingId.isNullOrBlank()) {
            existingId
        } else {
            val fresh = UUID.randomUUID().toString()
            prefs.edit().putString(KEY_DEVICE_ID, fresh).apply()
            fresh
        }
        val rawStatus = prefs.getString(KEY_STATUS, null)
        if (!rawStatus.isNullOrBlank()) {
            runCatching {
                _status.value = json.decodeFromString<LicenseStatus>(rawStatus)
            }
        }
    }

    private fun saveStatus(s: LicenseStatus) {
        _status.value = s
        if (::appContext.isInitialized) {
            appContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_STATUS, json.encodeToString(s))
                .apply()
        }
    }

    fun clearLicense() {
        _errorMessage.value = null
        saveStatus(LicenseStatus())
    }

    suspend fun activate(rawKey: String): Boolean = withContext(Dispatchers.IO) {
        val clean = rawKey.trim().uppercase()
        if (clean.isEmpty()) {
            _errorMessage.value = "Enter a license key."
            return@withContext false
        }
        _isChecking.value = true
        _errorMessage.value = null
        try {
            val bodyJson = JSONObject().apply {
                put("key", clean)
                put("deviceId", deviceId)
            }.toString()
            val req = Request.Builder()
                .url("$normalizedBaseURL/v1/activate")
                .post(bodyJson.toRequestBody("application/json".toMediaType()))
                .build()
            client.newCall(req).execute().use { resp ->
                val text = resp.body?.string().orEmpty()
                val obj = runCatching { JSONObject(text) }.getOrNull()
                if (resp.isSuccessful && obj?.optBoolean("valid", false) == true) {
                    val exp = if (obj.has("expiresAt") && !obj.isNull("expiresAt")) obj.optLong("expiresAt") else null
                    val life = obj.optBoolean("isLifetime", exp == null)
                    val label = obj.optString("durationLabel", if (life) "Lifetime" else "Active")
                    saveStatus(
                        LicenseStatus(
                            licenseKey = clean,
                            expiresAt = exp,
                            isLifetime = life,
                            durationLabel = label,
                            isActivated = true,
                            isExpiredOrRevoked = false,
                            lastVerifiedAt = System.currentTimeMillis() / 1000L
                        )
                    )
                    return@withContext true
                } else {
                    _errorMessage.value = obj?.optString("error")?.takeIf { it.isNotBlank() }
                        ?: "Invalid or already bound license key."
                    return@withContext false
                }
            }
        } catch (e: Exception) {
            _errorMessage.value = "Could not reach license server."
            return@withContext false
        } finally {
            _isChecking.value = false
        }
    }

    suspend fun verifySilently() = withContext(Dispatchers.IO) {
        val key = _status.value.licenseKey
        if (key.isBlank()) return@withContext
        try {
            val bodyJson = JSONObject().apply {
                put("key", key)
                put("deviceId", deviceId)
            }.toString()
            val req = Request.Builder()
                .url("$normalizedBaseURL/v1/verify")
                .post(bodyJson.toRequestBody("application/json".toMediaType()))
                .build()
            client.newCall(req).execute().use { resp ->
                val text = resp.body?.string().orEmpty()
                val obj = runCatching { JSONObject(text) }.getOrNull() ?: return@withContext
                if (resp.isSuccessful && obj.optBoolean("valid", false)) {
                    val exp = if (obj.has("expiresAt") && !obj.isNull("expiresAt")) obj.optLong("expiresAt") else null
                    val life = obj.optBoolean("isLifetime", exp == null)
                    saveStatus(
                        _status.value.copy(
                            expiresAt = exp,
                            isLifetime = life,
                            isActivated = true,
                            isExpiredOrRevoked = false,
                            lastVerifiedAt = System.currentTimeMillis() / 1000L
                        )
                    )
                } else if (resp.code == 401 || resp.code == 403 || obj.has("error")) {
                    saveStatus(_status.value.copy(isActivated = false, isExpiredOrRevoked = true))
                }
            }
        } catch (_: Exception) {
        }
    }
}
