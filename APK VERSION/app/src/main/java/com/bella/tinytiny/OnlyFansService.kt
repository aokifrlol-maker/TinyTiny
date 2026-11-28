package com.bella.tinytiny

import android.util.Base64
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.Request
import org.json.JSONObject
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import java.util.concurrent.ConcurrentHashMap

@Serializable
data class OFCreator(
    val id: String,
    val service: String = "onlyfans",
    val name: String,
    val displayName: String? = null,
    val avatar: String? = null,
    val banner: String? = null,
    val bio: String? = null,
    val postCount: Int? = null,
    val videoCount: Int? = null,
    val imageCount: Int? = null,
    val dmCount: Int? = null,
    val bookmarked: Int? = null,
    val gender: String? = null,
    val creatorTags: List<String>? = null
) {
    val label: String get() = displayName?.takeIf { it.isNotEmpty() } ?: "@$cleanHandle"
    val cleanHandle: String get() = name.replace("@", "")
    val avatarURL: String get() = avatar?.takeIf { it.isNotEmpty() } ?: "https://img.cum.st/creator/$service/$id/avatar.webp"
    val headerURL: String get() = banner?.takeIf { it.isNotEmpty() } ?: "https://img.cum.st/creator/$service/$id/banner.webp"
}

@Serializable
data class FollowedOFCreator(
    val id: String,
    val name: String,
    val displayName: String? = null,
    val avatarURL: String? = null
) {
    val handle: String get() = name.replace("@", "")
    val label: String get() = displayName?.takeIf { it.isNotEmpty() } ?: "@$handle"
}

@Serializable
data class OFVariant(
    val name: String,
    val bytes: Long? = null,
    val width: Int? = null,
    val height: Int? = null,
    val mime: String? = null
)

@Serializable
data class OFAttachment(
    val id: String? = null,
    val position: Int? = null,
    val kind: String,
    val filename: String? = null,
    val mimeType: String? = null,
    val mime: String? = null,
    val storageKey: String? = null,
    val bytes: Long? = null,
    val width: Int? = null,
    val height: Int? = null,
    val durationMs: Long? = null,
    val variants: List<OFVariant>? = null
)

@Serializable
data class OFPost(
    val id: String,
    val service: String? = null,
    val creatorId: String? = null,
    val creatorName: String? = null,
    val title: String? = null,
    val captionText: String? = null,
    val contentText: String? = null,
    val published: Long? = null,
    val added: Long? = null,
    val bookmarked: Int? = null,
    val attachments: List<OFAttachment>? = null,
    val tags: List<String>? = null,
    val creatorTags: List<String>? = null
)

@Serializable
data class OFFeedResponse(
    val posts: List<OFPost> = emptyList(),
    val dms: List<OFPost> = emptyList(),
    val total: Int? = null,
    val nextCursor: String? = null
)

@Serializable
data class OFCreatorsResponse(
    val creators: List<OFCreator> = emptyList()
)

@Serializable
data class OFSimilarCreatorsResponse(
    val similar: List<OFCreator> = emptyList(),
    val creators: List<OFCreator> = emptyList()
)

object OnlyFansAPI {
    private const val BASE = Config.onlyHavenBase
    private const val MEDIA_CDN = "https://cdn.cum.st/media"
    private const val THUMB_CDN = "https://img.cum.st/thumbnail"
    private val client = TinyTinyApplication.sharedHttpClient

    private val creatorById = ConcurrentHashMap<String, OFCreator>()
    private val creatorByName = ConcurrentHashMap<String, OFCreator>()
    private val creatorSearchCache = ConcurrentHashMap<String, List<OFCreator>>()
    @Volatile private var cachedTopCreators: List<OFCreator> = emptyList()
    @Volatile private var topCreatorsFetchedAt: Long = 0L

