package com.bella.tinytiny

import android.annotation.SuppressLint
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.JavascriptInterface
import android.webkit.RenderProcessGoneDetail
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
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
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.Serializable
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.net.URLEncoder
import java.time.Instant
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

// Exact iOS Codable wire format (requires mixIntoForYou: Bool, isConnected checks sessionId only)
@Serializable
data class InstagramAccountSession(
    var username: String = "",
    var userId: String = "",
    var sessionId: String = "",
    var csrfToken: String = "",
    var mixIntoForYou: Boolean = false
) {
    val isConnected: Boolean get() = sessionId.isNotEmpty()
}

object InstagramParser {
    fun parseReels(rawJson: String, routeKey: String = ""): List<Gif> {
        val root = try {
            val t = rawJson.trim()
            if (t.startsWith("[")) JSONArray(t) else JSONObject(t)
        } catch (_: Throwable) {
            return emptyList()
        }
        val results = mutableListOf<Gif>()
        val seen = mutableSetOf<String>()
        walk(root, null, null, routeKey, results, seen)
        return results
    }

    private fun walk(
        node: Any?,
        inheritedAuthor: String?,
        inheritedFollowed: Boolean?,
        routeKey: String,
        out: MutableList<Gif>,
        seen: MutableSet<String>
    ) {
        if (node == null) return
        when (node) {
            is JSONArray -> for (i in 0 until node.length()) walk(node.opt(i), inheritedAuthor, inheritedFollowed, routeKey, out, seen)
            is JSONObject -> {
                // Skip ads / sponsored / injected items
                if (node.has("ad_id") || node.has("ad_action") || node.has("injected") || node.optBoolean("is_paid_partnership", false)) return

                val isFollowingFeed = routeKey == "ig_following"
                if (isFollowingFeed) {
                    if (node.has("explore_item_info") || node.has("suggested_users") ||
                        node.has("bloks_netego") || node.has("clips_netego") || node.has("EndOfFeedDemarcator")
                    ) return
                    val inv = node.optString("inventory_source", "").lowercase()
                    if (inv.contains("recommend") || inv.contains("explore") || inv.contains("suggest") ||
                        inv.contains("unconnected") || inv.contains("isf_") || inv.contains("chaining")
                    ) return
                }

                // Unwrap `media` wrapper without double-walking
                val mediaWrap = node.optJSONObject("media")
                if (mediaWrap != null && node.optJSONArray("video_versions") == null && node.optString("video_url").isEmpty()) {
                    walk(mediaWrap, inheritedAuthor, inheritedFollowed, routeKey, out, seen)
                    return
                }

                val userObj = node.optJSONObject("user") ?: node.optJSONObject("owner")
                val uname = userObj?.optString("username")?.takeIf { it.isNotEmpty() } ?: inheritedAuthor ?: "instagram"
                val relFollow = userObj?.optJSONObject("friendship_status")?.let {
                    if (it.has("following")) it.optBoolean("following") else null
                } ?: userObj?.let {
                    when {
                        it.has("is_following") -> it.optBoolean("is_following")
                        it.has("followed_by_viewer") -> it.optBoolean("followed_by_viewer")
                        else -> null
                    }
                } ?: inheritedFollowed

                if (isFollowingFeed && relFollow == false) return

                val versions = node.optJSONArray("video_versions")
                val directVideoUrl = node.optString("video_url").takeIf { it.startsWith("http") }

                var bestUrl: String? = null
                var sdUrl: String? = null
                if (versions != null && versions.length() > 0) {
                    val list = mutableListOf<Pair<Int, String>>()
                    for (i in 0 until versions.length()) {
                        val v = versions.optJSONObject(i) ?: continue
                        val u = v.optString("url")
                        if (u.isNotEmpty()) list.add(v.optInt("width", 0) to u)
                    }
                    list.sortByDescending { it.first }
                    bestUrl = list.firstOrNull()?.second
                    sdUrl = list.lastOrNull()?.second ?: bestUrl
                } else if (directVideoUrl != null) {
                    bestUrl = directVideoUrl
                    sdUrl = directVideoUrl
                }

                if (bestUrl != null) {
                    val rawPk = node.opt("pk")?.toString()?.takeIf { it.isNotEmpty() }
                        ?: node.optString("id").takeIf { it.isNotEmpty() }
                        ?: node.optString("code").takeIf { it.isNotEmpty() }
                        ?: node.optString("shortcode").takeIf { it.isNotEmpty() }
                        ?: UUID.randomUUID().toString().take(12)
                    val cleanPk = rawPk.substringBefore('_')
                    val caption = node.optJSONObject("caption")?.optString("text")?.trim()
                        ?: node.optJSONObject("edge_media_to_caption")?.optJSONArray("edges")
                            ?.optJSONObject(0)?.optJSONObject("node")?.optString("text")?.trim()
                        ?: ""

                    if (AdultContentClassifier.isEligibleIGReel(caption = caption, author = uname, routeKey = routeKey)) {
                        val gid = "ig_$cleanPk"
                        val code = node.optString("code").ifEmpty { node.optString("shortcode") }
                        val permalink = if (code.isNotEmpty()) "https://www.instagram.com/reel/$code/" else "https://www.instagram.com/$uname/"
                        val dedupeKey = if (code.length >= 5) "ig_code_$code" else gid
                        if (seen.add(gid) && seen.add(dedupeKey)) {
                            val thumb = node.optJSONObject("image_versions2")?.optJSONArray("candidates")?.optJSONObject(0)?.optString("url")
                                ?: node.optString("display_url").takeIf { it.isNotEmpty() }
                                ?: node.optString("thumbnail_src").takeIf { it.isNotEmpty() }
                            val dims = node.optJSONObject("dimensions")
                            val w = node.optInt("original_width", 0).takeIf { it > 0 } ?: dims?.optInt("width", 0)?.takeIf { it > 0 }
                            val h = node.optInt("original_height", 0).takeIf { it > 0 } ?: dims?.optInt("height", 0)?.takeIf { it > 0 }
                            val likes = if (node.has("like_count")) node.optInt("like_count", 0)
                            else node.optJSONObject("edge_media_preview_like")?.optInt("count", 0) ?: 0
                            val takenAt = node.optLong("taken_at", 0L).takeIf { it > 0 }?.let { Instant.ofEpochSecond(it).toString() }
                            val tags = (Regex("#([A-Za-z0-9_]+)").findAll(caption).map { it.groupValues[1].lowercase() }.toList() +
                                PornTagCatalog.extractRecognizedTagsFromQuery(caption)).distinct()
                            MediaMetaRegistry.register(
                                postId = gid,
                                tags = tags,
                                creatorName = uname,
                                extraVideoURLs = listOfNotNull(bestUrl, sdUrl).distinct(),
                                followedByViewer = relFollow
                            )
                            out.add(
                                Gif(
                                    id = gid,
                                    title = caption.ifEmpty { "@$uname" },
                                    author = uname,
                                    subreddit = null,
                                    upvotes = likes,
                                    duration = node.optDouble("video_duration", 0.0).takeIf { it > 0 },
                                    width = w,
                                    height = h,
                                    mediaType = "video",
                                    mediaUrl = bestUrl,
                                    muxedUrl = sdUrl ?: bestUrl,
                                    muxedUrlHd = bestUrl,
                                    posterUrl = thumb,
                                    thumbnailUrl = thumb,
                                    sourceUrl = permalink,
                                    permalink = permalink,
                                    createdUtc = takenAt
                                )
                            )
                        }
                    }
                }

                val keys = node.keys()
                while (keys.hasNext()) {
                    walk(node.opt(keys.next()), uname, relFollow, routeKey, out, seen)
                }
            }
        }
    }

