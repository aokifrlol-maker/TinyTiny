package com.bella.tinytiny

import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.JsonNames
import java.net.URI
import java.time.Instant
import java.time.OffsetDateTime
import java.util.concurrent.ConcurrentHashMap
import kotlin.math.roundToInt

object Config {
    const val userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    const val goonedBase = "https://api.gooned.app"
    const val onlyHavenBase = "https://cum.st/api/v1"
    const val origin = "https://gooned.app"
    const val referer = "https://gooned.app/"
}

/**
 * Lossy list serializer matching iOS `Lossy<T>` — drops any single malformed item
 * instead of failing the entire feed/search response.
 */
class LossyListSerializer<T>(private val elementSerializer: KSerializer<T>) : KSerializer<List<T>> {
    private val listSerializer = ListSerializer(elementSerializer)
    override val descriptor: SerialDescriptor = listSerializer.descriptor

    override fun serialize(encoder: Encoder, value: List<T>) {
        listSerializer.serialize(encoder, value)
    }

    override fun deserialize(decoder: Decoder): List<T> {
        val jsonDecoder = decoder as? JsonDecoder ?: return listSerializer.deserialize(decoder)
        val el = jsonDecoder.decodeJsonElement()
        val arr = el as? JsonArray ?: return emptyList()
        val out = ArrayList<T>(arr.size)
        for (item in arr) {
            try {
                out.add(jsonDecoder.json.decodeFromJsonElement(elementSerializer, item))
            } catch (_: Throwable) {
                // Skip malformed element
            }
        }
        return out
    }
}

