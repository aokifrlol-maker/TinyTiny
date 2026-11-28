package com.bella.tinytiny

import android.annotation.SuppressLint
import android.os.Message
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
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.Serializable
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.net.URLEncoder
import java.time.Instant
import java.time.ZonedDateTime
import java.time.format.DateTimeFormatter
import java.util.Locale
import java.util.concurrent.ConcurrentHashMap

// Exact iOS Codable wire format — NO duplicate @JsonNames collision!
@Serializable
data class XAccountSession(
    var authToken: String = "",
    var ct0: String = "",
    var userId: String = "",
    var screenName: String = "",
    var mixIntoForYou: Boolean = true
) {
    val username: String get() = screenName
    val isConnected: Boolean get() = authToken.isNotEmpty() && ct0.isNotEmpty()
    val displayHandle: String get() = screenName.removePrefix("@").ifEmpty { "𝕏 Account" }
}

object XTweetParser {
    private val twitterDateFormatter = DateTimeFormatter.ofPattern("EEE MMM dd HH:mm:ss Z yyyy", Locale.US)

    fun parseScreenName(rawJson: String): String? {
        return try {
            val obj = JSONObject(rawJson)
            obj.optString("screen_name").takeIf { it.isNotEmpty() }
                ?: obj.optJSONObject("data")?.optJSONObject("viewer")?.optJSONObject("user_results")
                    ?.optJSONObject("result")?.let { r ->
                        r.optJSONObject("core")?.optString("screen_name")?.takeIf { it.isNotEmpty() }
                            ?: r.optJSONObject("legacy")?.optString("screen_name")?.takeIf { it.isNotEmpty() }
                    }
        } catch (_: Throwable) {
            null
        }
    }

    fun parseTweets(rawJson: String, routeKey: String = ""): List<Gif> {
        val root = try {
            val trimmed = rawJson.trim()
            if (trimmed.startsWith("[")) JSONArray(trimmed) else JSONObject(trimmed)
        } catch (_: Throwable) {
            return emptyList()
        }
        val results = mutableListOf<Gif>()
        val seen = mutableSetOf<String>()
        walk(root, null, "", null, routeKey, results, seen)
        return results
    }

