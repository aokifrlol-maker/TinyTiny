package com.bella.tinytiny

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.Base64
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.Send
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONObject
import java.io.File
import java.net.URI
import java.util.UUID

@Serializable
data class ShareDropPayload(
    val title: String? = null,
    val post: Gif? = null,
    val posts: List<Gif>? = null,
    val encryptedBlobUrl: String? = null,
    val fileExtension: String? = null
)

data class DirectIGDropPayload(
    val id: String,
    val videoUrl: String,
    val title: String,
    val referer: String?
)

object ShareService {
    private val client = TinyTinyApplication.sharedHttpClient

    val pendingReceivedPost = MutableStateFlow<Gif?>(null)
    val pendingReceivedPosts = MutableStateFlow<List<Gif>?>(null)
    val pendingReceivedTitle = MutableStateFlow<String?>(null)

    suspend fun createEncryptedShareLink(post: Gif): Pair<String, String>? = withContext(Dispatchers.IO) {
        val localUrl = OfflineManager.localMediaURL(post.id)
        if (localUrl != null && localUrl.startsWith("file://")) {
            val file = File(localUrl.removePrefix("file://"))
            if (file.exists() && file.length() in 1..(45L * 1024L * 1024L)) {
                val key = CryptoBox.generateKey()
                val encodedKey = CryptoBox.exportKeyBase64URL(key)
                val sealedBlob = CryptoBox.seal(file.readBytes(), key)
                val blobUrl = LicenseManager.uploadTemporaryEncryptedBlob(sealedBlob, file.name)
                if (!blobUrl.isNullOrEmpty()) {
                    val ext = file.extension.ifEmpty { "mp4" }
                    val payload = ShareDropPayload(
                        title = post.title ?: post.author,
                        encryptedBlobUrl = blobUrl,
                        fileExtension = ext
                    )
                    val raw = CryptoBox.json.encodeToString(payload).toByteArray(Charsets.UTF_8)
                    val sealed = CryptoBox.seal(raw, key)
                    val b64 = Base64.encodeToString(sealed, Base64.NO_WRAP)
                    try {
                        val bodyJson = JSONObject().apply {
                            put("key", LicenseManager.status.value.licenseKey)
                            put("cipher", b64)
                        }.toString()
                        val req = Request.Builder()
                            .url("${LicenseManager.normalizedBaseURL}/v1/share")
                            .post(bodyJson.toRequestBody("application/json".toMediaType()))
                            .build()
                        client.newCall(req).execute().use { resp ->
                            if (resp.code == 200) {
                                val shareId = JSONObject(resp.body?.string() ?: "").optString("id")
                                if (shareId.isNotEmpty()) {
                                    return@withContext "tinytiny://drop/$shareId#k=$encodedKey" to "TTDROP:$shareId.$encodedKey"
                                }
                            }
                        }
                    } catch (_: Throwable) {}
                }
            }
        }
        val payload = ShareDropPayload(title = post.title ?: post.author, post = post)
        sealAndPublishPayload(payload)
    }

    suspend fun createEncryptedCollectionShareLink(posts: List<Gif>, title: String? = null): Pair<String, String>? {
        val payload = ShareDropPayload(title = title ?: "${posts.size} Shared Clips", posts = posts)
        return sealAndPublishPayload(payload)
    }

