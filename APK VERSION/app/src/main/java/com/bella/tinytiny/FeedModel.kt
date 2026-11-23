package com.bella.tinytiny

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

enum class FeedSort(val rawValue: String, val label: String) {
    HOT("hot", "Hot"),
    TOP("top", "Top"),
    NEW("new", "New")
}

sealed class FeedSource {
    data object ForYou : FeedSource()
    data object Following : FeedSource()
    data class Category(val name: String) : FeedSource()
    data class Subreddit(val name: String) : FeedSource()
    data class User(val name: String) : FeedSource()
    data object XForYou : FeedSource()
    data object XFollowing : FeedSource()
    data object XBookmarks : FeedSource()
    data object XLikes : FeedSource()
    data class XSearch(val query: String) : FeedSource()
    data class XUser(val handle: String) : FeedSource()
    data object IGReels : FeedSource()
    data object IGFollowing : FeedSource()
    data object IGSaved : FeedSource()
    data class IGUser(val handle: String) : FeedSource()
    data class Rule34(val tag: String = "") : FeedSource()
    data object OFForYou : FeedSource()
    data object OFTrending : FeedSource()
    data object OFLatest : FeedSource()
    data object OFDMs : FeedSource()
    data class OFCreator(val id: String, val handle: String, val displayName: String? = null) : FeedSource()
    data class OFSearch(val query: String) : FeedSource()
    data class LongVideos(val site: LongVideoSite) : FeedSource()
    data class LongSearch(val site: LongVideoSite, val query: String) : FeedSource()
    data class MultiSearch(val query: String) : FeedSource()
    data class CustomList(val title: String) : FeedSource()

    val isList: Boolean get() = this is CustomList
    val isXFeed: Boolean get() = this is XForYou || this is XFollowing || this is XBookmarks || this is XLikes || this is XSearch || this is XUser
    val isIGFeed: Boolean get() = this is IGReels || this is IGFollowing || this is IGSaved || this is IGUser
    val isRule34Feed: Boolean get() = this is Rule34
    val isOFFeed: Boolean get() = this is OFForYou || this is OFTrending || this is OFLatest || this is OFDMs || this is OFCreator || this is OFSearch
    val isLongVideoFeed: Boolean get() = this is LongVideos || this is LongSearch

    val displayTitle: String
        get() = when (this) {
            is ForYou -> "For You"
            is Following -> "Following"
            is Category -> if (name == "BigTits") "Big Tits" else if (name == "Rule34") "Rule 34" else name
            is Subreddit -> "r/$name"
            is User -> "u/$name"
            is XForYou -> "𝕏 For You"
            is XFollowing -> "𝕏 Following"
            is XBookmarks -> "𝕏 Bookmarks"
            is XLikes -> "𝕏 Likes"
            is XSearch -> "𝕏: $query"
            is XUser -> "@${handle.removePrefix("@")}"
            is IGReels -> "IG Reels"
            is IGFollowing -> "IG Following"
            is IGSaved -> "IG Saved"
            is IGUser -> "IG @${handle.removePrefix("@")}"
            is Rule34 -> {
                val trimmed = tag.trim()
                if (trimmed.isEmpty()) "Rule34.xxx"
                else {
                    val parts = trimmed.split(Regex("\\s+"))
                    val userPart = parts.firstOrNull { it.lowercase().startsWith("user:") }
                    if (userPart != null) {
                        val artist = userPart.drop(5)
                        val extra = parts.filterNot { it.lowercase().startsWith("user:") }.joinToString(" ")
                        if (extra.isEmpty()) "R34 @$artist" else "@$artist · $extra"
                    } else {
                        "R34: $trimmed"
                    }
                }
            }
            is OFForYou -> "OF For You"
            is OFTrending -> "OF Trending"
            is OFLatest -> "OF Latest"
            is OFDMs -> "OF DMs"
            is OFCreator -> displayName?.takeIf { it.isNotEmpty() } ?: "@$handle"
            is OFSearch -> "OF: $query"
            is LongVideos -> site.displayTitle
            is LongSearch -> "${site.displayTitle}: $query"
            is MultiSearch -> "Search: $query"
            is CustomList -> title
        }