    fun extractNextCursor(rawJson: String): String? {
        return try {
            val root = JSONObject(rawJson)
            root.optJSONObject("paging_info")?.optString("max_id")?.takeIf { it.isNotEmpty() }
                ?: root.optString("next_max_id").takeIf { it.isNotEmpty() }
                ?: root.optJSONObject("data")?.optJSONObject("xdt_api__v1__clips__home__connection_v2")
                    ?.optJSONObject("page_info")?.optString("end_cursor")?.takeIf { it.isNotEmpty() }
        } catch (_: Throwable) {
            null
        }
    }
}

object InstagramWebEngine {
    data class IGDirectThread(
        val id: String,
        val title: String,
        val isGroup: Boolean,
        val subtitle: String
    )

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val lock = Mutex()
    private var webView: WebView? = null
    private var hostContainer: ViewGroup? = null
    private val routeBuffers = ConcurrentHashMap<String, MutableList<Gif>>()
    private val routeCursors = ConcurrentHashMap<String, String>()
    private val seenIdsByRoute = ConcurrentHashMap<String, MutableSet<String>>()
    private val waiters = ConcurrentHashMap<String, MutableList<CompletableDeferred<Unit>>>()
    @Volatile private var activeRouteKey = "ig_reels"
    @Volatile private var pageCounter = 0