    private suspend fun sealAndPublishPayload(payload: ShareDropPayload): Pair<String, String>? = withContext(Dispatchers.IO) {
        val key = CryptoBox.generateKey()
        val encodedKey = CryptoBox.exportKeyBase64URL(key)
        val raw = CryptoBox.json.encodeToString(payload).toByteArray(Charsets.UTF_8)
        val sealed = CryptoBox.seal(raw, key)
        val b64 = Base64.encodeToString(sealed, Base64.NO_WRAP)

        try {
            val bodyJson = JSONObject().apply {
                put("key", LicenseManager.status.value.licenseKey)
                put("cipher", b64)
            }.toString()
            val req = Request.Builder()
                .url("${LicenseManager.normalizedBaseURL}/v1/share")
                .post(bodyJson.toRequestBody("application/json".toMediaType()))
                .build()
            client.newCall(req).execute().use { resp ->
                if (resp.code == 200) {
                    val shareId = JSONObject(resp.body?.string() ?: "").optString("id")
                    if (shareId.isNotEmpty()) {
                        return@withContext "tinytiny://drop/$shareId#k=$encodedKey" to "TTDROP:$shareId.$encodedKey"
                    }
                }
            }
        } catch (_: Throwable) {}

        val b64Url = Base64.encodeToString(sealed, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
        "tinytiny://drop/inline?p=$b64Url#k=$encodedKey" to "TTPOST:$b64Url.$encodedKey"
    }

    suspend fun handleIncomingShare(raw: String): String? = withContext(Dispatchers.IO) {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return@withContext "Empty share link or code."

        if (trimmed.startsWith("TTPOST:")) {
            val parts = trimmed.removePrefix("TTPOST:").split(".", limit = 2)
            if (parts.size != 2) return@withContext "Invalid share code."
            val key = CryptoBox.importKeyBase64URL(parts[1]) ?: return@withContext "Invalid key."
            val cipher = decodeBase64URL(parts[0]) ?: return@withContext "Invalid capsule."
            val plain = try { CryptoBox.open(cipher, key) } catch (_: Throwable) { return@withContext "Could not decrypt share capsule." }
            val payload = try { CryptoBox.json.decodeFromString<ShareDropPayload>(String(plain, Charsets.UTF_8)) } catch (_: Throwable) { return@withContext "Invalid payload." }
            return@withContext openDecryptedPayload(payload, key)
        }

        var shareId = ""
        var keyStr = ""
        var inlineCipher = ""

        if (trimmed.startsWith("TTDROP:")) {
            val parts = trimmed.removePrefix("TTDROP:").split(".", limit = 2)
            if (parts.size == 2) { shareId = parts[0]; keyStr = parts[1] }
        } else {
            try {
                val uri = Uri.parse(trimmed)
                val frag = uri.fragment ?: ""
                if (frag.startsWith("k=")) keyStr = frag.removePrefix("k=")
                if (keyStr.isEmpty()) keyStr = uri.getQueryParameter("k") ?: ""
                inlineCipher = uri.getQueryParameter("p") ?: ""
                val last = uri.lastPathSegment ?: ""
                if (last.isNotEmpty() && last != "inline") shareId = last
            } catch (_: Throwable) {}
        }

        val key = CryptoBox.importKeyBase64URL(keyStr) ?: return@withContext "Missing or invalid decryption key."

        if (inlineCipher.isNotEmpty()) {
            val cipher = decodeBase64URL(inlineCipher)
            if (cipher != null) {
                try {
                    val plain = CryptoBox.open(cipher, key)
                    val payload = CryptoBox.json.decodeFromString<ShareDropPayload>(String(plain, Charsets.UTF_8))
                    return@withContext openDecryptedPayload(payload, key)
                } catch (_: Throwable) {}
            }
        }

        if (shareId.isEmpty()) return@withContext "Share drop not found."
        try {
            val req = Request.Builder().url("${LicenseManager.normalizedBaseURL}/v1/share/$shareId").build()
            client.newCall(req).execute().use { resp ->
                if (resp.code != 200) return@withContext "Share drop not found or expired."
                val b64 = JSONObject(resp.body?.string() ?: "").optString("cipher")
                val cipher = Base64.decode(b64, Base64.DEFAULT)
                val plain = CryptoBox.open(cipher, key)
                val payload = CryptoBox.json.decodeFromString<ShareDropPayload>(String(plain, Charsets.UTF_8))
                openDecryptedPayload(payload, key)
            }
        } catch (_: Throwable) {
            "Share drop not found or expired."
        }
    }

    private fun openDecryptedPayload(payload: ShareDropPayload, key: ByteArray): String? {
        if (!payload.posts.isNullOrEmpty()) {
            pendingReceivedPosts.value = payload.posts
            pendingReceivedPost.value = null
            pendingReceivedTitle.value = payload.title
            return null
        }
        if (payload.post != null) {
            pendingReceivedPost.value = payload.post
            pendingReceivedPosts.value = null
            pendingReceivedTitle.value = payload.title
            return null
        }
        val blobStr = payload.encryptedBlobUrl
        if (!blobStr.isNullOrEmpty()) {
            try {
                val u = URI(blobStr)
                val expectedHost = URI(LicenseManager.normalizedBaseURL).host
                if (u.scheme == "https" && u.host == expectedHost && (u.path ?: "").startsWith("/v1/blob/")) {
                    val req = Request.Builder().url(blobStr).build()
                    client.newCall(req).execute().use { resp ->
                        if (resp.code == 200) {
                            val cipher = resp.body?.bytes() ?: return "Empty blob."
                            val plainBytes = CryptoBox.open(cipher, key)
                            val safeExt = (payload.fileExtension ?: "mp4").lowercase().filter { it.isLetterOrDigit() }.take(8).ifEmpty { "mp4" }
                            val local = File(TinyTinyApplication.instance.cacheDir, "tt_drop_${UUID.randomUUID().toString().take(8)}.$safeExt")
                            local.writeBytes(plainBytes)
                            val localStr = "file://${local.absolutePath}"
                            val synth = Gif(
                                id = "drop_${UUID.randomUUID().toString().take(8)}",
                                title = payload.title,
                                author = "Shared Drop",
                                subreddit = "Drop",
                                mediaType = if (safeExt in setOf("jpg", "jpeg", "png", "webp")) "image" else "video",
                                mediaUrl = localStr,
                                muxedUrl = localStr,
                                muxedUrlHd = localStr,
                                sourceUrl = localStr,
                                permalink = localStr
                            )
                            pendingReceivedPost.value = synth
                            pendingReceivedTitle.value = payload.title
                            return null
                        }
                    }
                }
            } catch (_: Throwable) {}
        }
        return "Shared drop has no playable content."
    }

    private fun decodeBase64URL(token: String): ByteArray? {
        return try {
            val clean = token.replace("-", "+").replace("_", "/")
            val padded = clean + "=".repeat((4 - clean.length % 4) % 4)
            Base64.decode(padded, Base64.DEFAULT)
        } catch (_: Throwable) {
            null
        }
    }

    suspend fun fetchDirectIGDrop(dropId: String): DirectIGDropPayload? = withContext(Dispatchers.IO) {
        try {
            val req = Request.Builder().url("${LicenseManager.normalizedBaseURL}/v1/igdrop/$dropId").build()
            client.newCall(req).execute().use { resp ->
                if (resp.code != 200) return@withContext null
                val json = JSONObject(resp.body?.string() ?: return@withContext null)
                val mp4 = json.optString("mp4Url").takeIf { it.isNotEmpty() } ?: return@withContext null
                val title = json.optString("title", "Video")
                val ref = MediaHeaders.headers(mp4)["Referer"]
                DirectIGDropPayload(dropId, mp4, title, ref)
            }
        } catch (_: Throwable) {
            null
        }
    }
}

@Composable
fun ShareItemSheet(gif: Gif, onDismiss: () -> Unit) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    val settings by UserStore.shared.data.collectAsState()
    var link by remember { mutableStateOf<String?>(null) }
    var code by remember { mutableStateOf<String?>(null) }
    var copied by remember { mutableStateOf(false) }