    private val femboyOrTransRescueTags = setOf(
        "femboy", "femboys", "sissy", "trap", "traps", "crossdresser", "crossdressing",
        "ladyboy", "shemale", "trans", "transgender", "transwoman", "trans_woman",
        "transgirl", "mtf", "tgirl", "futa", "futanari"
    )

    private suspend inline fun <reified T> get(path: String, query: Map<String, String> = emptyMap()): T =
        withContext(Dispatchers.IO) {
            val ub = (BASE + path).toHttpUrlOrNull()?.newBuilder() ?: throw APIException(0, "Bad URL")
            for ((k, v) in query) ub.addQueryParameter(k, v)
            val req = Request.Builder()
                .url(ub.build())
                .header("User-Agent", Config.userAgent)
                .header("Accept", "application/json")
                .header("Referer", "https://cum.st/")
                .build()
            client.newCall(req).execute().use { resp ->
                if (!resp.isSuccessful) throw APIException(resp.code, "OF API error (${resp.code})")
                val body = resp.body?.string() ?: throw APIException(resp.code, "Empty")
                CryptoBox.json.decodeFromString<T>(body)
            }
        }

    private fun cacheCreators(creators: List<OFCreator>) {
        for (c in creators) {
            creatorById[c.id] = c
            creatorByName[c.cleanHandle.lowercase()] = c
            MediaMetaRegistry.registerCreatorGender(
                creatorId = c.id,
                creatorName = c.cleanHandle,
                gender = c.gender,
                tags = c.creatorTags ?: emptyList()
            )
        }
    }

    suspend fun lookupCreator(id: String? = null, handle: String? = null): OFCreator? {
        if (!id.isNullOrEmpty()) creatorById[id]?.let { return it }
        val clean = handle?.replace("@", "")?.trim()?.lowercase()
        if (!clean.isNullOrEmpty()) creatorByName[clean]?.let { return it }
        if (clean.isNullOrEmpty() || clean.length < 2) return null
        return try {
            val resp: OFCreatorsResponse = get("/creators", mapOf("service" to "onlyfans", "q" to clean, "n" to "10"))
            cacheCreators(resp.creators)
            resp.creators.firstOrNull { it.id == id || it.cleanHandle.equals(clean, ignoreCase = true) }
                ?: resp.creators.firstOrNull()
        } catch (_: Throwable) {
            null
        }
    }

    private fun withHiddenGenders(params: Map<String, String>, skipForFemboyTransQuery: String? = null): Map<String, String> {
        val out = params.toMutableMap()
        val qLower = (skipForFemboyTransQuery ?: "").lowercase()
        val isFemboyTrans = qLower.isNotEmpty() && femboyOrTransRescueTags.any { qLower.contains(it) }
        if (!isFemboyTrans) {
            SmartTasteEngine.shared.currentHiddenOFGendersCSV()?.let { out["hide_gender"] = it }
        }
        return out
    }

    private fun isCreatorHiddenLocally(gender: String?, tags: List<String>, caption: String? = null): Boolean {
        val hidden = SmartTasteEngine.shared.state.value.hiddenOFGenders
        if (hidden.isEmpty()) return false
        val g = gender?.trim()?.lowercase() ?: return false
        if (g !in hidden) return false
        // Femboy / trans rescue when hiding men/nonbinary
        if (g == "man" || g == "nonbinary") {
            val lowerTags = tags.map { it.lowercase() }
            val capLower = (caption ?: "").lowercase()
            if (lowerTags.any { it in femboyOrTransRescueTags } || femboyOrTransRescueTags.any { capLower.contains(it) }) {
                return false
            }
        }
        return true
    }

    private fun utcDateString(daysAgo: Int): String =
        LocalDate.now(ZoneOffset.UTC).minusDays(daysAgo.toLong()).toString()

    private fun defaultFilename(mime: String?, kind: String): String {
        val lower = (mime ?: "").lowercase()
        return when {
            lower.contains("mp4") || kind == "video" -> "original.mp4"
            lower.contains("webm") -> "original.webm"
            lower.contains("quicktime") || lower.contains("mov") -> "original.mov"
            lower.contains("png") -> "original.png"
            lower.contains("webp") -> "original.webp"
            lower.contains("gif") || kind == "gif" -> "original.gif"
            else -> "original.jpg"
        }
    }