    private fun walk(
        node: Any?,
        inheritedAuthor: String?,
        inheritedBio: String,
        inheritedFollowed: Boolean?,
        routeKey: String,
        out: MutableList<Gif>,
        seen: MutableSet<String>
    ) {
        if (node == null) return
        when (node) {
            is JSONArray -> {
                for (i in 0 until node.length()) {
                    walk(node.opt(i), inheritedAuthor, inheritedBio, inheritedFollowed, routeKey, out, seen)
                }
            }
            is JSONObject -> {
                // Strict ad / promoted rejection (exact iOS parity)
                val entryId = node.optString("entryId", "").lowercase()
                if (entryId.contains("promoted") || entryId.contains("who-to-follow") || entryId.contains(" module")) return
                if (node.has("promotedMetadata") || node.has("promoted_metadata") || node.has("adMetadata")) return
                val comp = node.optJSONObject("clientEventInfo")?.optString("component", "")?.lowercase() ?: ""
                if (comp.contains("promoted") || comp.contains("ad_")) return
                if (node.optString("tweetDisplayType", "").equals("Promoted", ignoreCase = true)) return

                val legacy = node.optJSONObject("legacy")
                val userResult = node.optJSONObject("core")?.optJSONObject("user_results")?.optJSONObject("result")
                val coreObj = userResult?.optJSONObject("core")
                val coreLegacy = userResult?.optJSONObject("legacy")
                val restUser = node.optJSONObject("user")

                val screenName = coreObj?.optString("screen_name")?.takeIf { it.isNotEmpty() }
                    ?: coreLegacy?.optString("screen_name")?.takeIf { it.isNotEmpty() }
                    ?: restUser?.optString("screen_name")?.takeIf { it.isNotEmpty() }
                    ?: node.optString("screen_name").takeIf { it.isNotEmpty() }
                    ?: inheritedAuthor

                val authorBio = coreLegacy?.optString("description")?.takeIf { it.isNotEmpty() }
                    ?: coreObj?.optString("description")?.takeIf { it.isNotEmpty() }
                    ?: userResult?.optString("description")?.takeIf { it.isNotEmpty() }
                    ?: restUser?.optString("description")?.takeIf { it.isNotEmpty() }
                    ?: inheritedBio

                val relFollow = userResult?.optJSONObject("relationship_perspectives")?.let {
                    if (it.has("following")) it.optBoolean("following") else null
                } ?: coreLegacy?.let { if (it.has("following")) it.optBoolean("following") else null }
                    ?: restUser?.let { if (it.has("following")) it.optBoolean("following") else null }
                    ?: inheritedFollowed

                val isFollowingFeed = routeKey == "x_following"

                // Extract media from media_entities2, legacy.extended_entities, node.extended_entities, or legacy.entities
                val mediaArr = node.optJSONArray("media_entities2")
                    ?: legacy?.optJSONArray("media_entities2")
                    ?: legacy?.optJSONObject("extended_entities")?.optJSONArray("media")
                    ?: node.optJSONObject("extended_entities")?.optJSONArray("media")
                    ?: legacy?.optJSONObject("entities")?.optJSONArray("media")

                val isRetweet = legacy?.has("retweeted_status_result") == true ||
                    legacy?.has("retweeted_status_id_str") == true ||
                    node.has("retweeted_status")

                if (mediaArr != null && mediaArr.length() > 0 && !(isFollowingFeed && (isRetweet || relFollow == false))) {
                    val restId = node.optString("rest_id").ifEmpty {
                        legacy?.optString("id_str") ?: node.optString("id_str")
                    }
                    val rawText = legacy?.optString("full_text")?.takeIf { it.isNotEmpty() }
                        ?: node.optJSONObject("details")?.optString("full_text")?.takeIf { it.isNotEmpty() }
                        ?: node.optString("full_text").takeIf { it.isNotEmpty() }
                        ?: node.optJSONObject("note_tweet")?.optJSONObject("note_tweet_results")
                            ?.optJSONObject("result")?.optString("text")?.takeIf { it.isNotEmpty() }
                        ?: legacy?.optString("text")?.takeIf { it.isNotEmpty() }
                        ?: node.optString("text")
                        ?: ""
                    val cleanText = rawText.replace(Regex("https?://t\\.co/[A-Za-z0-9]+"), "").trim()
                    val authorClean = (screenName ?: "x_user").removePrefix("@")

                    val possiblySensitive = (legacy?.optBoolean("possibly_sensitive", false) == true) ||
                        node.optBoolean("possibly_sensitive", false) ||
                        node.optBoolean("is_nsfw", false)

                    var hasAdultWarning = false
                    var hasGraphicOnly = false
                    for (mIdx in 0 until mediaArr.length()) {
                        val m = mediaArr.optJSONObject(mIdx) ?: continue
                        val sw = m.optJSONObject("sensitive_media_warning") ?: m.optJSONObject("ext_sensitive_media_warning")
                        if (sw != null) {
                            val adult = sw.optBoolean("adult_content", false) || sw.optBoolean("nudity", false)
                            if (adult) hasAdultWarning = true
                            if (sw.optBoolean("graphic_violence", false) && !adult) hasGraphicOnly = true
                        }
                    }

                    val eligible = AdultContentClassifier.isEligibleXTweet(
                        text = cleanText,
                        author = authorClean,
                        authorBio = authorBio,
                        possiblySensitive = possiblySensitive,
                        hasAdultWarning = hasAdultWarning,
                        hasGraphicViolenceOnly = hasGraphicOnly,
                        routeKey = routeKey
                    )

                    // NOTE: Never `return` early on failure — continue walking children!
                    if (eligible && routeKey == "x_images") {
                        // Solely Images section: extract ONLY photo media (and multi-photo albums), skip all videos/GIFs
                        val photos = mutableListOf<Triple<String, Int?, Int?>>()
                        for (mIdx in 0 until mediaArr.length()) {
                            val m = mediaArr.optJSONObject(mIdx) ?: continue
                            val type = m.optString("type").lowercase()
                            if (type != "photo") continue
                            val rawPhoto = m.optString("media_url_https").takeIf { it.isNotEmpty() }
                                ?: m.optString("media_url").takeIf { it.isNotEmpty() }
                                ?: continue
                            val orig = m.optJSONObject("original_info")
                            val large = m.optJSONObject("sizes")?.optJSONObject("large")
                            val w = m.optInt("original_img_width", 0).takeIf { it > 0 }
                                ?: orig?.optInt("width", 0)?.takeIf { it > 0 }
                                ?: large?.optInt("w", 0)?.takeIf { it > 0 }
                            val h = m.optInt("original_img_height", 0).takeIf { it > 0 }
                                ?: orig?.optInt("height", 0)?.takeIf { it > 0 }
                                ?: large?.optInt("h", 0)?.takeIf { it > 0 }
                            photos.add(Triple(rawPhoto, w, h))
                        }
                        if (photos.isNotEmpty()) {
                            val firstM = mediaArr.optJSONObject(0)
                            val rawTweetId = restId.ifEmpty {
                                firstM?.optString("source_status_id_str")?.ifEmpty { firstM.optString("id_str") } ?: ""
                            }
                            if (rawTweetId.isNotEmpty()) {
                                val gid = "x_img_$rawTweetId"
                                if (seen.add(gid)) {
                                    val (firstUrl, w, h) = photos.first()
                                    val created = parseTwitterDate(legacy?.optString("created_at"))
                                        ?: node.optLong("created_at_ms", 0L).takeIf { it > 0 }?.let { Instant.ofEpochMilli(it).toString() }
                                    val hashTags = Regex("#([A-Za-z0-9_]+)").findAll(cleanText).map { it.groupValues[1].lowercase() }.toList()
                                    val bioTags = PornTagCatalog.extractRecognizedTagsFromQuery("$cleanText $authorBio")
                                    val albumItems = if (photos.size > 1) {
                                        photos.mapIndexed { idx, (u, _, _) ->
                                            AlbumMediaItem(id = "${gid}_$idx", url = u, posterUrl = u, isVideo = false)
                                        }
                                    } else emptyList()
                                    MediaMetaRegistry.register(
                                        postId = gid,
                                        tags = (hashTags + bioTags).distinct(),
                                        creatorName = authorClean,
                                        albumItems = albumItems,
                                        followedByViewer = relFollow
                                    )
                                    out.add(
                                        Gif(
                                            id = gid,
                                            title = cleanText,
                                            author = authorClean,
                                            subreddit = null,
                                            upvotes = legacy?.optInt("favorite_count", 0) ?: node.optInt("favorite_count", 0),
                                            duration = null,
                                            width = w,
                                            height = h,
                                            mediaType = "image",
                                            mediaUrl = firstUrl,
                                            muxedUrl = null,
                                            muxedUrlHd = null,
                                            hlsUrl = null,
                                            posterUrl = firstUrl,
                                            thumbnailUrl = firstUrl,
                                            sourceUrl = "https://x.com/$authorClean/status/$rawTweetId",
                                            permalink = "https://x.com/$authorClean/status/$rawTweetId",
                                            createdUtc = created
                                        )
                                    )
                                }
                            }
                        }
                    } else if (eligible) {
                        for (mIdx in 0 until mediaArr.length()) {
                            val m = mediaArr.optJSONObject(mIdx) ?: continue
                            val type = m.optString("type")
                            val videoInfo = m.optJSONObject("video_info")
                            if (type != "video" && type != "animated_gif" && videoInfo == null) continue
                            val variants = videoInfo?.optJSONArray("variants") ?: continue

                            val mp4Variants = mutableListOf<Pair<Int, String>>()
                            var hlsUrl: String? = null
                            for (vIdx in 0 until variants.length()) {
                                val v = variants.optJSONObject(vIdx) ?: continue
                                val ct = v.optString("content_type").lowercase()
                                val u = v.optString("url")
                                if (u.isEmpty()) continue
                                if (ct.contains("mpegurl") || u.contains(".m3u8")) {
                                    hlsUrl = u
                                } else if (ct.contains("mp4") || u.contains(".mp4")) {
                                    mp4Variants.add(v.optInt("bitrate", 0) to u)
                                }
                            }
                            mp4Variants.sortByDescending { it.first }
                            val bestMp4 = mp4Variants.firstOrNull()?.second
                            val fastStartMp4 = mp4Variants.firstOrNull { it.first in 1..2_500_000 }?.second
                                ?: mp4Variants.lastOrNull()?.second
                            val sdMp4 = fastStartMp4 ?: mp4Variants.getOrNull(1)?.second ?: bestMp4

                            if (bestMp4 != null || hlsUrl != null) {
                                val rawTweetId = restId.ifEmpty {
                                    m.optString("source_status_id_str").ifEmpty { m.optString("id_str") }
                                }
                                if (rawTweetId.isEmpty()) continue
                                val gid = "x_$rawTweetId"
                                val mediaKey = m.optString("media_key").takeIf { it.isNotEmpty() }
                                    ?: m.optString("source_status_id_str").takeIf { it.isNotEmpty() }?.let { "xsrc_$it" }
                                    ?: m.optString("id_str").takeIf { it.isNotEmpty() }?.let { "xmed_$it" }
                                val dedupeKey = mediaKey ?: gid

                                val isNew = if (dedupeKey == gid) seen.add(gid) else (seen.add(gid) && seen.add(dedupeKey))
                                if (isNew) {
                                    val thumb = m.optString("media_url_https").takeIf { it.isNotEmpty() }
                                        ?: m.optString("media_url").takeIf { it.isNotEmpty() }
                                    val orig = m.optJSONObject("original_info")
                                    val large = m.optJSONObject("sizes")?.optJSONObject("large")
                                    val w = m.optInt("original_img_width", 0).takeIf { it > 0 }
                                        ?: orig?.optInt("width", 0)?.takeIf { it > 0 }
                                        ?: large?.optInt("w", 0)?.takeIf { it > 0 }
                                    val h = m.optInt("original_img_height", 0).takeIf { it > 0 }
                                        ?: orig?.optInt("height", 0)?.takeIf { it > 0 }
                                        ?: large?.optInt("h", 0)?.takeIf { it > 0 }
                                    val dur = videoInfo.optDouble("duration_millis", 0.0).takeIf { it > 0 }?.let { it / 1000.0 }
                                    val created = parseTwitterDate(legacy?.optString("created_at"))
                                        ?: node.optLong("created_at_ms", 0L).takeIf { it > 0 }?.let { Instant.ofEpochMilli(it).toString() }

                                    val hashTags = Regex("#([A-Za-z0-9_]+)").findAll(cleanText).map { it.groupValues[1].lowercase() }.toList()
                                    val bioTags = PornTagCatalog.extractRecognizedTagsFromQuery("$cleanText $authorBio")
                                    val allVariants = (mp4Variants.map { it.second } + listOfNotNull(hlsUrl)).distinct()
                                    MediaMetaRegistry.register(
                                        postId = gid,
                                        tags = (hashTags + bioTags).distinct(),
                                        creatorName = authorClean,
                                        extraVideoURLs = allVariants,
                                        fingerprint = mediaKey,
                                        followedByViewer = relFollow
                                    )

                                    out.add(
                                        Gif(
                                            id = gid,
                                            title = cleanText,
                                            author = authorClean,
                                            subreddit = null,
                                            upvotes = legacy?.optInt("favorite_count", 0) ?: node.optInt("favorite_count", 0),
                                            duration = dur,
                                            width = w,
                                            height = h,
                                            mediaType = if (type == "animated_gif") "gif" else "video",
                                            mediaUrl = bestMp4 ?: hlsUrl,
                                            muxedUrl = sdMp4 ?: bestMp4,
                                            muxedUrlHd = bestMp4 ?: sdMp4,
                                            hlsUrl = hlsUrl,
                                            posterUrl = thumb,
                                            thumbnailUrl = thumb,
                                            sourceUrl = "https://x.com/$authorClean/status/$rawTweetId",
                                            permalink = "https://x.com/$authorClean/status/$rawTweetId",
                                            createdUtc = created
                                        )
                                    )
                                    break // 1 primary video per tweet like iOS
                                }
                            }
                        }
                    }
                }

                val keys = node.keys()
                while (keys.hasNext()) {
                    val k = keys.next()
                    if (isFollowingFeed && k in setOf(
                            "retweeted_status_result", "retweeted_status_results",
                            "quoted_status_result", "quoted_status_results",
                            "retweeted_status", "quoted_status"
                        )
                    ) continue
                    walk(node.opt(k), screenName, authorBio, relFollow, routeKey, out, seen)
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

    // Full recursive JSON walker for Bottom cursor (matches iOS)
    fun extractBottomCursor(rawJson: String): String? {
        return try {
            val root = JSONObject(rawJson)
            fun findCursor(node: Any?): String? {
                when (node) {
                    is JSONArray -> {
                        for (i in 0 until node.length()) {
                            findCursor(node.opt(i))?.let { return it }
                        }
                    }
                    is JSONObject -> {
                        val ct = node.optString("cursorType", "").ifEmpty { node.optString("cursor_type", "") }
                        if (ct.equals("Bottom", ignoreCase = true)) {
                            node.optString("value").takeIf { it.isNotEmpty() }?.let { return it }
                        }
                        node.optString("bottom_cursor").takeIf { it.isNotEmpty() }?.let { return it }
                        val keys = node.keys()
                        while (keys.hasNext()) {
                            findCursor(node.opt(keys.next()))?.let { return it }
                        }
                    }
                }
                return null
            }
            findCursor(root)
        } catch (_: Throwable) {
            null
        }
    }
}

private data class CapturedGraphQLOp(
    val opName: String,
    val url: String,
    val headers: Map<String, String>
)

class XWebLane(private val laneName: String) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val lock = Mutex()
    private var webView: WebView? = null
    private var hostContainer: ViewGroup? = null
    private val routeBuffers = ConcurrentHashMap<String, MutableList<Gif>>()
    private val routeCursors = ConcurrentHashMap<String, String>()
    private val seenIdsByRoute = ConcurrentHashMap<String, MutableSet<String>>()
    private val dryPayloadCount = ConcurrentHashMap<String, Int>()
    private val capturedOps = ConcurrentHashMap<String, CapturedGraphQLOp>()
    private val directDisabledOps = ConcurrentHashMap.newKeySet<String>()
    private val waiters = ConcurrentHashMap<String, MutableList<CompletableDeferred<Unit>>>()

    @Volatile private var activeRouteKey: String = "x_foryou"
    @Volatile private var pageCounter: Int = 0
    @Volatile private var rateLimitedUntilMs: Long = 0L

    val isRateLimitedNow: Boolean get() = System.currentTimeMillis() < rateLimitedUntilMs

    private val hookJs = """
        (function(){
          if(window.__ttXHooked) return;
          window.__ttXHooked = true;
          try {
            HTMLMediaElement.prototype.play = function(){ try{ this.muted=true; this.pause(); }catch(e){} return Promise.resolve(); };
          } catch(e){}
          function isXApi(u){
            return u && (u.includes('/graphql/') || u.includes('/2/timeline') || u.includes('adaptive.json') || u.includes('settings.json') || u.includes('SearchTimeline') || u.includes('UserTweets') || u.includes('UserMedia') || u.includes('Bookmarks') || u.includes('HomeTimeline') || u.includes('HomeLatestTimeline') || u.includes('Likes'));
          }
          function captureOp(url, headersObj){
            try {
              if(!url || !url.includes('/graphql/')) return;
              const m = url.match(/\/graphql\/[^\/]+\/([A-Za-z0-9_]+)/);
              if(m && ['HomeTimeline','HomeLatestTimeline','SearchTimeline','UserMedia','Bookmarks'].includes(m[1])){
                window.TTXBridge.onGraphQLOp(m[1], url, JSON.stringify(headersObj || {}));
              }
            } catch(e){}
          }
          const origFetch = window.fetch;
          window.fetch = async function(){
            const arg0 = arguments[0];
            const arg1 = arguments[1] || {};
            const url = (arg0 && arg0.url) ? arg0.url : String(arg0 || '');
            try {
              const hdrs = {};
              const rawH = arg1.headers || (arg0 && arg0.headers);
              if(rawH && typeof rawH.forEach === 'function'){ rawH.forEach((v,k)=>{ hdrs[k]=v; }); }
              else if(rawH && typeof rawH === 'object'){ Object.keys(rawH).forEach(k=>{ hdrs[k]=String(rawH[k]); }); }
              captureOp(url, hdrs);
            } catch(e){}
            const resp = await origFetch.apply(this, arguments);
            try {
              if(isXApi(url)) {
                const st = resp.status || 200;
                const clone = resp.clone();
                clone.text().then(t => {
                  if(t && t.length > 10) window.TTXBridge.onPayload(url, location.href || '', st, t);
                });
              }
            } catch(e){}
            return resp;
          };
          const origOpen = XMLHttpRequest.prototype.open;
          const origSetHeader = XMLHttpRequest.prototype.setRequestHeader;
          const origSend = XMLHttpRequest.prototype.send;
          XMLHttpRequest.prototype.open = function(m, u){ this.__ttUrl = String(u || ''); this.__ttHdrs = {}; return origOpen.apply(this, arguments); };
          XMLHttpRequest.prototype.setRequestHeader = function(k, v){ try{ if(this.__ttHdrs) this.__ttHdrs[k]=v; }catch(e){} return origSetHeader.apply(this, arguments); };
          XMLHttpRequest.prototype.send = function(){
            try { captureOp(this.__ttUrl, this.__ttHdrs); } catch(e){}
            this.addEventListener('load', function(){
              try {
                if(isXApi(this.__ttUrl)) {
                  const t = typeof this.responseText === 'string' ? this.responseText : '';
                  if(t && t.length > 10) window.TTXBridge.onPayload(this.__ttUrl, location.href || '', this.status || 200, t);
                }
              } catch(e){}
            });
            return origSend.apply(this, arguments);
          };
        })();
    """.trimIndent()

    private val scrollAdvanceJS = """
        (function(){
          function nudge(){
            const dy = Math.max(900, window.innerHeight * 2.4);
            window.scrollBy(0, dy);
            window.dispatchEvent(new Event('scroll'));
            window.dispatchEvent(new WheelEvent('wheel', { deltaY: dy, bubbles: true }));
            const scrollers = document.querySelectorAll('div, main, section');
            for(let i=0;i<scrollers.length;i++){
              const el = scrollers[i];
              if(el.scrollHeight > el.clientHeight + 200){
                el.scrollTop += dy;
                el.dispatchEvent(new Event('scroll'));
              }
            }
          }
          nudge();
          setTimeout(nudge, 260);
        })();
    """.trimIndent()

    inner class Bridge {
        @JavascriptInterface
        fun onGraphQLOp(opName: String, url: String, headersJson: String) {
            try {
                val obj = JSONObject(headersJson)
                val map = mutableMapOf<String, String>()
                val keys = obj.keys()
                while (keys.hasNext()) {
                    val k = keys.next()
                    map[k] = obj.optString(k)
                }
                capturedOps[opName] = CapturedGraphQLOp(opName, url, map)
            } catch (_: Throwable) {}
        }

        @JavascriptInterface
        fun onPayload(url: String, pageUrl: String, status: Int, body: String) {
            if (status == 429 || (status >= 400 && body.contains("\"code\":88"))) {
                rateLimitedUntilMs = System.currentTimeMillis() + 45_000L
                notifyWaiters(activeRouteKey)
                return
            }
            if (status >= 400) return

            // Capture viewer screen_name if seen in settings/viewer payload
            if (url.contains("settings.json") || body.contains("\"screen_name\"")) {
                XTweetParser.parseScreenName(body)?.let { sn ->
                    val cur = UserStore.shared.data.value.xSession
                    if (cur.isConnected && (cur.screenName.isEmpty() || cur.screenName == "𝕏 Account")) {
                        UserStore.shared.updateXSession(cur.copy(screenName = sn))
                    }
                }
            }

            // Route isolation
            val key = activeRouteKey
            if (key == "x_following" && url.contains("HomeTimeline") && !url.contains("HomeLatestTimeline")) return
            if (key == "x_foryou" && url.contains("HomeLatestTimeline")) return

            scope.launch {
                val tweets = XTweetParser.parseTweets(body, routeKey = key)
                val cursor = XTweetParser.extractBottomCursor(body)
                if (!cursor.isNullOrEmpty()) routeCursors[key] = cursor

                val seenSet = seenIdsByRoute.getOrPut(key) { ConcurrentHashMap.newKeySet() }
                val store = UserStore.shared
                val fresh = tweets.filter { t ->
                    !store.isBlockedByAlgorithm(t) && seenSet.add(t.canonicalDedupeKey)
                }
                if (fresh.isNotEmpty()) {
                    dryPayloadCount[key] = 0
                    val list = routeBuffers.getOrPut(key) { mutableListOf() }
                    synchronized(list) { list.addAll(fresh) }
                    notifyWaiters(key)
                } else {
                    dryPayloadCount[key] = (dryPayloadCount[key] ?: 0) + 1
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
        // Double-check after registering waiter
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
        dryPayloadCount.clear()
        capturedOps.clear()
        directDisabledOps.clear()
        rateLimitedUntilMs = 0L
        val wvToDestroy = webView
        webView = null
        if (wvToDestroy != null) {
            android.os.Handler(android.os.Looper.getMainLooper()).post {
                runCatching {
                    (wvToDestroy.parent as? ViewGroup)?.removeView(wvToDestroy)
                    wvToDestroy.stopLoading()
                    wvToDestroy.loadUrl("about:blank")
                    wvToDestroy.destroy()
                }
            }
        }
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
            addJavascriptInterface(Bridge(), "TTXBridge")
            webChromeClient = WebChromeClient()
            webViewClient = object : WebViewClient() {
                override fun shouldInterceptRequest(view: WebView?, request: WebResourceRequest?): WebResourceResponse? {
                    val u = request?.url?.toString()?.lowercase() ?: return null
                    // Block heavy media/images/fonts inside headless feed WebView to save RAM & CPU
                    if (u.contains("video.twimg.com") || u.contains("pbs.twimg.com/media") ||
                        u.contains("pbs.twimg.com/ext_tw_video_thumb") || u.endsWith(".woff2") || u.endsWith(".woff")
                    ) {
                        return WebResourceResponse("text/plain", "utf-8", ByteArrayInputStream(ByteArray(0)))
                    }
                    return null
                }

                override fun onPageStarted(view: WebView?, url: String?, favicon: android.graphics.Bitmap?) {
                    view?.evaluateJavascript(hookJs, null)
                }

                override fun onPageFinished(view: WebView?, url: String?) {
                    view?.evaluateJavascript(hookJs, null)
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

    suspend fun warmUp(url: String = "https://x.com/home") {
        if (!UserStore.shared.data.value.xSession.isConnected) return
        val wv = ensureWebView()
        withContext(Dispatchers.Main) {
            if (wv.url.isNullOrEmpty() || wv.url == "about:blank") wv.loadUrl(url)
        }
    }

    // Direct GraphQL cursor replay — true instant infinite scroll matching iOS!
    suspend fun fetchGraphQLDirect(opName: String, routeKey: String, cursor: String?): GoonedFeedResponse? = withContext(Dispatchers.IO) {
        if (isRateLimitedNow || opName in directDisabledOps) return@withContext null
        val op = capturedOps[opName] ?: return@withContext null
        val parsed = op.url.toHttpUrlOrNull() ?: return@withContext null
        val rawVars = parsed.queryParameter("variables") ?: return@withContext null
        try {
            val varsObj = JSONObject(rawVars)
            varsObj.put("count", 40)
            if (!cursor.isNullOrEmpty() && !cursor.startsWith("xpage_")) {
                varsObj.put("cursor", cursor)
            }
            val newUrl = parsed.newBuilder()
                .setQueryParameter("variables", varsObj.toString())
                .build()
            val x = UserStore.shared.data.value.xSession
            val cookies = CookieManager.getInstance().getCookie("https://x.com")
                ?: "auth_token=${x.authToken}; ct0=${x.ct0}"
            val rb = Request.Builder()
                .url(newUrl)
                .header("User-Agent", Config.userAgent)
                .header("Cookie", cookies)
                .header("Referer", "https://x.com/home")
            for ((k, v) in op.headers) {
                if (!k.equals("cookie", ignoreCase = true) && !k.equals("content-length", ignoreCase = true)) {
                    rb.header(k, v)
                }
            }
            if (x.ct0.isNotEmpty()) rb.header("x-csrf-token", x.ct0)
            TinyTinyApplication.sharedHttpClient.newCall(rb.build()).execute().use { resp ->
                if (resp.code == 429) {
                    rateLimitedUntilMs = System.currentTimeMillis() + 45_000L
                    return@withContext null
                }
                if (resp.code == 400 || resp.code == 404 || resp.code == 422) {
                    directDisabledOps.add(opName)
                    return@withContext null
                }
                if (!resp.isSuccessful) return@withContext null
                val body = resp.body?.string() ?: return@withContext null
                if (body.contains("\"code\":88")) {
                    rateLimitedUntilMs = System.currentTimeMillis() + 45_000L
                    return@withContext null
                }
                val tweets = XTweetParser.parseTweets(body, routeKey = routeKey)
                val nextCursor = XTweetParser.extractBottomCursor(body)
                if (!nextCursor.isNullOrEmpty()) routeCursors[routeKey] = nextCursor
                val seenSet = seenIdsByRoute.getOrPut(routeKey) { ConcurrentHashMap.newKeySet() }
                val fresh = tweets.filter { !UserStore.shared.isBlockedByAlgorithm(it) && seenSet.add(it.canonicalDedupeKey) }
                GoonedFeedResponse(posts = fresh, after = nextCursor)
            }
        } catch (_: Throwable) {
            null
        }
    }

    suspend fun fetchRoute(routeKey: String, targetUrl: String, after: String? = null, directOpName: String? = null): GoonedFeedResponse {
        if (isRateLimitedNow) return GoonedFeedResponse()

        // 1. Try direct GraphQL cursor replay first when paginating!
        val effectiveCursor = after?.takeIf { !it.startsWith("xpage_") } ?: routeCursors[routeKey]
        if (directOpName != null && after != null && !effectiveCursor.isNullOrEmpty()) {
            val direct = fetchGraphQLDirect(directOpName, routeKey, effectiveCursor)
            if (direct != null && direct.posts.isNotEmpty()) {
                return direct
            }
        }

        // 2. Drain pre-pumped buffer immediately if already stocked
        val preDrained = drainBuffer(routeKey, maxCount = 24)
        if (preDrained.size >= 8) {
            scheduleBackgroundPump(routeKey)
            return GoonedFeedResponse(
                posts = preDrained,
                after = routeCursors[routeKey] ?: "xpage_${++pageCounter}"
            )
        }

        return lock.withLock {
            activeRouteKey = routeKey
            val wv = ensureWebView()
            withContext(Dispatchers.Main) {
                wv.evaluateJavascript(hookJs, null)
                val currentUrl = wv.url ?: ""
                val isSameBase = currentUrl.startsWith(targetUrl.substringBefore('?'))
                if (!isSameBase) {
                    wv.loadUrl(targetUrl)
                } else if (routeKey == "x_foryou" || routeKey == "x_following") {
                    val tabLabel = if (routeKey == "x_following") "Following" else "For you"
                    wv.evaluateJavascript(
                        """
                        (function(){
                          let tries = 0;
                          const iv = setInterval(function(){
                            tries++;
                            const tabs = Array.from(document.querySelectorAll('[role="tab"]'));
                            const target = tabs.find(t => (t.innerText || '').trim().toLowerCase() === '${tabLabel.lowercase()}');
                            if(target){
                              clearInterval(iv);
                              if(target.getAttribute('aria-selected') !== 'true') { target.click(); }
                              else { $scrollAdvanceJS }
                            } else if(tries >= 14) {
                              clearInterval(iv);
                              $scrollAdvanceJS
                            }
                          }, 180);
                        })();
                        """.trimIndent(),
                        null
                    )
                } else {
                    wv.evaluateJavascript(scrollAdvanceJS, null)
                }
            }

            awaitBuffer(routeKey, timeoutMs = 5500L)
            var items = (preDrained + drainBuffer(routeKey, maxCount = 30)).distinctBy { it.id }

            // Second scroll nudge if still empty
            if (items.isEmpty() && !isRateLimitedNow) {
                withContext(Dispatchers.Main) { wv.evaluateJavascript(scrollAdvanceJS, null) }
                awaitBuffer(routeKey, timeoutMs = 3500L)
                items = drainBuffer(routeKey, maxCount = 30)
            }

            // Dry-payload adult supplement fallback for Home For You
            if (items.isEmpty() && routeKey == "x_foryou" && (dryPayloadCount[routeKey] ?: 0) >= 2) {
                val algo = UserStore.shared.data.value.algorithm
                val tag = (algo.boostedTags.firstOrNull() ?: "nsfw").replace("_", " ")
                val enc = URLEncoder.encode("$tag filter:videos", "UTF-8")
                withContext(Dispatchers.Main) { wv.loadUrl("https://x.com/search?q=$enc&src=typed_query&f=live") }
                awaitBuffer(routeKey, timeoutMs = 4500L)
                items = drainBuffer(routeKey, maxCount = 24)
            }

            scheduleBackgroundPump(routeKey)
            GoonedFeedResponse(
                posts = items,
                after = routeCursors[routeKey] ?: "xpage_${++pageCounter}"
            )
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

    private fun scheduleBackgroundPump(routeKey: String) {
        if (isRateLimitedNow) return
        val buf = routeBuffers[routeKey]
        val buffered = if (buf != null) synchronized(buf) { buf.size } else 0
        if (buffered >= 16) return
        scope.launch {
            delay(650)
            if (activeRouteKey == routeKey && !isRateLimitedNow) {
                withContext(Dispatchers.Main) {
                    webView?.evaluateJavascript(scrollAdvanceJS, null)
                }
            }
        }
    }

    suspend fun followUser(screenName: String, follow: Boolean): Boolean = withContext(Dispatchers.IO) {
        val x = UserStore.shared.data.value.xSession
        if (!x.isConnected) return@withContext false
        val clean = screenName.replace("@", "").trim()
        if (clean.isEmpty()) return@withContext false
        try {
            val action = if (follow) "create" else "destroy"
            val cookies = CookieManager.getInstance().getCookie("https://x.com")
                ?: "auth_token=${x.authToken}; ct0=${x.ct0}"
            val req = Request.Builder()
                .url("https://x.com/i/api/1.1/friendships/$action.json")
                .header("User-Agent", Config.userAgent)
                .header("Authorization", "Bearer AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA")
                .header("x-csrf-token", x.ct0)
                .header("Cookie", cookies)
                .header("Referer", "https://x.com/$clean")
                .post("screen_name=${URLEncoder.encode(clean, "UTF-8")}".toRequestBody("application/x-www-form-urlencoded".toMediaType()))
                .build()
            TinyTinyApplication.sharedHttpClient.newCall(req).execute().use { it.isSuccessful }
        } catch (_: Throwable) {
            false
        }
    }
}

object XWebEngine {
    val home = XWebLane("home")
    val shared = XWebLane("shared")

    val isRateLimitedNow: Boolean get() = home.isRateLimitedNow || shared.isRateLimitedNow

    fun attachHost(container: ViewGroup) {
        home.attachHost(container)
        shared.attachHost(container)
    }

    fun resetSession() {
        home.resetSession()
        shared.resetSession()
        clearWebCookiesAndRestoreConnected(
            listOf("https://x.com", "https://twitter.com", "https://mobile.x.com", "https://mobile.twitter.com", "https://accounts.google.com")
        )
    }

    internal fun clearWebCookiesAndRestoreConnected(origins: List<String>) {
        android.os.Handler(android.os.Looper.getMainLooper()).post {
            runCatching {
                val ws = android.webkit.WebStorage.getInstance()
                for (origin in origins) ws.deleteOrigin(origin)
            }
            runCatching {
                val cm = CookieManager.getInstance()
                cm.removeAllCookies {
                    cm.flush()
                    kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Main).launch {
                        LicenseManager.injectRestoredSocialCookies()
                    }
                }
            }
        }
    }

    suspend fun warmUp() {
        home.warmUp("https://x.com/home")
        shared.warmUp("https://x.com/explore")
    }

    suspend fun followUser(screenName: String, follow: Boolean): Boolean = shared.followUser(screenName, follow)
}

object XAPI {
    suspend fun forYou(after: String? = null): GoonedFeedResponse = coroutineScope {
        val algo = UserStore.shared.data.value.algorithm
        val tasteTags = (algo.boostedTags + SmartTasteEngine.shared.activeQueryTags(algo.boostedTags, algo.blockedTags, 4)).distinct()
        val homeDef = async { XWebEngine.home.fetchRoute("x_foryou", "https://x.com/home", after, directOpName = "HomeTimeline") }
        val tasteDef = async {
            if (tasteTags.isNotEmpty() && after == null) {
                val tag = tasteTags.random().replace("_", " ")
                search(tag, sort = "hot", after = null).posts.take(8)
            } else emptyList()
        }
        val homeResp = homeDef.await()
        val tastePosts = tasteDef.await()
        val merged = mutableListOf<Gif>()
        val seen = mutableSetOf<String>()
        val maxLen = maxOf(homeResp.posts.size, tastePosts.size)
        for (i in 0 until maxLen) {
            if (i < homeResp.posts.size && seen.add(homeResp.posts[i].id)) merged.add(homeResp.posts[i])
            if (i < tastePosts.size && seen.add(tastePosts[i].id)) merged.add(tastePosts[i])
        }
        GoonedFeedResponse(posts = merged, after = homeResp.after)
    }

    suspend fun following(after: String? = null): GoonedFeedResponse =
        XWebEngine.home.fetchRoute("x_following", "https://x.com/home", after, directOpName = "HomeLatestTimeline")

    suspend fun bookmarks(after: String? = null): GoonedFeedResponse =
        XWebEngine.shared.fetchRoute("x_bookmarks", "https://x.com/i/bookmarks", after, directOpName = "Bookmarks")

    suspend fun likes(after: String? = null): GoonedFeedResponse {
        val sn = UserStore.shared.data.value.xSession.screenName.removePrefix("@").trim()
        val url = if (sn.isNotEmpty() && sn != "𝕏 Account") "https://x.com/$sn/likes" else "https://x.com/i/history/likes"
        val key = if (sn.isNotEmpty()) "x_likes_${sn.lowercase()}" else "x_likes"
        return XWebEngine.shared.fetchRoute(key, url, after)
    }

    suspend fun images(after: String? = null): GoonedFeedResponse {
        val algo = UserStore.shared.data.value.algorithm
        val tasteTags = (algo.boostedTags + SmartTasteEngine.shared.activeQueryTags(algo.boostedTags, algo.blockedTags, 4)).distinct()
        val tag = (tasteTags.firstOrNull() ?: "nsfw").replace("_", " ")
        val enc = URLEncoder.encode("$tag filter:images -filter:videos", "UTF-8")
        return XWebEngine.shared.fetchRoute(
            "x_images",
            "https://x.com/search?q=$enc&src=typed_query&f=top",
            after,
            directOpName = "SearchTimeline"
        )
    }

    suspend fun search(query: String, sort: String = "hot", after: String? = null): GoonedFeedResponse {
        val clean = query.trim().replace(Regex("(?i)^x:"), "").trim()
        if (clean.isEmpty()) return GoonedFeedResponse()
        val fParam = if (sort == "new") "live" else "top"
        val qWithFilter = if (clean.contains("filter:")) clean else "$clean filter:videos"
        val enc = URLEncoder.encode(qWithFilter, "UTF-8")
        val key = "x_search_${clean.lowercase()}_$fParam"
        val primary = XWebEngine.shared.fetchRoute(key, "https://x.com/search?q=$enc&src=typed_query&f=$fParam", after, directOpName = "SearchTimeline")
        if (primary.posts.isNotEmpty() || after != null) return primary
        // Broad fallback without filter:videos if empty
        val broadEnc = URLEncoder.encode(clean, "UTF-8")
        return XWebEngine.shared.fetchRoute("${key}_broad", "https://x.com/search?q=$broadEnc&src=typed_query&f=$fParam", null)
    }

    suspend fun userTweets(handle: String, after: String? = null): GoonedFeedResponse {
        val clean = handle.trim().replace(Regex("(?i)^x:"), "").replace("@", "")
        return XWebEngine.shared.fetchRoute("x_user_${clean.lowercase()}", "https://x.com/$clean/media", after, directOpName = "UserMedia")
    }
}

@SuppressLint("SetJavaScriptEnabled")
@Composable
fun XLoginSheet(onConnected: () -> Unit, onDismiss: () -> Unit) {
    val store = UserStore.shared
    val scope = rememberCoroutineScope()
    var detected by remember { mutableStateOf(false) }
    var showManual by remember { mutableStateOf(false) }
    var manualAuth by remember { mutableStateOf("") }
    var manualCt0 by remember { mutableStateOf("") }
    var manualHandle by remember { mutableStateOf("") }
    var popupWebView by remember { mutableStateOf<WebView?>(null) }
    val loginWebViewRef = remember { arrayOfNulls<WebView>(1) }

    fun completeSession(auth: String, ct0: String, uid: String, handle: String) {
        if (detected) return
        detected = true
        val clean = handle.trim().removePrefix("@").ifEmpty { "𝕏 Account" }
        store.updateXSession(XAccountSession(authToken = auth, ct0 = ct0, userId = uid, screenName = clean))
        scope.launch {
            LicenseManager.injectRestoredSocialCookies()
            XWebEngine.warmUp()
        }
        onConnected()
    }

    fun checkCookiesAndComplete(wv: WebView?) {
        if (detected) return
        val cm = CookieManager.getInstance()
        val combined = listOfNotNull(cm.getCookie("https://x.com"), cm.getCookie("https://twitter.com")).joinToString("; ")
        val map = combined.split(";").mapNotNull {
            val p = it.trim().split("=", limit = 2)
            if (p.size == 2) p[0].trim() to p[1].trim() else null
        }.toMap()
        val auth = map["auth_token"] ?: ""
        val ct0 = map["ct0"] ?: ""
        val twid = (map["twid"] ?: "").replace("u%3D", "").replace("u=", "").replace("\"", "")
        if (auth.isNotEmpty() && ct0.isNotEmpty()) {
            if (wv != null) {
                wv.evaluateJavascript(
                    "(function(){ const a = document.querySelector('a[data-testid=\"AppTabBar_Profile_Link\"]'); if(a) return (a.getAttribute('href')||'').replace(/^\\//,''); const m = (document.body.innerHTML||'').match(/\"screen_name\":\"([A-Za-z0-9_]+)\"/); return m ? m[1] : ''; })()"
                ) { res ->
                    val parsed = res?.trim('"')?.takeIf { it.isNotEmpty() && it != "null" } ?: ""
                    completeSession(auth, ct0, twid, parsed)
                }
            } else {
                completeSession(auth, ct0, twid, "")
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
            BrandLogoX(22.dp)
            Spacer(Modifier.width(10.dp))
            Text("Sign in to 𝕏", color = Color.White, fontSize = 18.sp, fontWeight = FontWeight.Bold)
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
                Text("Paste your auth_token and ct0 cookies from x.com.", color = Theme.textSecondary, fontSize = 12.5.sp)
                OutlinedTextField(value = manualAuth, onValueChange = { manualAuth = it }, label = { Text("auth_token") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(value = manualCt0, onValueChange = { manualCt0 = it }, label = { Text("ct0") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(value = manualHandle, onValueChange = { manualHandle = it }, label = { Text("@username (optional)") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                Button(
                    onClick = {
                        completeSession(manualAuth.trim(), manualCt0.trim(), "", manualHandle.trim())
                    },
                    enabled = manualAuth.trim().isNotEmpty() && manualCt0.trim().isNotEmpty(),
                    colors = ButtonDefaults.buttonColors(containerColor = Theme.accent),
                    shape = RoundedCornerShape(999.dp),
                    modifier = Modifier.fillMaxWidth().height(48.dp)
                ) {
                    Text("Connect 𝕏 Account", fontWeight = FontWeight.Bold)
                }
            }
        } else {
            // Stable WebView container — NO imePadding/minimumHeight thrashing so inputs never flicker!
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
                            settings.setSupportMultipleWindows(true)
                            settings.javaScriptCanOpenWindowsAutomatically = true
                            settings.mixedContentMode = android.webkit.WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE
                            settings.userAgentString = chromeUa
                            CookieManager.getInstance().setAcceptCookie(true)
                            CookieManager.getInstance().setAcceptThirdPartyCookies(this, true)
                            clearCache(true)
                            webChromeClient = object : WebChromeClient() {
                                override fun onCreateWindow(view: WebView?, isDialog: Boolean, isUserGesture: Boolean, resultMsg: Message?): Boolean {
                                    val popup = WebView(ctx).apply {
                                        settings.javaScriptEnabled = true
                                        settings.domStorageEnabled = true
                                        settings.userAgentString = chromeUa
                                        CookieManager.getInstance().setAcceptThirdPartyCookies(this, true)
                                        webViewClient = WebViewClient()
                                        webChromeClient = object : WebChromeClient() {
                                            override fun onCloseWindow(window: WebView?) {
                                                popupWebView = null
                                            }
                                        }
                                    }
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
                                    checkCookiesAndComplete(view)
                                }
                            }
                            loadUrl("https://x.com/i/flow/login")
                        }
                    },
                    modifier = Modifier.fillMaxSize(),
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
                            onClick = {
                                try {
                                    pop.stopLoading()
                                    pop.destroy()
                                } catch (_: Throwable) {}
                                popupWebView = null
                            },
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
