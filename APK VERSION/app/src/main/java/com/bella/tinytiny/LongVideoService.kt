package com.bella.tinytiny

import androidx.compose.ui.graphics.Color
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import java.net.URLEncoder
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

enum class LongVideoSite(val rawValue: String, val displayTitle: String, val accentColor: Color) {
    ALL("all", "All Sites", Theme.accentBright),
    EPORNER("eporner", "Eporner", Color(0xFFEB4059)),
    XVIDEOS("xvideos", "XVideos", Color(0xFFE62929)),
    PORNHUB("pornhub", "Pornhub", Color(0xFFFF9900)),
    XHAMSTER("xhamster", "xHamster", Color(0xFFE64273)),
    SPANKBANG("spankbang", "SpankBang", Color(0xFF52C7FA)),
    EROME("erome", "Erome", Color(0xFFEB579E))
}

object LongVideoAPI {
    private const val MOBILE_UA =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"
    private const val DESKTOP_UA =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

    private val client = TinyTinyApplication.sharedHttpClient
    private val resolvedCache = ConcurrentHashMap<String, Pair<List<String>, Long>>()

    private val eromeCardRegex = Regex(
        """href="(?:https?://(?:www\.)?erome\.com)?(/a/([A-Za-z0-9]+))"[^>]*>[\s\S]{0,600}?<img[^>]*?(?:alt="([^"]*)")?[^>]*?(?:data-src|src)="(https?://[^"]+)"""",
        RegexOption.IGNORE_CASE
    )
    private val xhCardRegex = Regex(
        """<a[^>]+href="(https://xhamster\.com/videos/[^"]+)"[^>]*>[\s\S]{0,600}?<img[^>]+src="(https://[^"]+xhcdn\.com[^"]+)"[^>]*alt="([^"]+)""""
    )

    private suspend fun fetchString(url: String, desktop: Boolean = false, referer: String? = null): String? =
        withContext(Dispatchers.IO) {
            try {
                val rb = Request.Builder()
                    .url(url)
                    .header("User-Agent", if (desktop) DESKTOP_UA else MOBILE_UA)
                    .header("Accept-Language", "en-US,en;q=0.9")
                if (!referer.isNullOrEmpty()) rb.header("Referer", referer)
                client.newCall(rb.build()).execute().use { resp ->
                    if (!resp.isSuccessful) return@withContext null
                    resp.body?.string()
                }
            } catch (_: Throwable) {
                null
            }
        }

    suspend fun fetchFeed(site: LongVideoSite, sort: String, query: String? = null, after: String?): GoonedFeedResponse =
        coroutineScope {
            val page = maxOf(1, after?.toIntOrNull() ?: 1)
            val cleanQ = (query ?: "").trim()
            val algo = UserStore.shared.data.value.algorithm
            val engine = SmartTasteEngine.shared
            val pinned = algo.boostedTags.filter { !MediaMetaRegistry.isStopTag(it) }
            val tasteTags = engine.activeQueryTags(algo.boostedTags, algo.blockedTags, 6)
            val blockedLower = (algo.blockedTags.map { it.lowercase() } + engine.state.value.suppressedTags).toSet()
            val pinnedLower = algo.boostedTags.map { it.lowercase() }.toSet()
            val suppressGay = (blockedLower.contains("gay") || blockedLower.contains("men") || blockedLower.contains("yaoi")) && !pinnedLower.contains("gay")

            val tasteQuery = if (cleanQ.isEmpty()) {
                val pool = if (pinned.isNotEmpty()) pinned else tasteTags
                if (pool.isNotEmpty()) pool[(page - 1) % pool.size].replace("_", " ") else null
            } else null

            val rawPosts: List<Gif> = when (site) {
                LongVideoSite.ALL -> {
                    val ep = async { fetchEporner(cleanQ, sort, page, suppressGay) }
                    val xv = async { fetchXVideos(cleanQ, sort, page) }
                    val ph = async { fetchPornhub(cleanQ, sort, page) }
                    val xh = async { fetchXHamster(cleanQ, sort, page) }
                    val sb = async { fetchSpankBang(cleanQ, sort, page, suppressGay) }
                    interleave(listOf(ep.await(), xv.await(), ph.await(), xh.await(), sb.await()))
                }
                LongVideoSite.EPORNER -> fetchEporner(cleanQ, sort, page, suppressGay)
                LongVideoSite.XVIDEOS -> fetchXVideos(cleanQ, sort, page)
                LongVideoSite.PORNHUB -> fetchPornhub(cleanQ, sort, page)
                LongVideoSite.XHAMSTER -> fetchXHamster(cleanQ, sort, page)
                LongVideoSite.SPANKBANG -> fetchSpankBang(cleanQ, sort, page, suppressGay)
                LongVideoSite.EROME -> {
                    if (tasteQuery != null) {
                        val mainD = async { fetchErome(cleanQ, sort, page) }
                        val tasteD = async { fetchErome(tasteQuery, sort, page) }
                        interleave(listOf(tasteD.await(), mainD.await()))
                    } else {
                        fetchErome(cleanQ, sort, page)
                    }
                }
            }
            GoonedFeedResponse(posts = rawPosts, after = if (rawPosts.isEmpty()) null else "${page + 1}")
        }

