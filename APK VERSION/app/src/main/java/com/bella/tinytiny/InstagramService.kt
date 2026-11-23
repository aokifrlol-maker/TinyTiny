package com.bella.tinytiny

import android.annotation.SuppressLint
import android.view.ViewGroup
import android.webkit.CookieManager
import android.webkit.JavascriptInterface
import android.webkit.WebResourceRequest
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
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.time.Instant
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

@Serializable
data class InstagramAccountSession(
    var username: String = "",
    var userId: String = "",
    var sessionId: String = "",
    var csrfToken: String = ""
) {
    val isConnected: Boolean get() = sessionId.isNotEmpty() && csrfToken.isNotEmpty()
}

object InstagramParser {
    fun parseReels(rawJson: String): List<Gif> {
        val root = try {
            val t = rawJson.trim()
            if (t.startsWith("[")) JSONArray(t) else JSONObject(t)
        } catch (_: Throwable) {
            return emptyList()
        }
        val results = mutableListOf<Gif>()
        val seen = mutableSetOf<String>()
        walk(root, results, seen, 0)
        return results
    }

    private fun walk(node: Any?, out: MutableList<Gif>, seen: MutableSet<String>, depth: Int) {
        if (depth > 16 || node == null) return
        when (node) {
            is JSONArray -> for (i in 0 until node.length()) walk(node.opt(i), out, seen, depth + 1)
            is JSONObject -> {
                val versions = node.optJSONArray("video_versions")
                val pk = node.opt("pk")?.toString()?.takeIf { it.isNotEmpty() } ?: node.optString("id").takeIf { it.isNotEmpty() }
                if (versions != null && versions.length() > 0 && pk != null) {
                    var bestUrl: String? = null
                    var bestW = 0
                    for (i in 0 until versions.length()) {
                        val v = versions.optJSONObject(i) ?: continue
                        val u = v.optString("url")
                        val w = v.optInt("width", 0)
                        if (u.isNotEmpty() && w >= bestW) {
                            bestW = w
                            bestUrl = u
                        }
                    }
                    if (bestUrl != null) {
                        val gid = "ig_$pk"
                        if (seen.add(gid)) {
                            val userObj = node.optJSONObject("user")
                            val uname = userObj?.optString("username")?.takeIf { it.isNotEmpty() } ?: "instagram"
                            val caption = node.optJSONObject("caption")?.optString("text")?.trim()
                            val code = node.optString("code")
                            val thumb = node.optJSONObject("image_versions2")?.optJSONArray("candidates")?.optJSONObject(0)?.optString("url")
                            val takenAt = node.optLong("taken_at", 0L).takeIf { it > 0 }?.let { Instant.ofEpochSecond(it).toString() }
                            val permalink = if (code.isNotEmpty()) "https://www.instagram.com/reel/$code/" else "https://www.instagram.com/$uname/"
                            out.add(
                                Gif(
                                    id = gid,
                                    title = caption?.takeIf { it.isNotEmpty() } ?: "@$uname",
                                    author = uname,
                                    subreddit = "instagram",
                                    upvotes = node.optInt("like_count", 0),
                                    duration = node.optDouble("video_duration", 0.0).takeIf { it > 0 },
                                    width = node.optInt("original_width", 0).takeIf { it > 0 },
                                    height = node.optInt("original_height", 0).takeIf { it > 0 },
                                    mediaType = "video",
                                    mediaUrl = bestUrl,
                                    muxedUrl = bestUrl,
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
                    walk(node.opt(keys.next()), out, seen, depth + 1)
                }
            }
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

    private var webView: WebView? = null
    private var hostContainer: ViewGroup? = null
    private val routeBuffers = ConcurrentHashMap<String, MutableList<Gif>>()
    @Volatile private var activeRouteKey = "ig_reels"

    private const val HOOK_JS = """
        (function(){
          if(window.__ttIGHooked) return;
          window.__ttIGHooked = true;
          function isIGApi(u){
            return u && (u.includes('/api/v1/') || u.includes('/graphql/query'));
          }
          const origFetch = window.fetch;
          window.fetch = async function(){
            const resp = await origFetch.apply(this, arguments);
            try {
              const url = (arguments[0] && arguments[0].url) ? arguments[0].url : String(arguments[0] || '');
              if(isIGApi(url)) {
                const clone = resp.clone();
                clone.text().then(t => { if(t && t.length > 100) window.TTIGBridge.onPayload(url, t); });
              }
            } catch(e){}
            return resp;
          };
          const origOpen = XMLHttpRequest.prototype.open;
          const origSend = XMLHttpRequest.prototype.send;
          XMLHttpRequest.prototype.open = function(m, u){ this.__ttUrl = String(u || ''); return origOpen.apply(this, arguments); };
          XMLHttpRequest.prototype.send = function(){
            this.addEventListener('load', function(){
              try {
                if(isIGApi(this.__ttUrl)) {
                  const t = typeof this.responseText === 'string' ? this.responseText : '';
                  if(t && t.length > 100) window.TTIGBridge.onPayload(this.__ttUrl, t);
                }
              } catch(e){}
            });
            return origSend.apply(this, arguments);
          };
        })();
    """

    class Bridge {
        @JavascriptInterface
        fun onPayload(url: String, body: String) {
            val reels = InstagramParser.parseReels(body)
            if (reels.isNotEmpty()) {
                val list = routeBuffers.getOrPut(activeRouteKey) { mutableListOf() }
                synchronized(list) {
                    val existing = list.map { it.id }.toSet()
                    for (r in reels) if (r.id !in existing) list.add(r)
                }
            }
        }
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
        webView?.let { wv ->
            (wv.parent as? ViewGroup)?.removeView(wv)
            wv.stopLoading()
            wv.loadUrl("about:blank")
            wv.destroy()
        }
        webView = null
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
        val ctx = hostContainer?.context ?: TinyTinyApplication.instance
        val chromeUa = try {
            android.webkit.WebSettings.getDefaultUserAgent(ctx).replace("; wv", "")
        } catch (_: Throwable) {
            "Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36"
        }
        val wv = WebView(ctx).apply {
            layoutParams = ViewGroup.LayoutParams(390, 844)
            setBackgroundColor(android.graphics.Color.BLACK)
            settings.javaScriptEnabled = true
            settings.domStorageEnabled = true
            settings.databaseEnabled = true
            settings.loadWithOverviewMode = true
            settings.useWideViewPort = true
            settings.mixedContentMode = android.webkit.WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE
            settings.userAgentString = chromeUa
            CookieManager.getInstance().setAcceptCookie(true)
            CookieManager.getInstance().setAcceptThirdPartyCookies(this, true)
            addJavascriptInterface(Bridge(), "TTIGBridge")
            webChromeClient = android.webkit.WebChromeClient()
            webViewClient = object : WebViewClient() {
                override fun onPageStarted(view: WebView?, url: String?, favicon: android.graphics.Bitmap?) {
                    view?.evaluateJavascript(HOOK_JS, null)
                }

                override fun onPageFinished(view: WebView?, url: String?) {
                    view?.evaluateJavascript(HOOK_JS, null)
                }
            }
        }
        hostContainer?.addView(wv, ViewGroup.LayoutParams(390, 844))
        webView = wv
        wv
    }

    suspend fun warmUp() {
        val wv = ensureWebView()
        withContext(Dispatchers.Main) {
            if (wv.url.isNullOrEmpty()) wv.loadUrl("https://www.instagram.com/reels/")
        }
    }

    suspend fun fetchRoute(routeKey: String, targetUrl: String, after: String? = null): GoonedFeedResponse {
        activeRouteKey = routeKey
        val wv = ensureWebView()
        withContext(Dispatchers.Main) {
            if (wv.url != targetUrl && after == null) {
                wv.loadUrl(targetUrl)
            } else {
                wv.evaluateJavascript("window.scrollBy(0, window.innerHeight * 2.0);", null)
            }
        }
        for (i in 0 until 20) {
            val buf = routeBuffers[routeKey]
            if (buf != null && buf.isNotEmpty()) break
            delay(250)
        }
        val items = routeBuffers.remove(routeKey)?.let { synchronized(it) { it.toList() } } ?: emptyList()
        return GoonedFeedResponse(posts = items, after = "${System.currentTimeMillis()}")
    }

    suspend fun fetchDirectInboxThreads(): List<IGDirectThread> = withContext(Dispatchers.IO) {
        val ig = UserStore.shared.data.value.igSession
        if (!ig.isConnected) return@withContext emptyList()
        try {
            val cookies = CookieManager.getInstance().getCookie("https://www.instagram.com") ?: ""
            val req = Request.Builder()
                .url("https://www.instagram.com/api/v1/direct_v2/inbox/?limit=20&thread_message_limit=1")
                .header("User-Agent", Config.userAgent)
                .header("X-IG-App-ID", "936619743392459")
                .header("X-CSRFToken", ig.csrfToken)
                .header("Cookie", cookies.ifEmpty { "sessionid=${ig.sessionId}; csrftoken=${ig.csrfToken}; ds_user_id=${ig.userId}" })
                .build()
            TinyTinyApplication.sharedHttpClient.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) return@withContext emptyList()
                val raw = resp.body?.string() ?: return@withContext emptyList()
                val threads = JSONObject(raw).optJSONObject("inbox")?.optJSONArray("threads") ?: return@withContext emptyList()
                val out = mutableListOf<IGDirectThread>()
                for (i in 0 until threads.length()) {
                    val t = threads.optJSONObject(i) ?: continue
                    val tid = t.optString("thread_id").takeIf { it.isNotEmpty() } ?: continue
                    val title = t.optString("thread_title").ifEmpty {
                        val users = t.optJSONArray("users")
                        if (users != null && users.length() > 0) users.optJSONObject(0)?.optString("username") ?: "Chat" else "Chat"
                    }
                    val isGroup = t.optBoolean("is_group", false)
                    out.add(IGDirectThread(tid, title, isGroup, if (isGroup) "Group Chat" else "Direct Message"))
                }
                out
            }
        } catch (_: Throwable) {
            emptyList()
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
            val videoBytes = TinyTinyApplication.sharedHttpClient.newCall(dlReq).execute().use { r ->
                if (!r.isSuccessful) return@withContext Result.failure(IllegalStateException("Failed to fetch MP4 (${r.code})"))
                r.body?.bytes() ?: return@withContext Result.failure(IllegalStateException("Empty video"))
            }
            val uploadId = System.currentTimeMillis().toString()
            val cookies = CookieManager.getInstance().getCookie("https://www.instagram.com")
                ?: "sessionid=${ig.sessionId}; csrftoken=${ig.csrfToken}; ds_user_id=${ig.userId}"
            val ruploadParams = JSONObject().apply {
                put("media_type", 2)
                put("upload_id", uploadId)
                put("xsharing_user_ids", JSONArray())
            }.toString()

            val upReq = Request.Builder()
                .url("https://i.instagram.com/rupload_igvideo/fb_uploader_$uploadId")
                .header("User-Agent", Config.userAgent)
                .header("X-IG-App-ID", "936619743392459")
                .header("X-CSRFToken", ig.csrfToken)
                .header("Cookie", cookies)
                .header("X-Instagram-Rupload-Params", ruploadParams)
                .header("X-Entity-Type", "video/mp4")
                .header("X-Entity-Name", "fb_uploader_$uploadId")
                .header("X-Entity-Length", "${videoBytes.size}")
                .header("Offset", "0")
                .post(videoBytes.toRequestBody("application/octet-stream".toMediaType()))
                .build()

            TinyTinyApplication.sharedHttpClient.newCall(upReq).execute().use { upResp ->
                if (!upResp.isSuccessful) return@withContext Result.failure(IllegalStateException("IG upload failed (${upResp.code})"))
            }

            val ctxToken = UUID.randomUUID().toString()
            val formBody = "action=send_item&thread_ids=[$threadId]&upload_id=$uploadId&client_context=$ctxToken"
                .toRequestBody("application/x-www-form-urlencoded".toMediaType())
            val sendReq = Request.Builder()
                .url("https://i.instagram.com/api/v1/direct_v2/threads/broadcast/configure_video/")
                .header("User-Agent", Config.userAgent)
                .header("X-IG-App-ID", "936619743392459")
                .header("X-CSRFToken", ig.csrfToken)
                .header("Cookie", cookies)
                .post(formBody)
                .build()
            TinyTinyApplication.sharedHttpClient.newCall(sendReq).execute().use { sendResp ->
                if (!sendResp.isSuccessful) return@withContext Result.failure(IllegalStateException("IG DM broadcast failed (${sendResp.code})"))
            }
            Result.success(Unit)
        } catch (e: Throwable) {
            Result.failure(e)
        }
    }
}

object InstagramAPI {
    suspend fun reelsFeed(after: String? = null): GoonedFeedResponse =
        InstagramWebEngine.fetchRoute("ig_reels", "https://www.instagram.com/reels/", after)

    suspend fun followingFeed(after: String? = null): GoonedFeedResponse =
        InstagramWebEngine.fetchRoute("ig_following", "https://www.instagram.com/", after)

    suspend fun savedFeed(after: String? = null): GoonedFeedResponse {
        val uname = UserStore.shared.data.value.igSession.username.trim().removePrefix("@")
        val target = if (uname.isNotEmpty() && uname != "IG Account") "https://www.instagram.com/$uname/saved/" else "https://www.instagram.com/accounts/saved/"
        return InstagramWebEngine.fetchRoute("ig_saved", target, after)
    }

    suspend fun userReels(handle: String, after: String? = null): GoonedFeedResponse {
        val clean = handle.trim().removePrefix("@")
        return InstagramWebEngine.fetchRoute("ig_user_$clean", "https://www.instagram.com/$clean/reels/", after)
    }
}

@SuppressLint("SetJavaScriptEnabled")
@Composable
fun InstagramLoginSheet(onConnected: () -> Unit, onDismiss: () -> Unit) {
    val store = UserStore.shared
    var detected by remember { mutableStateOf(false) }
    val loginWebViewRef = remember { arrayOfNulls<WebView>(1) }

    fun checkCookiesAndComplete(wv: WebView?) {
        if (detected) return
        val cookies = CookieManager.getInstance().getCookie("https://www.instagram.com") ?: ""
        val map = cookies.split(";").mapNotNull {
            val p = it.trim().split("=", limit = 2)
            if (p.size == 2) p[0] to p[1] else null
        }.toMap()
        val sid = map["sessionid"] ?: ""
        val csrf = map["csrftoken"] ?: ""
        val uid = map["ds_user_id"] ?: ""
        if (sid.isNotEmpty() && csrf.isNotEmpty()) {
            detected = true
            val finishWithHandle: (String) -> Unit = { handle ->
                val clean = handle.trim().removePrefix("@").ifEmpty { "IG Account" }
                store.updateIGSession(
                    InstagramAccountSession(
                        username = clean,
                        userId = uid,
                        sessionId = sid,
                        csrfToken = csrf
                    )
                )
                onConnected()
            }
            if (wv != null) {
                wv.evaluateJavascript(
                    "(function(){ const a = document.querySelector('a[href^=\"/\"][role=\"link\"] span'); return (window._sharedData && window._sharedData.config && window._sharedData.config.viewer && window._sharedData.config.viewer.username) || (a ? a.innerText : '') || ''; })()"
                ) { res ->
                    val parsed = res?.trim('"')?.takeIf { it.isNotEmpty() && it != "null" && !it.contains(" ") } ?: ""
                    finishWithHandle(parsed)
                }
            } else {
                finishWithHandle("")
            }
        }
    }

    LaunchedEffect(Unit) {
        while (!detected) {
            kotlinx.coroutines.delay(900)
            checkCookiesAndComplete(loginWebViewRef[0])
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black)
            .statusBarsPadding()
            .navigationBarsPadding()
            .imePadding()
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
            IconButton(onClick = onDismiss) {
                Icon(Icons.Default.Close, contentDescription = "Close", tint = Color.White)
            }
        }

        Box(modifier = Modifier.fillMaxWidth().weight(1f)) {
            AndroidView(
                factory = { ctx ->
                    WebView(ctx).apply {
                        loginWebViewRef[0] = this
                        layoutParams = ViewGroup.LayoutParams(
                            ViewGroup.LayoutParams.MATCH_PARENT,
                            ViewGroup.LayoutParams.MATCH_PARENT
                        )
                        minimumHeight = (ctx.resources.displayMetrics.heightPixels - 180).coerceAtLeast(500)
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
                        settings.loadWithOverviewMode = true
                        settings.useWideViewPort = true
                        settings.javaScriptCanOpenWindowsAutomatically = true
                        settings.mixedContentMode = android.webkit.WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE
                        settings.userAgentString = chromeUa
                        CookieManager.getInstance().setAcceptCookie(true)
                        CookieManager.getInstance().setAcceptThirdPartyCookies(this, true)
                        webChromeClient = android.webkit.WebChromeClient()
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
