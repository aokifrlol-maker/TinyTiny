package com.bella.tinytiny

import android.annotation.SuppressLint
import android.webkit.CookieManager
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Key
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import java.net.URLEncoder

@Serializable
data class Rule34Credentials(
    val userId: String = "",
    val apiKey: String = "",
    val customUserId: String = "",
    val useCustomCredentials: Boolean = false
) {
    val hasCustomCredentials: Boolean
        get() = (userId.trim().isNotEmpty() && apiKey.trim().isNotEmpty()) ||
            (useCustomCredentials && customUserId.trim().isNotEmpty() && apiKey.trim().isNotEmpty())

    // Built-in default credentials mean Rule34.xxx DAPI works out of the box just like iOS!
    val isConnected: Boolean get() = effectiveUserId.isNotEmpty() && effectiveApiKey.isNotEmpty()

    val effectiveUserId: String
        get() = if (hasCustomCredentials) userId.trim().ifEmpty { customUserId.trim() } else defaultUserId

    val effectiveApiKey: String
        get() = if (hasCustomCredentials) apiKey.trim() else defaultApiKey

    companion object {
        private val mask = intArrayOf(0x5A, 0x3D, 0x71, 0xA4, 0x2F, 0x91, 0xC6, 0x18)
        private val defaultUidBytes = intArrayOf(0x6D, 0x0D, 0x45, 0x93, 0x17, 0xA4, 0xFF)
        private val defaultKeyBytes = intArrayOf(
            0x3F, 0x5E, 0x12, 0xC7, 0x4D, 0xA7, 0xF4, 0x7A, 0x38, 0x5B, 0x17, 0x91, 0x19, 0xF0, 0xA5, 0x2D,
            0x38, 0x5F, 0x12, 0x90, 0x16, 0xF4, 0xFF, 0x2D, 0x6D, 0x5B, 0x17, 0x97, 0x16, 0xA1, 0xF3, 0x28,
            0x3F, 0x0A, 0x40, 0xC0, 0x4D, 0xF0, 0xA0, 0x7B, 0x6A, 0x59, 0x13, 0xC2, 0x17, 0xA0, 0xF3, 0x28,
            0x69, 0x08, 0x17, 0x97, 0x1E, 0xF5, 0xF6, 0x7B, 0x68, 0x0A, 0x49, 0x90, 0x1C, 0xF7, 0xA0, 0x2C,
            0x68, 0x59, 0x13, 0x95, 0x18, 0xF4, 0xF0, 0x29, 0x68, 0x58, 0x43, 0xC5, 0x4B, 0xF3, 0xF1, 0x20,
            0x6E, 0x0B, 0x46, 0xC1, 0x16, 0xA3, 0xA0, 0x7E, 0x38, 0x08, 0x14, 0x95, 0x1E, 0xA9, 0xA7, 0x29,
            0x6D, 0x0E, 0x15, 0xC1, 0x1E, 0xA7, 0xF3, 0x2D, 0x3C, 0x0D, 0x43, 0x96, 0x4D, 0xA3, 0xF0, 0x7E,
            0x62, 0x5F, 0x46, 0x90, 0x4B, 0xA8, 0xF4, 0x2D, 0x63, 0x04, 0x14, 0x96, 0x4C, 0xA9, 0xF5, 0x2B
        )

        private fun decode(bytes: IntArray): String {
            val out = ByteArray(bytes.size)
            for (i in bytes.indices) out[i] = (bytes[i] xor mask[i % mask.size]).toByte()
            return String(out, Charsets.UTF_8)
        }

        val defaultUserId: String by lazy { decode(defaultUidBytes) }
        val defaultApiKey: String by lazy { decode(defaultKeyBytes) }
    }
}

@Serializable
data class Rule34TagSuggestion(
    val label: String = "",
    val value: String = "",
    val type: String? = null
) {
    val id: String get() = value
}

object Rule34API {
    private val client = TinyTinyApplication.sharedHttpClient