    private const val HOOK_JS = """
        (function(){
          if(window.__ttIGHooked) return;
          window.__ttIGHooked = true;
          try {
            HTMLMediaElement.prototype.play = function(){ try{ this.muted=true; this.pause(); }catch(e){} return Promise.resolve(); };
          } catch(e){}
          const origFetch = window.fetch;
          window.fetch = async function(){
            const resp = await origFetch.apply(this, arguments);
            try {
              const url = (arguments[0] && arguments[0].url) ? arguments[0].url : String(arguments[0] || '');
              const clone = resp.clone();
              clone.text().then(t => {
                if(t && t.length > 40 && (t.includes('video_versions') || t.includes('video_url'))) {
                  window.TTIGBridge.onPayload(url, location.href || '', t);
                }
              });
            } catch(e){}
            return resp;
          };
          const origOpen = XMLHttpRequest.prototype.open;
          const origSend = XMLHttpRequest.prototype.send;
          XMLHttpRequest.prototype.open = function(m, u){ this.__ttUrl = String(u || ''); return origOpen.apply(this, arguments); };
          XMLHttpRequest.prototype.send = function(){
            this.addEventListener('load', function(){
              try {
                const t = typeof this.responseText === 'string' ? this.responseText : '';
                if(t && t.length > 40 && (t.includes('video_versions') || t.includes('video_url'))) {
                  window.TTIGBridge.onPayload(this.__ttUrl, location.href || '', t);
                }
              } catch(e){}
            });
            return origSend.apply(this, arguments);
          };
        })();
    """

    private const val SCROLL_ADVANCE_JS = """
        (function(){
          function nudge(){
            const dy = Math.max(800, window.innerHeight * 2.0);
            document.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowDown', code: 'ArrowDown', keyCode: 40, bubbles: true }));
            window.dispatchEvent(new WheelEvent('wheel', { deltaY: dy, bubbles: true }));
            window.scrollBy(0, dy);
            const els = document.querySelectorAll('div, main, section');
            for(let i=0;i<els.length;i++){
              const el = els[i];
              if(el.scrollHeight > el.clientHeight + 150){
                el.scrollTop += dy;
                el.dispatchEvent(new Event('scroll'));
              }
            }
          }
          nudge();
          setTimeout(nudge, 280);
        })();
    """

    class Bridge {
        @JavascriptInterface
        fun onPayload(url: String, pageUrl: String, body: String) {
            val key = activeRouteKey
            scope.launch {
                val reels = InstagramParser.parseReels(body, routeKey = key)
                InstagramParser.extractNextCursor(body)?.let { routeCursors[key] = it }
                val seenSet = seenIdsByRoute.getOrPut(key) { ConcurrentHashMap.newKeySet() }
                val fresh = reels.filter { !UserStore.shared.isBlockedByAlgorithm(it) && seenSet.add(it.canonicalDedupeKey) }
                if (fresh.isNotEmpty()) {
                    val list = routeBuffers.getOrPut(key) { mutableListOf() }
                    synchronized(list) { list.addAll(fresh) }
                    notifyWaiters(key)
                }
            }
        }
    }

    private fun notifyWaiters(key: String) {
        val list = waiters.remove(key) ?: return
        synchronized(list) { list.forEach { it.complete(Unit) } }
    }

    private suspend fun awaitBuffer(key: String, timeoutMs: Long) {
        val buf = routeBuffers[key]
        if (buf != null && synchronized(buf) { buf.isNotEmpty() }) return
        val deferred = CompletableDeferred<Unit>()
        val list = waiters.getOrPut(key) { mutableListOf() }
        synchronized(list) { list.add(deferred) }
        val buf2 = routeBuffers[key]
        if (buf2 != null && synchronized(buf2) { buf2.isNotEmpty() }) {
            deferred.complete(Unit)
            return
        }
        withTimeoutOrNull(timeoutMs) { deferred.await() }
    }

    fun attachHost(container: ViewGroup) {
        hostContainer = container
        val wv = webView ?: return
        if (wv.parent !== container) {
            (wv.parent as? ViewGroup)?.removeView(wv)
            container.addView(wv, ViewGroup.LayoutParams(390, 844))
        }
    }

