package com.bella.tinytiny

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import java.net.URLEncoder
import java.util.concurrent.TimeUnit

object HttpPool {
    val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(10, TimeUnit.SECONDS)
        .readTimeout(14, TimeUnit.SECONDS)
        .followRedirects(true)
        .build()

    fun getString(url: String, headers: Map<String, String> = emptyMap()): String? {
        return try {
            val b = Request.Builder()
                .url(url)
                .header(
                    "User-Agent",
                    "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36"
                )
            headers.forEach { (k, v) -> b.header(k, v) }
            client.newCall(b.build()).execute().use { resp ->
                if (!resp.isSuccessful) return null
                resp.body?.string()
            }
        } catch (_: Exception) {
            null
        }
    }

    fun encode(s: String): String = URLEncoder.encode(s, "UTF-8")
}

object GoonedAPI {
    private const val BASE = "https://api.gooned.app"
    private val goonedHeaders = mapOf(
        "Accept" to "application/json",
        "Origin" to "https://gooned.app",
        "Referer" to "https://gooned.app/",
        "Cache-Control" to "no-cache"
    )

    private fun randomForYouCursor(offset: Int = 0): String {
        val seed = java.util.UUID.randomUUID().toString().replace("-", "").lowercase().take(10)
        val raw = """{"seed":"$seed","offset":$offset}"""
        return android.util.Base64.encodeToString(raw.toByteArray(Charsets.UTF_8), android.util.Base64.NO_WRAP)
    }

    suspend fun forYou(sort: String, after: String?): GoonedFeedResponse = withContext(Dispatchers.IO) {
        val cur = after?.takeIf { it.isNotBlank() } ?: randomForYouCursor(0)
        val url = "$BASE/reddit/foryou?sort=${HttpPool.encode(sort)}&limit=25&after=${HttpPool.encode(cur)}"
        val body = HttpPool.getString(url, goonedHeaders) ?: return@withContext GoonedFeedResponse(emptyList())
        parseGoonedResponse(body)
    }

    suspend fun subreddit(name: String, sort: String, after: String?, limit: Int = 25): GoonedFeedResponse = withContext(Dispatchers.IO) {
        val clean = name.removePrefix("r/").removePrefix("/").trim()
        val afterQ = if (!after.isNullOrBlank()) "&after=${HttpPool.encode(after)}" else ""
        val url = "$BASE/reddit/subreddit/${HttpPool.encode(clean)}?sort=${HttpPool.encode(sort)}&limit=$limit$afterQ"
        val body = HttpPool.getString(url, goonedHeaders) ?: return@withContext GoonedFeedResponse(emptyList())
        parseGoonedResponse(body)
    }

    suspend fun user(name: String, after: String?): GoonedFeedResponse = withContext(Dispatchers.IO) {
        val clean = name.removePrefix("u/").removePrefix("@").trim()
        val afterQ = if (!after.isNullOrBlank()) "&after=${HttpPool.encode(after)}" else ""
        val url = "$BASE/reddit/user/${HttpPool.encode(clean)}?sort=hot&limit=25$afterQ"
        val body = HttpPool.getString(url, goonedHeaders) ?: return@withContext GoonedFeedResponse(emptyList())
        parseGoonedResponse(body)
    }

    suspend fun category(name: String, sort: String, after: String?, limit: Int = 25): GoonedFeedResponse = withContext(Dispatchers.IO) {
        val afterQ = if (!after.isNullOrBlank()) "&after=${HttpPool.encode(after)}" else ""
        val url = "$BASE/reddit/category/${HttpPool.encode(name)}?sort=${HttpPool.encode(sort)}&limit=$limit$afterQ"
        val body = HttpPool.getString(url, goonedHeaders) ?: return@withContext GoonedFeedResponse(emptyList())
        parseGoonedResponse(body)
    }

