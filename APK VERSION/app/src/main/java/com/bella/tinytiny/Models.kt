package com.bella.tinytiny

import kotlinx.serialization.Serializable
import java.net.URI
import java.util.concurrent.ConcurrentHashMap

object Config {
    const val userAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    const val goonedBase = "https://api.gooned.app"
    const val onlyHavenBase = "https://cum.st/api/v1"
    const val origin = "https://gooned.app"
    const val referer = "https://gooned.app/"
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
    val isXPost: Boolean
        get() = id.startsWith("x_") || (sourceUrl?.contains("x.com") == true) || (permalink?.contains("x.com") == true)

    val isIGPost: Boolean
        get() = id.startsWith("ig_") || (sourceUrl?.contains("instagram.com") == true) || (permalink?.contains("instagram.com") == true)

    val isRule34Post: Boolean
        get() = id.startsWith("r34") || (subreddit?.lowercase()?.contains("rule34") == true) || (sourceUrl?.contains("rule34.xxx") == true)

    val isOnlyFansPost: Boolean
        get() = id.startsWith("of_") || (sourceUrl?.contains("cum.st") == true) || (permalink?.contains("cum.st") == true)

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
            val candidate = permalink ?: sourceUrl ?: return null
            val parts = try { URI(candidate).path?.split("/")?.filter { it.isNotEmpty() } ?: emptyList() } catch (_: Throwable) { emptyList() }
            val idx = parts.indexOf("onlyfans")
            if (idx >= 0 && idx + 1 < parts.size) {
                val cid = parts[idx + 1]
                if (cid.isNotEmpty() && cid != "post") return cid
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
                .split(Regex("[^a-z0-9]+"))
                .filter { it.isNotEmpty() }
                .joinToString(" ")
            if (cleanTitle.length < 14) return null
            val durBucket = duration?.let { kotlin.math.round(it * 2.0).toInt() } ?: -1
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
        val candidates: List<String?> = if (isXPost && !hlsUrl.isNullOrEmpty()) {
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

    val imageURL: String?
        get() {
            OfflineManager.localMediaURL(id)?.let { local ->
                val ext = local.substringAfterLast('.', "").lowercase()
                if (ext in setOf("jpg", "jpeg", "png", "webp", "gif")) return local
            }
            for (raw in listOf(mediaUrl, muxedUrlHd, muxedUrl, posterUrl, thumbnailUrl)) {
                if (!raw.isNullOrEmpty() && isRenderableImageURLString(raw)) return raw
            }
            return null
        }

    val imageFallbackURLs: List<String>
        get() = listOfNotNull(mediaUrl, posterUrl, thumbnailUrl).distinct().filter { isRenderableImageURLString(it) }

    val posterURL: String?
        get() = listOfNotNull(posterUrl, thumbnailUrl, if (mediaType == "image") mediaUrl else null)
            .firstOrNull { isRenderableImageURLString(it) }

    val thumbURL: String?
        get() = listOfNotNull(thumbnailUrl, posterUrl, if (mediaType == "image") mediaUrl else null)
            .firstOrNull { isRenderableImageURLString(it) }

    val posterFallbackURLs: List<String>
        get() = listOfNotNull(posterUrl, thumbnailUrl, mediaUrl).distinct().filter { isRenderableImageURLString(it) }

    val relativeTime: String
        get() {
            val raw = createdUtc ?: return ""
            return try {
                val instant = java.time.Instant.parse(raw)
                val sec = kotlin.math.max(0L, (System.currentTimeMillis() - instant.toEpochMilli()) / 1000L)
                when {
                    sec < 60 -> "${sec}s"
                    sec < 3600 -> "${sec / 60}m"
                    sec < 86400 -> "${sec / 3600}h"
                    sec < 2592000 -> "${sec / 86400}d"
                    else -> "${sec / 2592000}mo"
                }
            } catch (_: Throwable) {
                ""
            }
        }

    companion object {
        fun isPlayableVideoURLString(s: String): Boolean {
            val lower = s.lowercase()
            if (lower.endsWith(".jpg") || lower.endsWith(".jpeg") || lower.endsWith(".png") || lower.endsWith(".webp") || lower.endsWith(".gif")) {
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
            val v = n ?: return ""
            return when {
                v >= 1_000_000 -> String.format("%.1fM", v / 1_000_000.0)
                v >= 1_000 -> String.format("%.1fK", v / 1_000.0)
                v > 0 -> "$v"
                else -> ""
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
            val noExt = cleanPath.substringBeforeLast('.').lowercase()
            return "media_$lowerHost/$noExt"
        }
    }
}

@Serializable
data class GoonedFeedResponse(
    val posts: List<Gif> = emptyList(),
    val after: String? = null
)

@Serializable
data class GoonedSearchItem(
    val name: String,
    val title: String? = null,
    val subscribers: Int? = null,
    val icon: String? = null
) {
    val id: String get() = name
}

@Serializable
data class GoonedSearchResponse(
    val subreddits: List<GoonedSearchItem> = emptyList(),
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
    private val creatorNameById = ConcurrentHashMap<String, String>()

    private val stopTags = setOf(
        "onlyfans", "of", "rule34", "r34", "reddit", "x", "twitter", "ig", "instagram",
        "nsfw", "porn", "xxx", "18", "adult", "sex", "video", "gif", "image", "post", "fyp", "foryou"
    )

    fun isStopTag(tag: String): Boolean {
        val clean = tag.trim().lowercase().removePrefix("#")
        return clean.length < 2 || clean in stopTags
    }

    fun register(
        postId: String,
        tags: List<String> = emptyList(),
        creatorName: String? = null,
        gender: String? = null,
        extraVideoURLs: List<String> = emptyList(),
        albumItems: List<AlbumMediaItem> = emptyList()
    ) {
        if (tags.isNotEmpty()) tagsById[postId] = tags
        if (!creatorName.isNullOrEmpty()) creatorNameById[postId] = creatorName
        if (!gender.isNullOrEmpty()) creatorGenderById[postId] = gender.lowercase()
        if (extraVideoURLs.isNotEmpty()) extraVideoURLsById[postId] = extraVideoURLs
        if (albumItems.isNotEmpty()) albumItemsById[postId] = albumItems
    }

    fun tags(forId: String): List<String> = tagsById[forId] ?: emptyList()
    fun extraVideoURLs(forId: String): List<String> = extraVideoURLsById[forId] ?: emptyList()
    fun albumItems(forId: String): List<AlbumMediaItem> = albumItemsById[forId] ?: emptyList()
    fun creatorGender(forId: String): String? = creatorGenderById[forId]
    fun creatorName(forId: String): String? = creatorNameById[forId]

    fun canonicalMediaFingerprint(gif: Gif): String? {
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
        val lower = urlString.lowercase()
        if (includeReferer) {
            when {
                lower.contains("cum.st") -> h["Referer"] = "https://cum.st/"
                lower.contains("erome.com") -> h["Referer"] = "https://www.erome.com/"
                lower.contains("eporner.com") -> h["Referer"] = "https://www.eporner.com/"
                lower.contains("xvideos") -> h["Referer"] = "https://www.xvideos.com/"
                lower.contains("phncdn") || lower.contains("pornhub") -> h["Referer"] = "https://www.pornhub.com/"
                lower.contains("xhcdn") || lower.contains("xhamster") -> h["Referer"] = "https://xhamster.com/"
                lower.contains("sb-cd.com") || lower.contains("spankbang") -> h["Referer"] = "https://spankbang.com/"
                lower.contains("rule34.xxx") -> h["Referer"] = "https://rule34.xxx/"
                lower.contains("twimg.com") -> h["Referer"] = "https://x.com/"
                lower.contains("cdninstagram.com") || lower.contains("fbcdn.net") -> h["Referer"] = "https://www.instagram.com/"
                lower.contains("redgifs.com") -> h["Referer"] = "https://www.redgifs.com/"
            }
        }
        return h
    }
}
