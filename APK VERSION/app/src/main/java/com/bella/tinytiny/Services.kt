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
    private val defaultSubs = listOf("nsfwgifs", "porninfifteenseconds", "60fpsporn", "NSFW_GIF", "gothsluts", "asiansgonewild", "femboys")

    suspend fun forYou(sort: String, after: String?): GoonedFeedResponse = withContext(Dispatchers.IO) {
        val sub = defaultSubs.random()
        subreddit(sub, sort, after, 24)
    }

    suspend fun subreddit(name: String, sort: String, after: String?, limit: Int = 24): GoonedFeedResponse = withContext(Dispatchers.IO) {
        val s = when (sort) {
            "top" -> "top"
            "new" -> "new"
            else -> "hot"
        }
        val afterQ = if (!after.isNullOrBlank()) "&after=${HttpPool.encode(after)}" else ""
        val url = "https://www.reddit.com/r/${HttpPool.encode(name)}/$s.json?limit=$limit&raw_json=1$afterQ"
        val body = HttpPool.getString(url, mapOf("Accept" to "application/json")) ?: return@withContext GoonedFeedResponse(emptyList())
        parseRedditListing(body, name)
    }

    suspend fun user(name: String, after: String?): GoonedFeedResponse = withContext(Dispatchers.IO) {
        val afterQ = if (!after.isNullOrBlank()) "&after=${HttpPool.encode(after)}" else ""
        val url = "https://www.reddit.com/user/${HttpPool.encode(name)}/submitted.json?limit=24&raw_json=1$afterQ"
        val body = HttpPool.getString(url, mapOf("Accept" to "application/json")) ?: return@withContext GoonedFeedResponse(emptyList())
        parseRedditListing(body, name)
    }

    suspend fun category(name: String, sort: String, after: String?, limit: Int = 20): GoonedFeedResponse =
        subreddit(name.replace(" ", ""), sort, after, limit)

    suspend fun searchSubreddits(query: String): List<String> = withContext(Dispatchers.IO) {
        val url = "https://www.reddit.com/subreddits/search.json?q=${HttpPool.encode(query)}&include_over_18=on&limit=8"
        val body = HttpPool.getString(url) ?: return@withContext emptyList()
        val out = mutableListOf<String>()
        runCatching {
            val children = JSONObject(body).getJSONObject("data").getJSONArray("children")
            for (i in 0 until children.length()) {
                val d = children.getJSONObject(i).getJSONObject("data")
                val name = d.optString("display_name")
                if (name.isNotBlank()) out.add(name)
            }
        }
        out
    }

    private fun parseRedditListing(raw: String, fallbackSub: String): GoonedFeedResponse {
        val posts = mutableListOf<Gif>()
        var nextAfter: String? = null
        runCatching {
            val data = JSONObject(raw).getJSONObject("data")
            nextAfter = data.optString("after").takeIf { it.isNotBlank() && it != "null" }
            val children = data.getJSONArray("children")
            for (i in 0 until children.length()) {
                val d = children.getJSONObject(i).optJSONObject("data") ?: continue
                val id = d.optString("id").takeIf { it.isNotBlank() } ?: continue
                val title = d.optString("title")
                val author = d.optString("author")
                val sub = d.optString("subreddit", fallbackSub)
                val ups = d.optInt("ups", 0)
                val permalink = "https://www.reddit.com" + d.optString("permalink")
                val urlOver = d.optString("url_overridden_by_dest", d.optString("url"))
                val created = d.optDouble("created_utc", 0.0)

                var videoUrl: String? = null
                var hlsUrl: String? = null
                var posterUrl: String? = null
                var mediaType = "video"

                val redditVideo = d.optJSONObject("secure_media")?.optJSONObject("reddit_video")
                    ?: d.optJSONObject("media")?.optJSONObject("reddit_video")
                if (redditVideo != null) {
                    videoUrl = redditVideo.optString("fallback_url").takeIf { it.isNotBlank() }
                    hlsUrl = redditVideo.optString("hls_url").takeIf { it.isNotBlank() }
                }

                val previewVideo = d.optJSONObject("preview")?.optJSONObject("reddit_video_preview")
                if (videoUrl == null && previewVideo != null) {
                    videoUrl = previewVideo.optString("fallback_url").takeIf { it.isNotBlank() }
                    hlsUrl = previewVideo.optString("hls_url").takeIf { it.isNotBlank() }
                }

                val images = d.optJSONObject("preview")?.optJSONArray("images")
                if (images != null && images.length() > 0) {
                    posterUrl = images.getJSONObject(0).optJSONObject("source")?.optString("url")
                }

                if (videoUrl == null && hlsUrl == null) {
                    val low = urlOver.lowercase()
                    if (low.endsWith(".mp4") || low.endsWith(".webm")) {
                        videoUrl = urlOver
                    } else if (low.endsWith(".gifv")) {
                        videoUrl = urlOver.replace(".gifv", ".mp4")
                    } else if (low.endsWith(".jpg") || low.endsWith(".jpeg") || low.endsWith(".png") || low.endsWith(".webp") || low.endsWith(".gif")) {
                        mediaType = "image"
                        posterUrl = urlOver
                    } else {
                        continue
                    }
                }

                val postId = "rd_$id"
                MediaMetaRegistry.register(postId = postId, tags = listOf(sub.lowercase()), creatorName = author)
                posts.add(
                    Gif(
                        id = postId,
                        title = title,
                        author = author,
                        subreddit = sub,
                        upvotes = ups,
                        mediaType = mediaType,
                        mediaUrl = videoUrl ?: posterUrl,
                        muxedUrl = videoUrl,
                        muxedUrlHd = videoUrl,
                        hlsUrl = hlsUrl,
                        posterUrl = posterUrl,
                        thumbnailUrl = posterUrl,
                        sourceUrl = urlOver,
                        permalink = permalink,
                        createdUtc = created
                    )
                )
            }
        }
        return GoonedFeedResponse(posts, nextAfter)
    }
}