@Serializable
data class Gif(
    val id: String,
    var title: String? = null,
    var author: String? = null,
    var subreddit: String? = null,
    var upvotes: Int? = null,
    var duration: Double? = null,
    var width: Int? = null,
    var height: Int? = null,
    var mediaType: String? = null,
    var mediaUrl: String? = null,
    var muxedUrl: String? = null,
    var muxedUrlHd: String? = null,
    var hlsUrl: String? = null,
    var posterUrl: String? = null,
    var thumbnailUrl: String? = null,
    var sourceUrl: String? = null,
    var permalink: String? = null,
    var createdUtc: String? = null
) {
    override fun equals(other: Any?): Boolean = (other as? Gif)?.id == id
    override fun hashCode(): Int = id.hashCode()

    val isXPost: Boolean
        get() = id.startsWith("x_") || (sourceUrl?.contains("x.com") == true) || (permalink?.contains("x.com") == true)

    val isIGPost: Boolean
        get() = id.startsWith("ig_") || (sourceUrl?.contains("instagram.com") == true) || (permalink?.contains("instagram.com") == true)

    val isRule34Post: Boolean
        get() = id.startsWith("r34") || (subreddit?.lowercase()?.contains("rule34") == true) || (sourceUrl?.contains("rule34.xxx") == true)

    val isOnlyFansPost: Boolean
        get() = id.startsWith("of_") || id.startsWith("ofdm_") || (sourceUrl?.contains("cum.st") == true) || (permalink?.contains("cum.st") == true)

    val isLongVideoPost: Boolean
        get() = id.startsWith("lv_")

    val longVideoSiteLabel: String?
        get() = when {
            !isLongVideoPost -> null
            id.startsWith("lv_ep_") -> "Eporner"
            id.startsWith("lv_xv_") -> "XVideos"
            id.startsWith("lv_ph_") -> "Pornhub"
            id.startsWith("lv_xh_") -> "xHamster"
            id.startsWith("lv_sb_") -> "SpankBang"
            id.startsWith("lv_er_") -> "Erome"
            else -> subreddit
        }

    val onlyFansCreatorId: String?
        get() {
            if (!isOnlyFansPost) return null
            MediaMetaRegistry.creatorId(id)?.let { return it }
            val candidate = permalink ?: sourceUrl ?: return null
            val parts = try { URI(candidate).path?.split("/")?.filter { it.isNotEmpty() } ?: emptyList() } catch (_: Throwable) { emptyList() }
            val idx = parts.indexOf("onlyfans")
            if (idx >= 0 && idx + 1 < parts.size) {
                val cid = parts[idx + 1]
                if (cid.isNotEmpty() && cid != "post" && cid != "user") return cid
                if (cid == "user" && idx + 2 < parts.size) return parts[idx + 2]
            }
            return null
        }

    val isImage: Boolean
        get() {
            if (mediaType == "image") return true
            if (isLongVideoPost) return false
            return remoteOrLocalVideoURLs(hd = true).isEmpty()
        }

    val hasPlayableMedia: Boolean
        get() = isLongVideoPost || remoteOrLocalVideoURLs(hd = true).isNotEmpty() || imageURL != null

    val knownAspect: Double?
        get() {
            val w = width ?: return null
            val h = height ?: return null
            return if (w > 0 && h > 0) w.toDouble() / h.toDouble() else null
        }

    val aspect: Double get() = knownAspect ?: 1.0

    val webURL: String
        get() = permalink?.takeIf { it.startsWith("http") }
            ?: sourceUrl?.takeIf { it.startsWith("http") }
            ?: "https://gooned.app"

    val canonicalDedupeKey: String
        get() {
            if (isIGPost) {
                if (!permalink.isNullOrEmpty()) {
                    try {
                        val code = URI(permalink).path?.split("/")?.lastOrNull { it.isNotEmpty() && it != "reel" && it != "p" }
                        if (!code.isNullOrEmpty() && code.length >= 5) return "ig_code_$code"
                    } catch (_: Throwable) {}
                }
                val raw = id.removePrefix("ig_")
                val base = raw.substringBefore("_")
                return "ig_pk_$base"
            }
            MediaMetaRegistry.canonicalMediaFingerprint(this)?.let { return it }
            val media = muxedUrlHd ?: muxedUrl ?: mediaUrl ?: posterUrl
            if (!media.isNullOrEmpty()) {
                try {
                    val u = URI(media)
                    val host = u.host
                    if (!host.isNullOrEmpty()) {
                        val norm = normalizedMediaDedupeKey(host, u.path ?: "")
                        if (norm.isNotEmpty()) return norm
                    }
                } catch (_: Throwable) {}
            }
            val poster = posterUrl ?: thumbnailUrl
            if (!poster.isNullOrEmpty()) {
                try {
                    val u = URI(poster)
                    val host = u.host
                    if (!host.isNullOrEmpty()) {
                        val norm = normalizedMediaDedupeKey(host, u.path ?: "")
                        if (norm.isNotEmpty()) return norm
                    }
                } catch (_: Throwable) {}
            }
            return id.lowercase()
        }

    val contentSimilarityKey: String?
        get() {
            val cleanTitle = (title ?: "")
                .lowercase()
                .replace(Regex("https?://\\S+"), "")
                .replace(Regex("@[A-Za-z0-9_]+"), "")
                .split(Regex("[^\\p{L}\\p{N}]+"))
                .filter { it.isNotEmpty() }
                .joinToString(" ")
            if (cleanTitle.length < 14) return null
            val durBucket = duration?.let { (it * 2.0).roundToInt() } ?: -1
            return "sim_${durBucket}_${cleanTitle.take(80)}"
        }

    fun allVideoURLs(hd: Boolean): List<String> = remoteOrLocalVideoURLs(hd)

    fun videoURL(hd: Boolean): String? = remoteOrLocalVideoURLs(hd).firstOrNull()

    private fun remoteOrLocalVideoURLs(hd: Boolean): List<String> {
        if (mediaType == "image") return emptyList()
        val urls = mutableListOf<String>()
        OfflineManager.localMediaURL(id)?.let { local ->
            val ext = local.substringAfterLast('.', "").lowercase()
            if (ext !in setOf("jpg", "jpeg", "png", "webp", "gif")) {
                urls.add(local)
            }
        }
        val candidates: List<String?> = if ((isXPost || hlsUrl?.contains("v.redd.it") == true) && !hlsUrl.isNullOrEmpty()) {
            if (hd) listOf(hlsUrl, muxedUrlHd, muxedUrl, mediaUrl) else listOf(hlsUrl, muxedUrl, muxedUrlHd, mediaUrl)
        } else {
            if (hd) listOf(muxedUrlHd, muxedUrl, mediaUrl, hlsUrl) else listOf(muxedUrl, muxedUrlHd, mediaUrl, hlsUrl)
        }
        val extra = MediaMetaRegistry.extraVideoURLs(id)
        for (raw in (candidates + extra)) {
            if (!raw.isNullOrEmpty() && isPlayableVideoURLString(raw) && !urls.contains(raw)) {
                urls.add(raw)
            }
        }
        return urls
    }

    val imageFallbackURLs: List<String>
        get() {
            val out = mutableListOf<String>()
            OfflineManager.localMediaURL(id)?.let { local ->
                val ext = local.substringAfterLast('.', "").lowercase()
                if (ext in setOf("jpg", "jpeg", "png", "webp", "gif")) out.add(local)
            }
            for (raw in listOf(mediaUrl, posterUrl, thumbnailUrl)) {
                if (!raw.isNullOrEmpty() && isRenderableImageURLString(raw) && !out.contains(raw)) {
                    out.add(raw)
                }
            }
            return out
        }

    val imageURL: String?
        get() = imageFallbackURLs.firstOrNull()

    val posterFallbackURLs: List<String>
        get() {
            val out = mutableListOf<String>()
            OfflineManager.localThumbURL(id)?.let { out.add(it) }
            for (raw in listOf(posterUrl, thumbnailUrl, mediaUrl)) {
                if (!raw.isNullOrEmpty() && isRenderableImageURLString(raw) && !out.contains(raw)) {
                    out.add(raw)
                }
            }
            return out
        }

    val posterURL: String?
        get() = posterFallbackURLs.firstOrNull()

    // Exact iOS priority: localThumbURL -> posterUrl -> thumbnailUrl -> mediaUrl (prevents blurred Reddit 140px thumbnails)
    val thumbURL: String?
        get() = posterFallbackURLs.firstOrNull()

    val relativeTime: String
        get() {
            val raw = createdUtc ?: return ""
            return try {
                val epochMs = try {
                    Instant.parse(raw).toEpochMilli()
                } catch (_: Throwable) {
                    OffsetDateTime.parse(raw).toInstant().toEpochMilli()
                }
                val sec = kotlin.math.max(0L, (System.currentTimeMillis() - epochMs) / 1000L)
                when {
                    sec < 3600 -> "${kotlin.math.max(1L, sec / 60)}m"
                    sec < 86400 -> "${sec / 3600}h"
                    sec < 2592000 -> "${sec / 86400}d"
                    sec < 31_536_000 -> "${sec / 2592000}mo"
                    else -> "${sec / 31_536_000}y"
                }
            } catch (_: Throwable) {
                ""
            }
        }

    companion object {
        fun isPlayableVideoURLString(s: String): Boolean {
            val lower = s.lowercase()
            val pathPart = lower.substringBefore('?')
            if (pathPart.endsWith(".jpg") || pathPart.endsWith(".jpeg") || pathPart.endsWith(".png") || pathPart.endsWith(".webp") || pathPart.endsWith(".gif")) {
                return false
            }
            if (lower.contains("redgifs.com/watch/") || lower.contains("redgifs.com/ifr/")) return false
            if (lower.contains(".mp4") || lower.contains(".mov") || lower.contains(".m4v") || lower.contains(".m3u8") || lower.contains(".webm")) return true
            return lower.contains("video.twimg.com") || lower.contains("v.redd.it") ||
                lower.contains("cdninstagram.com") || lower.contains("fbcdn.net") ||
                lower.contains("eporner.com") || lower.contains("phncdn.com") ||
                lower.contains("xhcdn.com") || lower.contains("sb-cd.com") || lower.contains("xvideos-cdn.com")
        }

        fun isRenderableImageURLString(s: String): Boolean {
            val lower = s.lowercase()
            if (lower.contains(".mp4") || lower.contains(".mov") || lower.contains(".m4v") || lower.contains(".m3u8") || lower.contains(".webm")) return false
            if (lower.contains("redgifs.com/watch/") || lower.contains("redgifs.com/ifr/")) return false
            return lower.startsWith("http://") || lower.startsWith("https://") || lower.startsWith("file://")
        }

        fun shortCount(n: Int?): String {
            val v = n ?: return "0"
            return when {
                v >= 1_000_000 -> String.format("%.1fM", v / 1_000_000.0)
                v >= 1_000 -> String.format("%.1fK", v / 1_000.0)
                v > 0 -> "$v"
                else -> "0"
            }
        }

        private fun normalizedMediaDedupeKey(host: String, path: String): String {
            val lowerHost = host.lowercase()
            val cleanPath = path.trim('/')
            if (cleanPath.isEmpty()) return ""
            if (lowerHost.contains("twimg.com")) {
                val parts = cleanPath.split("/")
                val tagIdx = parts.indexOfFirst {
                    it in setOf("ext_tw_video", "ext_tw_video_thumb", "amplify_video", "amplify_video_thumb", "tweet_video", "tweet_video_thumb")
                }
                if (tagIdx >= 0 && tagIdx + 1 < parts.size) return "twvid_${parts[tagIdx + 1]}"
            }
            if (lowerHost.contains("v.redd.it")) {
                val seg = cleanPath.substringBefore('/')
                if (seg.isNotEmpty()) return "vredd_${seg.lowercase()}"
            }
            if (lowerHost.contains("redgifs.com")) {
                val last = cleanPath.substringAfterLast('/').lowercase()
                val base = last.substringBeforeLast('.')
                    .replace("-mobile", "").replace("-silent", "").replace("-large", "")
                if (base.isNotEmpty()) return "redgifs_$base"
            }
            val lastSlash = cleanPath.lastIndexOf('/')
            val lastDot = cleanPath.lastIndexOf('.')
            val noExt = if (lastDot > lastSlash) cleanPath.substring(0, lastDot).lowercase() else cleanPath.lowercase()
            return "media_$lowerHost/$noExt"
        }
    }
}