    private fun mapAttachmentToGif(
        att: OFAttachment,
        postId: String,
        creatorId: String,
        creatorName: String,
        caption: String?,
        bookmarked: Int?,
        published: Long?,
        postTags: List<String>,
        prefix: String,
        videosOnly: Boolean = true,
        ignoreGenderFilter: Boolean = false
    ): Gif? {
        val kind = att.kind.lowercase()
        if (videosOnly && kind != "video") return null
        if (kind !in setOf("video", "image", "gif")) return null
        val sk = att.storageKey?.takeIf { it.isNotEmpty() } ?: return null
        val thumbUrl = "$THUMB_CDN/$sk/preview.webp"
        val variantNames = (att.variants ?: emptyList()).map { it.name }
        val pos = att.position ?: 0
        val cleanTitle = caption?.trim()?.takeIf { it.isNotEmpty() } ?: "@$creatorName"
        val isoDate = published?.takeIf { it > 0L }?.let { Instant.ofEpochSecond(it).toString() }
        val permalink = "https://cum.st/creators/onlyfans/$creatorId/post/$postId"
        val sourceUrl = "https://cum.st/creators/onlyfans/$creatorId"

        val creator = creatorById[creatorId] ?: creatorByName[creatorName.lowercase()]
        val mergedTags = (postTags + (creator?.creatorTags ?: emptyList())).distinct()
        if (!ignoreGenderFilter && isCreatorHiddenLocally(creator?.gender, mergedTags, cleanTitle)) return null

        val postIdFull = "${prefix}_${postId}_$pos"
        MediaMetaRegistry.register(
            postId = postIdFull,
            tags = mergedTags,
            creatorName = creatorName,
            creatorId = creatorId,
            gender = creator?.gender
        )

        val effectiveMime = att.mimeType ?: att.mime
        return if (kind == "video") {
            val origFile = defaultFilename(effectiveMime, kind)
            val hdName = variantNames.firstOrNull { it == "original.mp4" }
                ?: variantNames.firstOrNull { it.contains("1080") && it.endsWith(".mp4") }
                ?: variantNames.firstOrNull { it == "720p.mp4" }
                ?: origFile
            val sdName = variantNames.firstOrNull { it == "720p.mp4" }
                ?: variantNames.firstOrNull { it == "480p.mp4" }
                ?: variantNames.firstOrNull { it == "240p.mp4" }
                ?: hdName
            val lowName = variantNames.firstOrNull { it == "240p.mp4" } ?: sdName

            val hdUrl = "$MEDIA_CDN/$sk/$hdName"
            val sdUrl = "$MEDIA_CDN/$sk/$sdName"
            val lowUrl = "$MEDIA_CDN/$sk/$lowName"
            val extras = listOf(hdUrl, sdUrl, lowUrl, "$MEDIA_CDN/$sk/$origFile").distinct()
            MediaMetaRegistry.register(postId = postIdFull, extraVideoURLs = extras)

            Gif(
                id = postIdFull,
                title = cleanTitle,
                author = creatorName,
                subreddit = null,
                upvotes = bookmarked,
                duration = att.durationMs?.let { it / 1000.0 },
                width = att.width,
                height = att.height,
                mediaType = "video",
                mediaUrl = lowUrl,
                muxedUrl = sdUrl,
                muxedUrlHd = hdUrl,
                posterUrl = thumbUrl,
                thumbnailUrl = thumbUrl,
                sourceUrl = sourceUrl,
                permalink = permalink,
                createdUtc = isoDate
            )
        } else {
            val imgName = variantNames.firstOrNull { it.startsWith("original") } ?: defaultFilename(effectiveMime, kind)
            val orig = "$MEDIA_CDN/$sk/$imgName"
            Gif(
                id = postIdFull,
                title = cleanTitle,
                author = creatorName,
                subreddit = null,
                upvotes = bookmarked,
                width = att.width,
                height = att.height,
                mediaType = "image",
                mediaUrl = orig,
                posterUrl = thumbUrl,
                thumbnailUrl = thumbUrl,
                sourceUrl = sourceUrl,
                permalink = permalink,
                createdUtc = isoDate
            )
        }
    }