    suspend fun searchSubreddits(query: String): List<String> = withContext(Dispatchers.IO) {
        val url = "$BASE/reddit/search?q=${HttpPool.encode(query)}"
        val body = HttpPool.getString(url, goonedHeaders) ?: return@withContext emptyList()
        val out = mutableListOf<String>()
        runCatching {
            val arr = JSONObject(body).optJSONArray("subreddits") ?: JSONArray()
            for (i in 0 until arr.length()) {
                val n = arr.getJSONObject(i).optString("name")
                if (n.isNotBlank()) out.add(n)
            }
        }
        out
    }

    private fun parseGoonedResponse(raw: String): GoonedFeedResponse {
        val posts = mutableListOf<Gif>()
        var nextAfter: String? = null
        runCatching {
            val obj = JSONObject(raw)
            nextAfter = obj.optString("after").takeIf { it.isNotBlank() && it != "null" }
            val arr = obj.optJSONArray("posts") ?: JSONArray()
            for (i in 0 until arr.length()) {
                val p = arr.getJSONObject(i)
                val id = p.optString("id").takeIf { it.isNotBlank() } ?: continue
                val title = p.optString("title").takeIf { it.isNotBlank() && it != "null" }
                val author = p.optString("author").takeIf { it.isNotBlank() && it != "null" }
                val sub = p.optString("subreddit").takeIf { it.isNotBlank() && it != "null" }
                val mediaType = p.optString("mediaType").takeIf { it.isNotBlank() && it != "null" }
                val mediaUrl = p.optString("mediaUrl").takeIf { it.isNotBlank() && it != "null" }
                val muxedUrl = p.optString("muxedUrl").takeIf { it.isNotBlank() && it != "null" }
                val muxedUrlHd = p.optString("muxedUrlHd").takeIf { it.isNotBlank() && it != "null" }
                val hlsUrl = p.optString("hlsUrl").takeIf { it.isNotBlank() && it != "null" }
                val posterUrl = p.optString("posterUrl").takeIf { it.isNotBlank() && it != "null" }
                val thumbUrl = p.optString("thumbnailUrl").takeIf { it.isNotBlank() && it != "null" }
                val sourceUrl = p.optString("sourceUrl").takeIf { it.isNotBlank() && it != "null" }
                val permalink = p.optString("permalink").takeIf { it.isNotBlank() && it != "null" }
                if (!sub.isNullOrBlank()) {
                    MediaMetaRegistry.register(postId = id, tags = listOf(sub.lowercase()), creatorName = author)
                }
                posts.add(
                    Gif(
                        id = id,
                        title = title,
                        author = author,
                        subreddit = sub,
                        upvotes = p.optInt("upvotes", 0),
                        duration = p.optDouble("duration", 0.0).takeIf { !it.isNaN() && it > 0 },
                        width = p.optInt("width", 0).takeIf { it > 0 },
                        height = p.optInt("height", 0).takeIf { it > 0 },
                        mediaType = mediaType,
                        mediaUrl = mediaUrl,
                        muxedUrl = muxedUrl,
                        muxedUrlHd = muxedUrlHd,
                        hlsUrl = hlsUrl,
                        posterUrl = posterUrl,
                        thumbnailUrl = thumbUrl,
                        sourceUrl = sourceUrl,
                        permalink = permalink
                    )
                )
            }
        }
        return GoonedFeedResponse(posts, nextAfter)
    }
}

object OnlyFansAPI {
    private const val BASE = "https://cum.st/api/v1"
    private const val MEDIA_CDN = "https://cdn.cum.st/media"
    private const val THUMB_CDN = "https://img.cum.st/thumbnail"
    private val ofHeaders = mapOf(
        "Accept" to "application/json",
        "Referer" to "https://cum.st/",
        "Origin" to "https://cum.st"
    )

    private fun buildUrl(path: String, params: Map<String, String>): String {
        val merged = params.toMutableMap()
        val hidden = SmartTasteEngine.state.value.hiddenOFGenders
        if (hidden.isNotEmpty()) {
            merged["hide_gender"] = hidden.joinToString(",")
        }
        val q = merged.entries.joinToString("&") { "${it.key}=${HttpPool.encode(it.value)}" }
        return "$BASE$path?$q"
    }

