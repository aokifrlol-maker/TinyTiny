package com.bella.tinytiny

import android.annotation.SuppressLint
import android.os.Message
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
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
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import okhttp3.Request
import org.json.JSONObject
import java.net.URLEncoder
import java.time.Instant

@Serializable
data class RedditAccountSession(
    val redditSessionCookie: String = "",
    val tokenV2: String = "",
    val username: String = "",
    val mixIntoForYou: Boolean = false
) {
    val isConnected: Boolean
        get() = username.isNotEmpty() && (redditSessionCookie.isNotEmpty() || tokenV2.isNotEmpty())

    val cookieHeader: String
        get() {
            val parts = mutableListOf("over18=1")
            if (redditSessionCookie.isNotEmpty()) parts.add("reddit_session=$redditSessionCookie")
            if (tokenV2.isNotEmpty()) parts.add("token_v2=$tokenV2")
            return parts.joinToString("; ")
        }
}

object RedditPersonalAPI {
    private const val MOBILE_UA = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Mobile Safari/537.36"

    suspend fun homeFeed(after: String? = null): GoonedFeedResponse = fetchListing("/.json", after)
    suspend fun popularFeed(after: String? = null): GoonedFeedResponse = fetchListing("/r/popular.json", after)

    suspend fun savedFeed(after: String? = null): GoonedFeedResponse {
        val uname = UserStore.shared.data.value.redditSession.username
        if (uname.isEmpty()) return GoonedFeedResponse()
        return fetchListing("/user/$uname/saved.json", after)
    }

    suspend fun upvotedFeed(after: String? = null): GoonedFeedResponse {
        val uname = UserStore.shared.data.value.redditSession.username
        if (uname.isEmpty()) return GoonedFeedResponse()
        return fetchListing("/user/$uname/upvoted.json", after)
    }

    fun clearCookies() {
        try {
            val cm = CookieManager.getInstance()
            for (domain in listOf("https://www.reddit.com", "https://reddit.com", "https://oauth.reddit.com")) {
                cm.setCookie(domain, "reddit_session=; Max-Age=0; Path=/")
                cm.setCookie(domain, "token_v2=; Max-Age=0; Path=/")
            }
            cm.flush()
        } catch (_: Throwable) {}
    }