    private fun mapPosts(
        posts: List<OFPost>,
        prefix: String = "of",
        fallbackCreatorId: String? = null,
        fallbackCreatorName: String? = null,
        videosOnly: Boolean = true,
        strictCreatorId: String? = null,
        ignoreGenderFilter: Boolean = false
    ): List<Gif> {
        val out = mutableListOf<Gif>()
        for (p in posts) {
            if (!strictCreatorId.isNullOrEmpty() && !p.creatorId.isNullOrEmpty() && p.creatorId != strictCreatorId) {
                continue
            }
            val cid = p.creatorId?.takeIf { it.isNotEmpty() } ?: fallbackCreatorId ?: "0"
            val cname = p.creatorName?.takeIf { it.isNotEmpty() } ?: fallbackCreatorName ?: cid
            val combinedTags = ((p.tags ?: emptyList()) + (p.creatorTags ?: emptyList())).distinct()
            for (att in p.attachments ?: emptyList()) {
                mapAttachmentToGif(
                    att = att,
                    postId = p.id,
                    creatorId = cid,
                    creatorName = cname,
                    caption = p.captionText ?: p.contentText ?: p.title,
                    bookmarked = p.bookmarked,
                    published = p.published ?: p.added,
                    postTags = combinedTags,
                    prefix = prefix,
                    videosOnly = videosOnly,
                    ignoreGenderFilter = ignoreGenderFilter
                )?.let { out.add(it) }
            }
        }
        return out
    }

    private fun parsePageCursor(after: String?): Int {
        if (after.isNullOrEmpty()) return 0
        after.toIntOrNull()?.let { return it }
        return try {
            val raw = String(Base64.decode(after, Base64.DEFAULT), Charsets.UTF_8)
            JSONObject(raw).optInt("page", 0)
        } catch (_: Throwable) {
            0
        }
    }

    private fun encodePageCursor(page: Int): String =
        Base64.encodeToString("""{"page":$page}""".toByteArray(Charsets.UTF_8), Base64.NO_WRAP)