    fun resetSession() {
        routeBuffers.clear()
        routeCursors.clear()
        seenIdsByRoute.clear()
        webView?.let { wv ->
            (wv.parent as? ViewGroup)?.removeView(wv)
            wv.stopLoading()
            wv.loadUrl("about:blank")
            wv.destroy()
        }
        webView = null
        try {
            val cm = CookieManager.getInstance()
            for (domain in listOf("https://www.instagram.com", "https://i.instagram.com")) {
                cm.setCookie(domain, "sessionid=; Max-Age=0; Path=/")
                cm.setCookie(domain, "csrftoken=; Max-Age=0; Path=/")
                cm.setCookie(domain, "ds_user_id=; Max-Age=0; Path=/")
            }
            cm.flush()
        } catch (_: Throwable) {}
    }

    @SuppressLint("SetJavaScriptEnabled")
    suspend fun ensureWebView(): WebView = withContext(Dispatchers.Main) {
        webView?.let { existing ->
            hostContainer?.let { host ->
                if (existing.parent !== host) {
                    (existing.parent as? ViewGroup)?.removeView(existing)
                    host.addView(existing, ViewGroup.LayoutParams(390, 844))
                }
            }
            return@withContext existing
        }
        LicenseManager.injectRestoredSocialCookies()
        val ctx = hostContainer?.context ?: TinyTinyApplication.instance
        val wv = WebView(ctx).apply {
            layoutParams = ViewGroup.LayoutParams(390, 844)
            setBackgroundColor(android.graphics.Color.BLACK)
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.databaseEnabled = true
            settings.loadWithOverviewMode = true
            settings.useWideViewPort = true
            settings.mediaPlaybackRequiresUserGesture = true
            settings.mixedContentMode = android.webkit.WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE
            settings.userAgentString = Config.userAgent
            CookieManager.getInstance().setAcceptCookie(true)
            CookieManager.getInstance().setAcceptThirdPartyCookies(this, true)
            addJavascriptInterface(Bridge(), "TTIGBridge")
            webChromeClient = WebChromeClient()
            webViewClient = object : WebViewClient() {
                override fun shouldInterceptRequest(view: WebView?, request: WebResourceRequest?): WebResourceResponse? {
                    val u = request?.url?.toString()?.lowercase() ?: return null
                    if (u.contains(".mp4") || u.contains(".woff2") || u.contains("scontent") && u.contains(".jpg")) {
                        return WebResourceResponse("text/plain", "utf-8", ByteArrayInputStream(ByteArray(0)))
                    }
                    return null
                }

                override fun onPageStarted(view: WebView?, url: String?, favicon: android.graphics.Bitmap?) {
                    view?.evaluateJavascript(HOOK_JS, null)
                }

                override fun onPageFinished(view: WebView?, url: String?) {
                    view?.evaluateJavascript(HOOK_JS, null)
                }

                override fun onRenderProcessGone(view: WebView?, detail: RenderProcessGoneDetail?): Boolean {
                    webView = null
                    return true
                }
            }
        }
        hostContainer?.addView(wv, ViewGroup.LayoutParams(390, 844))
        webView = wv
        wv
    }

    suspend fun warmUp() {
        if (!UserStore.shared.data.value.igSession.isConnected) return
        val wv = ensureWebView()
        withContext(Dispatchers.Main) {
            if (wv.url.isNullOrEmpty() || wv.url == "about:blank") wv.loadUrl("https://www.instagram.com/reels/")
        }
    }

    suspend fun fetchRoute(routeKey: String, targetUrl: String, after: String? = null, apiTriggerJS: String? = null): GoonedFeedResponse {
        val preDrained = drainBuffer(routeKey, 20)
        if (preDrained.size >= 6) {
            return GoonedFeedResponse(posts = preDrained, after = routeCursors[routeKey] ?: "igpage_${++pageCounter}")
        }

        return lock.withLock {
            activeRouteKey = routeKey
            val wv = ensureWebView()
            withContext(Dispatchers.Main) {
                wv.evaluateJavascript(HOOK_JS, null)
                val cur = wv.url ?: ""
                val needsLoad = cur.isEmpty() || cur == "about:blank" ||
                    (targetUrl.contains("variant=following") && !cur.contains("variant=following")) ||
                    (!targetUrl.contains("variant=following") && !cur.startsWith(targetUrl.substringBefore('?')))
                if (needsLoad) {
                    wv.loadUrl(targetUrl)
                } else if (!apiTriggerJS.isNullOrEmpty()) {
                    wv.evaluateJavascript(apiTriggerJS, null)
                } else {
                    wv.evaluateJavascript(SCROLL_ADVANCE_JS, null)
                }
            }
            awaitBuffer(routeKey, 5000L)
            var items = (preDrained + drainBuffer(routeKey, 24)).distinctBy { it.id }
            if (items.isEmpty()) {
                withContext(Dispatchers.Main) {
                    if (!apiTriggerJS.isNullOrEmpty()) wv.evaluateJavascript(apiTriggerJS, null)
                    wv.evaluateJavascript(SCROLL_ADVANCE_JS, null)
                }
                awaitBuffer(routeKey, 3500L)
                items = drainBuffer(routeKey, 24)
            }
            GoonedFeedResponse(posts = items, after = routeCursors[routeKey] ?: "igpage_${++pageCounter}")
        }
    }