    suspend fun trending(after: String?): GoonedFeedResponse = withContext(Dispatchers.IO) {
        val offset = after?.toIntOrNull() ?: 0
        val url = buildUrl("/posts", mapOf("service" to "onlyfans", "sort" to "popular", "o" to "$offset", "n" to "24"))
        fetchPosts(url, offset)
    }

    suspend fun latest(after: String?): GoonedFeedResponse = withContext(Dispatchers.IO) {
        val offset = after?.toIntOrNull() ?: 0
        val url = buildUrl("/posts", mapOf("service" to "onlyfans", "sort" to "recent", "o" to "$offset", "n" to "24"))
        fetchPosts(url, offset)
    }

    suspend fun dms(after: String?): GoonedFeedResponse = withContext(Dispatchers.IO) {
        val offset = after?.toIntOrNull() ?: 0
        val url = buildUrl("/posts", mapOf("service" to "onlyfans", "q" to "dm", "o" to "$offset", "n" to "24"))
        fetchPosts(url, offset)
    }

    suspend fun searchPosts(query: String, after: String?): GoonedFeedResponse = withContext(Dispatchers.IO) {
        val offset = after?.toIntOrNull() ?: 0
        val url = buildUrl("/posts", mapOf("service" to "onlyfans", "q" to query, "o" to "$offset", "n" to "24"))
        fetchPosts(url, offset)
    }

    suspend fun creatorFeed(id: String, after: String?): GoonedFeedResponse = withContext(Dispatchers.IO) {
        val offset = after?.toIntOrNull() ?: 0
        val url = buildUrl("/posts", mapOf("service" to "onlyfans", "creator_id" to id, "o" to "$offset", "n" to "24"))
        fetchPosts(url, offset)
    }

    suspend fun forYou(
        after: String?,
        seedCreators: List<String>,
        tasteTags: List<String>
    ): GoonedFeedResponse = coroutineScope {
        val page = after?.toIntOrNull() ?: 0
        val queries = (seedCreators.take(2) + tasteTags.take(2)).distinct()
        if (queries.isEmpty()) {
            return@coroutineScope trending(after)
        }
        val batches = queries.map { q ->
            async(Dispatchers.IO) { searchPosts(q, "${page * 12}").posts }
        } + listOf(async(Dispatchers.IO) { trending("${page * 18}").posts })
        val merged = batches.awaitAll().flatten().distinctBy { it.id }
        GoonedFeedResponse(merged, "${page + 1}")
    }