    suspend fun fetchForYou(
        after: String? = null,
        seedCreatorIds: List<String> = emptyList(),
        tasteTags: List<String> = emptyList()
    ): GoonedFeedResponse = coroutineScope {
        val page = parsePageCursor(after)
        val offset = page * 24

        val tasteDeferred = async {
            val tag = tasteTags.getOrNull(page % maxOf(1, tasteTags.size))?.replace("_", " ")?.trim()
            if (!tag.isNullOrEmpty() && tag.length >= 3) {
                try {
                    val qParams = withHiddenGenders(
                        mapOf("service" to "onlyfans", "type" to "videos", "q" to tag, "sort" to "relevance", "o" to "$offset", "n" to "24"),
                        skipForFemboyTransQuery = tag
                    )
                    val r: OFFeedResponse = get("/posts", qParams)
                    val mapped = mapPosts(r.posts, videosOnly = true)
                    if (mapped.isNotEmpty()) return@async mapped
                    val ctParams = withHiddenGenders(
                        mapOf("service" to "onlyfans", "type" to "videos", "creator_tag" to tag.lowercase(), "sort" to "popular", "o" to "$offset", "n" to "24"),
                        skipForFemboyTransQuery = tag
                    )
                    mapPosts(get<OFFeedResponse>("/posts", ctParams).posts, videosOnly = true)
                } catch (_: Throwable) {
                    emptyList()
                }
            } else emptyList()
        }

        val similarDeferred = async {
            val seedId = seedCreatorIds.getOrNull(page % maxOf(1, seedCreatorIds.size))
            if (!seedId.isNullOrEmpty()) {
                try {
                    val simResp: OFSimilarCreatorsResponse = get("/onlyfans/user/$seedId/similar")
                    val sims = (simResp.similar + simResp.creators).distinctBy { it.id }
                    cacheCreators(sims)
                    val pick = sims.getOrNull(page % maxOf(1, sims.size)) ?: return@async emptyList()
                    val pr: OFFeedResponse = get("/onlyfans/user/${pick.id}/posts", mapOf("type" to "videos", "sort" to "popular", "o" to "0", "n" to "16"))
                    mapPosts(pr.posts, fallbackCreatorId = pick.id, fallbackCreatorName = pick.cleanHandle, videosOnly = true)
                } catch (_: Throwable) {
                    emptyList()
                }
            } else emptyList()
        }

        val trendDeferred = async { fetchTrending("$offset").posts }
        val latestDeferred = async { fetchLatest("$offset").posts }

        val buckets = listOf(tasteDeferred.await(), similarDeferred.await(), trendDeferred.await(), latestDeferred.await())
        val maxLen = buckets.maxOfOrNull { it.size } ?: 0
        val out = mutableListOf<Gif>()
        val seen = mutableSetOf<String>()
        for (i in 0 until maxLen) {
            for (b in buckets) {
                if (i < b.size && seen.add(b[i].id)) out.add(b[i])
            }
        }
        GoonedFeedResponse(posts = out, after = encodePageCursor(page + 1))
    }

    suspend fun fetchTrending(after: String? = null): GoonedFeedResponse {
        val offset = after?.toIntOrNull() ?: 0
        val periods = listOf("week", "month")
        val period = periods.getOrNull((offset / 50) % periods.size) ?: "week"
        val params = withHiddenGenders(
            mapOf("service" to "onlyfans", "type" to "videos", "period" to period, "o" to "$offset", "n" to "50")
        )
        return try {
            val resp: OFFeedResponse = get("/posts/popular", params)
            val gifs = mapPosts(resp.posts, videosOnly = true)
            if (gifs.isNotEmpty()) {
                GoonedFeedResponse(gifs, "${offset + 50}")
            } else {
                fetchLatest("$offset")
            }
        } catch (_: Throwable) {
            fetchLatest("$offset")
        }
    }

    suspend fun fetchLatest(after: String? = null): GoonedFeedResponse {
        val offset = after?.toIntOrNull() ?: 0
        val params = withHiddenGenders(
            mapOf("service" to "onlyfans", "type" to "videos", "sort" to "recent", "o" to "$offset", "n" to "40")
        )
        return try {
            val resp: OFFeedResponse = get("/posts", params)
            val mapped = mapPosts(resp.posts, videosOnly = true)
            GoonedFeedResponse(mapped, if (resp.posts.isEmpty()) null else "${offset + 40}")
        } catch (_: Throwable) {
            GoonedFeedResponse()
        }
    }

    suspend fun fetchDMs(after: String? = null): GoonedFeedResponse {
        val offset = after?.toIntOrNull() ?: 0
        val period = if ((offset / 40) % 2 == 0) "week" else "month"
        val params = withHiddenGenders(
            mapOf("service" to "onlyfans", "type" to "videos", "period" to period, "o" to "$offset", "n" to "40")
        )
        return try {
            val resp: OFFeedResponse = get("/dms/popular", params)
            val rows = if (resp.dms.isNotEmpty()) resp.dms else resp.posts
            val gifs = mapPosts(rows, prefix = "of_dm", videosOnly = true)
            if (gifs.isNotEmpty()) return GoonedFeedResponse(gifs, "${offset + 40}")
            val fallback: OFFeedResponse = get(
                "/dms",
                withHiddenGenders(mapOf("service" to "onlyfans", "type" to "videos", "sort" to "recent", "o" to "$offset", "n" to "40"))
            )
            val fbRows = if (fallback.dms.isNotEmpty()) fallback.dms else fallback.posts
            val fbGifs = mapPosts(fbRows, prefix = "of_dm", videosOnly = true)
            GoonedFeedResponse(fbGifs, if (fbRows.isEmpty()) null else "${offset + 40}")
        } catch (_: Throwable) {
            GoonedFeedResponse()
        }
    }