    private fun drainBuffer(key: String, maxCount: Int): List<Gif> {
        val list = routeBuffers[key] ?: return emptyList()
        return synchronized(list) {
            if (list.isEmpty()) emptyList()
            else {
                val take = minOf(maxCount, list.size)
                val out = list.subList(0, take).toList()
                list.subList(0, take).clear()
                out
            }
        }
    }

    suspend fun followUser(handle: String, follow: Boolean): Boolean = withContext(Dispatchers.IO) {
        val ig = UserStore.shared.data.value.igSession
        if (!ig.isConnected) return@withContext false
        val clean = handle.replace("@", "").trim()
        if (clean.isEmpty()) return@withContext false
        try {
            val cookies = CookieManager.getInstance().getCookie("https://www.instagram.com")
                ?: "sessionid=${ig.sessionId}; csrftoken=${ig.csrfToken}; ds_user_id=${ig.userId}"
            val profReq = Request.Builder()
                .url("https://www.instagram.com/api/v1/users/web_profile_info/?username=${URLEncoder.encode(clean, "UTF-8")}")
                .header("User-Agent", Config.userAgent)
                .header("X-IG-App-ID", "936619743392459")
                .header("X-CSRFToken", ig.csrfToken)
                .header("Cookie", cookies)
                .build()
            val uid = TinyTinyApplication.sharedHttpClient.newCall(profReq).execute().use { r ->
                if (!r.isSuccessful) return@withContext false
                JSONObject(r.body?.string() ?: "").optJSONObject("data")?.optJSONObject("user")?.optString("id")
            } ?: return@withContext false
            if (uid.isEmpty()) return@withContext false
            val action = if (follow) "follow" else "unfollow"
            val actReq = Request.Builder()
                .url("https://www.instagram.com/api/v1/web/friendships/$uid/$action/")
                .header("User-Agent", Config.userAgent)
                .header("X-IG-App-ID", "936619743392459")
                .header("X-CSRFToken", ig.csrfToken)
                .header("X-Requested-With", "XMLHttpRequest")
                .header("Origin", "https://www.instagram.com")
                .header("Referer", "https://www.instagram.com/$clean/")
                .header("Cookie", cookies)
                .post("".toRequestBody("application/x-www-form-urlencoded".toMediaType()))
                .build()
            TinyTinyApplication.sharedHttpClient.newCall(actReq).execute().use { it.isSuccessful }
        } catch (_: Throwable) {
            false
        }
    }

    suspend fun fetchDirectInboxThreads(): List<IGDirectThread> = withContext(Dispatchers.IO) {
        val ig = UserStore.shared.data.value.igSession
        if (!ig.isConnected) return@withContext emptyList()
        val cookies = CookieManager.getInstance().getCookie("https://www.instagram.com")
            ?.takeIf { it.contains("sessionid=") }
            ?: "sessionid=${ig.sessionId}; csrftoken=${ig.csrfToken}; ds_user_id=${ig.userId}"
        val req = Request.Builder()
            .url("https://www.instagram.com/api/v1/direct_v2/inbox/?persistentBadging=true&folder=&limit=40&thread_message_limit=5")
            .header("User-Agent", Config.userAgent)
            .header("X-IG-App-ID", "936619743392459")
            .header("X-ASBD-ID", "129477")
            .header("X-CSRFToken", ig.csrfToken)
            .header("X-Requested-With", "XMLHttpRequest")
            .header("Referer", "https://www.instagram.com/direct/inbox/")
            .header("Cookie", cookies)
            .build()
        TinyTinyApplication.sharedHttpClient.newCall(req).execute().use { resp ->
            if (!resp.isSuccessful) throw IllegalStateException("Instagram inbox error (HTTP ${resp.code})")
            val raw = resp.body?.string() ?: return@withContext emptyList()
            val threads = JSONObject(raw).optJSONObject("inbox")?.optJSONArray("threads") ?: return@withContext emptyList()
            val out = mutableListOf<IGDirectThread>()
            for (i in 0 until threads.length()) {
                val t = threads.optJSONObject(i) ?: continue
                val tid = t.optString("thread_id").takeIf { it.isNotEmpty() } ?: continue
                val users = t.optJSONArray("users")
                val title = t.optString("thread_title").ifEmpty {
                    if (users != null && users.length() > 0) users.optJSONObject(0)?.optString("username") ?: "Chat" else "Chat"
                }
                val isGroup = t.optBoolean("is_group", false) || (users != null && users.length() > 1)
                out.add(IGDirectThread(tid, title, isGroup, if (isGroup) "Group Chat" else "Direct Message"))
            }
            out
        }
    }