    LaunchedEffect(gif.id) {
        val res = ShareService.createEncryptedShareLink(gif)
        link = res?.first
        code = res?.second
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .liquidGlassBackground(tinted = settings.settings.tintedGlass)
            .statusBarsPadding()
            .navigationBarsPadding()
            .padding(20.dp)
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Default.Lock, contentDescription = null, tint = Theme.accentBright)
                Spacer(Modifier.width(8.dp))
                Text("Encrypted Drop Share", color = Color.White, fontSize = 19.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.weight(1f))
                IconButton(onClick = onDismiss) { Icon(Icons.Default.Close, contentDescription = "Close", tint = Color.White) }
            }
            Text("End-to-end AES-256-GCM encrypted. Key stays in link fragment.", color = Theme.textSecondary, fontSize = 12.5.sp)

            if (link == null) {
                CircularProgressIndicator(color = Theme.accentBright)
            } else {
                Column(modifier = Modifier.fillMaxWidth().liquidGlassCard(cornerRadius = 16.dp).padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(code ?: "", color = Color.White, fontSize = 12.sp, maxLines = 2)
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        Button(
                            onClick = {
                                val cm = ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                                cm.setPrimaryClip(ClipData.newPlainText("TinyTiny Drop", code ?: link))
                                copied = true
                            },
                            colors = ButtonDefaults.buttonColors(containerColor = Theme.accent)
                        ) {
                            Icon(Icons.Default.ContentCopy, contentDescription = null, modifier = Modifier.size(16.dp))
                            Spacer(Modifier.width(6.dp))
                            Text(if (copied) "Copied!" else "Copy Code")
                        }
                        OutlinedButton(onClick = {
                            val send = Intent(Intent.ACTION_SEND).apply {
                                type = "text/plain"
                                putExtra(Intent.EXTRA_TEXT, link ?: code)
                            }
                            ctx.startActivity(Intent.createChooser(send, "Share Drop"))
                        }) {
                            Text("Share Link", color = Color.White)
                        }
                    }
                }
            }
        }
    }
}