    suspend fun fetchCreatorPosts(
        creatorId: String,
        handle: String,
        sort: String = "hot",
        after: String? = null
    ): GoonedFeedResponse {
        val cleanHandle = handle.replace("@", "").trim()
        val stageAndOffset = (after ?: "posts:0").split(":")
        val stage = if (stageAndOffset.size == 2) stageAndOffset[0] else "posts"
        val offset = if (stageAndOffset.size == 2) (stageAndOffset[1].toIntOrNull() ?: 0) else (after?.toIntOrNull() ?: 0)
        val sortParam = if (sort == "new") "recent" else "popular"

        return try {
            when (stage) {
                "posts" -> {
                    val resp: OFFeedResponse = get(
                        "/onlyfans/user/$creatorId/posts",
                        mapOf("type" to "videos", "sort" to sortParam, "o" to "$offset", "n" to "40")
                    )
                    val gifs = mapPosts(
                        resp.posts,
                        fallbackCreatorId = creatorId,
                        fallbackCreatorName = cleanHandle,
                        videosOnly = true,
                        strictCreatorId = creatorId,
                        ignoreGenderFilter = true
                    )
                    if (gifs.isNotEmpty()) {
                        GoonedFeedResponse(gifs, "posts:${offset + 40}")
                    } else {
                        fetchCreatorPosts(creatorId, cleanHandle, sort, "dms:0")
                    }
                }
                "dms" -> {
                    val resp: OFFeedResponse = get(
                        "/onlyfans/user/$creatorId/dms",
                        mapOf("type" to "videos", "sort" to sortParam, "o" to "$offset", "n" to "40")
                    )
                    val rows = if (resp.dms.isNotEmpty()) resp.dms else resp.posts
                    val gifs = mapPosts(
                        rows,
                        prefix = "of_dm",
                        fallbackCreatorId = creatorId,
                        fallbackCreatorName = cleanHandle,
                        videosOnly = true,
                        strictCreatorId = creatorId,
                        ignoreGenderFilter = true
                    )
                    if (gifs.isNotEmpty()) {
                        GoonedFeedResponse(gifs, "dms:${offset + 40}")
                    } else {
                        // Strictly stop after this creator's own posts & DMs — never leak similar/trending creators
                        GoonedFeedResponse(emptyList(), null)
                    }
                }
                else -> GoonedFeedResponse(emptyList(), null)
            }
        } catch (_: Throwable) {
            GoonedFeedResponse(emptyList(), null)
        }
    }

    suspend fun searchPosts(query: String, after: String? = null): GoonedFeedResponse = coroutineScope {
        val clean = query.trim().replace("@", "")
        if (clean.isEmpty()) return@coroutineScope fetchTrending(after)
        val offset = after?.toIntOrNull() ?: 0
        val results = mutableListOf<Gif>()
        val seen = mutableSetOf<String>()

        if (clean.length >= 3) {
            try {
                val params = withHiddenGenders(
                    mapOf("service" to "onlyfans", "type" to "videos", "q" to clean, "sort" to "relevance", "o" to "$offset", "n" to "40"),
                    skipForFemboyTransQuery = clean
                )
                val resp: OFFeedResponse = get("/posts", params)
                for (g in mapPosts(resp.posts, videosOnly = true)) {
                    if (seen.add(g.id)) results.add(g)
                }
            } catch (_: Throwable) {}
        }

        // Blend videos from top 3 matching creators when offset == 0 and results < 8
        if (offset == 0 && results.size < 8) {
            val matchingCreators = searchCreators(clean, limit = 3)
            val tasks = matchingCreators.map { c ->
                async {
                    try {
                        val r: OFFeedResponse = get(
                            "/onlyfans/user/${c.id}/posts",
                            mapOf("type" to "videos", "sort" to "popular", "o" to "0", "n" to "12")
                        )
                        mapPosts(r.posts, fallbackCreatorId = c.id, fallbackCreatorName = c.cleanHandle, videosOnly = true)
                    } catch (_: Throwable) {
                        emptyList()
                    }
                }
            }
            for (t in tasks) {
                for (g in t.await()) {
                    if (seen.add(g.id)) results.add(g)
                }
            }
        }

        GoonedFeedResponse(results, if (results.isEmpty()) null else "${offset + 40}")
    }