    suspend fun sendVideoToDirectThread(
        threadId: String,
        videoUrl: String,
        referer: String?,
        title: String
    ): Result<Unit> = withContext(Dispatchers.IO) {
        val ig = UserStore.shared.data.value.igSession
        if (!ig.isConnected) return@withContext Result.failure(IllegalStateException("Not signed into Instagram"))
        try {
            val dlReq = Request.Builder().url(videoUrl).apply {
                for ((k, v) in MediaHeaders.headers(videoUrl)) header(k, v)
                if (!referer.isNullOrEmpty()) header("Referer", referer)
            }.build()
            val videoBytes = TinyTinyApplication.longTransferHttpClient.newCall(dlReq).execute().use { r ->
                if (!r.isSuccessful) return@withContext Result.failure(IllegalStateException("Failed to fetch MP4 (${r.code})"))
                r.body?.bytes() ?: return@withContext Result.failure(IllegalStateException("Empty video"))
            }
            val uploadId = System.currentTimeMillis().toString()
            val cookies = CookieManager.getInstance().getCookie("https://www.instagram.com")
                ?.takeIf { it.contains("sessionid=") }
                ?: "sessionid=${ig.sessionId}; csrftoken=${ig.csrfToken}; ds_user_id=${ig.userId}"
            val ruploadParams = JSONObject().apply {
                put("media_type", 2)
                put("upload_id", uploadId)
                put("upload_media_height", 720)
                put("upload_media_width", 720)
                put("xsharing_user_ids", JSONArray())
            }.toString()

            val upReq = Request.Builder()
                .url("https://i.instagram.com/rupload_igvideo/fb_uploader_$uploadId")
                .header("User-Agent", Config.userAgent)
                .header("X-IG-App-ID", "936619743392459")
                .header("X-ASBD-ID", "129477")
                .header("X-CSRFToken", ig.csrfToken)
                .header("Origin", "https://www.instagram.com")
                .header("Referer", "https://www.instagram.com/direct/t/$threadId/")
                .header("Cookie", cookies)
                .header("X-Instagram-Rupload-Params", ruploadParams)
                .header("X-Entity-Name", "fb_uploader_$uploadId")
                .header("X-Entity-Length", "${videoBytes.size}")
                .header("Offset", "0")
                .post(videoBytes.toRequestBody("application/octet-stream".toMediaType()))
                .build()

            TinyTinyApplication.longTransferHttpClient.newCall(upReq).execute().use { upResp ->
                if (!upResp.isSuccessful) return@withContext Result.failure(IllegalStateException("IG upload failed (${upResp.code})"))
            }

            val ctxToken = UUID.randomUUID().toString()
            val encodedThreads = URLEncoder.encode("""["$threadId"]""", "UTF-8")
            val formBody = "action=send_item&thread_ids=$encodedThreads&upload_id=$uploadId&client_context=$ctxToken"
                .toRequestBody("application/x-www-form-urlencoded".toMediaType())
            val sendReq = Request.Builder()
                .url("https://i.instagram.com/api/v1/direct_v2/threads/broadcast/configure_video/")
                .header("User-Agent", Config.userAgent)
                .header("X-IG-App-ID", "936619743392459")
                .header("X-ASBD-ID", "129477")
                .header("X-CSRFToken", ig.csrfToken)
                .header("X-Requested-With", "XMLHttpRequest")
                .header("Origin", "https://www.instagram.com")
                .header("Referer", "https://www.instagram.com/direct/t/$threadId/")
                .header("Cookie", cookies)
                .post(formBody)
                .build()
            TinyTinyApplication.sharedHttpClient.newCall(sendReq).execute().use { sendResp ->
                val respText = sendResp.body?.string() ?: ""
                if (!sendResp.isSuccessful || !respText.contains("\"ok\"")) {
                    return@withContext Result.failure(IllegalStateException("IG DM broadcast failed (${sendResp.code})"))
                }
            }
            Result.success(Unit)
        } catch (e: Throwable) {
            Result.failure(e)
        }
    }
}