@Serializable
data class GoonedFeedResponse(
    @Serializable(with = LossyListSerializer::class)
    val posts: List<Gif> = emptyList(),
    val after: String? = null
)

@OptIn(ExperimentalSerializationApi::class)
@Serializable
data class GoonedSearchItem(
    val name: String,
    val title: String? = null,
    val subscribers: Int? = null,
    @JsonNames("icon")
    val iconUrl: String? = null
) {
    val id: String get() = name.lowercase()
}

@Serializable
data class GoonedSearchResponse(
    @Serializable(with = LossyListSerializer::class)
    val subreddits: List<GoonedSearchItem> = emptyList(),
    @Serializable(with = LossyListSerializer::class)
    val users: List<GoonedSearchItem> = emptyList()
)

@Serializable
data class GoonedCategoryMeta(
    val subscribers: Int = 0,
    val subreddits: List<String> = emptyList()
)

@Serializable
data class GoonedCategoriesResponse(
    val categories: Map<String, GoonedCategoryMeta> = emptyMap()
)

@Serializable
data class AlbumMediaItem(
    val id: String,
    val url: String,
    val posterUrl: String? = null,
    val isVideo: Boolean
)

object MediaMetaRegistry {
    private val tagsById = ConcurrentHashMap<String, List<String>>()
    private val extraVideoURLsById = ConcurrentHashMap<String, List<String>>()
    private val albumItemsById = ConcurrentHashMap<String, List<AlbumMediaItem>>()
    private val creatorGenderById = ConcurrentHashMap<String, String>()
    private val creatorGenderByKey = ConcurrentHashMap<String, String>()
    private val creatorNameById = ConcurrentHashMap<String, String>()
    private val creatorIdByPost = ConcurrentHashMap<String, String>()
    private val creatorClusterTags = ConcurrentHashMap<String, List<String>>()
    private val viewerFollowsByKey = ConcurrentHashMap<String, Boolean>()
    private val fingerprintsById = ConcurrentHashMap<String, String>()

