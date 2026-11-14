package com.bella.tinytiny

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
import java.util.concurrent.TimeUnit

@Serializable
data class ShareDropPayload(
    val kind: String,
    val title: String? = null,
    val post: Gif? = null,
    val posts: List<Gif>? = null,
    val fileName: String? = null,
    val fileExtension: String? = null,
    val encryptedBlobUrl: String? = null
)

object ShareService {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = false }
    private val client = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(20, TimeUnit.SECONDS)
        .build()

    private val _pendingPost = MutableStateFlow<Gif?>(null)
    val pendingPost = _pendingPost.asStateFlow()

    private val _pendingPosts = MutableStateFlow<List<Gif>?>(null)
    val pendingPosts = _pendingPosts.asStateFlow()

    private val _pendingTitle = MutableStateFlow<String?>(null)
    val pendingTitle = _pendingTitle.asStateFlow()

    fun consumePending() {
        _pendingPost.value = null
        _pendingPosts.value = null
        _pendingTitle.value = null
    }

    suspend fun createEncryptedShareLink(post: Gif): Pair<String, String>? {
        val payload = ShareDropPayload(kind = "post", title = post.title ?: post.author, post = post)
        return sealAndPublishPayload(payload)
    }

    suspend fun createEncryptedCollectionShareLink(posts: List<Gif>, title: String? = null): Pair<String, String>? {
        val slice = posts.take(60)
        if (slice.isEmpty()) return null
        val label = title?.trim()?.takeIf { it.isNotBlank() } ?: "Shared Collection (${slice.size})"
        val payload = ShareDropPayload(kind = "collection", title = label, posts = slice)
        return sealAndPublishPayload(payload)
    }

    private suspend fun sealAndPublishPayload(payload: ShareDropPayload): Pair<String, String>? = withContext(Dispatchers.IO) {
        val key = CryptoBox.generateKey()
        val encodedKey = CryptoBox.exportKeyBase64URL(key)
        val rawJson = json.encodeToString(payload).toByteArray(Charsets.UTF_8)
        val sealed = CryptoBox.seal(rawJson, key)
        val b64 = android.util.Base64.encodeToString(sealed, android.util.Base64.NO_WRAP)

        try {
            val reqBody = JSONObject().apply {
                put("key", LicenseManager.status.value.licenseKey)
                put("cipher", b64)
            }.toString()
            val req = Request.Builder()
                .url("${LicenseManager.normalizedBaseURL}/v1/share")
                .post(reqBody.toRequestBody("application/json".toMediaType()))
                .build()
            client.newCall(req).execute().use { resp ->
                if (resp.isSuccessful) {
                    val obj = JSONObject(resp.body?.string().orEmpty())
                    val id = obj.optString("id")
                    if (id.isNotBlank()) {
                        val code = "TTDROP:$id.$encodedKey"
                        val link = "tinytiny://drop/$id#k=$encodedKey"
                        return@withContext link to code
                    }
                }
            }
        } catch (_: Exception) {
        }

        val b64Url = CryptoBox.encodeBase64URL(sealed)
        val code = "TTPOST:$b64Url.$encodedKey"
        val link = "tinytiny://drop/inline?p=$b64Url#k=$encodedKey"
        return@withContext link to code
    }

    suspend fun handleIncomingShare(raw: String): String? = withContext(Dispatchers.IO) {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return@withContext "Empty share link or code."

        if (trimmed.startsWith("TTPOST:")) {
            val parts = trimmed.removePrefix("TTPOST:").split(".", limit = 2)
            if (parts.size != 2) return@withContext "Invalid share capsule."
            val key = CryptoBox.importKeyBase64URL(parts[1]) ?: return@withContext "Invalid key."
            val cipher = CryptoBox.decodeBase64URL(parts[0])
            val plain = CryptoBox.open(cipher, key) ?: return@withContext "Could not decrypt share capsule."
            val payload = runCatching { json.decodeFromString<ShareDropPayload>(String(plain)) }.getOrNull()
                ?: return@withContext "Corrupt share payload."
            return@withContext openPayload(payload)
        }

        var shareId = ""
        var keyStr = ""
        var inlineCipher = ""

        if (trimmed.startsWith("TTDROP:")) {
            val parts = trimmed.removePrefix("TTDROP:").split(".", limit = 2)
            if (parts.size == 2) {
                shareId = parts[0]
                keyStr = parts[1]
            }
        } else {
            runCatching {
                val uri = android.net.Uri.parse(trimmed)
                val frag = uri.fragment.orEmpty()
                if (frag.startsWith("k=")) keyStr = frag.removePrefix("k=")
                if (keyStr.isBlank()) keyStr = uri.getQueryParameter("k").orEmpty()
                inlineCipher = uri.getQueryParameter("p").orEmpty()
                val seg = uri.lastPathSegment.orEmpty()
                if (seg.isNotBlank() && seg != "inline") shareId = seg
            }
        }

        val key = CryptoBox.importKeyBase64URL(keyStr) ?: return@withContext "Missing or invalid decryption key."
        if (inlineCipher.isNotBlank()) {
            val cipher = CryptoBox.decodeBase64URL(inlineCipher)
            val plain = CryptoBox.open(cipher, key)
            val payload = plain?.let { runCatching { json.decodeFromString<ShareDropPayload>(String(it)) }.getOrNull() }
            if (payload != null) return@withContext openPayload(payload)
        }

        if (shareId.isBlank()) return@withContext "Invalid drop ID."
        return@withContext try {
            val req = Request.Builder()
                .url("${LicenseManager.normalizedBaseURL}/v1/share/$shareId")
                .get()
                .build()
            client.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) return@withContext "Share drop not found or expired."
                val obj = JSONObject(resp.body?.string().orEmpty())
                val b64 = obj.optString("cipher")
                val cipher = android.util.Base64.decode(b64, android.util.Base64.DEFAULT)
                val plain = CryptoBox.open(cipher, key) ?: return@withContext "Decryption failed."
                val payload = json.decodeFromString<ShareDropPayload>(String(plain))
                openPayload(payload)
            }
        } catch (_: Exception) {
            "Could not fetch share drop."
        }
    }

    private fun openPayload(payload: ShareDropPayload): String? {
        if (!payload.posts.isNullOrEmpty()) {
            _pendingPosts.value = payload.posts
            _pendingPost.value = null
            _pendingTitle.value = payload.title
            return null
        }
        if (payload.post != null) {
            _pendingPost.value = payload.post
            _pendingPosts.value = null
            _pendingTitle.value = payload.title
            return null
        }
        return "Empty share payload."
    }
}