object InstagramAPI {
    suspend fun reelsFeed(after: String? = null): GoonedFeedResponse {
        val maxId = after?.takeIf { !it.startsWith("igpage_") } ?: ""
        val trigger = if (maxId.isNotEmpty()) {
            """fetch('/api/v1/clips/home/', { method:'POST', credentials:'include', headers:{'content-type':'application/x-www-form-urlencoded','x-ig-app-id':'936619743392459'}, body:'page_size=12&max_id='+encodeURIComponent('$maxId') }).catch(()=>{});"""
        } else null
        return InstagramWebEngine.fetchRoute("ig_reels", "https://www.instagram.com/reels/", after, apiTriggerJS = trigger)
    }

    suspend fun followingFeed(after: String? = null): GoonedFeedResponse {
        val maxId = after?.takeIf { !it.startsWith("igpage_") } ?: ""
        val trigger = if (maxId.isNotEmpty()) {
            """fetch('/api/v1/feed/timeline/', { method:'POST', credentials:'include', headers:{'content-type':'application/x-www-form-urlencoded','x-ig-app-id':'936619743392459'}, body:'reason=pagination&max_id='+encodeURIComponent('$maxId') }).catch(()=>{});"""
        } else null
        return InstagramWebEngine.fetchRoute("ig_following", "https://www.instagram.com/?variant=following", after, apiTriggerJS = trigger)
    }

    suspend fun savedFeed(after: String? = null): GoonedFeedResponse {
        val uname = UserStore.shared.data.value.igSession.username.trim().removePrefix("@")
        val target = if (uname.isNotEmpty() && uname != "IG Account") "https://www.instagram.com/$uname/saved/" else "https://www.instagram.com/accounts/saved/"
        val maxId = after?.takeIf { !it.startsWith("igpage_") } ?: ""
        val trigger = if (maxId.isNotEmpty()) {
            """fetch('/api/v1/feed/saved/posts/?max_id='+encodeURIComponent('$maxId'), { credentials:'include', headers:{'x-ig-app-id':'936619743392459'} }).catch(()=>{});"""
        } else null
        return InstagramWebEngine.fetchRoute("ig_saved", target, after, apiTriggerJS = trigger)
    }

    suspend fun userReels(handle: String, after: String? = null): GoonedFeedResponse {
        val clean = handle.trim().replace(Regex("(?i)^ig:"), "").replace("@", "")
        return InstagramWebEngine.fetchRoute("ig_user_${clean.lowercase()}", "https://www.instagram.com/$clean/reels/", after)
    }
}