object OnlyFansAPI {
    private const val BASE = "https://cum.st/api"

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
        val body = HttpPool.getString(url, mapOf("Accept" to "application/json")) ?: return GoonedFeedResponse(emptyList())
        val posts = mutableListOf<Gif>()
        runCatching {
            val arr = if (body.trimStart().startsWith("[")) JSONArray(body) else JSONObject(body).optJSONArray("posts") ?: JSONArray()
            for (i in 0 until arr.length()) {
                val obj = arr.getJSONObject(i)
                val id = obj.optString("id").takeIf { it.isNotBlank() } ?: continue
                val title = obj.optString("content", obj.optString("title"))
                val creatorObj = obj.optJSONObject("creator")
                val cId = creatorObj?.optString("id") ?: obj.optString("user")
                val cName = creatorObj?.optString("name") ?: obj.optString("creator_name", "onlyfans")
                val cGender = creatorObj?.optString("gender")?.takeIf { it.isNotBlank() }
                val tagsArr = obj.optJSONArray("tags")
                val tagList = mutableListOf<String>()
                if (tagsArr != null) {
                    for (t in 0 until tagsArr.length()) {
                        tagList.add(tagsArr.optString(t))
                    }
                }

                var videoUrl: String? = null
                var posterUrl: String? = null
                val attachments = obj.optJSONArray("attachments")
                if (attachments != null) {
                    for (a in 0 until attachments.length()) {
                        val att = attachments.getJSONObject(a)
                        val u = att.optString("url", att.optString("path"))
                        if (u.contains(".mp4") || u.contains(".m3u8")) {
                            if (videoUrl == null) videoUrl = u
                        } else if (u.isNotBlank() && posterUrl == null) {
                            posterUrl = u
                        }
                    }
                }
                if (videoUrl == null && posterUrl == null) continue
                val postId = "of_$id"
                MediaMetaRegistry.register(
                    postId = postId,
                    tags = tagList,
                    creatorGender = cGender,
                    creatorId = cId,
                    creatorName = cName
                )
                posts.add(
                    Gif(
                        id = postId,
                        title = title,
                        author = cName,
                        subreddit = "OnlyFans",
                        mediaType = if (videoUrl != null) "video" else "image",
                        mediaUrl = videoUrl ?: posterUrl,
                        muxedUrl = videoUrl,
                        muxedUrlHd = videoUrl,
                        posterUrl = posterUrl,
                        thumbnailUrl = posterUrl,
                        permalink = "https://onlyfans.com/$cName"
                    )
                )
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
