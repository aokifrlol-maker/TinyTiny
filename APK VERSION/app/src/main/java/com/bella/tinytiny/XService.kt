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
import org.json.JSONArray
import org.json.JSONObject
import java.net.URLEncoder
import java.time.Instant
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap

@Serializable
data class XAccountSession(
    var username: String = "",
    var authToken: String = "",
    var ct0: String = "",
    var isConnected: Boolean = false
)

object XTweetParser {
    private val twitterDateFormatter = DateTimeFormatter.ofPattern("EEE MMM dd HH:mm:ss Z yyyy", Locale.US)

    fun parseTweets(rawJson: String): List<Gif> {
        val root = try {
            val trimmed = rawJson.trim()
            if (trimmed.startsWith("[")) JSONArray(trimmed) else JSONObject(trimmed)
        } catch (_: Throwable) {
            return emptyList()
        }
        val results = mutableListOf<Gif>()
        val seen = mutableSetOf<String>()
        walk(root, null, results, seen, 0)
        return results
    }

    private fun walk(node: Any?, inheritedAuthor: String?, out: MutableList<Gif>, seen: MutableSet<String>, depth: Int) {
        if (depth > 18 || node == null) return
        when (node) {
            is JSONArray -> {
                for (i in 0 until node.length()) {
                    walk(node.opt(i), inheritedAuthor, out, seen, depth + 1)
                }
            }
            is JSONObject -> {
                val legacy = node.optJSONObject("legacy")
                val coreUser = node.optJSONObject("core")?.optJSONObject("user_results")?.optJSONObject("result")?.optJSONObject("legacy")
                val screenName = coreUser?.optString("screen_name")?.takeIf { it.isNotEmpty() }
                    ?: node.optString("screen_name").takeIf { it.isNotEmpty() }
                    ?: inheritedAuthor

                if (legacy != null) {
                    val restId = node.optString("rest_id").ifEmpty { legacy.optString("id_str") }
                    val extEntities = legacy.optJSONObject("extended_entities") ?: legacy.optJSONObject("entities")
                    val mediaArr = extEntities?.optJSONArray("media")
                    if (restId.isNotEmpty() && mediaArr != null) {
                        for (mIdx in 0 until mediaArr.length()) {
                            val m = mediaArr.optJSONObject(mIdx) ?: continue
                            val type = m.optString("type")
                            if (type != "video" && type != "animated_gif") continue
                            val videoInfo = m.optJSONObject("video_info") ?: continue
                            val variants = videoInfo.optJSONArray("variants") ?: continue
                            var bestMp4: String? = null
                            var bestBitrate = -1
                            var lowMp4: String? = null
                            var lowBitrate = Int.MAX_VALUE
                            var hlsUrl: String? = null
                            for (vIdx in 0 until variants.length()) {
                                val v = variants.optJSONObject(vIdx) ?: continue
                                val ct = v.optString("content_type")
                                val u = v.optString("url")
                                if (u.isEmpty()) continue
                                if (ct.contains("mpegurl") || u.contains(".m3u8")) {
                                    hlsUrl = u
                                } else if (ct == "video/mp4") {
                                    val br = v.optInt("bitrate", 0)
                                    if (br >= bestBitrate) { bestBitrate = br; bestMp4 = u }
                                    if (br <= lowBitrate) { lowBitrate = br; lowMp4 = u }
                                }
                            }
                            if (bestMp4 != null || hlsUrl != null) {
                                val gid = "x_${restId}_$mIdx"
                                if (seen.add(gid)) {
                                    val fullText = legacy.optString("full_text").replace(Regex("https://t\\.co/\\S+"), "").trim()
                                    val thumb = m.optString("media_url_https").takeIf { it.isNotEmpty() }
                                    val orig = m.optJSONObject("original_info")
                                    val w = orig?.optInt("width", 0)?.takeIf { it > 0 }
                                    val h = orig?.optInt("height", 0)?.takeIf { it > 0 }
                                    val dur = videoInfo.optDouble("duration_millis", 0.0).takeIf { it > 0 }?.let { it / 1000.0 }
                                    val created = parseTwitterDate(legacy.optString("created_at"))
                                    val authorClean = screenName ?: "x_user"
                                    val tags = Regex("#([A-Za-z0-9_]+)").findAll(fullText).map { it.groupValues[1].lowercase() }.toList()
                                    MediaMetaRegistry.register(gid, tags = tags, creatorName = authorClean)
                                    out.add(
                                        Gif(
                                            id = gid,
                                            title = fullText.ifEmpty { "@$authorClean" },
                                            author = authorClean,
                                            subreddit = "x.com",
                                            upvotes = legacy.optInt("favorite_count", 0),
                                            duration = dur,
                                            width = w,
                                            height = h,
                                            mediaType = "video",
                                            mediaUrl = lowMp4 ?: bestMp4 ?: hlsUrl,
                                            muxedUrl = lowMp4 ?: bestMp4,
                                            muxedUrlHd = bestMp4 ?: lowMp4,
                                            hlsUrl = hlsUrl,
                                            posterUrl = thumb,
                                            thumbnailUrl = thumb,
                                            sourceUrl = "https://x.com/$authorClean/status/$restId",
                                            permalink = "https://x.com/$authorClean/status/$restId",
                                            createdUtc = created
                                        )
                                    )
                                }
                            }
                        }
                    }
                }
                val keys = node.keys()
                while (keys.hasNext()) {
                    val k = keys.next()
                    walk(node.opt(k), screenName, out, seen, depth + 1)
                }
            }
        }
    }