    val swipeKey: Pair<String, String>
        get() = when (this) {
            is ForYou -> "foryou" to "foryou"
            is Following -> "following" to "following"
            is Category -> "category" to name
            is Subreddit -> "subreddit" to name
            is User -> "user" to name
            is XForYou -> "xforyou" to "xforyou"
            is XFollowing -> "xfollowing" to "xfollowing"
            is XBookmarks -> "xbookmarks" to "xbookmarks"
            is XLikes -> "xlikes" to "xlikes"
            is XSearch -> "xsearch" to query
            is XUser -> "xuser" to handle
            is IGReels -> "igreels" to "igreels"
            is IGFollowing -> "igfollowing" to "igfollowing"
            is IGSaved -> "igsaved" to "igsaved"
            is IGUser -> "iguser" to handle
            is Rule34 -> "rule34" to tag.ifEmpty { "all" }
            is OFForYou -> "offoryou" to "offoryou"
            is OFTrending -> "oftrending" to "oftrending"
            is OFLatest -> "oflatest" to "oflatest"
            is OFDMs -> "ofdms" to "ofdms"
            is OFCreator -> "ofcreator" to id
            is OFSearch -> "ofsearch" to query
            is LongVideos -> "long" to site.rawValue
            is LongSearch -> "longsearch" to "${site.rawValue}:$query"
            is MultiSearch -> "multisearch" to query
            is CustomList -> "list" to title
        }
}