    // Full 61-tag iOS stopTags parity
    private val stopTags = setOf(
        "onlyfans", "of", "rule34", "r34", "reddit", "x", "twitter", "ig", "instagram",
        "nsfw", "porn", "xxx", "18", "18+", "18plus", "adult", "sex", "video", "videos",
        "gif", "gifs", "image", "post", "fyp", "foryou", "foryoupage", "viral", "trending",
        "new", "free", "ppv", "customs", "linkinbio", "dm", "dms", "announcements", "vip",
        "promo", "subscribe", "sub", "like", "repost", "rt", "hd", "4k", "1080p", "720p",
        "mp4", "explore", "reels", "reel", "shorts", "gooning", "gooned",
        "eporner", "pornhub", "xhamster", "spankbang", "xvideos", "tiktok", "tiktok_nsfw",
        "snapchat", "snapchat_nsfw"
    )

    fun isStopTag(tag: String): Boolean {
        val clean = tag.trim().lowercase().replace("#", "")
        return clean.length < 2 || clean in stopTags
    }

    private fun cleanTagList(raw: List<String>): List<String> =
        raw.map { it.trim().lowercase().replace("#", "") }
            .filter { it.length >= 2 && it !in stopTags }
            .distinct()

    private fun evictIfNeeded() {
        if (tagsById.size > 4000) {
            val drop = tagsById.keys.take(1000)
            for (k in drop) {
                tagsById.remove(k)
                extraVideoURLsById.remove(k)
                albumItemsById.remove(k)
                fingerprintsById.remove(k)
                creatorGenderById.remove(k)
                creatorNameById.remove(k)
                creatorIdByPost.remove(k)
            }
        }
    }