    suspend fun verifyUsername(cookieHeader: String): String? = withContext(Dispatchers.IO) {
        try {
            val req = Request.Builder()
                .url("https://www.reddit.com/api/me.json")
                .header("User-Agent", MOBILE_UA)
                .header("Accept", "application/json")
                .header("Referer", "https://www.reddit.com/")
                .header("Cookie", cookieHeader)
                .get()
                .build()
            TinyTinyApplication.sharedHttpClient.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) return@withContext null
                val raw = resp.body?.string() ?: return@withContext null
                val name = JSONObject(raw).optJSONObject("data")?.optString("name")?.trim()
                name?.takeIf { it.isNotEmpty() }
            }
        } catch (_: Throwable) {
            null
        }
    }

    private suspend fun fetchListing(path: String, after: String?): GoonedFeedResponse = withContext(Dispatchers.IO) {
        val rd = UserStore.shared.data.value.redditSession
        if (!rd.isConnected) return@withContext GoonedFeedResponse()
        val afterQ = if (!after.isNullOrEmpty()) "&after=${URLEncoder.encode(after, "UTF-8")}" else ""
        val url = "https://www.reddit.com$path?raw_json=1&limit=35$afterQ"
        try {
            val req = Request.Builder()
                .url(url)
                .header("User-Agent", MOBILE_UA)
                .header("Accept", "application/json")
                .header("Cookie", rd.cookieHeader)
                .header("Referer", "https://www.reddit.com/")
                .get()
                .build()
            TinyTinyApplication.sharedHttpClient.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) return@withContext GoonedFeedResponse()
                val raw = resp.body?.string() ?: return@withContext GoonedFeedResponse()
                parseListing(raw)
            }
        } catch (_: Throwable) {
            GoonedFeedResponse()
        }
    }

    private fun parseListing(rawJson: String): GoonedFeedResponse {
        val root = try { JSONObject(rawJson) } catch (_: Throwable) { return GoonedFeedResponse() }
        val listing = root.optJSONObject("data") ?: return GoonedFeedResponse()
        val children = listing.optJSONArray("children") ?: return GoonedFeedResponse()
        val nextAfter = listing.optString("after").takeIf { it.isNotEmpty() && it != "null" }

        val posts = mutableListOf<Gif>()
        val seen = mutableSetOf<String>()

        for (i in 0 until children.length()) {
            val raw = children.optJSONObject(i)?.optJSONObject("data") ?: continue
            val postId = raw.optString("id").takeIf { it.isNotEmpty() } ?: continue
            val gid = "rd_$postId"
            if (!seen.add(gid)) continue

            val mediaNode = raw.optJSONArray("crosspost_parent_list")?.optJSONObject(0) ?: raw
            val title = raw.optString("title").trim()
            val author = raw.optString("author").takeIf { it.isNotEmpty() }
            val subreddit = raw.optString("subreddit").takeIf { it.isNotEmpty() }
            val ups = raw.optInt("ups", raw.optInt("score", 0))
            val permalinkPath = raw.optString("permalink")
            val permalink = if (permalinkPath.isNotEmpty()) "https://www.reddit.com$permalinkPath" else "https://www.reddit.com/comments/$postId"
            val createdEpoch = raw.optLong("created_utc", 0L)
            val createdIso = createdEpoch.takeIf { it > 0L }?.let { Instant.ofEpochSecond(it).toString() }

            val thumb = extractThumb(mediaNode) ?: extractThumb(raw)
            val media = extractMedia(mediaNode) ?: extractMedia(raw) ?: continue

            MediaMetaRegistry.register(
                postId = gid,
                tags = listOfNotNull(subreddit?.lowercase()),
                creatorName = author,
                extraVideoURLs = media.extraVideos
            )
            if (media.galleryItems.size > 1) {
                MediaMetaRegistry.registerAlbumItems(gid, media.galleryItems)
            }

            posts.add(
                Gif(
                    id = gid,
                    title = title.ifEmpty { subreddit?.let { "r/$it" } ?: "Reddit" },
                    author = author,
                    subreddit = subreddit,
                    upvotes = ups,
                    duration = media.duration,
                    width = media.width,
                    height = media.height,
                    mediaType = if (media.isImage) "image" else "video",
                    mediaUrl = media.primaryUrl,
                    muxedUrl = if (media.isImage) null else (media.sdUrl ?: media.primaryUrl),
                    muxedUrlHd = if (media.isImage) null else (media.hdUrl ?: media.primaryUrl),
                    hlsUrl = if (media.isImage) null else media.hlsUrl,
                    posterUrl = thumb ?: if (media.isImage) media.primaryUrl else null,
                    thumbnailUrl = thumb ?: if (media.isImage) media.primaryUrl else null,
                    sourceUrl = permalink,
                    permalink = permalink,
                    createdUtc = createdIso
                )
            )
        }
        return GoonedFeedResponse(posts = posts, after = nextAfter)
    }

    private data class ExtractedMedia(
        val isImage: Boolean,
        val primaryUrl: String,
        val sdUrl: String?,
        val hdUrl: String?,
        val hlsUrl: String?,
        val extraVideos: List<String>,
        val galleryItems: List<AlbumMediaItem>,
        val width: Int?,
        val height: Int?,
        val duration: Double?
    )

    private fun extractThumb(node: JSONObject): String? {
        val preview = node.optJSONObject("preview")
            ?.optJSONArray("images")
            ?.optJSONObject(0)
            ?.optJSONObject("source")
            ?.optString("url")
            ?.replace("&amp;", "&")
            ?.takeIf { it.startsWith("http") }
        if (preview != null) return preview
        return node.optString("thumbnail").replace("&amp;", "&").takeIf { it.startsWith("http") }
    }

    private fun extractMedia(node: JSONObject): ExtractedMedia? {
        // 1. Native Reddit Video — ALWAYS prefer HLS (.m3u8) so audio is muxed (fallback_url is video-only!)
        val rv = node.optJSONObject("secure_media")?.optJSONObject("reddit_video")
            ?: node.optJSONObject("media")?.optJSONObject("reddit_video")
            ?: node.optJSONObject("preview")?.optJSONObject("reddit_video_preview")

        if (rv != null) {
            val hls = rv.optString("hls_url").replace("&amp;", "&").trim().takeIf { it.startsWith("http") }
            val fallback = rv.optString("fallback_url").replace("&amp;", "&").trim().takeIf { it.startsWith("http") }
            val scrubber = rv.optString("scrubber_media_url").replace("&amp;", "&").trim().takeIf { it.startsWith("http") }
            val candidates = listOfNotNull(hls, fallback, scrubber).distinct()
            if (candidates.isNotEmpty()) {
                return ExtractedMedia(
                    isImage = false,
                    primaryUrl = candidates.first(),
                    sdUrl = hls ?: fallback ?: candidates.first(),
                    hdUrl = hls ?: fallback ?: candidates.first(),
                    hlsUrl = hls,
                    extraVideos = candidates,
                    galleryItems = emptyList(),
                    width = rv.optInt("width", 0).takeIf { it > 0 },
                    height = rv.optInt("height", 0).takeIf { it > 0 },
                    duration = rv.optDouble("duration", 0.0).takeIf { it > 0.0 }
                )
            }
        }

        // 2. Preview MP4 variant
        val mp4Src = node.optJSONObject("preview")
            ?.optJSONArray("images")
            ?.optJSONObject(0)
            ?.optJSONObject("variants")
            ?.optJSONObject("mp4")
            ?.optJSONObject("source")
        val mp4Url = mp4Src?.optString("url")?.replace("&amp;", "&")?.takeIf { it.startsWith("http") }
        if (mp4Url != null) {
            return ExtractedMedia(
                isImage = false,
                primaryUrl = mp4Url,
                sdUrl = mp4Url,
                hdUrl = mp4Url,
                hlsUrl = null,
                extraVideos = listOf(mp4Url),
                galleryItems = emptyList(),
                width = mp4Src.optInt("width", 0).takeIf { it > 0 },
                height = mp4Src.optInt("height", 0).takeIf { it > 0 },
                duration = null
            )
        }

        // 3. Reddit Gallery (ordered by gallery_data.items)
        val gallery = node.optJSONObject("media_metadata")
        if (gallery != null) {
            val orderedIds = mutableListOf<String>()
            val gItems = node.optJSONObject("gallery_data")?.optJSONArray("items")
            if (gItems != null) {
                for (j in 0 until gItems.length()) {
                    gItems.optJSONObject(j)?.optString("media_id")?.takeIf { it.isNotEmpty() }?.let { orderedIds.add(it) }
                }
            }
            if (orderedIds.isEmpty()) {
                val keys = gallery.keys()
                while (keys.hasNext()) orderedIds.add(keys.next())
            }
            val slides = mutableListOf<AlbumMediaItem>()
            var firstW: Int? = null
            var firstH: Int? = null
            for ((idx, mid) in orderedIds.withIndex()) {
                val s = gallery.optJSONObject(mid)?.optJSONObject("s") ?: continue
                val u = (s.optString("u").ifEmpty { s.optString("gif") }).replace("&amp;", "&")
                if (u.startsWith("http")) {
                    if (firstW == null) firstW = s.optInt("x", 0).takeIf { it > 0 }
                    if (firstH == null) firstH = s.optInt("y", 0).takeIf { it > 0 }
                    slides.add(AlbumMediaItem(id = "rdg_${mid}_$idx", url = u, posterUrl = u, isVideo = false))
                }
            }
            if (slides.isNotEmpty()) {
                return ExtractedMedia(
                    isImage = true,
                    primaryUrl = slides.first().url,
                    sdUrl = null,
                    hdUrl = null,
                    hlsUrl = null,
                    extraVideos = emptyList(),
                    galleryItems = slides,
                    width = firstW,
                    height = firstH,
                    duration = null
                )
            }
        }

        // 4. Direct URL (strip ?query before extension check)
        val rawUrl = (node.optString("url_overridden_by_dest").ifEmpty { node.optString("url") }).replace("&amp;", "&")
        val lower = rawUrl.lowercase()
        val pathOnly = lower.substringBefore("?")
        if (lower.startsWith("http")) {
            if (pathOnly.endsWith(".mp4") || pathOnly.endsWith(".mov") || lower.contains(".mp4?")) {
                return ExtractedMedia(false, rawUrl, rawUrl, rawUrl, null, listOf(rawUrl), emptyList(), null, null, null)
            }
            if (pathOnly.endsWith(".gifv")) {
                val mp4 = rawUrl.dropLast(5) + ".mp4"
                return ExtractedMedia(false, mp4, mp4, mp4, null, listOf(mp4), emptyList(), null, null, null)
            }
            if (lower.contains("i.redd.it/") || lower.contains("preview.redd.it/") ||
                pathOnly.endsWith(".jpg") || pathOnly.endsWith(".jpeg") ||
                pathOnly.endsWith(".png") || pathOnly.endsWith(".webp") || pathOnly.endsWith(".gif")
            ) {
                return ExtractedMedia(true, rawUrl, null, null, null, emptyList(), emptyList(), null, null, null)
            }
        }

        return null
    }
}

