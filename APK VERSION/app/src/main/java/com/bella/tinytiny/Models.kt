package com.bella.tinytiny

import kotlinx.serialization.Serializable
import java.util.concurrent.ConcurrentHashMap

@Serializable
data class Gif(
    val id: String,
    val title: String? = null,
    val author: String? = null,
    val subreddit: String? = null,
    val upvotes: Int? = null,
    val duration: Double? = null,
    val width: Int? = null,
    val height: Int? = null,
    val mediaType: String? = null,
    val mediaUrl: String? = null,
    val muxedUrl: String? = null,
    val muxedUrlHd: String? = null,
    val hlsUrl: String? = null,
    val posterUrl: String? = null,
    val thumbnailUrl: String? = null,
    val sourceUrl: String? = null,
    val permalink: String? = null,
    val createdUtc: Double? = null
) {
    val isImage: Boolean
        get() {
            if (mediaType == "image") return true
            val u = (muxedUrlHd ?: muxedUrl ?: mediaUrl ?: "").lowercase()
            return (u.endsWith(".jpg") || u.endsWith(".jpeg") || u.endsWith(".png") || u.endsWith(".webp") || u.endsWith(".gif")) &&
                hlsUrl.isNullOrBlank() && muxedUrl.isNullOrBlank() && muxedUrlHd.isNullOrBlank()
        }

    val isXPost: Boolean get() = id.startsWith("x_")
    val isIGPost: Boolean get() = id.startsWith("ig_")
    val isRule34Post: Boolean get() = id.startsWith("r34_")
    val isOnlyFansPost: Boolean get() = id.startsWith("of_")
    val isLongVideoPost: Boolean get() = id.startsWith("lv_")

    val longVideoSiteLabel: String?
        get() = when {
            id.startsWith("lv_ep_") -> "EPORNER"
            id.startsWith("lv_xv_") -> "XVIDEOS"
            id.startsWith("lv_ph_") -> "PORNHUB"
            id.startsWith("lv_xh_") -> "XHAMSTER"
            id.startsWith("lv_sb_") -> "SPANKBANG"
            else -> if (isLongVideoPost) "LONG" else null
        }

    val onlyFansCreatorId: String?
        get() = MediaMetaRegistry.creatorId(id)

    val hasPlayableMedia: Boolean
        get() = !videoURL(hd = false).isNullOrBlank() || !imageURL.isNullOrBlank()

    fun videoURL(hd: Boolean): String? {
        if (isImage) return null
        val candidates = if (hd) {
            listOf(muxedUrlHd, muxedUrl, hlsUrl, mediaUrl)
        } else {
            listOf(muxedUrl, hlsUrl, muxedUrlHd, mediaUrl)
        }
        return candidates.firstOrNull { !it.isNullOrBlank() && (it.startsWith("http://") || it.startsWith("https://")) }
    }

    fun fallbackVideoURLs(hd: Boolean): List<String> {
        val raw = if (hd) {
            listOf(muxedUrlHd, muxedUrl, hlsUrl, mediaUrl)
        } else {
            listOf(muxedUrl, hlsUrl, muxedUrlHd, mediaUrl)
        }
        val extra = MediaMetaRegistry.extraVideoURLs(id)
        return (raw.filterNotNull() + extra)
            .filter { it.startsWith("http://") || it.startsWith("https://") }
            .distinct()
    }

    val imageURL: String?
        get() {
            val u = muxedUrlHd ?: muxedUrl ?: mediaUrl ?: posterUrl ?: thumbnailUrl
            return if (!u.isNullOrBlank() && (u.startsWith("http://") || u.startsWith("https://"))) u else null
        }

    val posterOrThumb: String?
        get() = listOf(posterUrl, thumbnailUrl, imageURL).firstOrNull { !it.isNullOrBlank() }

    val webURL: String
        get() = permalink?.takeIf { it.startsWith("http") }
            ?: sourceUrl?.takeIf { it.startsWith("http") }
            ?: "https://www.reddit.com"

    val canonicalDedupeKey: String
        get() {
            val raw = (videoURL(false) ?: imageURL ?: id).lowercase()
            return raw.substringBefore("?")
        }

    val contentSimilarityKey: String?
        get() {
            val fp = MediaMetaRegistry.fingerprint(id)
            if (!fp.isNullOrBlank()) return "fp:$fp"
            val t = title?.trim()?.lowercase()?.replace(Regex("[^a-z0-9]"), "") ?: ""
            return if (t.length >= 10) "t:${t.take(36)}" else null
        }
}