    fun register(
        postId: String,
        tags: List<String> = emptyList(),
        creatorName: String? = null,
        creatorId: String? = null,
        gender: String? = null,
        extraVideoURLs: List<String> = emptyList(),
        albumItems: List<AlbumMediaItem> = emptyList(),
        fingerprint: String? = null,
        followedByViewer: Boolean? = null
    ) {
        evictIfNeeded()
        val cleaned = cleanTagList(tags)
        if (cleaned.isNotEmpty()) {
            val merged = ((tagsById[postId] ?: emptyList()) + cleaned).distinct().take(24)
            tagsById[postId] = merged
        }
        val cleanAuthor = creatorName?.trim()?.lowercase()?.replace("@", "")?.takeIf { it.isNotEmpty() }
        if (cleanAuthor != null) {
            creatorNameById[postId] = creatorName.trim()
            if (cleaned.isNotEmpty()) {
                val prev = creatorClusterTags["n:$cleanAuthor"] ?: emptyList()
                creatorClusterTags["n:$cleanAuthor"] = (prev + cleaned).distinct().take(24)
            }
            if (followedByViewer != null) viewerFollowsByKey["n:$cleanAuthor"] = followedByViewer
        }
        val cleanCid = creatorId?.trim()?.takeIf { it.isNotEmpty() }
        if (cleanCid != null) {
            creatorIdByPost[postId] = cleanCid
            if (cleaned.isNotEmpty()) {
                val prev = creatorClusterTags["id:$cleanCid"] ?: emptyList()
                creatorClusterTags["id:$cleanCid"] = (prev + cleaned).distinct().take(24)
            }
        }
        val cleanGender = gender?.trim()?.lowercase()?.takeIf { it.isNotEmpty() }
        if (cleanGender != null) {
            creatorGenderById[postId] = cleanGender
            if (cleanCid != null) creatorGenderByKey["id:$cleanCid"] = cleanGender
            if (cleanAuthor != null) creatorGenderByKey["n:$cleanAuthor"] = cleanGender
        }
        if (extraVideoURLs.isNotEmpty()) {
            val prev = extraVideoURLsById[postId] ?: emptyList()
            extraVideoURLsById[postId] = (prev + extraVideoURLs).distinct()
        }
        if (albumItems.isNotEmpty()) albumItemsById[postId] = albumItems
        if (!fingerprint.isNullOrEmpty()) fingerprintsById[postId] = fingerprint
        if (followedByViewer != null) viewerFollowsByKey["p:$postId"] = followedByViewer
    }

    fun registerAlbumItems(postId: String, items: List<AlbumMediaItem>) {
        if (items.isNotEmpty()) albumItemsById[postId] = items
    }

    fun registerCreatorGender(
        creatorId: String? = null,
        creatorName: String? = null,
        gender: String? = null,
        tags: List<String> = emptyList()
    ) {
        val cleanGender = gender?.trim()?.lowercase()?.takeIf { it.isNotEmpty() }
        val cleanedTags = cleanTagList(tags)
        val cid = creatorId?.trim()?.takeIf { it.isNotEmpty() }
        val cname = creatorName?.trim()?.lowercase()?.replace("@", "")?.takeIf { it.isNotEmpty() }
        if (cid != null) {
            if (cleanGender != null) creatorGenderByKey["id:$cid"] = cleanGender
            if (cleanedTags.isNotEmpty()) {
                val prev = creatorClusterTags["id:$cid"] ?: emptyList()
                creatorClusterTags["id:$cid"] = (prev + cleanedTags).distinct().take(24)
            }
        }
        if (cname != null) {
            if (cleanGender != null) creatorGenderByKey["n:$cname"] = cleanGender
            if (cleanedTags.isNotEmpty()) {
                val prev = creatorClusterTags["n:$cname"] ?: emptyList()
                creatorClusterTags["n:$cname"] = (prev + cleanedTags).distinct().take(24)
            }
        }
    }