    private suspend fun fetchEporner(query: String, sort: String, page: Int, suppressGay: Boolean): List<Gif> {
        val order = if (sort == "new") "latest" else "top-weekly"
        val q = URLEncoder.encode(query.ifEmpty { "all" }, "UTF-8")
        val url = "https://www.eporner.com/api/v2/video/search/?query=$q&per_page=25&page=$page&thumbsize=big&order=$order&gay=${if (suppressGay) 0 else 1}&lq=1&format=json"
        val raw = fetchString(url) ?: return emptyList()
        val out = mutableListOf<Gif>()
        try {
            val videos = JSONObject(raw).optJSONArray("videos") ?: return emptyList()
            for (i in 0 until videos.length()) {
                val v = videos.optJSONObject(i) ?: continue
                val id = v.optString("id").takeIf { it.isNotEmpty() } ?: continue
                val title = v.optString("title").ifEmpty { "Eporner Video" }
                val thumb = v.optJSONObject("default_thumb")?.optString("src")
                val pageUrl = v.optString("url").ifEmpty { "https://www.eporner.com/hd-porn/$id/" }
                val dur = v.optDouble("length_sec", 0.0).takeIf { it > 0 }
                out.add(
                    Gif(
                        id = "lv_ep_$id",
                        title = title,
                        author = "Eporner",
                        subreddit = "Eporner",
                        duration = dur,
                        width = 1280,
                        height = 720,
                        mediaType = "video",
                        posterUrl = thumb,
                        thumbnailUrl = thumb,
                        sourceUrl = pageUrl,
                        permalink = pageUrl
                    )
                )
            }
        } catch (_: Throwable) {}
        return out
    }