@Serializable
data class GoonedCategory(
    val name: String,
    val count: Int? = null
)

enum class FeedSort(val rawValue: String, val label: String) {
    HOT("hot", "Hot"),
    TOP("top", "Top"),
    NEW("new", "New")
}

enum class LongVideoSite(val rawValue: String, val label: String) {
    ALL("all", "All"),
    EPORNER("eporner", "Eporner"),
    XVIDEOS("xvideos", "XVideos"),
    PORNHUB("pornhub", "Pornhub"),
    XHAMSTER("xhamster", "xHamster"),
    SPANKBANG("spankbang", "SpankBang")
}

sealed class FeedSource {
    data object ForYou : FeedSource()
    data object Following : FeedSource()
    data object XForYou : FeedSource()
    data object XFollowing : FeedSource()
    data object XBookmarks : FeedSource()
    data class XUser(val username: String) : FeedSource()
    data object IGReels : FeedSource()
    data object IGFollowing : FeedSource()
    data object IGSaved : FeedSource()
    data class IGUser(val username: String) : FeedSource()
    data object OFForYou : FeedSource()
    data object OFTrending : FeedSource()
    data object OFLatest : FeedSource()
    data object OFDMs : FeedSource()
    data class OFCreator(val id: String, val handle: String, val displayName: String) : FeedSource()
    data class Rule34(val tag: String) : FeedSource()
    data class LongVideos(val site: LongVideoSite) : FeedSource()
    data class LongSearch(val site: LongVideoSite, val query: String) : FeedSource()
    data class Subreddit(val name: String) : FeedSource()
    data class User(val name: String) : FeedSource()
    data class Category(val name: String) : FeedSource()
    data class MultiSearch(val query: String) : FeedSource()
    data class CustomList(val title: String, val items: List<Gif>) : FeedSource()

    val isXFeed: Boolean get() = this is XForYou || this is XFollowing || this is XBookmarks || this is XUser
    val isIGFeed: Boolean get() = this is IGReels || this is IGFollowing || this is IGSaved || this is IGUser
    val isOFFeed: Boolean get() = this is OFForYou || this is OFTrending || this is OFLatest || this is OFDMs || this is OFCreator
    val isLongFeed: Boolean get() = this is LongVideos || this is LongSearch

    val displayTitle: String
        get() = when (this) {
            is ForYou -> "For You"
            is Following -> "Following"
            is XForYou -> "𝕏 For You"
            is XFollowing -> "𝕏 Following"
            is XBookmarks -> "𝕏 Bookmarks"
            is XUser -> "@$username"
            is IGReels -> "IG Reels"
            is IGFollowing -> "IG Following"
            is IGSaved -> "IG Saved"
            is IGUser -> "@$username"
            is OFForYou -> "OF For You"
            is OFTrending -> "OF Trending"
            is OFLatest -> "OF Latest"
            is OFDMs -> "OF DMs"
            is OFCreator -> displayName.ifBlank { "@$handle" }
            is Rule34 -> if (tag.isBlank()) "Rule34" else "#$tag"
            is LongVideos -> site.label
            is LongSearch -> "${site.label}: $query"
            is Subreddit -> "/r/$name"
            is User -> "u/$name"
            is Category -> name
            is MultiSearch -> "Search: $query"
            is CustomList -> title
        }