    fun parseTags(raw: String): List<String> {
        return raw.trim()
            .split(Regex("\\s+"))
            .map {
                it.replace("#", "")
                    .replace(Regex("(?i)r34:"), "")
                    .lowercase()
            }
            .filter { it.isNotEmpty() }
    }

    private fun normalizeHTTPS(raw: String?): String? {
        if (raw.isNullOrBlank()) return null
        val t = raw.trim()
        return when {
            t.startsWith("//") -> "https:$t"
            t.startsWith("http://") -> "https://${t.removePrefix("http://")}"
            else -> t
        }
    }

    suspend fun autocomplete(rawQuery: String): List<Rule34TagSuggestion> = withContext(Dispatchers.IO) {
        val activeWord = parseTags(rawQuery).lastOrNull() ?: return@withContext emptyList()
        try {
            val enc = URLEncoder.encode(activeWord, "UTF-8")
            val req = Request.Builder()
                .url("https://api.rule34.xxx/autocomplete.php?q=$enc")
                .header("User-Agent", "GoonedR34Client/2.0 (iOS; Mobile)")
                .build()
            client.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) return@withContext emptyList()
                val body = resp.body?.string() ?: return@withContext emptyList()
                CryptoBox.json.decodeFromString<List<Rule34TagSuggestion>>(body)
            }
        } catch (_: Throwable) {
            emptyList()
        }
    }

    suspend fun fetchFeed(
        tag: String?,
        sort: String,
        after: String?,
        credentials: Rule34Credentials
    ): GoonedFeedResponse = coroutineScope {
        val page = after?.toIntOrNull() ?: 0
        val tags = parseTags(tag ?: "")
        val algo = UserStore.shared.data.value.algorithm
        val engine = SmartTasteEngine.shared
        val combinedBlocked = (algo.blockedTags.map { it.lowercase() } + engine.state.value.suppressedTags).toMutableSet()
        val pinnedLower = algo.boostedTags.map { it.lowercase() }.toSet()
        if ((combinedBlocked.contains("gay") || combinedBlocked.contains("men") || combinedBlocked.contains("yaoi")) &&
            !pinnedLower.contains("gay") && !pinnedLower.contains("yaoi")
        ) {
            combinedBlocked.addAll(listOf("gay", "yaoi", "bara", "male_only", "males_only"))
        }
        val pinned = algo.boostedTags.filter { !MediaMetaRegistry.isStopTag(it) }
        val tasteTags = if (pinned.isNotEmpty()) pinned else engine.activeQueryTags(algo.boostedTags, algo.blockedTags, 6)
        val blocked = combinedBlocked.toList()
        val cleanTagString = tags.joinToString(" ")

        val combined = mutableListOf<Gif>()
        val seen = mutableSetOf<String>()

        if (credentials.isConnected) {
            val activeTasteTag = if (cleanTagString.isEmpty() && tasteTags.isNotEmpty()) {
                tasteTags[page % tasteTags.size].replace(" ", "_")
            } else null

            if (activeTasteTag != null) {
                val tasteDeferred = async { fetchDirectRule34XXX(activeTasteTag, blocked, sort, page, credentials) }
                val mainDeferred = async { fetchDirectRule34XXX(cleanTagString, blocked, sort, page, credentials) }
                val tastePosts = tasteDeferred.await()
                val directPosts = mainDeferred.await()
                val maxLen = maxOf(tastePosts.size, directPosts.size)
                for (i in 0 until maxLen) {
                    if (i < tastePosts.size && seen.add(tastePosts[i].id)) combined.add(tastePosts[i])
                    if (i < directPosts.size && seen.add(directPosts[i].id)) combined.add(directPosts[i])
                }
            } else {
                val directPosts = fetchDirectRule34XXX(cleanTagString, blocked, sort, page, credentials)
                for (p in directPosts) if (seen.add(p.id)) combined.add(p)
            }
        }

        if (combined.size < 12) {
            val effectiveQuery = if (combined.isEmpty() && tags.size > 1) (tags.firstOrNull() ?: "") else cleanTagString
            val booruPosts = fetchZeroAuthBooru(effectiveQuery, blocked, page)
            for (p in booruPosts) if (seen.add(p.id)) combined.add(p)
        }

        GoonedFeedResponse(posts = combined, after = "${page + 1}")
    }

    private suspend fun fetchDirectRule34XXX(
        tag: String,
        blockedTags: List<String>,
        sort: String,
        page: Int,
        credentials: Rule34Credentials
    ): List<Gif> = withContext(Dispatchers.IO) {
        val tagParts = mutableListOf<String>()
        if (tag.isNotEmpty()) tagParts.add(tag)
        tagParts.add("-rating:safe")
        tagParts.add("-rating:questionable")
        for (b in blockedTags.take(8)) {
            if (b.isNotEmpty() && !tag.lowercase().contains(b.lowercase())) {
                tagParts.add("-${b.replace(" ", "_")}")
            }
        }
        if (sort == "top" || sort == "hot") tagParts.add("sort:score:desc")

        val ub = "https://api.rule34.xxx/index.php".toHttpUrlOrNull()!!.newBuilder()
            .addQueryParameter("page", "dapi")
            .addQueryParameter("s", "post")
            .addQueryParameter("q", "index")
            .addQueryParameter("json", "1")
            .addQueryParameter("limit", "40")
            .addQueryParameter("pid", "$page")
            .addQueryParameter("tags", tagParts.joinToString(" "))
            .addQueryParameter("user_id", credentials.effectiveUserId)
            .addQueryParameter("api_key", credentials.effectiveApiKey)

        try {
            val req = Request.Builder()
                .url(ub.build())
                .header("User-Agent", "GoonedR34Client/2.0 (iOS; Mobile)")
                .build()
            client.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) return@withContext emptyList()
                val body = resp.body?.string() ?: return@withContext emptyList()
                parseGelbooruStyleJSON(body, prefix = "r34", siteHost = "rule34.xxx")
            }
        } catch (_: Throwable) {
            emptyList()
        }
    }

    // Exact iOS Tier 2 Zero-Auth Booru engines: yande.re + hypnohub.net + realbooru.com (no unintended Reddit fallback)
    private suspend fun fetchZeroAuthBooru(
        tag: String,
        blockedTags: List<String>,
        page: Int
    ): List<Gif> = coroutineScope {
        val negBlock = blockedTags.take(5)
            .filter { it.isNotEmpty() && !tag.lowercase().contains(it.lowercase()) }
            .joinToString(" ") { "-${it.replace(" ", "_")}" }
        val yandeTags = (if (tag.isEmpty()) "order:score rating:e" else "$tag rating:e") +
            (if (negBlock.isEmpty()) "" else " $negBlock")
        val gelTags = (if (tag.isEmpty()) "-rating:safe -rating:questionable" else "$tag -rating:safe -rating:questionable") +
            (if (negBlock.isEmpty()) "" else " $negBlock")

        val hypnoDef = async {
            fetchRaw(
                "https://hypnohub.net/index.php",
                mapOf("page" to "dapi", "s" to "post", "q" to "index", "json" to "1", "limit" to "20", "pid" to "$page", "tags" to gelTags)
            ) { parseGelbooruStyleJSON(it, prefix = "r34h", siteHost = "hypnohub.net") }
        }
        val realDef = async {
            fetchRaw(
                "https://realbooru.com/index.php",
                mapOf("page" to "dapi", "s" to "post", "q" to "index", "json" to "1", "limit" to "20", "pid" to "$page", "tags" to gelTags)
            ) { parseGelbooruStyleJSON(it, prefix = "r34b", siteHost = "realbooru.com") }
        }
        val yandeDef = async {
            fetchRaw(
                "https://yande.re/post.json",
                mapOf("limit" to "20", "page" to "${page + 1}", "tags" to yandeTags)
            ) { parseMoebooruJSON(it, prefix = "r34y", siteHost = "yande.re") }
        }
        (hypnoDef.await() + realDef.await() + yandeDef.await()).distinctBy { it.id }
    }

    private suspend fun fetchRaw(base: String, query: Map<String, String>, parser: (String) -> List<Gif>): List<Gif> =
        withContext(Dispatchers.IO) {
            try {
                val ub = base.toHttpUrlOrNull()?.newBuilder() ?: return@withContext emptyList()
                for ((k, v) in query) ub.addQueryParameter(k, v)
                val req = Request.Builder()
                    .url(ub.build())
                    .header("User-Agent", "GoonedR34Client/2.0 (iOS; Mobile)")
                    .build()
                client.newCall(req).execute().use { resp ->
                    if (!resp.isSuccessful) return@withContext emptyList()
                    val body = resp.body?.string() ?: return@withContext emptyList()
                    parser(body)
                }
            } catch (_: Throwable) {
                emptyList()
            }
        }

    private fun parseGelbooruStyleJSON(body: String, prefix: String, siteHost: String): List<Gif> {
        val items: JSONArray = try {
            val trimmed = body.trim()
            if (trimmed.startsWith("[")) JSONArray(trimmed)
            else JSONObject(trimmed).optJSONArray("post") ?: return emptyList()
        } catch (_: Throwable) {
            return emptyList()
        }
        val posts = mutableListOf<Gif>()
        for (i in 0 until items.length()) {
            val item = items.optJSONObject(i) ?: continue
            val rating = item.optString("rating", "").lowercase()
            if (rating in setOf("s", "safe", "general")) continue
            val idVal = item.opt("id")?.toString() ?: continue
            val fileUrl = normalizeHTTPS(item.optString("file_url")) ?: continue
            val sampleUrl = normalizeHTTPS(item.optString("sample_url"))
            val previewUrl = normalizeHTTPS(item.optString("preview_url"))

            val filePath = fileUrl.lowercase().substringBefore('?')
            val samplePath = (sampleUrl ?: "").lowercase().substringBefore('?')
            val isGif = filePath.endsWith(".gif")
            val isMp4 = filePath.endsWith(".mp4") || filePath.endsWith(".m4v") || filePath.endsWith(".mov")
            val isWebm = filePath.endsWith(".webm")
            val isSampleMp4 = samplePath.endsWith(".mp4") || samplePath.endsWith(".m4v")

            val playableVideo = when {
                isMp4 -> fileUrl
                isSampleMp4 -> sampleUrl
                isWebm -> fileUrl // Android ExoPlayer supports webm natively!
                else -> null
            }
            val preferredImg = if (isGif) fileUrl else (sampleUrl ?: fileUrl)
            val poster = previewUrl ?: preferredImg
            val score = item.optInt("score", 0)
            val w = item.optInt("width", 0).takeIf { it > 0 }
            val h = item.optInt("height", 0).takeIf { it > 0 }
            val owner = item.optString("owner").ifEmpty { "rule34" }
            val splitTags = item.optString("tags").split(" ")
                .map { it.lowercase() }
                .filter { it.isNotEmpty() && !MediaMetaRegistry.isStopTag(it) }
            val postId = "${prefix}_$idVal"
            if (splitTags.isNotEmpty()) {
                MediaMetaRegistry.register(postId, splitTags.take(18), creatorName = owner)
            }
            val topTags = splitTags.take(8).joinToString(" ") { "#$it" }
            val permalink = "https://$siteHost/index.php?page=post&s=view&id=$idVal"

            posts.add(
                Gif(
                    id = postId,
                    title = topTags,
                    author = owner,
                    subreddit = siteHost,
                    upvotes = score,
                    width = w,
                    height = h,
                    mediaType = if (playableVideo != null) "video" else "image",
                    mediaUrl = playableVideo ?: preferredImg,
                    muxedUrl = playableVideo,
                    muxedUrlHd = if (isMp4 || isWebm) fileUrl else playableVideo,
                    posterUrl = poster,
                    thumbnailUrl = poster,
                    sourceUrl = permalink,
                    permalink = permalink
                )
            )
        }
        return posts
    }

    private fun parseMoebooruJSON(body: String, prefix: String, siteHost: String): List<Gif> {
        val items = try { JSONArray(body) } catch (_: Throwable) { return emptyList() }
        val posts = mutableListOf<Gif>()
        for (i in 0 until items.length()) {
            val item = items.optJSONObject(i) ?: continue
            val rating = item.optString("rating", "").lowercase()
            if (rating in setOf("s", "safe", "general")) continue
            val idVal = item.opt("id")?.toString() ?: continue
            val fileUrl = normalizeHTTPS(item.optString("file_url"))
                ?: normalizeHTTPS(item.optString("jpeg_url")) ?: continue
            val sampleUrl = normalizeHTTPS(item.optString("sample_url"))
            val previewUrl = normalizeHTTPS(item.optString("preview_url"))
            val filePath = fileUrl.lowercase().substringBefore('?')
            val isMp4 = filePath.endsWith(".mp4") || filePath.endsWith(".m4v") || filePath.endsWith(".webm")
            val isGif = filePath.endsWith(".gif")
            val splitTags = item.optString("tags").split(" ")
                .map { it.lowercase() }
                .filter { it.isNotEmpty() && !MediaMetaRegistry.isStopTag(it) }
            val author = item.optString("author").ifEmpty { "rule34" }
            val postId = "${prefix}_$idVal"
            if (splitTags.isNotEmpty()) MediaMetaRegistry.register(postId, splitTags.take(18), creatorName = author)
            val preferredImg = if (isGif) fileUrl else (sampleUrl ?: fileUrl)
            val permalink = "https://$siteHost/post/show/$idVal"

            posts.add(
                Gif(
                    id = postId,
                    title = splitTags.take(8).joinToString(" ") { "#$it" },
                    author = author,
                    subreddit = siteHost,
                    upvotes = item.optInt("score", 0),
                    width = item.optInt("width", 0).takeIf { it > 0 },
                    height = item.optInt("height", 0).takeIf { it > 0 },
                    mediaType = if (isMp4) "video" else "image",
                    mediaUrl = if (isMp4) fileUrl else preferredImg,
                    muxedUrl = if (isMp4) fileUrl else null,
                    muxedUrlHd = if (isMp4) fileUrl else null,
                    posterUrl = previewUrl ?: sampleUrl ?: fileUrl,
                    thumbnailUrl = previewUrl ?: sampleUrl ?: fileUrl,
                    sourceUrl = permalink,
                    permalink = permalink
                )
            )
        }
        return posts
    }
}