    private fun fetchPosts(url: String, offset: Int): GoonedFeedResponse {
        val body = HttpPool.getString(url, ofHeaders) ?: return GoonedFeedResponse(emptyList())
        val posts = mutableListOf<Gif>()
        runCatching {
            val arr = if (body.trimStart().startsWith("[")) JSONArray(body) else JSONObject(body).optJSONArray("posts") ?: JSONArray()
            for (i in 0 until arr.length()) {
                val obj = arr.getJSONObject(i)
                val postIdRaw = obj.optString("id").takeIf { it.isNotBlank() } ?: continue
                val title = obj.optString("content", obj.optString("title")).takeIf { it.isNotBlank() && it != "null" }
                val creatorObj = obj.optJSONObject("creator")
                val cId = creatorObj?.optString("id")?.takeIf { it.isNotBlank() } ?: obj.optString("creatorId", obj.optString("user"))
                val cName = creatorObj?.optString("name")?.takeIf { it.isNotBlank() } ?: obj.optString("creatorName", "onlyfans")
                val cGender = creatorObj?.optString("gender")?.takeIf { it.isNotBlank() && it != "null" }
                val tagsArr = obj.optJSONArray("tags")
                val tagList = mutableListOf<String>()
                if (tagsArr != null) {
                    for (t in 0 until tagsArr.length()) {
                        val s = tagsArr.optString(t)
                        if (s.isNotBlank()) tagList.add(s)
                    }
                }

                val attachments = obj.optJSONArray("attachments") ?: continue
                for (a in 0 until attachments.length()) {
                    val att = attachments.getJSONObject(a)
                    val kind = att.optString("kind", "").lowercase()
                    if (kind != "video" && kind != "image" && kind != "gif") continue
                    val sk = att.optString("storageKey", "").takeIf { it.isNotBlank() && it != "null" } ?: continue
                    val variantsArr = att.optJSONArray("variants")
                    val variantNames = mutableListOf<String>()
                    if (variantsArr != null) {
                        for (v in 0 until variantsArr.length()) {
                            val vn = variantsArr.getJSONObject(v).optString("name")
                            if (vn.isNotBlank()) variantNames.add(vn)
                        }
                    }
                    val thumbURL = "$THUMB_CDN/$sk/preview.webp"
                    val gid = "of_${postIdRaw}_$a"
                    MediaMetaRegistry.register(
                        postId = gid,
                        tags = tagList,
                        creatorGender = cGender,
                        creatorId = cId,
                        creatorName = cName
                    )
                    if (kind == "video") {
                        val hdName = variantNames.firstOrNull { it == "original.mp4" }
                            ?: variantNames.firstOrNull { it.contains("1080") }
                            ?: variantNames.firstOrNull { it == "720p.mp4" }
                            ?: variantNames.firstOrNull()
                            ?: "original.mp4"
                        val sdName = variantNames.firstOrNull { it == "720p.mp4" } ?: hdName
                        val lowName = variantNames.firstOrNull { it == "240p.mp4" } ?: sdName
                        posts.add(
                            Gif(
                                id = gid,
                                title = title ?: "@$cName",
                                author = cName,
                                subreddit = "OnlyFans",
                                mediaType = "video",
                                mediaUrl = "$MEDIA_CDN/$sk/$lowName",
                                muxedUrl = "$MEDIA_CDN/$sk/$sdName",
                                muxedUrlHd = "$MEDIA_CDN/$sk/$hdName",
                                posterUrl = thumbURL,
                                thumbnailUrl = thumbURL,
                                sourceUrl = "https://cum.st/creators/onlyfans/$cId",
                                permalink = "https://cum.st/creators/onlyfans/$cId/post/$postIdRaw"
                            )
                        )
                    } else {
                        val imgName = variantNames.firstOrNull { it.startsWith("original") } ?: variantNames.firstOrNull() ?: "original.jpg"
                        posts.add(
                            Gif(
                                id = gid,
                                title = title ?: "@$cName",
                                author = cName,
                                subreddit = "OnlyFans",
                                mediaType = "image",
                                mediaUrl = "$MEDIA_CDN/$sk/$imgName",
                                posterUrl = thumbURL,
                                thumbnailUrl = thumbURL,
                                sourceUrl = "https://cum.st/creators/onlyfans/$cId",
                                permalink = "https://cum.st/creators/onlyfans/$cId/post/$postIdRaw"
                            )
                        )
                    }
                }
            }
        }
        return GoonedFeedResponse(posts, if (posts.isEmpty()) null else "${offset + posts.size}")
    }
}