@Composable
fun ShareCollectionSheet(posts: List<Gif>, title: String? = null, onDismiss: () -> Unit) {
    val ctx = LocalContext.current
    val settings by UserStore.shared.data.collectAsState()
    var link by remember { mutableStateOf<String?>(null) }
    var code by remember { mutableStateOf<String?>(null) }
    var copied by remember { mutableStateOf(false) }

    LaunchedEffect(posts) {
        val res = ShareService.createEncryptedCollectionShareLink(posts, title)
        link = res?.first
        code = res?.second
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .liquidGlassBackground(tinted = settings.settings.tintedGlass)
            .statusBarsPadding()
            .navigationBarsPadding()
            .padding(20.dp)
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Default.Lock, contentDescription = null, tint = Theme.accentBright)
                Spacer(Modifier.width(8.dp))
                Text("Share ${posts.size} Clips", color = Color.White, fontSize = 19.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.weight(1f))
                IconButton(onClick = onDismiss) { Icon(Icons.Default.Close, contentDescription = "Close", tint = Color.White) }
            }
            Text("End-to-end AES-256-GCM encrypted collection drop.", color = Theme.textSecondary, fontSize = 12.5.sp)

            if (link == null) {
                CircularProgressIndicator(color = Theme.accentBright)
            } else {
                Column(modifier = Modifier.fillMaxWidth().liquidGlassCard(cornerRadius = 16.dp).padding(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(code ?: "", color = Color.White, fontSize = 12.sp, maxLines = 2)
                    Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        Button(
                            onClick = {
                                val cm = ctx.getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                                cm.setPrimaryClip(ClipData.newPlainText("TinyTiny Collection", code ?: link))
                                copied = true
                            },
                            colors = ButtonDefaults.buttonColors(containerColor = Theme.accent)
                        ) {
                            Icon(Icons.Default.ContentCopy, contentDescription = null, modifier = Modifier.size(16.dp))
                            Spacer(Modifier.width(6.dp))
                            Text(if (copied) "Copied!" else "Copy Code")
                        }
                        OutlinedButton(onClick = {
                            val send = Intent(Intent.ACTION_SEND).apply {
                                type = "text/plain"
                                putExtra(Intent.EXTRA_TEXT, link ?: code)
                            }
                            ctx.startActivity(Intent.createChooser(send, "Share Collection"))
                        }) {
                            Text("Share Link", color = Color.White)
                        }
                    }
                }
            }
        }
    }
}