class FeedModel(
    initialSource: FeedSource,
    initialItems: List<Gif> = emptyList()
) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    val source = MutableStateFlow(initialSource)
    val sort = MutableStateFlow(FeedSort.HOT)
    val items = MutableStateFlow<List<Gif>>(initialItems)
    val isLoading = MutableStateFlow(false)
    val errorText = MutableStateFlow<String?>(null)

    private var afterCursor: String? = null
    private var mixOfCursor: String? = null
    private var mixR34Cursor: String? = null
    private var mixXCursor: String? = null
    private var mixIGCursor: String? = null
    private var hasMore = initialSource !is FeedSource.CustomList
    private val ids = mutableSetOf<String>()
    private val mediaKeys = mutableSetOf<String>()
    private val seenSimKeys = mutableSetOf<String>()
    private var activeJob: Job? = null

    val currentCursor: String? get() = afterCursor
    val canLoadMore: Boolean get() = source.value !is FeedSource.CustomList && hasMore

    init {
        if (initialItems.isNotEmpty()) {
            ids.addAll(initialItems.map { it.id })
            mediaKeys.addAll(initialItems.map { it.canonicalDedupeKey })
        } else if (!initialSource.isList) {
            val key = cursorKey(initialSource, sort.value)
            scope.launch {
                val cached = loadDiskCache(key)
                if (items.value.isEmpty() && cached.isNotEmpty()) {
                    val keepSeen = isProfileOrSearch(initialSource)
                    val filtered = cached.filter { keepSeen || !UserStore.shared.isSeen(it) }
                    if (filtered.isNotEmpty()) {
                        items.value = filtered
                        ids.addAll(filtered.map { it.id })
                        mediaKeys.addAll(filtered.map { it.canonicalDedupeKey })
                    }
                }
            }
        }
    }

    private fun cursorKey(src: FeedSource, s: FeedSort): String {
        val (k, n) = src.swipeKey
        return "$k:${n.lowercase()}:${s.rawValue}"
    }

    private fun isProfileOrSearch(src: FeedSource): Boolean = when (src) {
        is FeedSource.XUser, is FeedSource.XSearch, is FeedSource.XBookmarks, is FeedSource.XLikes,
        is FeedSource.IGUser, is FeedSource.IGSaved, is FeedSource.OFCreator, is FeedSource.OFSearch,
        is FeedSource.User, is FeedSource.Subreddit, is FeedSource.LongSearch, is FeedSource.MultiSearch -> true
        is FeedSource.Rule34 -> src.tag.trim().isNotEmpty()
        else -> false
    }

    fun switchSource(
        newSource: FeedSource,
        initialItems: List<Gif> = emptyList(),
        cursor: String? = null,
        allowLoadMore: Boolean = true
    ) {
        activeJob?.cancel()
        source.value = newSource
        ids.clear()
        mediaKeys.clear()
        seenSimKeys.clear()
        mixOfCursor = null
        mixR34Cursor = null
        mixXCursor = null
        mixIGCursor = null
        errorText.value = null
        if (initialItems.isNotEmpty()) {
            items.value = initialItems
            ids.addAll(initialItems.map { it.id })
            mediaKeys.addAll(initialItems.map { it.canonicalDedupeKey })
            hasMore = allowLoadMore && newSource !is FeedSource.CustomList
            afterCursor = cursor
            isLoading.value = false
        } else {
            items.value = emptyList()
            hasMore = newSource !is FeedSource.CustomList
            afterCursor = UserStore.shared.savedCursor(cursorKey(newSource, sort.value))
            activeJob = scope.launch { refresh(keepSavedCursor = true) }
        }
    }

    fun setSort(newSort: FeedSort) {
        if (sort.value == newSort) return
        sort.value = newSort
        activeJob?.cancel()
        activeJob = scope.launch { refresh(keepSavedCursor = false) }
    }

    fun shuffleItems() {
        val cur = items.value
        if (cur.size > 2) {
            val unseen = cur.filter { !UserStore.shared.isSeen(it) }.shuffled()
            items.value = if (unseen.isNotEmpty()) unseen else cur.shuffled()
        }
        scope.launch { loadMore() }
    }

    fun removeDisliked(gif: Gif) {
        val cur = items.value
        val curIdx = cur.indexOfFirst { it.id == gif.id }
        val cats = UserStore.shared.categories.value
        val engine = SmartTasteEngine.shared
        val next = cur.mapIndexedNotNull { idx, item ->
            if (item.id == gif.id) null
            else if (curIdx >= 0 && idx > curIdx && engine.isSuppressedInDiscovery(item, cats)) null
            else item
        }
        items.value = if (curIdx >= 0 && curIdx < next.size) {
            val head = next.subList(0, curIdx)
            val tail = UserStore.shared.rankWithAlgorithm(next.subList(curIdx, next.size))
            head + tail
        } else next
    }

    fun onItemAppear(gif: Gif) {
        val list = items.value
        val idx = list.indexOfFirst { it.id == gif.id }
        if (idx >= 0) {
            // Prefetch upcoming thumbnails/images with MediaHeaders
            val ctx = TinyTinyApplication.instance
            val loader = coil.Coil.imageLoader(ctx)
            for (nextIdx in (idx + 1)..minOf(list.lastIndex, idx + 3)) {
                val u = list[nextIdx].imageURL ?: list[nextIdx].posterURL ?: continue
                val rb = coil.request.ImageRequest.Builder(ctx).data(u)
                for ((k, v) in MediaHeaders.headers(u)) rb.addHeader(k, v)
                loader.enqueue(rb.build())
            }
            if (list.size - idx <= 10 && canLoadMore && !isLoading.value) {
                scope.launch { loadMore() }
            }
        }
    }

    suspend fun refresh(rotateCursor: Boolean = false, keepSavedCursor: Boolean = false) {
        if (source.value is FeedSource.CustomList) return
        ids.clear()
        mediaKeys.clear()
        seenSimKeys.clear()
        mixOfCursor = null
        mixR34Cursor = null
        mixXCursor = null
        mixIGCursor = null
        items.value = emptyList()
        hasMore = true
        afterCursor = when {
            rotateCursor && source.value is FeedSource.ForYou -> GoonedAPI.randomForYouCursor(0)
            keepSavedCursor -> UserStore.shared.savedCursor(cursorKey(source.value, sort.value))
            else -> null
        }
        loadMore()
    }

    suspend fun loadMore() {
        if (isLoading.value || !canLoadMore) return
        isLoading.value = true
        errorText.value = null
        val src = source.value
        val curSort = sort.value
        val profileOrSearch = isProfileOrSearch(src)

        try {
            var added = 0
            var attempts = 0
            val fallbackSeen = mutableListOf<Gif>()
            while (added < 8 && attempts < 3 && hasMore) {
                attempts++
                val resp = fetchPage(src, curSort, afterCursor)
                afterCursor = resp.after
                if (!resp.after.isNullOrEmpty()) {
                    UserStore.shared.saveCursor(resp.after, cursorKey(src, curSort))
                } else if (!profileOrSearch && src !is FeedSource.ForYou) {
                    hasMore = false
                }

                val playable = resp.posts.filter { it.hasPlayableMedia }
                val batch = mutableListOf<Gif>()
                for (post in playable) {
                    if (!ids.add(post.id)) continue
                    if (!mediaKeys.add(post.canonicalDedupeKey)) continue
                    val sim = post.contentSimilarityKey
                    if (sim != null && !seenSimKeys.add(sim)) continue
                    if (!profileOrSearch && UserStore.shared.isSeen(post)) {
                        fallbackSeen.add(post)
                    } else {
                        batch.add(post)
                    }
                }
                val ranked = when (src) {
                    is FeedSource.ForYou, is FeedSource.XForYou, is FeedSource.IGReels,
                    is FeedSource.Category, is FeedSource.Rule34, is FeedSource.OFForYou,
                    is FeedSource.OFTrending, is FeedSource.OFLatest, is FeedSource.OFDMs,
                    is FeedSource.LongVideos -> UserStore.shared.rankWithAlgorithm(batch)
                    else -> batch
                }
                if (ranked.isNotEmpty()) {
                    items.value = items.value + ranked
                    added += ranked.size
                    saveDiskCache(items.value.takeLast(20), cursorKey(src, curSort))
                }
                if (resp.after.isNullOrEmpty()) break
            }

            if (items.value.isEmpty() && fallbackSeen.isNotEmpty() && (profileOrSearch || src is FeedSource.Following)) {
                items.value = fallbackSeen.shuffled()
            }

            if (items.value.isEmpty()) {
                errorText.value = when {
                    src.isXFeed && !UserStore.shared.data.value.xSession.isConnected -> "Connect your personal 𝕏 account to load 𝕏 videos."
                    src.isIGFeed && !UserStore.shared.data.value.igSession.isConnected -> "Connect your personal Instagram account to load IG Reels."
                    else -> {
                        LicenseManager.reportError(src.displayTitle, "Empty feed load")
                        "Couldn't load ${src.displayTitle} yet. Tap Retry."
                    }
                }
            }
        } catch (e: Throwable) {
            if (items.value.isEmpty()) {
                errorText.value = e.localizedMessage ?: "Couldn't load ${src.displayTitle}."
            }
        } finally {
            isLoading.value = false
        }
    }

    private suspend fun fetchPage(src: FeedSource, s: FeedSort, cursor: String?): GoonedFeedResponse = when (src) {
        is FeedSource.ForYou -> fetchMixedForYou(s, cursor)
        is FeedSource.Following -> {
            val d = UserStore.shared.data.value
            GoonedAPI.following(d.followedSubreddits, d.followedUsers, cursor)
        }
        is FeedSource.Category -> GoonedAPI.category(src.name, s.rawValue, after = cursor)
        is FeedSource.Subreddit -> GoonedAPI.subreddit(src.name, s.rawValue, after = cursor)
        is FeedSource.User -> GoonedAPI.user(src.name, s.rawValue, after = cursor)
        is FeedSource.XForYou -> XAPI.forYou(cursor)
        is FeedSource.XFollowing -> XAPI.following(cursor)
        is FeedSource.XBookmarks -> XAPI.bookmarks(cursor)
        is FeedSource.XLikes -> XAPI.likes(cursor)
        is FeedSource.XSearch -> XAPI.search(src.query, cursor)
        is FeedSource.XUser -> XAPI.userTweets(src.handle, cursor)
        is FeedSource.IGReels -> InstagramAPI.reelsFeed(cursor)
        is FeedSource.IGFollowing -> InstagramAPI.followingFeed(cursor)
        is FeedSource.IGSaved -> InstagramAPI.savedFeed(cursor)
        is FeedSource.IGUser -> InstagramAPI.userReels(src.handle, cursor)
        is FeedSource.Rule34 -> Rule34API.fetchFeed(src.tag, s.rawValue, cursor, UserStore.shared.data.value.r34Credentials)
        is FeedSource.OFForYou -> OnlyFansAPI.fetchForYou(cursor)
        is FeedSource.OFTrending -> OnlyFansAPI.fetchTrending(cursor)
        is FeedSource.OFLatest -> OnlyFansAPI.fetchLatest(cursor)
        is FeedSource.OFDMs -> OnlyFansAPI.fetchDMs(cursor)
        is FeedSource.OFCreator -> OnlyFansAPI.fetchCreatorPosts(src.id, src.handle, cursor)
        is FeedSource.OFSearch -> OnlyFansAPI.searchPosts(src.query, cursor)
        is FeedSource.LongVideos -> LongVideoAPI.fetchFeed(src.site, s.rawValue, null, cursor)
        is FeedSource.LongSearch -> LongVideoAPI.fetchFeed(src.site, s.rawValue, src.query, cursor)
        is FeedSource.MultiSearch -> fetchMultiSearch(src.query, s, cursor)
        is FeedSource.CustomList -> GoonedFeedResponse()
    }

    private suspend fun fetchMultiSearch(query: String, s: FeedSort, cursor: String?): GoonedFeedResponse = coroutineScope {
        val d = UserStore.shared.data.value
        val ofDef = async { try { OnlyFansAPI.searchPosts(query, cursor) } catch (_: Throwable) { null } }
        val r34Def = async { try { Rule34API.fetchFeed(Rule34API.parseTags(query).joinToString(" "), s.rawValue, cursor, d.r34Credentials) } catch (_: Throwable) { null } }
        val eromeDef = async { try { LongVideoAPI.fetchFeed(LongVideoSite.EROME, s.rawValue, query, cursor) } catch (_: Throwable) { null } }
        val longDef = async { try { LongVideoAPI.fetchFeed(LongVideoSite.ALL, s.rawValue, query, cursor) } catch (_: Throwable) { null } }
        val xDef = if (d.xSession.isConnected) async { try { XAPI.search(query, cursor) } catch (_: Throwable) { null } } else null
        val pools = listOfNotNull(
            ofDef.await()?.posts,
            eromeDef.await()?.posts,
            r34Def.await()?.posts,
            longDef.await()?.posts,
            xDef?.await()?.posts
        ).filter { it.isNotEmpty() }
        val mixed = mutableListOf<Gif>()
        val maxLen = pools.maxOfOrNull { it.size } ?: 0
        for (i in 0 until maxLen) {
            for (p in pools) if (i < p.size) mixed.add(p[i])
        }
        val nextPage = (cursor?.toIntOrNull() ?: 1) + 1
        GoonedFeedResponse(mixed, if (mixed.isEmpty()) null else "$nextPage")
    }

    private suspend fun fetchMixedForYou(s: FeedSort, cursor: String?): GoonedFeedResponse = coroutineScope {
        val fy = SmartTasteEngine.shared.state.value.forYouSources
        val d = UserStore.shared.data.value
        val rDef = if (fy.enableReddit) async { try { GoonedAPI.forYou(s.rawValue, after = cursor) } catch (_: Throwable) { null } } else null
        val ofDef = if (fy.enableOnlyFans) async { try { OnlyFansAPI.fetchForYou(mixOfCursor) } catch (_: Throwable) { null } } else null
        val r34Def = if (fy.enableRule34) async { try { Rule34API.fetchFeed(null, s.rawValue, mixR34Cursor, d.r34Credentials) } catch (_: Throwable) { null } } else null
        val xDef = if (fy.enableX && d.xSession.isConnected) async { try { XAPI.forYou(mixXCursor) } catch (_: Throwable) { null } } else null
        val igDef = if (fy.enableIG && d.igSession.isConnected) async { try { InstagramAPI.reelsFeed(mixIGCursor) } catch (_: Throwable) { null } } else null

        val rResp = rDef?.await()
        val ofResp = ofDef?.await()
        val r34Resp = r34Def?.await()
        val xResp = xDef?.await()
        val igResp = igDef?.await()

        ofResp?.after?.let { mixOfCursor = it }
        r34Resp?.after?.let { mixR34Cursor = it }
        xResp?.after?.let { mixXCursor = it }
        igResp?.after?.let { mixIGCursor = it }

        val pools = listOfNotNull(
            rResp?.posts,
            ofResp?.posts,
            r34Resp?.posts,
            xResp?.posts,
            igResp?.posts
        ).filter { it.isNotEmpty() }

        val mixed = mutableListOf<Gif>()
        val maxLen = pools.maxOfOrNull { it.size } ?: 0
        for (i in 0 until maxLen) {
            for (p in pools) if (i < p.size) mixed.add(p[i])
        }
        GoonedFeedResponse(mixed, rResp?.after ?: GoonedAPI.randomForYouCursor(25))
    }

    private suspend fun loadDiskCache(key: String): List<Gif> = withContext(Dispatchers.IO) {
        val dir = File(TinyTinyApplication.instance.cacheDir, "FeedDiskCache")
        val f = File(dir, key.replace(Regex("[^A-Za-z0-9._-]"), "_") + ".json")
        if (!f.exists()) return@withContext emptyList()
        CryptoBox.openCodable<List<Gif>>(f.readBytes()) ?: emptyList()
    }

    private fun saveDiskCache(posts: List<Gif>, key: String) {
        scope.launch(Dispatchers.IO) {
            val dir = File(TinyTinyApplication.instance.cacheDir, "FeedDiskCache").apply { mkdirs() }
            val f = File(dir, key.replace(Regex("[^A-Za-z0-9._-]"), "_") + ".json")
            CryptoBox.sealCodable(posts)?.let { f.writeBytes(it) }
        }
    }
}