object Rule34API {
    suspend fun fetchFeed(
        tag: String?,
        sort: String,
        after: String?,
        credentials: Rule34Credentials
    ): GoonedFeedResponse = withContext(Dispatchers.IO) {
        val page = after?.toIntOrNull() ?: 0
        val algo = UserStore.data.value.algorithm
        val blocked = (algo.blockedTags.map { it.lowercase() } + SmartTasteEngine.state.value.suppressedTags).toMutableSet()
        val pinned = algo.boostedTags.map { it.lowercase() }.toSet()
        if ((blocked.contains("gay") || blocked.contains("men") || blocked.contains("yaoi")) && !pinned.contains("gay")) {
            blocked.addAll(listOf("gay", "yaoi", "bara", "male_only", "males_only"))
        }

        val cleanTag = tag?.trim().orEmpty()
        val tasteTags = if (cleanTag.isBlank()) SmartTasteEngine.activeQueryTags(algo.boostedTags, algo.blockedTags, 6) else emptyList()
        val effectiveTag = when {
            cleanTag.isNotBlank() -> cleanTag
            tasteTags.isNotEmpty() -> tasteTags[page % tasteTags.size]
            else -> ""
        }
        val negTags = blocked.take(10).joinToString(" ") { "-$it" }
        val fullQuery = listOf(effectiveTag, negTags).filter { it.isNotBlank() }.joinToString(" ")
        val authQ = if (credentials.isConnected) "&user_id=${HttpPool.encode(credentials.userId)}&api_key=${HttpPool.encode(credentials.apiKey)}" else ""
        val sortTag = if (sort == "top") "sort:score:desc" else ""
        val qAll = listOf(fullQuery, sortTag).filter { it.isNotBlank() }.joinToString(" ")

        val url = "https://api.rule34.xxx/index.php?page=dapi&s=post&q=index&json=1&limit=28&pid=$page&tags=${HttpPool.encode(qAll)}$authQ"
        val body = HttpPool.getString(url) ?: return@withContext GoonedFeedResponse(emptyList())
        val posts = mutableListOf<Gif>()
        runCatching {
            val arr = JSONArray(body)
            for (i in 0 until arr.length()) {
                val o = arr.getJSONObject(i)
                val id = o.opt("id")?.toString() ?: continue
                val fileUrl = o.optString("file_url")
                val sampleUrl = o.optString("sample_url", fileUrl)
                val previewUrl = o.optString("preview_url", sampleUrl)
                val tagsStr = o.optString("tags")
                val splitTags = tagsStr.split(" ").map { it.trim().lowercase() }.filter { it.isNotBlank() && !MediaMetaRegistry.isStopTag(it) }
                val owner = o.optString("owner", "rule34")
                val postId = "r34_$id"
                MediaMetaRegistry.register(postId = postId, tags = splitTags.take(18), creatorName = owner)
                val isMp4 = fileUrl.lowercase().endsWith(".mp4") || fileUrl.lowercase().endsWith(".webm")
                posts.add(
                    Gif(
                        id = postId,
                        title = splitTags.take(8).joinToString(" ") { "#$it" },
                        author = owner,
                        subreddit = "rule34.xxx",
                        upvotes = o.optInt("score", 0),
                        width = o.optInt("width", 1080),
                        height = o.optInt("height", 1080),
                        mediaType = if (isMp4) "video" else "image",
                        mediaUrl = if (isMp4) fileUrl else sampleUrl,
                        muxedUrl = if (isMp4) fileUrl else null,
                        muxedUrlHd = if (isMp4) fileUrl else null,
                        posterUrl = previewUrl,
                        thumbnailUrl = previewUrl,
                        permalink = "https://rule34.xxx/index.php?page=post&s=view&id=$id"
                    )
                )
            }
        }
        GoonedFeedResponse(posts, if (posts.isEmpty()) null else "${page + 1}")
    }
}