@Composable
fun ReceiveDropSheet(onDismiss: () -> Unit) {
    val scope = rememberCoroutineScope()
    val settings by UserStore.shared.data.collectAsState()
    var input by remember { mutableStateOf("") }
    var err by remember { mutableStateOf<String?>(null) }
    var loading by remember { mutableStateOf(false) }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .liquidGlassBackground(tinted = settings.settings.tintedGlass)
            .statusBarsPadding()
            .navigationBarsPadding()
            .padding(20.dp)
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("Open Encrypted Drop", color = Color.White, fontSize = 19.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.weight(1f))
                IconButton(onClick = onDismiss) { Icon(Icons.Default.Close, contentDescription = "Close", tint = Color.White) }
            }
            OutlinedTextField(
                value = input,
                onValueChange = { input = it },
                placeholder = { Text("Paste TTDROP:, TTPOST:, or tinytiny:// link") },
                modifier = Modifier.fillMaxWidth()
            )
            err?.let { Text(it, color = Color(0xFFFF6B6B), fontSize = 13.sp) }
            Button(
                onClick = {
                    scope.launch {
                        loading = true
                        err = ShareService.handleIncomingShare(input)
                        loading = false
                        if (err == null) onDismiss()
                    }
                },
                enabled = !loading && input.trim().isNotEmpty(),
                colors = ButtonDefaults.buttonColors(containerColor = Theme.accent),
                modifier = Modifier.fillMaxWidth()
            ) {
                if (loading) CircularProgressIndicator(color = Color.White, modifier = Modifier.size(18.dp))
                else Text("Decrypt & Open", fontWeight = FontWeight.Bold)
            }
        }
    }
}

@Composable
fun IGDirectSendSheet(payload: DirectIGDropPayload, onDismiss: () -> Unit) {
    val scope = rememberCoroutineScope()
    val settings by UserStore.shared.data.collectAsState()
    var threads by remember { mutableStateOf<List<InstagramWebEngine.IGDirectThread>>(emptyList()) }
    var loading by remember { mutableStateOf(true) }
    var sendingId by remember { mutableStateOf<String?>(null) }
    var statusMsg by remember { mutableStateOf<String?>(null) }
    var errorMsg by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(payload.id) {
        threads = InstagramWebEngine.fetchDirectInboxThreads()
        loading = false
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .liquidGlassBackground(tinted = settings.settings.tintedGlass)
            .statusBarsPadding()
            .navigationBarsPadding()
            .padding(20.dp)
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Column(modifier = Modifier.weight(1f)) {
                    Text("Send MP4 to Instagram", color = Color.White, fontSize = 19.sp, fontWeight = FontWeight.Bold)
                    Text(payload.title, color = Theme.textSecondary, fontSize = 12.sp, maxLines = 1)
                }
                IconButton(onClick = onDismiss) { Icon(Icons.Default.Close, contentDescription = "Close", tint = Color.White) }
            }

            statusMsg?.let { Text(it, color = Color(0xFF4ADE80), fontWeight = FontWeight.Bold) }
            errorMsg?.let { Text(it, color = Color(0xFFFF6B6B), fontSize = 12.sp) }

            if (loading) {
                Box(Modifier.fillMaxWidth().padding(32.dp), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = Theme.accentBright)
                }
            } else if (threads.isEmpty()) {
                Text("No Instagram chats loaded. Make sure you are signed into Instagram.", color = Theme.textSecondary)
            } else {
                LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    items(threads, key = { it.id }) { t ->
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .liquidGlassCard(cornerRadius = 14.dp, tinted = settings.settings.tintedGlass)
                                .clickable(enabled = sendingId == null) {
                                    scope.launch {
                                        sendingId = t.id
                                        errorMsg = null
                                        val res = InstagramWebEngine.sendVideoToDirectThread(t.id, payload.videoUrl, payload.referer, payload.title)
                                        sendingId = null
                                        res.onSuccess { statusMsg = "Sent to ${t.title}!" }
                                            .onFailure { errorMsg = it.localizedMessage ?: "Send failed" }
                                    }
                                }
                                .padding(14.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text(t.title, color = Color.White, fontWeight = FontWeight.Bold)
                                Text(t.subtitle, color = Theme.textSecondary, fontSize = 12.sp)
                            }
                            if (sendingId == t.id) {
                                CircularProgressIndicator(color = Theme.accentBright, modifier = Modifier.size(18.dp))
                            } else {
                                Icon(Icons.Default.Send, contentDescription = "Send", tint = Theme.accentBright)
                            }
                        }
                    }
                }
            }
        }
    }
}
