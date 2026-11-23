package com.bella.tinytiny

import android.annotation.SuppressLint
import android.webkit.CookieManager
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Key
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
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
    val apiKey: String = ""
) {
    val isConnected: Boolean get() = userId.trim().isNotEmpty() && apiKey.trim().isNotEmpty()
    val hasCustomCredentials: Boolean get() = isConnected
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

    suspend fun autocomplete(rawQuery: String): List<Rule34TagSuggestion> = withContext(Dispatchers.IO) {
        val activeWord = parseTags(rawQuery).lastOrNull() ?: return@withContext emptyList()
        try {
            val enc = URLEncoder.encode(activeWord, "UTF-8")
            val req = Request.Builder()
                .url("https://api.rule34.xxx/autocomplete.php?q=$enc")
                .header("User-Agent", "GoonedR34Client/2.0 (Android; Mobile)")
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
            val booruPosts = fetchZeroAuthBooru(effectiveQuery, blocked, sort, page)
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
            .addQueryParameter("user_id", credentials.userId.trim())
            .addQueryParameter("api_key", credentials.apiKey.trim())

        try {
            val req = Request.Builder()
                .url(ub.build())
                .header("User-Agent", "GoonedR34Client/2.0 (Android; Mobile)")
                .header("Referer", "https://rule34.xxx/")
                .build()
            client.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) return@withContext emptyList()
                val body = resp.body?.string() ?: return@withContext emptyList()
                parseGelbooruStyleJSON(body, prefix = "r34")
            }
        } catch (_: Throwable) {
            emptyList()
        }
    }

    private suspend fun fetchZeroAuthBooru(
        tag: String,
        blockedTags: List<String>,
        sort: String,
        page: Int
    ): List<Gif> = coroutineScope {
        val negBlock = blockedTags.take(5).filter { it.isNotEmpty() && !tag.lowercase().contains(it.lowercase()) }
            .joinToString(" ") { "-${it.replace(" ", "_")}" }
        val yandeTags = (if (tag.isEmpty()) "order:score rating:e" else "$tag rating:e") +
            (if (negBlock.isEmpty()) "" else " $negBlock")
        val gelTags = (if (tag.isEmpty()) "-rating:safe -rating:questionable" else "$tag -rating:safe -rating:questionable") +
            (if (negBlock.isEmpty()) "" else " $negBlock")

        val yandeDef = async {
            fetchRaw("https://yande.re/post.json", mapOf("limit" to "30", "page" to "${page + 1}", "tags" to yandeTags)) {
                parseYandereJSON(it)
            }
        }
        val konachanDef = async {
            fetchRaw("https://konachan.com/post.json", mapOf("limit" to "25", "page" to "${page + 1}", "tags" to yandeTags)) {
                parseYandereJSON(it)
            }
        }
        val yPosts = yandeDef.await()
        val kPosts = konachanDef.await()
        val combined = (yPosts + kPosts).distinctBy { it.id }
        if (combined.isNotEmpty()) return@coroutineScope combined
        if (tag.isEmpty()) {
            try {
                GoonedAPI.category("Rule34", sort = sort, limit = 25).posts
            } catch (_: Throwable) {
                emptyList()
            }
        } else {
            emptyList()
        }
    }

    private suspend fun fetchRaw(base: String, query: Map<String, String>, parser: (String) -> List<Gif>): List<Gif> =
        withContext(Dispatchers.IO) {
            try {
                val ub = base.toHttpUrlOrNull()?.newBuilder() ?: return@withContext emptyList()
                for ((k, v) in query) ub.addQueryParameter(k, v)
                val req = Request.Builder()
                    .url(ub.build())
                    .header("User-Agent", "GoonedR34Client/2.0 (Android; Mobile)")
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

    private fun parseGelbooruStyleJSON(body: String, prefix: String): List<Gif> {
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
            val idVal = item.opt("id")?.toString() ?: continue
            val fileUrl = item.optString("file_url").takeIf { it.isNotEmpty() } ?: continue
            val sampleUrl = item.optString("sample_url").takeIf { it.isNotEmpty() }
            val previewUrl = item.optString("preview_url").takeIf { it.isNotEmpty() }
            val lower = fileUrl.lowercase()
            val sampleLower = (sampleUrl ?: "").lowercase()
            val isMp4 = lower.endsWith(".mp4") || lower.endsWith(".m4v") || lower.endsWith(".mov") || lower.endsWith(".webm")
            val isSampleMp4 = sampleLower.endsWith(".mp4") || sampleLower.endsWith(".webm")

            val playableVideo = when {
                isSampleMp4 && sampleLower.endsWith(".mp4") -> sampleUrl
                isMp4 -> fileUrl
                isSampleMp4 -> sampleUrl
                else -> null
            }
            val preferredImg = sampleUrl ?: fileUrl
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

            posts.add(
                Gif(
                    id = postId,
                    title = topTags,
                    author = owner,
                    subreddit = "rule34.xxx",
                    upvotes = score,
                    width = w,
                    height = h,
                    mediaType = if (playableVideo != null) "video" else "image",
                    mediaUrl = playableVideo ?: preferredImg,
                    muxedUrl = playableVideo,
                    muxedUrlHd = if (isMp4) fileUrl else playableVideo,
                    posterUrl = previewUrl ?: preferredImg,
                    thumbnailUrl = previewUrl ?: preferredImg,
                    sourceUrl = "https://rule34.xxx/index.php?page=post&s=view&id=$idVal",
                    permalink = "https://rule34.xxx/index.php?page=post&s=view&id=$idVal"
                )
            )
        }
        return posts
    }

    private fun parseYandereJSON(body: String): List<Gif> {
        val items = try { JSONArray(body) } catch (_: Throwable) { return emptyList() }
        val posts = mutableListOf<Gif>()
        for (i in 0 until items.length()) {
            val item = items.optJSONObject(i) ?: continue
            val idVal = item.opt("id")?.toString() ?: continue
            val fileUrl = item.optString("file_url").takeIf { it.isNotEmpty() } ?: continue
            val sampleUrl = item.optString("sample_url").takeIf { it.isNotEmpty() }
            val previewUrl = item.optString("preview_url").takeIf { it.isNotEmpty() }
            if (fileUrl.lowercase().endsWith(".webm")) continue
            val splitTags = item.optString("tags").split(" ").map { it.lowercase() }.filter { it.isNotEmpty() && !MediaMetaRegistry.isStopTag(it) }
            val author = item.optString("author").ifEmpty { "rule34" }
            val postId = "r34y_$idVal"
            if (splitTags.isNotEmpty()) MediaMetaRegistry.register(postId, splitTags.take(18), creatorName = author)
            posts.add(
                Gif(
                    id = postId,
                    title = splitTags.take(8).joinToString(" ") { "#$it" },
                    author = author,
                    subreddit = "rule34.xxx",
                    upvotes = item.optInt("score", 0),
                    width = item.optInt("width", 0).takeIf { it > 0 },
                    height = item.optInt("height", 0).takeIf { it > 0 },
                    mediaType = if (fileUrl.lowercase().endsWith(".mp4")) "video" else "image",
                    mediaUrl = sampleUrl ?: fileUrl,
                    muxedUrl = if (fileUrl.lowercase().endsWith(".mp4")) fileUrl else null,
                    muxedUrlHd = if (fileUrl.lowercase().endsWith(".mp4")) fileUrl else null,
                    posterUrl = previewUrl ?: sampleUrl ?: fileUrl,
                    thumbnailUrl = previewUrl ?: sampleUrl ?: fileUrl,
                    sourceUrl = "https://yande.re/post/show/$idVal",
                    permalink = "https://yande.re/post/show/$idVal"
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
    var userIdInput by remember { mutableStateOf(current.r34Credentials.userId) }
    var apiKeyInput by remember { mutableStateOf(current.r34Credentials.apiKey) }
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
            Text(
                "Sign into rule34.xxx below or paste your User ID & API Key from Account → Options → API Access.",
                color = Theme.textSecondary,
                fontSize = 13.sp
            )

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
                label = { Text("User ID") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )
            OutlinedTextField(
                value = apiKeyInput,
                onValueChange = { apiKeyInput = it },
                label = { Text("API Key") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )

            Row(horizontalArrangement = Arrangement.spacedBy(10.dp), modifier = Modifier.fillMaxWidth()) {
                Button(
                    onClick = {
                        store.updateR34Credentials(Rule34Credentials(userIdInput.trim(), apiKeyInput.trim()))
                        onDismiss()
                    },
                    modifier = Modifier.weight(1f),
                    colors = ButtonDefaults.buttonColors(containerColor = Theme.accent)
                ) {
                    Text("Save Key", fontWeight = FontWeight.Bold)
                }
                if (current.r34Credentials.isConnected) {
                    OutlinedButton(
                        onClick = {
                            store.updateR34Credentials(Rule34Credentials())
                            onDismiss()
                        }
                    ) {
                        Text("Clear", color = Color.White)
                    }
                }
            }
        }
    }
}