object LongVideoAPI {
    suspend fun fetchFeed(site: LongVideoSite, sort: String, query: String?, after: String?): GoonedFeedResponse = coroutineScope {
        val page = (after?.toIntOrNull() ?: 1).coerceAtLeast(1)
        val cleanQ = query?.trim().orEmpty()
        val algo = UserStore.data.value.algorithm
        val tasteTags = SmartTasteEngine.activeQueryTags(algo.boostedTags, algo.blockedTags, 6)
        val blockedLower = algo.blockedTags.map { it.lowercase() }.toSet() + SmartTasteEngine.state.value.suppressedTags
        val pinnedLower = algo.boostedTags.map { it.lowercase() }.toSet()
        val suppressGay = (blockedLower.contains("gay") || blockedLower.contains("men") || blockedLower.contains("yaoi")) && !pinnedLower.contains("gay")

        val effectiveQ = if (cleanQ.isNotBlank()) cleanQ else tasteTags.getOrNull((page - 1) % tasteTags.size.coerceAtLeast(1)).orEmpty().replace("_", " ")

        val rawPosts: List<Gif> = when (site) {
            LongVideoSite.EPORNER -> fetchEporner(effectiveQ, sort, page, suppressGay)
            LongVideoSite.XVIDEOS -> fetchXVideos(effectiveQ, sort, page)
            LongVideoSite.PORNHUB -> fetchPornhub(effectiveQ, sort, page)
            LongVideoSite.XHAMSTER -> fetchXVideos(effectiveQ, sort, page)
            LongVideoSite.SPANKBANG -> fetchXVideos(effectiveQ, sort, page)
            LongVideoSite.ALL -> {
                val ep = async(Dispatchers.IO) { fetchEporner(effectiveQ, sort, page, suppressGay) }
                val xv = async(Dispatchers.IO) { fetchXVideos(effectiveQ, sort, page) }
                val ph = async(Dispatchers.IO) { fetchPornhub(effectiveQ, sort, page) }
                val buckets = listOf(ep.await(), xv.await(), ph.await())
                val maxLen = buckets.maxOfOrNull { it.size } ?: 0
                val mixed = mutableListOf<Gif>()
                for (i in 0 until maxLen) {
                    for (b in buckets) if (i < b.size) mixed.add(b[i])
                }
                mixed
            }
        }
        GoonedFeedResponse(rawPosts, if (rawPosts.isEmpty()) null else "${page + 1}")
    }

    private fun fetchEporner(query: String, sort: String, page: Int, suppressGay: Boolean): List<Gif> {
        val order = when (sort) {
            "top" -> "top-rated"
            "new" -> "latest"
            else -> "most-popular"
        }
        val gayFlag = if (suppressGay) "0" else "1"
        val q = if (query.isBlank()) "all" else query
        val url = "https://www.eporner.com/api/v2/video/search/?query=${HttpPool.encode(q)}&per_page=18&page=$page&thumbsize=big&order=$order&gay=$gayFlag&format=json"
        val body = HttpPool.getString(url) ?: return emptyList()
        val out = mutableListOf<Gif>()
        runCatching {
            val videos = JSONObject(body).optJSONArray("videos") ?: return@runCatching
            for (i in 0 until videos.length()) {
                val v = videos.getJSONObject(i)
                val id = v.optString("id").takeIf { it.isNotBlank() } ?: continue
                val title = v.optString("title")
                val embed = v.optString("embed")
                val thumb = v.optJSONObject("default_thumb")?.optString("src")
                val kw = v.optString("keywords").split(",").map { it.trim().lowercase().replace(" ", "_") }.filter { it.isNotBlank() && !MediaMetaRegistry.isStopTag(it) }
                val postId = "lv_ep_$id"
                MediaMetaRegistry.register(postId = postId, tags = kw.take(14), creatorName = "Eporner")
                val direct = resolveEpornerMp4(id) ?: continue
                out.add(
                    Gif(
                        id = postId,
                        title = title,
                        author = "Eporner",
                        subreddit = "Eporner",
                        upvotes = v.optInt("views", 0),
                        duration = v.optDouble("length_sec", 0.0),
                        mediaType = "video",
                        mediaUrl = direct,
                        muxedUrl = direct,
                        muxedUrlHd = direct,
                        posterUrl = thumb,
                        thumbnailUrl = thumb,
                        permalink = v.optString("url", embed)
                    )
                )
            }
        }
        return out
    }

    private fun resolveEpornerMp4(id: String): String? {
        val html = HttpPool.getString("https://www.eporner.com/embed/$id/") ?: return null
        val match = Regex("""https://[^"'\s]+\.mp4[^"'\s]*""").find(html)
        return match?.value
    }