    private suspend fun fetchXVideos(query: String, sort: String, page: Int): List<Gif> {
        val url = if (query.isEmpty()) {
            val base = if (sort == "new") "https://www.xvideos.com/new" else "https://www.xvideos.com/best"
            if (page <= 1) base else "$base/$page"
        } else {
            val enc = URLEncoder.encode(query, "UTF-8")
            "https://www.xvideos.com/?k=$enc&p=${page - 1}"
        }
        val html = fetchString(url, desktop = true) ?: return emptyList()
        val regex = Regex("""id="video_(\d+)"[\s\S]{0,900}?<img[^>]+data-src="([^"]+)"[\s\S]{0,600}?<a[^>]+href="(/video[^"]+)"[^>]*title="([^"]+)"""")
        val out = mutableListOf<Gif>()
        for (m in regex.findAll(html).take(25)) {
            val vid = m.groupValues[1]
            val thumb = m.groupValues[2]
            val rel = m.groupValues[3]
            val title = decodeHtml(m.groupValues[4])
            val pageUrl = "https://www.xvideos.com$rel"
            out.add(
                Gif(
                    id = "lv_xv_$vid",
                    title = title,
                    author = "XVideos",
                    subreddit = "XVideos",
                    width = 1280,
                    height = 720,
                    mediaType = "video",
                    posterUrl = thumb,
                    thumbnailUrl = thumb,
                    sourceUrl = pageUrl,
                    permalink = pageUrl
                )
            )
        }
        return out
    }

    private suspend fun fetchPornhub(query: String, sort: String, page: Int): List<Gif> {
        // Tier 1: Pornhub Webmasters JSON API (matches iOS)
        try {
            val enc = URLEncoder.encode(query.ifEmpty { "amateur" }, "UTF-8")
            val ordering = if (sort == "new") "newest" else "mostviewed"
            val apiUrl = "https://www.pornhub.com/webmasters/search?search=$enc&ordering=$ordering&page=$page&thumbsize=large"
            val raw = fetchString(apiUrl, desktop = true)
            if (!raw.isNullOrEmpty() && raw.trimStart().startsWith("{")) {
                val arr = JSONObject(raw).optJSONArray("videos")
                if (arr != null && arr.length() > 0) {
                    val out = mutableListOf<Gif>()
                    for (i in 0 until minOf(25, arr.length())) {
                        val v = arr.optJSONObject(i) ?: continue
                        val vkey = v.optString("video_id").takeIf { it.isNotEmpty() } ?: continue
                        val title = decodeHtml(v.optString("title").ifEmpty { "Pornhub Video" })
                        val thumb = v.optString("thumb").ifEmpty { v.optString("default_thumb") }.takeIf { it.isNotEmpty() }
                        val pageUrl = v.optString("url").ifEmpty { "https://www.pornhub.com/view_video.php?viewkey=$vkey" }
                        out.add(
                            Gif(
                                id = "lv_ph_$vkey",
                                title = title,
                                author = "Pornhub",
                                subreddit = "Pornhub",
                                width = 1280,
                                height = 720,
                                mediaType = "video",
                                posterUrl = thumb,
                                thumbnailUrl = thumb,
                                sourceUrl = pageUrl,
                                permalink = pageUrl
                            )
                        )
                    }
                    if (out.isNotEmpty()) return out
                }
            }
        } catch (_: Throwable) {}

        val url = if (query.isEmpty()) {
            val o = if (sort == "new") "cm" else "mv"
            "https://www.pornhub.com/video?o=$o&page=$page"
        } else {
            val enc = URLEncoder.encode(query, "UTF-8")
            "https://www.pornhub.com/video/search?search=$enc&page=$page"
        }
        val html = fetchString(url, desktop = true) ?: return emptyList()
        val regex = Regex("""data-video-vkey="([a-z0-9]+)"[\s\S]{0,1000}?data-thumb_url="([^"]+)"[\s\S]{0,600}?title="([^"]+)"""", RegexOption.IGNORE_CASE)
        val out = mutableListOf<Gif>()
        for (m in regex.findAll(html).take(25)) {
            val vkey = m.groupValues[1]
            val thumb = m.groupValues[2]
            val title = decodeHtml(m.groupValues[3])
            val pageUrl = "https://www.pornhub.com/view_video.php?viewkey=$vkey"
            out.add(
                Gif(
                    id = "lv_ph_$vkey",
                    title = title,
                    author = "Pornhub",
                    subreddit = "Pornhub",
                    width = 1280,
                    height = 720,
                    mediaType = "video",
                    posterUrl = thumb,
                    thumbnailUrl = thumb,
                    sourceUrl = pageUrl,
                    permalink = pageUrl
                )
            )
        }
        return out
    }

    private suspend fun fetchXHamster(query: String, sort: String, page: Int): List<Gif> {
        val url = if (query.isEmpty()) {
            val path = if (sort == "new") "newest" else "best/weekly"
            if (page <= 1) "https://xhamster.com/$path" else "https://xhamster.com/$path/$page"
        } else {
            val enc = URLEncoder.encode(query, "UTF-8").replace("+", "%20")
            "https://xhamster.com/search/$enc?page=$page"
        }
        val html = fetchString(url) ?: return emptyList()
        val out = mutableListOf<Gif>()
        val seen = mutableSetOf<String>()
        for (m in xhCardRegex.findAll(html).take(24)) {
            val vUrl = m.groupValues[1]
            val thumb = m.groupValues[2]
            val title = decodeHtml(m.groupValues[3])
            val slug = vUrl.substringAfterLast('/')
            val id = "lv_xh_${slug.takeLast(24)}"
            if (!seen.add(id)) continue
            out.add(
                Gif(
                    id = id,
                    title = title,
                    author = "xHamster",
                    subreddit = "xHamster",
                    width = 1280,
                    height = 720,
                    mediaType = "video",
                    posterUrl = thumb,
                    thumbnailUrl = thumb,
                    sourceUrl = vUrl,
                    permalink = vUrl
                )
            )
        }
        return out
    }

    private suspend fun fetchSpankBang(query: String, sort: String, page: Int, suppressGay: Boolean): List<Gif> {
        val url = if (query.isEmpty()) {
            val path = if (sort == "new") "new_videos" else "trending_videos"
            "https://spankbang.com/$path/$page/"
        } else {
            val enc = URLEncoder.encode(query, "UTF-8").replace("+", "%20")
            "https://spankbang.com/s/$enc/$page/"
        }
        val html = fetchString(url, desktop = true) ?: return emptyList()
        val regex = Regex("""<a[^>]+href="(/[a-z0-9]+/video/[^"]+)"[^>]*>[\s\S]{0,600}?data-src="(https://[^"]+)"[\s\S]{0,400}?alt="([^"]+)"""", RegexOption.IGNORE_CASE)
        val out = mutableListOf<Gif>()
        for (m in regex.findAll(html).take(24)) {
            val rel = m.groupValues[1]
            val thumb = m.groupValues[2]
            val title = decodeHtml(m.groupValues[3])
            val code = rel.trim('/').substringBefore('/')
            val pageUrl = "https://spankbang.com$rel"
            out.add(
                Gif(
                    id = "lv_sb_$code",
                    title = title,
                    author = "SpankBang",
                    subreddit = "SpankBang",
                    width = 1280,
                    height = 720,
                    mediaType = "video",
                    posterUrl = thumb,
                    thumbnailUrl = thumb,
                    sourceUrl = pageUrl,
                    permalink = pageUrl
                )
            )
        }
        return out
    }

    private suspend fun fetchErome(query: String, sort: String, page: Int): List<Gif> {
        val url = if (query.isEmpty()) {
            val path = if (sort == "new") "explore/new" else "explore"
            if (page <= 1) "https://www.erome.com/$path" else "https://www.erome.com/$path?page=$page"
        } else {
            val enc = URLEncoder.encode(query, "UTF-8")
            "https://www.erome.com/search?q=$enc&page=$page"
        }
        val html = fetchString(url, desktop = true, referer = "https://www.erome.com/") ?: return emptyList()
        val out = mutableListOf<Gif>()
        val seen = mutableSetOf<String>()
        for (m in eromeCardRegex.findAll(html).take(24)) {
            val rel = m.groupValues[1]
            val code = m.groupValues[2]
            val rawAlt = m.groupValues[3]
            val thumb = m.groupValues[4]
            val id = "lv_er_$code"
            if (!seen.add(id)) continue
            val cleanTitle = decodeHtml(rawAlt.replace(Regex("""\s*#[A-Za-z0-9_]+\s*$"""), "").trim())
            val fullUrl = "https://www.erome.com$rel"
            out.add(
                Gif(
                    id = id,
                    title = cleanTitle.ifEmpty { "Erome Album" },
                    author = "Erome",
                    subreddit = "Erome",
                    width = 720,
                    height = 1280,
                    mediaType = "video",
                    posterUrl = thumb,
                    thumbnailUrl = thumb,
                    sourceUrl = fullUrl,
                    permalink = fullUrl
                )
            )
        }
        return out
    }

    suspend fun resolvePlayableURLs(gif: Gif): List<String> {
        val now = System.currentTimeMillis()
        resolvedCache[gif.id]?.let { (urls, at) ->
            if (now - at < 30 * 60_000L && urls.isNotEmpty()) return urls
        }
        val pageUrl = gif.sourceUrl ?: gif.permalink ?: return emptyList()
        val urls: List<String> = when {
            gif.id.startsWith("lv_er_") -> resolveErome(gif.id, pageUrl)
            gif.id.startsWith("lv_xv_") -> resolveXVideos(pageUrl)
            gif.id.startsWith("lv_ep_") -> resolveEporner(pageUrl)
            gif.id.startsWith("lv_ph_") -> resolvePornhub(pageUrl)
            gif.id.startsWith("lv_xh_") -> resolveXHamster(pageUrl)
            gif.id.startsWith("lv_sb_") -> resolveSpankBang(pageUrl)
            else -> emptyList()
        }
        if (urls.isNotEmpty()) {
            resolvedCache[gif.id] = urls to now
            MediaMetaRegistry.register(gif.id, extraVideoURLs = urls)
        }
        return urls
    }

    private suspend fun resolveErome(gifId: String, pageUrl: String): List<String> {
        val albumCode = pageUrl.trimEnd('/').substringAfterLast('/')
        val html = fetchString(pageUrl, desktop = true, referer = "https://www.erome.com/") ?: return emptyList()
        val cleaned = html.replace("\\/", "/")
        val esc = Regex.escape(albumCode)
        val vidRegex = Regex("""https?://v\d*\.erome\.com/[^"'\s>]+/$esc/[^"'\s>]+\.(?:mp4|m4v|mov)(?:\?[^"'\s>]*)?""", RegexOption.IGNORE_CASE)
        val imgRegex = Regex("""https?://s\d*\.erome\.com/[^"'\s>]+/$esc/(?!thumbs/)[^"'\s>]+\.(?:jpg|jpeg|png|webp)(?:\?[^"'\s>]*)?""", RegexOption.IGNORE_CASE)

        val videoURLs = mutableListOf<String>()
        val albumItems = mutableListOf<AlbumMediaItem>()
        val seen = mutableSetOf<String>()

        for (m in vidRegex.findAll(cleaned)) {
            val s = m.value
            if (seen.add(s)) {
                videoURLs.add(s)
                albumItems.add(AlbumMediaItem(id = s, url = s, isVideo = true))
            }
        }
        for (m in imgRegex.findAll(cleaned)) {
            val s = m.value
            val stem = s.substringAfterLast('/').substringBefore('?').substringBeforeLast('.')
            val matchesVideo = videoURLs.any { it.substringAfterLast('/').substringBefore('?').substringBeforeLast('.').startsWith(stem) && stem.isNotEmpty() }
            if (!matchesVideo && seen.add(s)) {
                albumItems.add(AlbumMediaItem(id = s, url = s, isVideo = false))
            }
        }
        if (albumItems.isNotEmpty()) {
            MediaMetaRegistry.register(gifId, extraVideoURLs = videoURLs, albumItems = albumItems)
        }
        return videoURLs
    }

    private suspend fun resolveXVideos(pageUrl: String): List<String> {
        val html = fetchString(pageUrl, desktop = true, referer = "https://www.xvideos.com/") ?: return emptyList()
        val high = Regex("""setVideoUrlHigh\('([^']+)'\)""", RegexOption.IGNORE_CASE).find(html)?.groupValues?.get(1)
        val low = Regex("""setVideoUrlLow\('([^']+)'\)""", RegexOption.IGNORE_CASE).find(html)?.groupValues?.get(1)
        val hls = Regex("""setVideoHLS\('([^']+)'\)""", RegexOption.IGNORE_CASE).find(html)?.groupValues?.get(1)
        return listOfNotNull(high, low, hls).distinct()
    }

    private fun rankVideoURLs(urls: Sequence<String>): List<String> {
        fun qualityScore(u: String): Int {
            val l = u.lowercase()
            return when {
                "1080" in l -> 5
                "720" in l -> 4
                "480" in l -> 3
                "360" in l -> 2
                "240" in l -> 1
                ".m3u8" in l -> 4
                else -> 3
            }
        }
        return urls.map { it.replace("\\/", "/") }.distinct().sortedByDescending { qualityScore(it) }.take(4).toList()
    }

    suspend fun searchEromePreview(query: String, limit: Int = 8): List<Gif> {
        val q = query.trim()
        if (q.length < 2) return emptyList()
        return fetchErome(q, "hot", 1).take(limit)
    }

    private fun epornerBase36Hash(hex: String): String {
        val alphabet = "0123456789abcdefghijklmnopqrstuvwxyz"
        val sb = StringBuilder()
        var i = 0
        val limit = minOf(32, hex.length)
        while (i < limit) {
            val chunk = hex.substring(i, minOf(i + 8, limit))
            var v = chunk.toLongOrNull(16) ?: 0L
            if (v == 0L) {
                sb.append('0')
            } else {
                val sub = StringBuilder()
                while (v > 0L) {
                    sub.append(alphabet[(v % 36L).toInt()])
                    v /= 36L
                }
                sb.append(sub.reverse())
            }
            i += 8
        }
        return sb.toString()
    }

    private suspend fun resolveEporner(pageUrl: String): List<String> {
        // Tier 1: Eporner embed + Base36 XHR direct MP4 resolver (matches iOS)
        val idMatch = Regex("""(?:video-|hd-porn/|embed/)([A-Za-z0-9]+)""").find(pageUrl)?.groupValues?.get(1)
        if (!idMatch.isNullOrEmpty()) {
            val embedUrl = "https://www.eporner.com/embed/$idMatch/"
            val embedHtml = fetchString(embedUrl, desktop = true, referer = "https://www.eporner.com/")
            if (!embedHtml.isNullOrEmpty()) {
                val vid = Regex("""vid\s*=\s*'([^']+)'""").find(embedHtml)?.groupValues?.get(1)
                val rawHash = Regex("""hash\s*=\s*'([^']+)'""").find(embedHtml)?.groupValues?.get(1)
                if (!vid.isNullOrEmpty() && !rawHash.isNullOrEmpty() && rawHash.length >= 32) {
                    val b36 = epornerBase36Hash(rawHash)
                    val xhrUrl = "https://www.eporner.com/xhr/video/$vid?hash=$b36&domain=www.eporner.com&fallback=false&embed=true&supportedFormats=mp4"
                    val xhrJson = fetchString(xhrUrl, desktop = true, referer = embedUrl)
                    if (!xhrJson.isNullOrEmpty()) {
                        try {
                            val mp4Obj = JSONObject(xhrJson).optJSONObject("sources")?.optJSONObject("mp4")
                            if (mp4Obj != null) {
                                val scored = mutableListOf<Pair<Int, String>>()
                                val keys = mp4Obj.keys()
                                while (keys.hasNext()) {
                                    val k = keys.next()
                                    val src = mp4Obj.optJSONObject(k)?.optString("src")
                                    if (!src.isNullOrEmpty()) {
                                        val res = k.filter { it.isDigit() }.toIntOrNull() ?: 480
                                        scored.add(res to src)
                                    }
                                }
                                if (scored.isNotEmpty()) {
                                    return scored.sortedByDescending { it.first }.map { it.second }.distinct()
                                }
                            }
                        } catch (_: Throwable) {}
                    }
                }
            }
        }
        val html = fetchString(pageUrl, desktop = true, referer = "https://www.eporner.com/") ?: return emptyList()
        return rankVideoURLs(Regex("""https://[^"'\s\\]+?\.mp4[^"'\s\\]*""").findAll(html).map { it.value })
    }

    private suspend fun resolvePornhub(pageUrl: String): List<String> {
        val html = fetchString(pageUrl, desktop = true, referer = "https://www.pornhub.com/") ?: return emptyList()
        return rankVideoURLs(Regex("""https://[^"'\s\\]+?(?:phncdn\.com)[^"'\s\\]+?(?:\.mp4|\.m3u8)[^"'\s\\]*""").findAll(html).map { it.value })
    }

    private suspend fun resolveXHamster(pageUrl: String): List<String> {
        val html = fetchString(pageUrl, desktop = true, referer = "https://xhamster.com/") ?: return emptyList()
        return rankVideoURLs(Regex("""https?://[^"'\s\\]+xhcdn\.com[^"'\s\\]+?(?:\.mp4|\.m3u8)[^"'\s\\]*""").findAll(html).map { it.value })
    }

    private suspend fun resolveSpankBang(pageUrl: String): List<String> {
        val html = fetchString(pageUrl, desktop = true, referer = "https://spankbang.com/") ?: return emptyList()
        return rankVideoURLs(Regex("""https?://[^"'\s\\]+sb-cd\.com[^"'\s\\]+?(?:\.mp4|\.m3u8)[^"'\s\\]*""").findAll(html).map { it.value })
    }

    private fun interleave(lists: List<List<Gif>>): List<Gif> {
        val maxLen = lists.maxOfOrNull { it.size } ?: 0
        val out = mutableListOf<Gif>()
        val seen = mutableSetOf<String>()
        for (i in 0 until maxLen) {
            for (l in lists) {
                if (i < l.size && seen.add(l[i].id)) out.add(l[i])
            }
        }
        return out
    }

    private fun decodeHtml(s: String): String =
        s.replace("&amp;", "&").replace("&quot;", "\"").replace("&#39;", "'").replace("&lt;", "<").replace("&gt;", ">")
}
