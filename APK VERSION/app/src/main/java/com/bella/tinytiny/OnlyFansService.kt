package com.bella.tinytiny

import android.util.Base64
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.SerialName
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
    @SerialName("display_name") val displayName: String? = null,
    val avatar: String? = null,
    val banner: String? = null,
    val bio: String? = null,
    @SerialName("post_count") val postCount: Int? = null,
    @SerialName("media_count") val mediaCount: Int? = null,
    @SerialName("favorited_count") val favoritedCount: Int? = null,
    val gender: String? = null,
    @SerialName("creator_tags") val creatorTags: List<String>? = null
) {
    val label: String get() = displayName?.takeIf { it.isNotEmpty() } ?: "@$name"
    val cleanHandle: String get() = name.replace("@", "")
}

@Serializable
data class FollowedOFCreator(
    val id: String,
    val name: String,
    val displayName: String? = null
) {
    val label: String get() = displayName?.takeIf { it.isNotEmpty() } ?: "@$name"
}

@Serializable
data class OFVariant(
    val name: String,
    val width: Int? = null,
    val height: Int? = null,
    val size: Int? = null,
    val mime: String? = null
)

@Serializable
data class OFAttachment(
    val id: String? = null,
    val position: Int? = null,
    val kind: String,
    val filename: String? = null,
    val mime: String? = null,
    @SerialName("storage_key") val storageKey: String? = null,
    val size: Int? = null,
    val width: Int? = null,
    val height: Int? = null,
    @SerialName("duration_ms") val durationMs: Int? = null,
    val variants: List<OFVariant>? = null
)

@Serializable
data class OFPost(
    val id: String,
    val service: String? = null,
    @SerialName("creator_id") val creatorId: String? = null,
    @SerialName("creator_name") val creatorName: String? = null,
    @SerialName("creator_display_name") val creatorDisplayName: String? = null,
    val title: String? = null,
    val caption: String? = null,
    @SerialName("published_at") val publishedAt: Int? = null,
    @SerialName("bookmarked_count") val bookmarkedCount: Int? = null,
    val attachments: List<OFAttachment>? = null
)

@Serializable
data class OFFeedResponse(
    val posts: List<OFPost> = emptyList(),
    @SerialName("next_cursor") val nextCursor: String? = null
)

@Serializable
data class OFCreatorsResponse(
    val creators: List<OFCreator> = emptyList()
)

object OnlyFansAPI {
    private const val BASE = Config.onlyHavenBase
    private const val MEDIA_CDN = "https://cdn.cum.st/media"
    private const val THUMB_CDN = "https://img.cum.st/thumbnail"
    private val client = TinyTinyApplication.sharedHttpClient