    suspend fun fetchTopCreators(limit: Int = 50): List<OFCreator> = coroutineScope {
        val now = System.currentTimeMillis()
        if (cachedTopCreators.isNotEmpty() && now - topCreatorsFetchedAt < 300_000L) {
            return@coroutineScope cachedTopCreators
                .filter { !isCreatorHiddenLocally(it.gender, it.creatorTags ?: emptyList()) }
                .take(limit)
        }
        try {
            val p1 = async {
                get<OFCreatorsResponse>(
                    "/creators",
                    withHiddenGenders(mapOf("service" to "onlyfans", "sort" to "bookmarked", "content" to "imported", "o" to "0", "n" to "50"))
                ).creators
            }
            val p2 = async {
                try {
                    get<OFCreatorsResponse>(
                        "/creators",
                        withHiddenGenders(mapOf("service" to "onlyfans", "sort" to "bookmarked", "content" to "imported", "o" to "50", "n" to "50"))
                    ).creators
                } catch (_: Throwable) {
                    emptyList()
                }
            }
            val all = (p1.await() + p2.await()).distinctBy { it.id }
            cacheCreators(all)
            cachedTopCreators = all
            topCreatorsFetchedAt = now
            all.filter { !isCreatorHiddenLocally(it.gender, it.creatorTags ?: emptyList()) }.take(limit)
        } catch (_: Throwable) {
            emptyList()
        }
    }

    suspend fun searchCreators(query: String, limit: Int = 20): List<OFCreator> {
        val clean = query.trim().replace(Regex("(?i)^of:"), "").replace("@", "").trim()
        if (clean.isEmpty()) return fetchTopCreators(limit)
        val hiddenCsv = SmartTasteEngine.shared.currentHiddenOFGendersCSV() ?: ""
        val cacheKey = "${clean.lowercase()}|$hiddenCsv"
        creatorSearchCache[cacheKey]?.let { return it.take(limit) }

        val topPool = fetchTopCreators(100)
        val localMatches = topPool.filter { c ->
            c.cleanHandle.contains(clean, ignoreCase = true) ||
                (c.displayName?.contains(clean, ignoreCase = true) == true) ||
                (c.creatorTags?.any { it.contains(clean, ignoreCase = true) } == true)
        }
        if (clean.length < 3) {
            return localMatches.sortedByDescending { it.videoCount ?: 0 }.take(limit)
        }
        return try {
            val resp: OFCreatorsResponse = get(
                "/creators",
                withHiddenGenders(
                    mapOf("service" to "onlyfans", "q" to clean, "sort" to "bookmarked", "o" to "0", "n" to "$limit"),
                    skipForFemboyTransQuery = clean
                )
            )
            cacheCreators(resp.creators)
            val merged = (resp.creators + localMatches)
                .distinctBy { it.id }
                .filter { !isCreatorHiddenLocally(it.gender, it.creatorTags ?: emptyList()) }
                .sortedByDescending { it.videoCount ?: 0 }
            creatorSearchCache[cacheKey] = merged
            merged.take(limit)
        } catch (_: Throwable) {
            localMatches.take(limit)
        }
    }
}
