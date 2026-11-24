package com.bella.tinytiny

import androidx.compose.ui.graphics.Color
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import java.net.URLEncoder
import java.util.concurrent.ConcurrentHashMap

enum class LongVideoSite(val rawValue: String, val displayTitle: String, val accentColor: Color) {
    ALL("all", "All", Theme.accentBright),
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
    private val bgScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
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

            suspend fun blendWithTaste(fetchFn: suspend (String) -> List<Gif>): List<Gif> {
                if (tasteQuery == null) return fetchFn(cleanQ)
                val tDef = async { fetchFn(tasteQuery) }
                val mDef = async { fetchFn(cleanQ) }
                return interleave(listOf(tDef.await(), mDef.await()))
            }

            val rawPosts: List<Gif> = when (site) {
                LongVideoSite.ALL -> {
                    val qForMix = if (cleanQ.isNotEmpty()) cleanQ else (tasteQuery ?: "")
                    val ep = async { fetchEporner(qForMix, sort, page, suppressGay) }
                    val xv = async { fetchXVideos(qForMix, sort, page) }
                    val ph = async { fetchPornhub(qForMix, sort, page) }
                    val xh = async { fetchXHamster(qForMix, sort, page) }
                    val sb = async { fetchSpankBang(qForMix, sort, page, suppressGay) }
                    interleave(listOf(ep.await(), xv.await(), ph.await(), xh.await(), sb.await()))
                }
                LongVideoSite.EPORNER -> blendWithTaste { fetchEporner(it, sort, page, suppressGay) }
                LongVideoSite.XVIDEOS -> blendWithTaste { fetchXVideos(it, sort, page) }
                LongVideoSite.PORNHUB -> blendWithTaste { fetchPornhub(it, sort, page) }
                LongVideoSite.XHAMSTER -> blendWithTaste { fetchXHamster(it, sort, page) }
                LongVideoSite.SPANKBANG -> blendWithTaste { fetchSpankBang(it, sort, page, suppressGay) }
                LongVideoSite.EROME -> blendWithTaste { fetchErome(it, sort, page) }
            }

            // Pre-resolve first 3 videos in background just like iOS
            if (rawPosts.isNotEmpty()) {
                val toPre = rawPosts.take(3)
                bgScope.launch {
                    for (p in toPre) {
                        try { resolvePlayableURLs(p) } catch (_: Throwable) {}
                    }
                }
            }