@SuppressLint("SetJavaScriptEnabled")
@Composable
fun RedditLoginSheet(
    onSuccess: () -> Unit,
    onDismiss: () -> Unit
) {
    val ctx = androidx.compose.ui.platform.LocalContext.current
    val scope = rememberCoroutineScope()
    var statusText by remember { mutableStateOf("Tap 'Email me a one-time link', copy link, then tap Paste Link") }
    var captured by remember { mutableStateOf(false) }
    var checking by remember { mutableStateOf(false) }
    var popupWebView by remember { mutableStateOf<WebView?>(null) }
    var mainWebView by remember { mutableStateOf<WebView?>(null) }
    var showPasteBar by remember { mutableStateOf(false) }
    var pastedLink by remember { mutableStateOf("") }

    fun loadMagicLink(raw: String) {
        val trimmed = raw.trim()
        if (trimmed.startsWith("https://", ignoreCase = true) || trimmed.startsWith("http://", ignoreCase = true)) {
            statusText = "Opening one-time login link..."
            showPasteBar = false
            pastedLink = ""
            mainWebView?.loadUrl(trimmed)
        } else {
            statusText = "Copy the full https:// login link from your Reddit email first"
            showPasteBar = true
        }
    }

    fun closePopup() {
        popupWebView?.let { pop ->
            try {
                pop.stopLoading()
                pop.destroy()
            } catch (_: Throwable) {}
        }
        popupWebView = null
    }

    fun checkCookiesNow() {
        if (captured || checking) return
        checking = true
        scope.launch {
            try {
                val cm = CookieManager.getInstance()
                cm.flush()
                val combined = listOfNotNull(
                    cm.getCookie("https://www.reddit.com"),
                    cm.getCookie("https://reddit.com")
                ).joinToString("; ")
                val map = combined.split(";").mapNotNull {
                    val idx = it.indexOf('=')
                    if (idx > 0) {
                        val k = it.substring(0, idx).trim()
                        val v = it.substring(idx + 1).trim()
                        if (v.isNotEmpty()) k to v else null
                    } else null
                }.toMap()
                val sessionVal = map["reddit_session"] ?: ""
                val tokenVal = map["token_v2"] ?: ""
                if (sessionVal.isNotEmpty() || tokenVal.isNotEmpty()) {
                    val temp = RedditAccountSession(redditSessionCookie = sessionVal, tokenV2 = tokenVal)
                    val uname = RedditPersonalAPI.verifyUsername(temp.cookieHeader)
                    if (!uname.isNullOrEmpty() && !captured) {
                        captured = true
                        statusText = "Connected as u/$uname!"
                        closePopup()
                        val keepMix = UserStore.shared.data.value.redditSession.mixIntoForYou
                        UserStore.shared.updateRedditSession(
                            RedditAccountSession(
                                redditSessionCookie = sessionVal,
                                tokenV2 = tokenVal,
                                username = uname,
                                mixIntoForYou = keepMix
                            )
                        )
                        onSuccess()
                        onDismiss()
                    }
                }
            } finally {
                checking = false
            }
        }
    }

    DisposableEffect(Unit) {
        onDispose { closePopup() }
    }

    LaunchedEffect(Unit) {
        while (!captured) {
            delay(1400)
            checkCookiesNow()
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color(0xFF0E060B))
            .statusBarsPadding()
            .navigationBarsPadding()
    ) {
        Column(Modifier.fillMaxSize()) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(Color(0xFF1A0A12))
                    .padding(horizontal = 14.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically
            ) {
                Column(Modifier.weight(1f)) {
                    Text("Connect Reddit", color = Color.White, fontSize = 16.sp, fontWeight = FontWeight.Bold)
                    Text(statusText, color = Theme.textSecondary, fontSize = 11.5.sp, maxLines = 1)
                }
                TextButton(onClick = {
                    val cm = ctx.getSystemService(android.content.Context.CLIPBOARD_SERVICE) as? android.content.ClipboardManager
                    val clip = cm?.primaryClip?.getItemAt(0)?.coerceToText(ctx)?.toString()?.trim()
                    if (!clip.isNullOrEmpty() && clip.startsWith("http", ignoreCase = true)) {
                        loadMagicLink(clip)
                    } else {
                        showPasteBar = !showPasteBar
                    }
                }) {
                    Text("Paste Link", color = Theme.accentBright, fontWeight = FontWeight.Bold, fontSize = 12.5.sp)
                }
                TextButton(onClick = { checkCookiesNow() }) {
                    Text("Done", color = Color.White, fontWeight = FontWeight.SemiBold, fontSize = 12.5.sp)
                }
                IconButton(onClick = { closePopup(); onDismiss() }) {
                    Icon(Icons.Default.Close, contentDescription = "Close", tint = Color.White)
                }
            }

            if (showPasteBar) {
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .background(Color(0xFF14070E))
                        .padding(horizontal = 12.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    OutlinedTextField(
                        value = pastedLink,
                        onValueChange = { pastedLink = it },
                        placeholder = { Text("Paste Reddit email login link (https://...)", fontSize = 12.sp) },
                        singleLine = true,
                        modifier = Modifier.weight(1f)
                    )
                    Button(
                        onClick = { loadMagicLink(pastedLink) },
                        colors = ButtonDefaults.buttonColors(containerColor = Theme.accent)
                    ) {
                        Text("Open", fontWeight = FontWeight.Bold, fontSize = 12.5.sp)
                    }
                }
            }

            Box(modifier = Modifier.fillMaxWidth().weight(1f)) {
                AndroidView(
                    modifier = Modifier.fillMaxSize(),
                    factory = { ctx ->
                        WebView(ctx).apply {
                            mainWebView = this
                            layoutParams = ViewGroup.LayoutParams(
                                ViewGroup.LayoutParams.MATCH_PARENT,
                                ViewGroup.LayoutParams.MATCH_PARENT
                            )
                            isFocusable = true
                            isFocusableInTouchMode = true
                            setBackgroundColor(android.graphics.Color.BLACK)
                            // Firefox Mobile UA avoids Google OAuth's Android Chrome WebView (wv / X-Requested-With) 403 block
                            val oauthSafeUa = "Mozilla/5.0 (Android 14; Mobile; rv:132.0) Gecko/132.0 Firefox/132.0"
                            settings.javaScriptEnabled = true
                            settings.domStorageEnabled = true
                            @Suppress("DEPRECATION")
                            settings.databaseEnabled = true
                            settings.loadWithOverviewMode = true
                            settings.useWideViewPort = true
                            settings.setSupportMultipleWindows(true)
                            settings.javaScriptCanOpenWindowsAutomatically = true
                            settings.mixedContentMode = WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE
                            settings.userAgentString = oauthSafeUa
                            CookieManager.getInstance().setAcceptCookie(true)
                            CookieManager.getInstance().setAcceptThirdPartyCookies(this, true)
                            webChromeClient = object : WebChromeClient() {
                                override fun onCreateWindow(
                                    view: WebView?,
                                    isDialog: Boolean,
                                    isUserGesture: Boolean,
                                    resultMsg: Message?
                                ): Boolean {
                                    val popup = WebView(ctx).apply {
                                        layoutParams = ViewGroup.LayoutParams(
                                            ViewGroup.LayoutParams.MATCH_PARENT,
                                            ViewGroup.LayoutParams.MATCH_PARENT
                                        )
                                        settings.javaScriptEnabled = true
                                        settings.domStorageEnabled = true
                                        settings.loadWithOverviewMode = true
                                        settings.useWideViewPort = true
                                        settings.setSupportMultipleWindows(true)
                                        settings.javaScriptCanOpenWindowsAutomatically = true
                                        settings.userAgentString = oauthSafeUa
                                        CookieManager.getInstance().setAcceptCookie(true)
                                        CookieManager.getInstance().setAcceptThirdPartyCookies(this, true)
                                        webViewClient = object : WebViewClient() {
                                            override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean = false
                                            override fun onPageFinished(view: WebView?, url: String?) {
                                                checkCookiesNow()
                                            }
                                        }
                                        webChromeClient = object : WebChromeClient() {
                                            override fun onCloseWindow(window: WebView?) {
                                                closePopup()
                                                checkCookiesNow()
                                            }
                                        }
                                    }
                                    closePopup()
                                    popupWebView = popup
                                    val transport = resultMsg?.obj as? WebView.WebViewTransport
                                    transport?.webView = popup
                                    resultMsg?.sendToTarget()
                                    return true
                                }
                            }
                            webViewClient = object : WebViewClient() {
                                override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean = false
                                override fun onPageFinished(view: WebView?, url: String?) {
                                    checkCookiesNow()
                                }
                            }
                            loadUrl("https://www.reddit.com/login")
                        }
                    },
                    onRelease = { wv ->
                        try {
                            wv.stopLoading()
                            wv.destroy()
                        } catch (_: Throwable) {}
                    }
                )

                popupWebView?.let { pop ->
                    Box(modifier = Modifier.fillMaxSize().background(Color.Black)) {
                        AndroidView(factory = { pop }, modifier = Modifier.fillMaxSize())
                        IconButton(
                            onClick = { closePopup(); checkCookiesNow() },
                            modifier = Modifier.align(Alignment.TopEnd).padding(8.dp)
                        ) {
                            Icon(Icons.Default.Close, contentDescription = "Close Popup", tint = Color.White)
                        }
                    }
                }
            }
        }
    }
}