    private fun fetchXVideos(query: String, sort: String, page: Int): List<Gif> {
        val url = if (query.isBlank()) {
            "https://www.xvideos.com/new/$page"
        } else {
            "https://www.xvideos.com/?k=${HttpPool.encode(query)}&p=${page - 1}"
        }
        val html = HttpPool.getString(url) ?: return emptyList()
        val matches = Regex("""href="(/video[^"]+)"[^>]*title="([^"]+)"""").findAll(html).take(8).toList()
        val out = mutableListOf<Gif>()
        for (m in matches) {
            val path = m.groupValues[1]
            val title = m.groupValues[2]
            val vidHtml = HttpPool.getString("https://www.xvideos.com$path") ?: continue
            val hls = Regex("""setVideoHLS\('([^']+)'\)""").find(vidHtml)?.groupValues?.get(1)
            val mp4 = Regex("""setVideoUrlHigh\('([^']+)'\)""").find(vidHtml)?.groupValues?.get(1)
                ?: Regex("""setVideoUrlLow\('([^']+)'\)""").find(vidHtml)?.groupValues?.get(1)
            val thumb = Regex("""setThumbUrl169\('([^']+)'\)""").find(vidHtml)?.groupValues?.get(1)
            if (hls == null && mp4 == null) continue
            val id = path.hashCode().toString()
            out.add(
                Gif(
                    id = "lv_xv_$id",
                    title = title,
                    author = "XVideos",
                    subreddit = "XVideos",
                    mediaType = "video",
                    mediaUrl = mp4 ?: hls,
                    muxedUrl = mp4,
                    muxedUrlHd = mp4,
                    hlsUrl = hls,
                    posterUrl = thumb,
                    thumbnailUrl = thumb,
                    permalink = "https://www.xvideos.com$path"
                )
            )
        }
        return out
    }

    private fun fetchPornhub(query: String, sort: String, page: Int): List<Gif> {
        val q = if (query.isBlank()) "amateur" else query
        val url = "https://www.pornhub.com/webmasters/search?search=${HttpPool.encode(q)}&page=$page&thumbsize=large_hd"
        val body = HttpPool.getString(url) ?: return emptyList()
        val out = mutableListOf<Gif>()
        runCatching {
            val videos = JSONObject(body).optJSONArray("videos") ?: return@runCatching
            for (i in 0 until videos.length()) {
                val v = videos.getJSONObject(i)
                val vid = v.optString("video_id").takeIf { it.isNotBlank() } ?: continue
                val title = v.optString("title")
                val thumb = v.optString("default_thumb", v.optString("thumb"))
                val postId = "lv_ph_$vid"
                out.add(
                    Gif(
                        id = postId,
                        title = title,
                        author = "Pornhub",
                        subreddit = "Pornhub",
                        upvotes = v.optInt("views", 0),
                        mediaType = "video",
                        mediaUrl = thumb,
                        posterUrl = thumb,
                        thumbnailUrl = thumb,
                        permalink = v.optString("url")
                    )
                )
            }
        }
        return out
    }
}

object XAPI {
    private const val BEARER = "AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA"

    suspend fun feed(followingOnly: Boolean, after: String?): GoonedFeedResponse = withContext(Dispatchers.IO) {
        val sess = UserStore.data.value.xSession
        if (!sess.isConnected) return@withContext GoonedFeedResponse(emptyList())
        val op = if (followingOnly) "HomeLatestTimeline" else "HomeTimeline"
        val queryId = if (followingOnly) "U0c3R0a1o1R2U2" else "HJFjzBg766"
        val vars = """{"count":20,"includePromotedContent":false,"latestControlAvailable":true${if (!after.isNullOrBlank()) ""","cursor":"$after"""" else ""}}"""
        val url = "https://x.com/i/api/graphql/$queryId/$op?variables=${HttpPool.encode(vars)}"
        val body = HttpPool.getString(
            url,
            mapOf(
                "Authorization" to "Bearer $BEARER",
                "x-csrf-token" to sess.ct0,
                "Cookie" to "auth_token=${sess.authToken}; ct0=${sess.ct0}",
                "x-twitter-auth-type" to "OAuth2Session"
            )
        ) ?: return@withContext GoonedFeedResponse(emptyList())
        parseXResponse(body, strictFollowing = followingOnly)
    }