    fun tags(forId: String, author: String? = null): List<String> {
        val out = mutableListOf<String>()
        tagsById[forId]?.let { out.addAll(it) }
        creatorIdByPost[forId]?.let { cid -> creatorClusterTags["id:$cid"]?.let { out.addAll(it) } }
        val cleanAuthor = (author ?: creatorNameById[forId])?.trim()?.lowercase()?.replace("@", "")
        if (!cleanAuthor.isNullOrEmpty()) {
            creatorClusterTags["n:$cleanAuthor"]?.let { out.addAll(it) }
        }
        return out.distinct()
    }

    fun extraVideoURLs(forId: String): List<String> = extraVideoURLsById[forId] ?: emptyList()
    fun albumItems(forId: String): List<AlbumMediaItem> = albumItemsById[forId] ?: emptyList()
    fun creatorId(forId: String): String? = creatorIdByPost[forId]
    fun creatorName(forId: String): String? = creatorNameById[forId]

    fun creatorGender(forId: String, author: String? = null): String? {
        creatorGenderById[forId]?.let { return it }
        creatorIdByPost[forId]?.let { cid -> creatorGenderByKey["id:$cid"]?.let { return it } }
        val cleanAuthor = (author ?: creatorNameById[forId])?.trim()?.lowercase()?.replace("@", "")
        if (!cleanAuthor.isNullOrEmpty()) {
            creatorGenderByKey["n:$cleanAuthor"]?.let { return it }
        }
        return null
    }

    fun isFollowedByViewer(postId: String, author: String? = null): Boolean? {
        viewerFollowsByKey["p:$postId"]?.let { return it }
        val cleanAuthor = (author ?: creatorNameById[postId])?.trim()?.lowercase()?.replace("@", "")
        if (!cleanAuthor.isNullOrEmpty()) {
            viewerFollowsByKey["n:$cleanAuthor"]?.let { return it }
        }
        return null
    }

    fun canonicalMediaFingerprint(gif: Gif): String? {
        fingerprintsById[gif.id]?.let { return it }
        val firstAlbum = albumItemsById[gif.id]?.firstOrNull()?.url ?: return null
        return try {
            val u = URI(firstAlbum)
            "album_${u.host}_${u.path?.substringBeforeLast('.')}"
        } catch (_: Throwable) {
            null
        }
    }
}

object MediaHeaders {
    fun headers(urlString: String, includeReferer: Boolean = true): Map<String, String> {
        val h = mutableMapOf("User-Agent" to Config.userAgent)
        if (!includeReferer) return h
        val host = try { URI(urlString).host?.lowercase() } catch (_: Throwable) { null } ?: urlString.lowercase()
        val referer = when {
            host.contains("cum.st") -> "https://cum.st/"
            host.contains("erome.com") -> "https://www.erome.com/"
            host.contains("yande.re") -> "https://yande.re/"
            host.contains("hypnohub") -> "https://hypnohub.net/"
            host.contains("realbooru") -> "https://realbooru.com/"
            host.contains("gelbooru") -> "https://gelbooru.com/"
            host.contains("rule34") -> "https://rule34.xxx/"
            host.contains("twimg.com") || host.contains("x.com") || host.contains("twitter.com") -> "https://x.com/"
            host.contains("cdninstagram.com") || host.contains("fbcdn.net") || host.contains("instagram.com") -> "https://www.instagram.com/"
            host.contains("eporner") -> "https://www.eporner.com/"
            host.contains("xvideos") -> "https://www.xvideos.com/"
            host.contains("phncdn") || host.contains("pornhub") -> "https://www.pornhub.com/"
            host.contains("xhcdn") || host.contains("xhamster") -> "https://xhamster.com/"
            host.contains("sb-cd") || host.contains("spankbang") -> "https://spankbang.com/"
            host.contains("redgifs.com") -> "https://www.redgifs.com/"
            host.contains("redd.it") || host.contains("reddit.com") || host.contains("redditmedia.com") || host.contains("redditstatic.com") -> "https://www.reddit.com/"
            else -> Config.referer
        }
        h["Referer"] = referer
        return h
    }
}