    val swipeKey: String
        get() = when (this) {
            is ForYou -> "core:foryou"
            is Following -> "core:following"
            is XForYou -> "x:foryou"
            is XFollowing -> "x:following"
            is XBookmarks -> "x:bookmarks"
            is XUser -> "x:user:$username"
            is IGReels -> "ig:reels"
            is IGFollowing -> "ig:following"
            is IGSaved -> "ig:saved"
            is IGUser -> "ig:user:$username"
            is OFForYou -> "of:foryou"
            is OFTrending -> "of:trending"
            is OFLatest -> "of:latest"
            is OFDMs -> "of:dms"
            is OFCreator -> "of:creator:$id"
            is Rule34 -> "r34:$tag"
            is LongVideos -> "long:${site.rawValue}"
            is LongSearch -> "longq:${site.rawValue}:$query"
            is Subreddit -> "sub:$name"
            is User -> "user:$name"
            is Category -> "cat:$name"
            is MultiSearch -> "multi:$query"
            is CustomList -> "list:$title"
        }
}

data class GoonedFeedResponse(
    val posts: List<Gif>,
    val after: String? = null
)

object MediaMetaRegistry {
    private val tagsMap = ConcurrentHashMap<String, List<String>>()
    private val extraUrlsMap = ConcurrentHashMap<String, List<String>>()
    private val fingerprintMap = ConcurrentHashMap<String, String>()
    private val genderMap = ConcurrentHashMap<String, String>()
    private val creatorIdMap = ConcurrentHashMap<String, String>()
    private val creatorNameMap = ConcurrentHashMap<String, String>()
    private val followedMap = ConcurrentHashMap<String, Boolean>()

    private val stopTags = setOf(
        "onlyfans", "of", "fansly", "nsfw", "porn", "video", "videos", "clip", "clips",
        "reel", "reels", "fyp", "foryou", "trending", "viral", "leak", "leaks",
        "hd", "4k", "60fps", "mp4", "gif", "image", "photo", "pic", "pics",
        "twitter", "x", "instagram", "ig", "reddit", "rule34", "r34", "xxx",
        "eporner", "pornhub", "xhamster", "spankbang", "xvideos", "cumst", "gooned"
    )

    fun isStopTag(tag: String): Boolean {
        val clean = tag.trim().lowercase().removePrefix("#")
        return clean.length < 2 || stopTags.contains(clean)
    }

    fun register(
        postId: String,
        fingerprint: String? = null,
        extraVideoURLs: List<String> = emptyList(),
        tags: List<String> = emptyList(),
        creatorGender: String? = null,
        creatorId: String? = null,
        creatorName: String? = null,
        followedByViewer: Boolean? = null
    ) {
        if (!fingerprint.isNullOrBlank()) fingerprintMap[postId] = fingerprint
        if (extraVideoURLs.isNotEmpty()) extraUrlsMap[postId] = extraVideoURLs
        val cleanTags = tags.map { it.trim().lowercase().removePrefix("#") }.filter { !isStopTag(it) }.distinct()
        if (cleanTags.isNotEmpty()) tagsMap[postId] = cleanTags
        if (!creatorGender.isNullOrBlank()) genderMap[postId] = creatorGender.lowercase()
        if (!creatorId.isNullOrBlank()) creatorIdMap[postId] = creatorId
        if (!creatorName.isNullOrBlank()) creatorNameMap[postId] = creatorName
        if (followedByViewer != null) followedMap[postId] = followedByViewer
    }

    fun tags(postId: String): List<String> = tagsMap[postId] ?: emptyList()
    fun extraVideoURLs(postId: String): List<String> = extraUrlsMap[postId] ?: emptyList()
    fun fingerprint(postId: String): String? = fingerprintMap[postId]
    fun creatorGender(postId: String): String? = genderMap[postId]
    fun creatorId(postId: String): String? = creatorIdMap[postId]
    fun creatorName(postId: String): String? = creatorNameMap[postId]
    fun isFollowedByViewer(postId: String): Boolean? = followedMap[postId]
}