@SuppressLint("SetJavaScriptEnabled")
@Composable
fun InstagramLoginSheet(onConnected: () -> Unit, onDismiss: () -> Unit) {
    val store = UserStore.shared
    val scope = rememberCoroutineScope()
    var detected by remember { mutableStateOf(false) }
    var showManual by remember { mutableStateOf(false) }
    var manualSid by remember { mutableStateOf("") }
    var manualCsrf by remember { mutableStateOf("") }
    var manualHandle by remember { mutableStateOf("") }
    val loginWebViewRef = remember { arrayOfNulls<WebView>(1) }

    fun completeSession(sid: String, csrf: String, uid: String, handle: String) {
        if (detected) return
        detected = true
        val clean = handle.trim().removePrefix("@").ifEmpty { "IG Account" }
        store.updateIGSession(
            InstagramAccountSession(
                username = clean,
                userId = uid,
                sessionId = sid,
                csrfToken = csrf
            )
        )
        scope.launch {
            LicenseManager.injectRestoredSocialCookies()
            InstagramWebEngine.warmUp()
        }
        onConnected()
    }

    fun checkCookiesAndComplete(wv: WebView?) {
        if (detected) return
        val cookies = CookieManager.getInstance().getCookie("https://www.instagram.com") ?: ""
        val map = cookies.split(";").mapNotNull {
            val p = it.trim().split("=", limit = 2)
            if (p.size == 2) p[0].trim() to p[1].trim() else null
        }.toMap()
        val sid = map["sessionid"] ?: ""
        val csrf = map["csrftoken"] ?: ""
        val uid = map["ds_user_id"] ?: ""
        if (sid.isNotEmpty()) {
            if (wv != null) {
                wv.evaluateJavascript(
                    "(function(){ const a = document.querySelector('a[href^=\"/\"][role=\"link\"] span'); return (window._sharedData && window._sharedData.config && window._sharedData.config.viewer && window._sharedData.config.viewer.username) || (a ? a.innerText : '') || ''; })()"
                ) { res ->
                    val parsed = res?.trim('"')?.takeIf { it.isNotEmpty() && it != "null" && !it.contains(" ") } ?: ""
                    completeSession(sid, csrf, uid, parsed)
                }
            } else {
                completeSession(sid, csrf, uid, "")
            }
        }
    }

    LaunchedEffect(showManual) {
        if (!showManual) {
            while (!detected) {
                delay(1000)
                checkCookiesAndComplete(loginWebViewRef[0])
            }
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black)
            .statusBarsPadding()
            .navigationBarsPadding()
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 14.dp, vertical = 10.dp)
        ) {
            BrandLogoInstagram(22.dp)
            Spacer(Modifier.width(10.dp))
            Text("Sign in to Instagram", color = Color.White, fontSize = 18.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.weight(1f))
            TextButton(onClick = { showManual = !showManual }) {
                Icon(Icons.Default.Key, contentDescription = null, tint = Theme.accentBright, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(4.dp))
                Text(if (showManual) "Web Login" else "Cookies", color = Theme.accentBright, fontSize = 12.5.sp)
            }
            TextButton(onClick = { checkCookiesAndComplete(loginWebViewRef[0]) }) {
                Text("Done", color = Color.White, fontWeight = FontWeight.Bold, fontSize = 13.sp)
            }
            IconButton(onClick = onDismiss) {
                Icon(Icons.Default.Close, contentDescription = "Close", tint = Color.White)
            }
        }

        if (showManual) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .verticalScroll(rememberScrollState())
                    .imePadding()
                    .padding(20.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                Text("Manual Cookie Sign-In", color = Color.White, fontSize = 17.sp, fontWeight = FontWeight.Bold)
                Text("Paste your sessionid cookie from instagram.com.", color = Theme.textSecondary, fontSize = 12.5.sp)
                OutlinedTextField(value = manualSid, onValueChange = { manualSid = it }, label = { Text("sessionid") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(value = manualCsrf, onValueChange = { manualCsrf = it }, label = { Text("csrftoken (optional)") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(value = manualHandle, onValueChange = { manualHandle = it }, label = { Text("@username (optional)") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                Button(
                    onClick = { completeSession(manualSid.trim(), manualCsrf.trim(), "", manualHandle.trim()) },
                    enabled = manualSid.trim().isNotEmpty(),
                    colors = ButtonDefaults.buttonColors(containerColor = Theme.accent),
                    shape = RoundedCornerShape(999.dp),
                    modifier = Modifier.fillMaxWidth().height(48.dp)
                ) {
                    Text("Connect Instagram", fontWeight = FontWeight.Bold)
                }
            }
        } else {
            Box(modifier = Modifier.fillMaxWidth().weight(1f)) {
                AndroidView(
                    factory = { ctx ->
                        WebView(ctx).apply {
                            loginWebViewRef[0] = this
                            layoutParams = ViewGroup.LayoutParams(
                                ViewGroup.LayoutParams.MATCH_PARENT,
                                ViewGroup.LayoutParams.MATCH_PARENT
                            )
                            isFocusable = true
                            isFocusableInTouchMode = true
                            setBackgroundColor(android.graphics.Color.BLACK)
                            val chromeUa = try {
                                android.webkit.WebSettings.getDefaultUserAgent(ctx).replace("; wv", "")
                            } catch (_: Throwable) {
                                "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36"
                            }
                            settings.javaScriptEnabled = true
                            settings.domStorageEnabled = true
                            settings.databaseEnabled = true
                            settings.loadWithOverviewMode = true
                            settings.useWideViewPort = true
                            settings.javaScriptCanOpenWindowsAutomatically = true
                            settings.mixedContentMode = android.webkit.WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE
                            settings.userAgentString = chromeUa
                            CookieManager.getInstance().setAcceptCookie(true)
                            CookieManager.getInstance().setAcceptThirdPartyCookies(this, true)
                            webChromeClient = WebChromeClient()
                            webViewClient = object : WebViewClient() {
                                override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean = false
                                override fun onPageFinished(view: WebView?, url: String?) {
                                    checkCookiesAndComplete(view)
                                }
                            }
                            loadUrl("https://www.instagram.com/accounts/login/")
                        }
                    },
                    modifier = Modifier.fillMaxSize()
                )
            }
        }
    }
}