            GoonedFeedResponse(posts = rawPosts, after = if (rawPosts.isEmpty()) null else "${page + 1}")
        }

    private suspend fun fetchEporner(query: String, sort: String, page: Int, suppressGay: Boolean): List<Gif> {
        val order = when (sort) {
            "top" -> "top-rated"
            "new" -> "latest"
            else -> "most-popular"
        }
        val q = URLEncoder.encode(query.ifEmpty { "all" }, "UTF-8")
        val gayFlag = if (suppressGay && !query.lowercase().contains("gay")) 0 else 1
        val url = "https://www.eporner.com/api/v2/video/search/?query=$q&per_page=24&page=$page&thumbsize=big&order=$order&gay=$gayFlag&format=json"
        val raw = fetchString(url) ?: return emptyList()
        val out = mutableListOf<Gif>()
        try {
            val videos = JSONObject(raw).optJSONArray("videos") ?: return emptyList()
            for (i in 0 until videos.length()) {
                val v = videos.optJSONObject(i) ?: continue
                val id = v.optString("id").takeIf { it.isNotEmpty() } ?: continue
                val dur = v.optDouble("length_sec", 0.0).takeIf { it > 0 }
                if (query.isEmpty() && (dur ?: 0.0) < 90.0) continue
                val title = v.optString("title").ifEmpty { "Eporner Video" }
                val thumbObj = v.optJSONObject("default_thumb")
                val thumb = thumbObj?.optString("src")
                val tw = thumbObj?.optInt("width", 1280)?.takeIf { it > 0 } ?: 1280
                val th = thumbObj?.optInt("height", 720)?.takeIf { it > 0 } ?: 720
                val pageUrl = v.optString("url").ifEmpty { "https://www.eporner.com/video-$id/" }
                val views = v.optInt("views", 0).takeIf { it > 0 }
                val kw = v.optString("keywords", "").split(",").map { it.trim().lowercase() }.filter { it.isNotEmpty() }
                val postId = "lv_ep_$id"
                if (kw.isNotEmpty()) MediaMetaRegistry.register(postId, tags = kw, creatorName = "Eporner")
                out.add(
                    Gif(
                        id = postId,
                        title = title,
                        author = "Eporner",
                        subreddit = "Eporner",
                        upvotes = views,
                        duration = dur,
                        width = if (th > tw) 720 else 1280,
                        height = if (th > tw) 1280 else 720,
                        mediaType = "video",
                        posterUrl = thumb,
                        thumbnailUrl = thumb,
                        sourceUrl = "eporner:$id",
                        permalink = pageUrl
                    )
                )
            }
        } catch (_: Throwable) {}
        return out
    }

    private suspend fun fetchXVideos(query: String, sort: String, page: Int): List<Gif> {
        val url = if (query.isEmpty()) {
            when (sort) {
                "new" -> "https://www.xvideos.com/new/${maxOf(1, page)}"
                "top" -> if (page <= 1) "https://www.xvideos.com/best" else "https://www.xvideos.com/best/${page - 1}"
                else -> if (page <= 1) "https://www.xvideos.com/" else "https://www.xvideos.com/new/$page"
            }
        } else {
            val enc = URLEncoder.encode(query, "UTF-8")
            val sortParam = when (sort) {
                "new" -> "&sort=uploaddate"
                "top" -> "&sort=rating"
                else -> "&sort=relevance"
            }
            "https://www.xvideos.com/?k=$enc&p=${maxOf(0, page - 1)}$sortParam"
        }
        val html = fetchString(url, desktop = true) ?: return emptyList()
        val out = mutableListOf<Gif>()
        val seen = mutableSetOf<String>()
        val blocks = html.split("id=\"video_")
        for (block in blocks.drop(1).take(30)) {
            val eid = Regex("""data-eid="([^"]+)"""").find(block)?.groupValues?.get(1)
                ?: Regex("""href="/video\.([a-z0-9]+)/""").find(block)?.groupValues?.get(1)
                ?: continue
            if (eid.isEmpty()) continue
            val postId = "lv_xv_$eid"
            if (!seen.add(postId)) continue
            val title = decodeHtml(
                Regex("""title="([^"]+)"""").find(block)?.groupValues?.get(1)
                    ?: Regex("""<p class="title"><a[^>]*>([^<]+)</a>""").find(block)?.groupValues?.get(1)
                    ?: "XVideos"
            )
            val thumb = Regex("""data-src="([^"]+)"""").find(block)?.groupValues?.get(1)
                ?: Regex("""src="(https://[^"]+xvideos-cdn\.com[^"]+\.jpg[^"]*)"""").find(block)?.groupValues?.get(1)
            val uploader = Regex("""<span class="name">([^<]+)</span>""").find(block)?.groupValues?.get(1) ?: "XVideos"
            val durStr = Regex("""<span class="duration">([^<]+)</span>""").find(block)?.groupValues?.get(1)
            val dur = parseHumanDuration(durStr)
            val pageUrl = "https://www.xvideos.com/video.$eid/0"
            out.add(
                Gif(
                    id = postId,
                    title = title,
                    author = uploader,
                    subreddit = "XVideos",
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
        return out.take(24)
    }

    private suspend fun fetchPornhub(query: String, sort: String, page: Int): List<Gif> {
        try {
            val ordering = when (sort) {
                "top" -> "rating"
                "new" -> "newest"
                else -> "mostviewed"
            }
            val period = if (sort == "new") "daily" else "weekly"
            val qPart = if (query.isNotEmpty()) "search=${URLEncoder.encode(query, "UTF-8")}&" else ""
            val apiUrl = "https://www.pornhub.com/webmasters/search?${qPart}ordering=$ordering&period=$period&page=$page&thumbsize=large_hd"
            val raw = fetchString(apiUrl, desktop = false)
            if (!raw.isNullOrEmpty() && raw.trimStart().startsWith("{")) {
                val arr = JSONObject(raw).optJSONArray("videos")
                if (arr != null && arr.length() > 0) {
                    val out = mutableListOf<Gif>()
                    for (i in 0 until minOf(25, arr.length())) {
                        val v = arr.optJSONObject(i) ?: continue
                        val vkey = v.optString("video_id").takeIf { it.isNotEmpty() } ?: continue
                        val title = decodeHtml(v.optString("title").ifEmpty { "Pornhub Video" })
                        val thumb = v.optString("default_thumb").ifEmpty { v.optString("thumb") }.takeIf { it.isNotEmpty() }
                        val pageUrl = v.optString("url").ifEmpty { "https://www.pornhub.com/view_video.php?viewkey=$vkey" }
                        val dur = parseColonDuration(v.optString("duration"))
                        val views = v.optInt("views", 0).takeIf { it > 0 }
                        val tags = mutableListOf<String>()
                        v.optJSONArray("tags")?.let { ta ->
                            for (j in 0 until ta.length()) {
                                ta.optJSONObject(j)?.optString("tag_name")?.takeIf { it.isNotEmpty() }?.let { tags.add(it.lowercase()) }
                            }
                        }
                        v.optJSONArray("categories")?.let { ca ->
                            for (j in 0 until ca.length()) {
                                ca.optJSONObject(j)?.optString("category")?.takeIf { it.isNotEmpty() }?.let { tags.add(it.lowercase()) }
                            }
                        }
                        val postId = "lv_ph_$vkey"
                        if (tags.isNotEmpty()) MediaMetaRegistry.register(postId, tags = tags, creatorName = "Pornhub")
                        out.add(
                            Gif(
                                id = postId,
                                title = title,
                                author = "Pornhub",
                                subreddit = "Pornhub",
                                upvotes = views,
                                duration = dur,
                                width = 1280,
                                height = 720,
                                mediaType = "video",
                                posterUrl = thumb,
                                thumbnailUrl = thumb,
                                sourceUrl = "pornhub:$vkey",
                                permalink = pageUrl
                            )
                        )
                    }
                    if (out.isNotEmpty()) return out
                }
            }
        } catch (_: Throwable) {}

        // Tier 2 HTML fallback
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
                    sourceUrl = "pornhub:$vkey",
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

        // Tier 1: Recursive JSON walk of window.initials (matches iOS)
        try {
            val idx = html.indexOf("window.initials")
            if (idx >= 0) {
                val start = html.indexOf('{', idx)
                val end = html.indexOf(";</script>", start)
                if (start >= 0 && end > start) {
                    val root = JSONObject(html.substring(start, end))
                    fun walkXH(node: Any?, depth: Int) {
                        if (depth > 14 || node == null || out.size >= 24) return
                        when (node) {
                            is JSONArray -> for (i in 0 until node.length()) walkXH(node.opt(i), depth + 1)
                            is JSONObject -> {
                                val pageUrl = node.optString("pageURL").takeIf { it.contains("xhamster.com/videos/") }
                                val title = node.optString("title").takeIf { it.isNotEmpty() }
                                val thumb = node.optString("thumbURL").takeIf { it.isNotEmpty() }
                                    ?: node.optJSONObject("landing")?.optString("logo")?.takeIf { it.isNotEmpty() }
                                if (pageUrl != null && title != null && thumb != null) {
                                    val vidId = node.opt("id")?.toString()?.takeIf { it.isNotEmpty() }
                                        ?: pageUrl.substringAfterLast('/').takeLast(24)
                                    val gid = "lv_xh_$vidId"
                                    if (seen.add(gid)) {
                                        out.add(
                                            Gif(
                                                id = gid,
                                                title = decodeHtml(title),
                                                author = "xHamster",
                                                subreddit = "xHamster",
                                                upvotes = node.optInt("views", 0).takeIf { it > 0 },
                                                duration = node.optDouble("duration", 0.0).takeIf { it > 0 },
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
                                }
                                val keys = node.keys()
                                while (keys.hasNext()) walkXH(node.opt(keys.next()), depth + 1)
                            }
                        }
                    }
                    walkXH(root, 0)
                    if (out.isNotEmpty()) return out
                }
            }
        } catch (_: Throwable) {}

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

    private suspend fun fetchSpankBang(query: String, sort: String, page: Int, suppressGay: Boolean): List<Gif> = coroutineScope {
        val url = if (query.isEmpty()) {
            val path = when (sort) {
                "top" -> "most_popular"
                "new" -> "new_videos"
                else -> "trending_videos"
            }
            "https://spankbang.com/$path/$page/"
        } else {
            val enc = URLEncoder.encode(query, "UTF-8")
            "https://spankbang.com/s/$enc/$page/"
        }
        val html = fetchString(url, desktop = true)
        val out = mutableListOf<Gif>()
        val seen = mutableSetOf<String>()
        if (!html.isNullOrEmpty()) {
            val blocks = html.split("data-id=\"")
            for (block in blocks.drop(1).take(30)) {
                val rel = Regex("""href="(/[a-z0-9\-_]+/video/[^"]+)"""", RegexOption.IGNORE_CASE).find(block)?.groupValues?.get(1) ?: continue
                val code = rel.trim('/').substringBefore('/')
                val id = "lv_sb_$code"
                if (!seen.add(id)) continue
                val thumb = Regex("""(?:data-src|src)="(https://[^"]+(?:sb-cd|spankbang)[^"]+)"""", RegexOption.IGNORE_CASE).find(block)?.groupValues?.get(1)
                val title = decodeHtml(Regex("""(?:alt|title)="([^"]+)"""").find(block)?.groupValues?.get(1) ?: "SpankBang")
                val pageUrl = "https://spankbang.com$rel"
                out.add(
                    Gif(
                        id = id,
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
        }
        if (out.isNotEmpty()) return@coroutineScope out.take(24)

        // Cloudflare 403 fallback matching iOS: interleaved XVideos + Eporner rebadged as SpankBang
        val xvDef = async { fetchXVideos(query, sort, page) }
        val epDef = async { fetchEporner(query, sort, page, suppressGay) }
        val xvRebadged = xvDef.await().map { g ->
            g.copy(id = "lv_sb_xv_${g.id.removePrefix("lv_xv_")}", subreddit = "SpankBang")
        }
        val epRebadged = epDef.await().map { g ->
            g.copy(id = "lv_sb_ep_${g.id.removePrefix("lv_ep_")}", subreddit = "SpankBang")
        }
        interleave(listOf(xvRebadged, epRebadged)).take(24)
    }

    private suspend fun fetchErome(query: String, sort: String, page: Int): List<Gif> {
        val url = if (query.isEmpty()) {
            val path = if (sort == "new") "explore/new" else "explore"
            "https://www.erome.com/$path?page=$page"
        } else {
            val enc = URLEncoder.encode(query, "UTF-8")
            val orderParam = if (sort == "new") "&o=new" else ""
            "https://www.erome.com/search?q=$enc&page=$page$orderParam"
        }
        val html = fetchString(url, desktop = true, referer = "https://www.erome.com/")
        val out = mutableListOf<Gif>()
        val seen = mutableSetOf<String>()
        if (!html.isNullOrEmpty()) {
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
        }
        // Multi-word zero-result fallback on page 1 (matches iOS)
        if (out.isEmpty() && page == 1 && query.contains(" ")) {
            val longest = query.split(Regex("\\s+")).filter { it.length >= 3 }.maxByOrNull { it.length }
            if (longest != null && longest != query) {
                return fetchErome(longest, sort, page)
            }
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
            gif.id.startsWith("lv_xv_") || gif.id.startsWith("lv_sb_xv_") -> resolveXVideos(gif.id, pageUrl)
            gif.id.startsWith("lv_ep_") || gif.id.startsWith("lv_sb_ep_") -> resolveEporner(pageUrl, gif.permalink)
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
                albumItems.add(AlbumMediaItem(id = s, url = s, posterUrl = s, isVideo = false))
            }
        }
        if (albumItems.isNotEmpty()) {
            MediaMetaRegistry.registerAlbumItems(gifId, albumItems)
            MediaMetaRegistry.register(gifId, extraVideoURLs = videoURLs)
        }
        return videoURLs
    }

    private suspend fun resolveXVideos(gifId: String, pageUrl: String): List<String> {
        val html = fetchString(pageUrl, desktop = true, referer = "https://www.xvideos.com/") ?: return emptyList()
        val high = Regex("""setVideoUrlHigh\('([^']+)'\)""", RegexOption.IGNORE_CASE).find(html)?.groupValues?.get(1)
        val low = Regex("""setVideoUrlLow\('([^']+)'\)""", RegexOption.IGNORE_CASE).find(html)?.groupValues?.get(1)
        val hls = Regex("""setVideoHLS\('([^']+)'\)""", RegexOption.IGNORE_CASE).find(html)?.groupValues?.get(1)
        val tags = Regex("""/tags/([a-z0-9\-_]+)""", RegexOption.IGNORE_CASE)
            .findAll(html).map { it.groupValues[1].lowercase() }.distinct().take(12).toList()
        if (tags.isNotEmpty()) MediaMetaRegistry.register(gifId, tags = tags)
        return listOfNotNull(hls, high, low).distinct()
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
                ".m3u8" in l -> 2
                else -> 3
            }
        }
        return urls.map { it.replace("\\/", "/") }.distinct().sortedByDescending { qualityScore(it) }.take(6).toList()
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

    private suspend fun resolveEporner(sourceUrl: String, permalink: String?): List<String> {
        val idMatch = if (sourceUrl.startsWith("eporner:")) {
            sourceUrl.removePrefix("eporner:")
        } else {
            Regex("""(?:video-|hd-porn/|embed/)([A-Za-z0-9]+)""").find(sourceUrl)?.groupValues?.get(1)
        }
        if (!idMatch.isNullOrEmpty()) {
            val embedUrl = "https://www.eporner.com/embed/$idMatch/"
            val embedHtml = fetchString(embedUrl, desktop = false, referer = "https://www.eporner.com/")
            if (!embedHtml.isNullOrEmpty()) {
                val vid = Regex("""vid\s*=\s*'([^']+)'""").find(embedHtml)?.groupValues?.get(1)
                val rawHash = Regex("""hash\s*=\s*'([^']+)'""").find(embedHtml)?.groupValues?.get(1)
                if (!vid.isNullOrEmpty() && !rawHash.isNullOrEmpty() && rawHash.length >= 32) {
                    val b36 = epornerBase36Hash(rawHash)
                    val xhrUrl = "https://www.eporner.com/xhr/video/$vid?hash=$b36&domain=www.eporner.com&fallback=false&embed=true&supportedFormats=mp4"
                    val xhrJson = fetchString(xhrUrl, desktop = false, referer = embedUrl)
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
        val target = permalink ?: if (idMatch != null) "https://www.eporner.com/video-$idMatch/" else sourceUrl
        val html = fetchString(target, desktop = false, referer = "https://www.eporner.com/") ?: return emptyList()
        val cleaned = html.replace("\\/", "/")
        val jsonLd = Regex(""""contentUrl"\s*:\s*"(https?://[^"]+)"""").find(cleaned)?.groupValues?.get(1)
        val mp4s = rankVideoURLs(Regex("""https?://[^"'\s\\]+?\.mp4[^"'\s\\]*""").findAll(cleaned).map { it.value })
        return (listOfNotNull(jsonLd) + mp4s).distinct()
    }

    private suspend fun resolvePornhub(pageUrl: String): List<String> {
        val vid = Regex("""viewkey=([a-z0-9]+)""", RegexOption.IGNORE_CASE).find(pageUrl)?.groupValues?.get(1)
            ?: pageUrl.removePrefix("pornhub:").takeIf { it.isNotEmpty() && !it.startsWith("http") }
        val embedUrl = if (!vid.isNullOrEmpty()) "https://www.pornhub.com/embed/$vid" else pageUrl
        val html = fetchString(embedUrl, desktop = false, referer = "https://www.pornhub.com/") ?: return emptyList()
        val cleaned = html.replace("\\/", "/")
        val urls = mutableListOf<String>()
        val seen = mutableSetOf<String>()
        val getMediaUrl = Regex("""(https://www\.pornhub\.com/video/get_media\?[^"'\s\\]+)""").find(cleaned)?.groupValues?.get(1)
        if (!getMediaUrl.isNullOrEmpty()) {
            val gmRaw = fetchString(getMediaUrl, desktop = false, referer = embedUrl)
            if (!gmRaw.isNullOrEmpty() && gmRaw.trimStart().startsWith("[")) {
                try {
                    val arr = JSONArray(gmRaw)
                    val scored = mutableListOf<Pair<Int, String>>()
                    for (i in 0 until arr.length()) {
                        val obj = arr.optJSONObject(i) ?: continue
                        val uStr = obj.optString("videoUrl")
                        if (uStr.isEmpty()) continue
                        val fmt = obj.optString("format")
                        if (fmt == "mp4" || uStr.contains(".mp4")) {
                            val q = obj.opt("quality")?.toString()?.filter { it.isDigit() }?.toIntOrNull() ?: 480
                            scored.add(q to uStr)
                        }
                    }
                    for ((_, u) in scored.sortedByDescending { it.first }) {
                        if (seen.add(u)) urls.add(u)
                    }
                } catch (_: Throwable) {}
            }
        }
        for (m in Regex("""https://[^"'\s\\]+?master\.m3u8[^"'\s\\]*""").findAll(cleaned)) {
            if (seen.add(m.value)) urls.add(m.value)
        }
        if (urls.isNotEmpty()) return urls
        return rankVideoURLs(Regex("""https://[^"'\s\\]+?(?:phncdn\.com)[^"'\s\\]+?(?:\.mp4|\.m3u8)[^"'\s\\]*""").findAll(cleaned).map { it.value })
    }

    private suspend fun resolveXHamster(pageUrl: String): List<String> {
        val html = fetchString(pageUrl, desktop = false, referer = "https://xhamster.com/") ?: return emptyList()
        // CRITICAL FIX: Unescape \/ -> / BEFORE matching URLs!
        val cleaned = html.replace("\\/", "/")
        val p1 = Regex("""https?://[^"'\s]+?(?:1080p|720p|480p)[^"'\s]*?\.mp4[^"'\s]*""", RegexOption.IGNORE_CASE).findAll(cleaned).map { it.value }
        val p2 = Regex("""https?://[^"'\s]+?xhcdn\.com[^"'\s]+?\.mp4[^"'\s]*""", RegexOption.IGNORE_CASE).findAll(cleaned).map { it.value }
        val p3 = Regex("""https?://[^"'\s]+?xhcdn\.com[^"'\s]+?\.m3u8[^"'\s]*""", RegexOption.IGNORE_CASE).findAll(cleaned).map { it.value }
        return rankVideoURLs(p1 + p2 + p3)
    }

    private suspend fun resolveSpankBang(pageUrl: String): List<String> {
        val html = fetchString(pageUrl, desktop = true, referer = "https://spankbang.com/") ?: return emptyList()
        // CRITICAL FIX: Unescape \/ -> / BEFORE matching URLs & match both sb-cd.com and spankbang.com!
        val cleaned = html.replace("\\/", "/")
        val urls = Regex("""https?://[^"'\s]+?(?:sb-cd\.com|spankbang\.com)[^"'\s]+?(?:\.mp4|\.m3u8)[^"'\s]*""", RegexOption.IGNORE_CASE)
            .findAll(cleaned).map { it.value }
        return rankVideoURLs(urls)
    }

    private fun parseHumanDuration(raw: String?): Double? {
        if (raw.isNullOrBlank()) return null
        val lower = raw.lowercase()
        var total = 0.0
        Regex("""(\d+)\s*h""").find(lower)?.groupValues?.get(1)?.toDoubleOrNull()?.let { total += it * 3600 }
        Regex("""(\d+)\s*min""").find(lower)?.groupValues?.get(1)?.toDoubleOrNull()?.let { total += it * 60 }
        Regex("""(\d+)\s*sec""").find(lower)?.groupValues?.get(1)?.toDoubleOrNull()?.let { total += it }
        return if (total > 0) total else null
    }

    private fun parseColonDuration(raw: String?): Double? {
        if (raw.isNullOrBlank()) return null
        val parts = raw.trim().split(":").mapNotNull { it.toDoubleOrNull() }
        return when (parts.size) {
            2 -> parts[0] * 60 + parts[1]
            3 -> parts[0] * 3600 + parts[1] * 60 + parts[2]
            else -> null
        }?.takeIf { it > 0 }
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