    private fun parseTwitterDate(raw: String?): String? {
        if (raw.isNullOrEmpty()) return null
        return try {
            ZonedDateTime.parse(raw, twitterDateFormatter).toInstant().toString()
        } catch (_: Throwable) {
            null
        }
    }

    fun extractBottomCursor(rawJson: String): String? {
        return try {
            val m = Regex(""""cursorType"\s*:\s*"Bottom"[\s\S]{0,120}?"value"\s*:\s*"([^"]+)"""").find(rawJson)
                ?: Regex(""""value"\s*:\s*"([^"]+)"[\s\S]{0,120}?"cursorType"\s*:\s*"Bottom"""").find(rawJson)
            m?.groupValues?.get(1)
        } catch (_: Throwable) {
            null
        }
    }
}

object XWebEngine {
    private var webView: WebView? = null
    private var hostContainer: ViewGroup? = null
    private val routeBuffers = ConcurrentHashMap<String, MutableList<Gif>>()
    private val routeCursors = ConcurrentHashMap<String, String>()
    @Volatile private var activeRouteKey: String = "x_foryou"
    @Volatile var isRateLimitedNow: Boolean = false
        private set

    private const val HOOK_JS = """
        (function(){
          if(window.__ttXHooked) return;
          window.__ttXHooked = true;
          function isXApi(u){
            return u && (u.includes('/graphql/') || u.includes('/2/timeline') || u.includes('SearchTimeline') || u.includes('UserTweets') || u.includes('Bookmarks') || u.includes('HomeTimeline') || u.includes('Likes'));
          }
          const origFetch = window.fetch;
          window.fetch = async function(){
            const resp = await origFetch.apply(this, arguments);
            try {
              const url = (arguments[0] && arguments[0].url) ? arguments[0].url : String(arguments[0] || '');
              if(isXApi(url)) {
                if(resp.status === 429) { window.TTXBridge.onRateLimit(); }
                const clone = resp.clone();
                clone.text().then(t => { if(t && t.length > 100) window.TTXBridge.onPayload(url, t); });
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
                if(isXApi(this.__ttUrl)) {
                  if(this.status === 429) { window.TTXBridge.onRateLimit(); }
                  const t = typeof this.responseText === 'string' ? this.responseText : '';
                  if(t && t.length > 100) window.TTXBridge.onPayload(this.__ttUrl, t);
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
            val tweets = XTweetParser.parseTweets(body)
            val cursor = XTweetParser.extractBottomCursor(body)
            val key = activeRouteKey
            if (tweets.isNotEmpty()) {
                val list = routeBuffers.getOrPut(key) { mutableListOf() }
                synchronized(list) {
                    val existing = list.map { it.id }.toSet()
                    for (t in tweets) if (t.id !in existing) list.add(t)
                }
            }
            if (!cursor.isNullOrEmpty()) routeCursors[key] = cursor
        }

        @JavascriptInterface
        fun onRateLimit() {
            isRateLimitedNow = true
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
        routeCursors.clear()
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
            addJavascriptInterface(Bridge(), "TTXBridge")
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
            if (wv.url.isNullOrEmpty()) wv.loadUrl("https://x.com/home")
        }
    }

    suspend fun fetchRoute(routeKey: String, targetUrl: String, after: String? = null): GoonedFeedResponse {
        activeRouteKey = routeKey
        val wv = ensureWebView()
        withContext(Dispatchers.Main) {
            wv.evaluateJavascript(HOOK_JS, null)
            val currentUrl = wv.url ?: ""
            val isSameBase = currentUrl.startsWith(targetUrl)
            if (!isSameBase && after == null) {
                wv.loadUrl(targetUrl)
            } else if (routeKey == "x_foryou" || routeKey == "x_following") {
                val tabLabel = if (routeKey == "x_following") "Following" else "For you"
                wv.evaluateJavascript(
                    """
                    (function(){
                      const tabs = Array.from(document.querySelectorAll('[role="tab"]'));
                      const target = tabs.find(t => (t.innerText || '').trim().toLowerCase() === '${tabLabel.lowercase()}');
                      if(target && target.getAttribute('aria-selected') !== 'true') { target.click(); }
                      else { window.scrollBy(0, window.innerHeight * 2.2); }
                    })();
                    """.trimIndent(),
                    null
                )
            } else {
                wv.evaluateJavascript("window.scrollBy(0, window.innerHeight * 2.2);", null)
            }
        }
        for (i in 0 until 24) {
            val buf = routeBuffers[routeKey]
            if (buf != null && buf.isNotEmpty()) break
            delay(250)
        }
        val items = routeBuffers.remove(routeKey)?.let { synchronized(it) { it.toList() } } ?: emptyList()
        return GoonedFeedResponse(posts = items, after = routeCursors[routeKey] ?: "${System.currentTimeMillis()}")
    }
}

object XAPI {
    suspend fun forYou(after: String? = null): GoonedFeedResponse =
        XWebEngine.fetchRoute("x_foryou", "https://x.com/home", after)

    suspend fun following(after: String? = null): GoonedFeedResponse =
        XWebEngine.fetchRoute("x_following", "https://x.com/home", after)

    suspend fun bookmarks(after: String? = null): GoonedFeedResponse =
        XWebEngine.fetchRoute("x_bookmarks", "https://x.com/i/bookmarks", after)

    suspend fun likes(after: String? = null): GoonedFeedResponse {
        val uname = UserStore.shared.data.value.xSession.username.removePrefix("@").trim()
        val url = if (uname.isNotEmpty() && uname != "𝕏 Account") "https://x.com/$uname/likes" else "https://x.com/home"
        return XWebEngine.fetchRoute("x_likes", url, after)
    }

    suspend fun search(query: String, after: String? = null): GoonedFeedResponse {
        val enc = URLEncoder.encode(query.trim(), "UTF-8")
        return XWebEngine.fetchRoute("x_search_$query", "https://x.com/search?q=$enc&f=live", after)
    }

    suspend fun userTweets(handle: String, after: String? = null): GoonedFeedResponse {
        val clean = handle.trim().removePrefix("@")
        return XWebEngine.fetchRoute("x_user_$clean", "https://x.com/$clean/media", after)
    }
}

@SuppressLint("SetJavaScriptEnabled")
@Composable
fun XLoginSheet(onConnected: () -> Unit, onDismiss: () -> Unit) {
    val store = UserStore.shared
    var detected by remember { mutableStateOf(false) }
    val loginWebViewRef = remember { arrayOfNulls<WebView>(1) }

    fun checkCookiesAndComplete(wv: WebView?) {
        if (detected) return
        val cookies = CookieManager.getInstance().getCookie("https://x.com") ?: ""
        val map = cookies.split(";").mapNotNull {
            val p = it.trim().split("=", limit = 2)
            if (p.size == 2) p[0] to p[1] else null
        }.toMap()
        val auth = map["auth_token"] ?: ""
        val ct0 = map["ct0"] ?: ""
        if (auth.isNotEmpty() && ct0.isNotEmpty()) {
            detected = true
            val finishWithHandle: (String) -> Unit = { handle ->
                val clean = handle.trim().removePrefix("@").ifEmpty { "𝕏 Account" }
                store.updateXSession(XAccountSession(username = clean, authToken = auth, ct0 = ct0, isConnected = true))
                onConnected()
            }
            if (wv != null) {
                wv.evaluateJavascript(
                    "(function(){ const a = document.querySelector('a[data-testid=\"AppTabBar_Profile_Link\"]'); return a ? (a.getAttribute('href') || '').replace(/^\\//,'') : ''; })()"
                ) { res ->
                    val parsed = res?.trim('"')?.takeIf { it.isNotEmpty() && it != "null" } ?: ""
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
            BrandLogoX(22.dp)
            Spacer(Modifier.width(10.dp))
            Text("Sign in to 𝕏", color = Color.White, fontSize = 18.sp, fontWeight = FontWeight.Bold)
            Spacer(Modifier.weight(1f))
            IconButton(onClick = onDismiss) {
                Icon(Icons.Default.Close, contentDescription = "Close", tint = Color.White)
            }
        }

        AndroidView(
            factory = { ctx ->
                WebView(ctx).apply {
                    loginWebViewRef[0] = this
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
                    loadUrl("https://x.com/login")
                }
            },
            modifier = Modifier.fillMaxWidth().weight(1f)
        )
    }
}