@SuppressLint("SetJavaScriptEnabled")
@Composable
fun Rule34KeySheet(onDismiss: () -> Unit) {
    val store = UserStore.shared
    val current by store.data.collectAsState()
    var userIdInput by remember { mutableStateOf(if (current.r34Credentials.hasCustomCredentials) current.r34Credentials.effectiveUserId else "") }
    var apiKeyInput by remember { mutableStateOf(if (current.r34Credentials.hasCustomCredentials) current.r34Credentials.effectiveApiKey else "") }
    var showAccountWebView by remember { mutableStateOf(false) }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .liquidGlassBackground(tinted = current.settings.tintedGlass)
            .statusBarsPadding()
            .navigationBarsPadding()
            .padding(20.dp)
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(14.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Default.Key, contentDescription = null, tint = Color(0xFFABE6A3))
                Spacer(Modifier.width(8.dp))
                Text("Rule34.xxx DAPI Key", color = Color.White, fontSize = 20.sp, fontWeight = FontWeight.Bold)
                Spacer(Modifier.weight(1f))
                IconButton(onClick = onDismiss) {
                    Icon(Icons.Default.Close, contentDescription = "Close", tint = Color.White)
                }
            }

            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .fillMaxWidth()
                    .liquidGlassCard(cornerRadius = 14.dp, tinted = current.settings.tintedGlass)
                    .padding(12.dp)
            ) {
                Icon(Icons.Default.CheckCircle, contentDescription = null, tint = Color(0xFF8BE280), modifier = Modifier.size(20.dp))
                Spacer(Modifier.width(10.dp))
                Column {
                    Text(
                        if (current.r34Credentials.hasCustomCredentials) "Custom API Key Active" else "Built-in Default API Active",
                        color = Color.White,
                        fontWeight = FontWeight.Bold,
                        fontSize = 13.5.sp
                    )
                    Text(
                        if (current.r34Credentials.hasCustomCredentials) "Using your personal rule34.xxx DAPI credentials."
                        else "Rule34.xxx works out of the box. Override below only if you want your own key.",
                        color = Theme.textSecondary,
                        fontSize = 12.sp
                    )
                }
            }

            Button(
                onClick = { showAccountWebView = !showAccountWebView },
                colors = ButtonDefaults.buttonColors(containerColor = Color(0xFF478042))
            ) {
                Text(if (showAccountWebView) "Hide Rule34 Web Login" else "Open Rule34 Account Page", color = Color.White)
            }

            if (showAccountWebView) {
                Box(
                    modifier = Modifier
                        .fillMaxWidth()
                        .height(340.dp)
                        .liquidGlassCard(cornerRadius = 16.dp)
                ) {
                    AndroidView(
                        factory = { ctx ->
                            WebView(ctx).apply {
                                settings.javaScriptEnabled = true
                                settings.domStorageEnabled = true
                                settings.userAgentString = Config.userAgent
                                CookieManager.getInstance().setAcceptCookie(true)
                                webViewClient = object : WebViewClient() {
                                    override fun onPageFinished(view: WebView?, url: String?) {
                                        view?.evaluateJavascript(
                                            "(function(){var t=document.body.innerText||'';var u=t.match(/user_id=(\\d+)/);var k=t.match(/api_key=([a-f0-9]+)/i);return JSON.stringify({u:u?u[1]:'',k:k?k[1]:''});})();"
                                        ) { res ->
                                            try {
                                                val clean = res.trim('"').replace("\\\"", "\"")
                                                val obj = JSONObject(clean)
                                                val u = obj.optString("u")
                                                val k = obj.optString("k")
                                                if (u.isNotEmpty() && k.isNotEmpty()) {
                                                    userIdInput = u
                                                    apiKeyInput = k
                                                }
                                            } catch (_: Throwable) {}
                                        }
                                    }
                                }
                                loadUrl("https://rule34.xxx/index.php?page=account&s=options")
                            }
                        },
                        modifier = Modifier.fillMaxSize()
                    )
                }
            }

            OutlinedTextField(
                value = userIdInput,
                onValueChange = { userIdInput = it },
                label = { Text("Custom User ID") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )
            OutlinedTextField(
                value = apiKeyInput,
                onValueChange = { apiKeyInput = it },
                label = { Text("Custom API Key") },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                modifier = Modifier.fillMaxWidth()
            )

            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                Button(
                    onClick = {
                        val u = userIdInput.trim()
                        val k = apiKeyInput.trim()
                        store.updateR34Credentials(
                            Rule34Credentials(
                                userId = u,
                                apiKey = k,
                                customUserId = u,
                                useCustomCredentials = u.isNotEmpty() && k.isNotEmpty()
                            )
                        )
                        onDismiss()
                    },
                    modifier = Modifier.weight(1f),
                    colors = ButtonDefaults.buttonColors(containerColor = Theme.accent)
                ) {
                    Text("Save Custom Key", fontWeight = FontWeight.Bold)
                }
                if (current.r34Credentials.hasCustomCredentials) {
                    OutlinedButton(
                        onClick = {
                            store.updateR34Credentials(Rule34Credentials())
                            onDismiss()
                        }
                    ) {
                        Text("Use Default", color = Color.White)
                    }
                }
            }
        }
    }
}