    private val creatorById = ConcurrentHashMap<String, OFCreator>()
    private val creatorByName = ConcurrentHashMap<String, OFCreator>()
    private var cachedTopCreators: List<OFCreator> = emptyList()

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
            creatorByName[c.name.lowercase()] = c
        }
    }

    private fun withHiddenGenders(params: Map<String, String>): Map<String, String> {
        val out = params.toMutableMap()
        SmartTasteEngine.shared.currentHiddenOFGendersCSV()?.let { out["hide_gender"] = it }
        return out
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
        published: Int?,
        prefix: String
    ): Gif? {
        val kind = att.kind.lowercase()
        if (kind !in setOf("video", "image", "gif")) return null
        val sk = att.storageKey?.takeIf { it.isNotEmpty() } ?: return null
        val thumbUrl = "$THUMB_CDN/$sk/preview.webp"
        val variantNames = (att.variants ?: emptyList()).map { it.name }
        val pos = att.position ?: 0
        val cleanTitle = caption?.trim()?.takeIf { it.isNotEmpty() } ?: "@$creatorName"
        val isoDate = published?.takeIf { it > 0 }?.let { Instant.ofEpochSecond(it.toLong()).toString() }
        val permalink = "https://cum.st/creators/onlyfans/$creatorId/post/$postId"

        val creator = creatorById[creatorId] ?: creatorByName[creatorName.lowercase()]
        val postIdFull = "${prefix}_${postId}_$pos"
        MediaMetaRegistry.register(
            postId = postIdFull,
            tags = creator?.creatorTags ?: emptyList(),
            creatorName = creatorName,
            gender = creator?.gender
        )

        return if (kind == "video") {
            val file = defaultFilename(att.mime, kind)
            val original = "$MEDIA_CDN/$sk/$file"
            val hdVariant = listOf("1080p", "720p", "480p", "360p").firstOrNull { it in variantNames }
            val sdVariant = listOf("480p", "720p", "360p").firstOrNull { it in variantNames }
            val hdUrl = hdVariant?.let { "$MEDIA_CDN/$sk/$it.mp4" } ?: original
            val sdUrl = sdVariant?.let { "$MEDIA_CDN/$sk/$it.mp4" } ?: original
            Gif(
                id = postIdFull,
                title = cleanTitle,
                author = creatorName,
                subreddit = "onlyfans",
                upvotes = bookmarked,
                duration = att.durationMs?.let { it / 1000.0 },
                width = att.width,
                height = att.height,
                mediaType = "video",
                mediaUrl = sdUrl,
                muxedUrl = sdUrl,
                muxedUrlHd = hdUrl,
                posterUrl = thumbUrl,
                thumbnailUrl = thumbUrl,
                sourceUrl = permalink,
                permalink = permalink,
                createdUtc = isoDate
            )
        } else {
            val file = defaultFilename(att.mime, kind)
            val orig = "$MEDIA_CDN/$sk/$file"
            Gif(
                id = postIdFull,
                title = cleanTitle,
                author = creatorName,
                subreddit = "onlyfans",
                upvotes = bookmarked,
                width = att.width,
                height = att.height,
                mediaType = if (kind == "gif") "gif" else "image",
                mediaUrl = orig,
                posterUrl = thumbUrl,
                thumbnailUrl = thumbUrl,
                sourceUrl = permalink,
                permalink = permalink,
                createdUtc = isoDate
            )
        }
    }

    private fun mapPosts(posts: List<OFPost>, prefix: String = "of"): List<Gif> {
        val out = mutableListOf<Gif>()
        for (p in posts) {
            val cid = p.creatorId ?: continue
            val cname = p.creatorName ?: cid
            for (att in p.attachments ?: emptyList()) {
                mapAttachmentToGif(
                    att = att,
                    postId = p.id,
                    creatorId = cid,
                    creatorName = cname,
                    caption = p.caption ?: p.title,
                    bookmarked = p.bookmarkedCount,
                    published = p.publishedAt,
                    prefix = prefix
                )?.let { out.add(it) }
            }
        }
        return out
    }

    suspend fun fetchForYou(after: String? = null): GoonedFeedResponse {
        val offset = after?.toIntOrNull() ?: 0
        val params = withHiddenGenders(
            mapOf("service" to "onlyfans", "sort" to "popular", "n" to "35", "offset" to "$offset")
        )
        return try {
            val resp: OFFeedResponse = get("/posts", params)
            val gifs = mapPosts(resp.posts)
            GoonedFeedResponse(gifs, "${offset + 35}")
        } catch (_: Throwable) {
            GoonedFeedResponse()
        }
    }

    suspend fun fetchTrending(after: String? = null): GoonedFeedResponse {
        val offset = after?.toIntOrNull() ?: 0
        val params = withHiddenGenders(
            mapOf("service" to "onlyfans", "sort" to "trending", "since" to utcDateString(14), "n" to "35", "offset" to "$offset")
        )
        return try {
            val resp: OFFeedResponse = get("/posts", params)
            GoonedFeedResponse(mapPosts(resp.posts), "${offset + 35}")
        } catch (_: Throwable) {
            GoonedFeedResponse()
        }
    }

    suspend fun fetchLatest(after: String? = null): GoonedFeedResponse {
        val offset = after?.toIntOrNull() ?: 0
        val params = withHiddenGenders(
            mapOf("service" to "onlyfans", "sort" to "newest", "n" to "35", "offset" to "$offset")
        )
        return try {
            val resp: OFFeedResponse = get("/posts", params)
            GoonedFeedResponse(mapPosts(resp.posts), "${offset + 35}")
        } catch (_: Throwable) {
            GoonedFeedResponse()
        }
    }

    suspend fun fetchDMs(after: String? = null): GoonedFeedResponse {
        val offset = after?.toIntOrNull() ?: 0
        val params = withHiddenGenders(
            mapOf("service" to "onlyfans", "kind" to "dm", "n" to "35", "offset" to "$offset")
        )
        return try {
            val resp: OFFeedResponse = get("/posts", params)
            GoonedFeedResponse(mapPosts(resp.posts), "${offset + 35}")
        } catch (_: Throwable) {
            GoonedFeedResponse()
        }
    }

    suspend fun fetchCreatorPosts(creatorId: String, handle: String, after: String? = null): GoonedFeedResponse {
        val offset = after?.toIntOrNull() ?: 0
        return try {
            val resp: OFFeedResponse = get("/creators/onlyfans/$creatorId/posts", mapOf("n" to "35", "offset" to "$offset"))
            val gifs = mapPosts(resp.posts)
            GoonedFeedResponse(gifs, if (gifs.isEmpty()) null else "${offset + 35}")
        } catch (_: Throwable) {
            GoonedFeedResponse()
        }
    }

    suspend fun searchPosts(query: String, after: String? = null): GoonedFeedResponse {
        val offset = after?.toIntOrNull() ?: 0
        val params = withHiddenGenders(
            mapOf("service" to "onlyfans", "q" to query, "n" to "35", "offset" to "$offset")
        )
        return try {
            val resp: OFFeedResponse = get("/posts", params)
            val gifs = mapPosts(resp.posts)
            GoonedFeedResponse(gifs, if (gifs.isEmpty()) null else "${offset + 35}")
        } catch (_: Throwable) {
            GoonedFeedResponse()
        }
    }

    suspend fun fetchTopCreators(limit: Int = 25): List<OFCreator> {
        if (cachedTopCreators.isNotEmpty()) return cachedTopCreators.take(limit)
        return try {
            val resp: OFCreatorsResponse = get("/creators", withHiddenGenders(mapOf("service" to "onlyfans", "sort" to "popular", "n" to "$limit")))
            cacheCreators(resp.creators)
            cachedTopCreators = resp.creators
            resp.creators
        } catch (_: Throwable) {
            emptyList()
        }
    }

    suspend fun searchCreators(query: String, limit: Int = 20): List<OFCreator> {
        val clean = query.trim().removePrefix("@")
        if (clean.isEmpty()) return fetchTopCreators(limit)
        return try {
            val resp: OFCreatorsResponse = get("/creators", withHiddenGenders(mapOf("service" to "onlyfans", "q" to clean, "n" to "$limit")))
            cacheCreators(resp.creators)
            resp.creators
        } catch (_: Throwable) {
            emptyList()
        }
    }
}