    suspend fun search(query: String, sort: String, after: String?): GoonedFeedResponse = withContext(Dispatchers.IO) {
        val sess = UserStore.data.value.xSession
        if (!sess.isConnected) return@withContext GoonedFeedResponse(emptyList())
        GoonedFeedResponse(emptyList())
    }

    private fun parseXResponse(raw: String, strictFollowing: Boolean): GoonedFeedResponse {
        val posts = mutableListOf<Gif>()
        runCatching {
            val mp4Matches = Regex("""https://video\.twimg\.com/[^"\\]+\.mp4[^"\\]*""").findAll(raw).map { it.value }.distinct().toList()
            mp4Matches.forEachIndexed { idx, mp4 ->
                posts.add(
                    Gif(
                        id = "x_${mp4.hashCode()}_$idx",
                        title = if (strictFollowing) "Following" else "𝕏 Video",
                        author = "x_user",
                        subreddit = "𝕏",
                        mediaType = "video",
                        mediaUrl = mp4,
                        muxedUrl = mp4,
                        muxedUrlHd = mp4,
                        permalink = "https://x.com"
                    )
                )
            }
        }
        return GoonedFeedResponse(posts, null)
    }
}

object InstagramAPI {
    suspend fun reels(followingOnly: Boolean, after: String?): GoonedFeedResponse = withContext(Dispatchers.IO) {
        val sess = UserStore.data.value.igSession
        if (!sess.isConnected) return@withContext GoonedFeedResponse(emptyList())
        val endpoint = if (followingOnly) {
            "https://www.instagram.com/api/v1/feed/timeline/"
        } else {
            "https://www.instagram.com/api/v1/clips/discover/"
        }
        val body = HttpPool.getString(
            endpoint,
            mapOf(
                "X-IG-App-ID" to "936619743392459",
                "X-CSRFToken" to sess.csrfToken,
                "Cookie" to "sessionid=${sess.sessionId}; csrftoken=${sess.csrfToken}; ds_user_id=${sess.dsUserId}"
            )
        ) ?: return@withContext GoonedFeedResponse(emptyList())
        val posts = mutableListOf<Gif>()
        runCatching {
            val root = JSONObject(body)
            val items = root.optJSONArray("feed_items") ?: root.optJSONArray("items") ?: JSONArray()
            for (i in 0 until items.length()) {
                val item = items.getJSONObject(i)
                val media = item.optJSONObject("media_or_ad") ?: item.optJSONObject("media") ?: item
                val user = media.optJSONObject("user")
                val friendship = user?.optJSONObject("friendship_status")
                if (followingOnly && friendship != null && !friendship.optBoolean("following", true)) {
                    continue
                }
                val id = media.optString("id").takeIf { it.isNotBlank() } ?: continue
                val videos = media.optJSONArray("video_versions")
                val videoUrl = videos?.optJSONObject(0)?.optString("url")
                val imgs = media.optJSONObject("image_versions2")?.optJSONArray("candidates")
                val imgUrl = imgs?.optJSONObject(0)?.optString("url")
                if (videoUrl == null && imgUrl == null) continue
                val username = user?.optString("username", "instagram") ?: "instagram"
                posts.add(
                    Gif(
                        id = "ig_$id",
                        title = media.optJSONObject("caption")?.optString("text"),
                        author = username,
                        subreddit = "Instagram",
                        upvotes = media.optInt("like_count", 0),
                        mediaType = if (videoUrl != null) "video" else "image",
                        mediaUrl = videoUrl ?: imgUrl,
                        muxedUrl = videoUrl,
                        muxedUrlHd = videoUrl,
                        posterUrl = imgUrl,
                        thumbnailUrl = imgUrl,
                        permalink = "https://www.instagram.com/$username/"
                    )
                )
            }
        }
        GoonedFeedResponse(posts, null)
    }
}
