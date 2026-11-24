package com.bella.tinytiny

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import java.io.File
import kotlin.coroutines.coroutineContext
import kotlin.random.Random

// Exact iOS order: HOT, NEW, TOP
enum class FeedSort(val rawValue: String, val label: String) {
    HOT("hot", "Hot"),
    NEW("new", "New"),
    TOP("top", "Top")
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

    val isInfiniteSource: Boolean
        get() = this is ForYou || this is Rule34 || this is LongVideos || this is OFForYou ||
            this is OFTrending || this is OFLatest || this is OFDMs || this is XForYou || this is IGReels

    val isDiscoverySource: Boolean
        get() = when (this) {
            is ForYou, is XForYou, is IGReels, is Category, is Rule34, is OFForYou,
            is OFTrending, is OFLatest, is OFDMs, is LongVideos -> true
            else -> false
        }

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
            is XUser -> "@${handle.replace("@", "")}"
            is IGReels -> "IG Reels"
            is IGFollowing -> "IG Following"
            is IGSaved -> "IG Saved"
            is IGUser -> "IG @${handle.replace("@", "")}"
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
            is OFCreator -> {
                val clean = handle.replace("@", "")
                if (!displayName.isNullOrEmpty()) "$displayName (@$clean)" else "OF @$clean"
            }
            is OFSearch -> "OF: $query"
            is LongVideos -> if (site == LongVideoSite.ALL) "Long Videos" else site.displayTitle
            is LongSearch -> if (site == LongVideoSite.ALL) "Long: $query" else "${site.displayTitle}: $query"
            is MultiSearch -> "Search: $query"
            is CustomList -> title
        }

    // Exact iOS swipeKey parity so savedCursors & recentFeeds work cross-platform!
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
            is OFCreator -> "ofcreator" to "$id|${handle.replace("@", "")}"
            is OFSearch -> "ofsearch" to query
            is LongVideos -> "longvideos" to site.rawValue
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
    val isSwitching = MutableStateFlow(false)
    val errorText = MutableStateFlow<String?>(null)

    private var afterCursor: String? = null
    private var mixOfCursor: String? = null
    private var mixR34Cursor: String? = null
    private var mixXCursor: String? = null
    private var mixIGCursor: String? = null
    private var hasMore = initialSource !is FeedSource.CustomList
    private var emptyPageStreak = 0
    private var lastAppearedIndex = 0
    private var followingRoundRobin = 0
    private val followingCursors = mutableMapOf<String, String>()

    private val ids = mutableSetOf<String>()
    private val mediaKeys = mutableSetOf<String>()
    private val seenSimKeys = mutableSetOf<String>()
    private var activeJob: Job? = null

    val currentCursor: String? get() = afterCursor
    val canLoadMore: Boolean get() = source.value !is FeedSource.CustomList && hasMore

    private fun isAllowedByForYouSources(post: Gif, fy: ForYouSourceSettings): Boolean = when {
        post.isRule34Post -> fy.includeRule34
        post.isOnlyFansPost -> fy.includeOnlyFans
        post.isXPost -> fy.includeX
        post.isIGPost -> fy.includeInstagram
        post.isLongVideoPost -> fy.includeLongVideos
        else -> fy.includeReddit
    }

    init {
        if (initialItems.isNotEmpty()) {
            recordDedupKeys(initialItems)
        } else if (!initialSource.isList) {
            val key = cursorKey(initialSource, sort.value)
            scope.launch {
                val cached = loadDiskCache(key)
                if (items.value.isEmpty() && cached.isNotEmpty()) {
                    val keepSeen = isProfileOrSearch(initialSource)
                    val fy = SmartTasteEngine.shared.state.value.sourceSettings
                    val filtered = cached.filter {
                        (keepSeen || !UserStore.shared.isSeen(it)) &&
                            !UserStore.shared.isBlockedByAlgorithm(it) &&
                            (initialSource !is FeedSource.ForYou || isAllowedByForYouSources(it, fy))
                    }
                    if (filtered.isNotEmpty()) {
                        items.value = filtered
                        recordDedupKeys(filtered)
                    }
                }
            }
        }
        // Live-purge disabled platforms from For You whenever Settings change
        scope.launch {
            SmartTasteEngine.shared.state.collect { taste ->
                if (source.value is FeedSource.ForYou) {
                    val fy = taste.sourceSettings
                    val cur = items.value
                    val filtered = cur.filter { isAllowedByForYouSources(it, fy) }
                    if (filtered.size != cur.size) {
                        items.value = filtered
                    }
                }
            }
        }
    }

    private fun recordDedupKeys(list: List<Gif>) {
        for (g in list) {
            ids.add(g.id)
            mediaKeys.add(g.canonicalDedupeKey)
            g.contentSimilarityKey?.let { seenSimKeys.add(it) }
        }
    }

    private fun cursorKey(src: FeedSource, s: FeedSort): String {
        val (k, n) = src.swipeKey
        return "$k:${n.lowercase()}:${s.rawValue}"
    }

    private fun isProfileOrSearch(src: FeedSource): Boolean = when (src) {
        is FeedSource.XUser, is FeedSource.XSearch, is FeedSource.XBookmarks, is FeedSource.XLikes,
        is FeedSource.IGUser, is FeedSource.IGSaved, is FeedSource.OFCreator, is FeedSource.OFSearch,
        is FeedSource.User, is FeedSource.Subreddit, is FeedSource.LongSearch -> true
        is FeedSource.Rule34 -> src.tag.trim().isNotEmpty()
        else -> false
    }

    fun switchSource(
        newSource: FeedSource,
        initialItems: List<Gif> = emptyList(),
        cursor: String? = null,
        allowLoadMore: Boolean = false
    ) {
        if (source.value == newSource && initialItems.isEmpty() && items.value.isNotEmpty()) {
            activeJob?.cancel()
            isLoading.value = false
            activeJob = scope.launch { refresh(rotateCursor = true, keepSavedCursor = false) }
            return
        }
        activeJob?.cancel()
        isLoading.value = false // CRITICAL FIX: prevent stale isLoading=true from aborting refresh()
        isSwitching.value = true
        source.value = newSource
        ids.clear()
        mediaKeys.clear()
        seenSimKeys.clear()
        emptyPageStreak = 0
        mixOfCursor = null
        mixR34Cursor = null
        mixXCursor = null
        mixIGCursor = null
        errorText.value = null
        if (initialItems.isNotEmpty()) {
            items.value = initialItems
            recordDedupKeys(initialItems)
            hasMore = allowLoadMore && newSource !is FeedSource.CustomList
            afterCursor = cursor
            isSwitching.value = false
        } else {
            items.value = emptyList()
            hasMore = newSource !is FeedSource.CustomList
            afterCursor = UserStore.shared.savedCursor(cursorKey(newSource, sort.value))
            activeJob = scope.launch {
                try {
                    refresh(keepSavedCursor = true)
                } finally {
                    isSwitching.value = false
                }
            }
        }
    }

    fun setSort(newSort: FeedSort) {
        if (sort.value == newSort) return
        sort.value = newSort
        activeJob?.cancel()
        isLoading.value = false // CRITICAL FIX
        activeJob = scope.launch { refresh(keepSavedCursor = true) }
    }

    fun shuffleItems() {
        val cur = items.value
        if (cur.size > 2) {
            val unseen = cur.filter { !UserStore.shared.isSeen(it) }.shuffled()
            items.value = if (unseen.isNotEmpty()) unseen else cur.shuffled()
        }
        scope.launch { loadMore() }
    }

    fun removeDisliked(gif: Gif, purgeUpcomingOF: Boolean = false) {
        val cur = items.value
        val curIdx = cur.indexOfFirst { it.id == gif.id }
        val dedupe = gif.canonicalDedupeKey
        val sim = gif.contentSimilarityKey
        ids.add(gif.id)
        mediaKeys.add(dedupe)
        if (sim != null) seenSimKeys.add(sim)

        val next = cur.mapIndexedNotNull { idx, item ->
            if (item.id == gif.id || item.canonicalDedupeKey == dedupe || (sim != null && item.contentSimilarityKey == sim)) null
            else if (curIdx >= 0 && idx > curIdx && UserStore.shared.isBlockedByAlgorithm(item)) null
            else if (purgeUpcomingOF && curIdx >= 0 && idx > curIdx && item.isOnlyFansPost) null
            else item
        }
        items.value = if (curIdx >= 0 && curIdx < next.size) {
            val head = next.subList(0, curIdx)
            val tail = UserStore.shared.rankWithAlgorithm(next.subList(curIdx, next.size))
            head + tail
        } else next
    }

    fun refreshTailForUpdatedTaste(currentID: String? = null) {
        val cur = items.value
        if (cur.size < 3) return
        val idx = currentID?.let { id -> cur.indexOfFirst { it.id == id } } ?: lastAppearedIndex
        val split = (idx + 1).coerceIn(1, cur.size)
        val head = cur.subList(0, split)
        val tail = UserStore.shared.rankWithAlgorithm(cur.subList(split, cur.size))
        items.value = head + tail
    }

    fun purgeSuppressedItems(afterCurrentID: String? = null, purgeUpcomingOF: Boolean = false) {
        val cur = items.value
        if (cur.isEmpty()) return
        val idx = afterCurrentID?.let { id -> cur.indexOfFirst { it.id == id } } ?: lastAppearedIndex
        val next = cur.mapIndexedNotNull { i, item ->
            if (i <= idx) item
            else if (UserStore.shared.isBlockedByAlgorithm(item)) null
            else if (purgeUpcomingOF && item.isOnlyFansPost) null
            else item
        }
        if (next.size != cur.size) items.value = next
    }

    fun onItemAppear(gif: Gif) {
        val list = items.value
        val idx = list.indexOfFirst { it.id == gif.id }
        if (idx >= 0) {
            lastAppearedIndex = idx
            val ctx = TinyTinyApplication.instance
            val loader = coil.Coil.imageLoader(ctx)
            for (nextIdx in (idx + 1)..minOf(list.lastIndex, idx + 5)) {
                val u = list[nextIdx].posterURL ?: list[nextIdx].imageURL ?: continue
                val rb = coil.request.ImageRequest.Builder(ctx).data(u)
                for ((k, v) in MediaHeaders.headers(u)) rb.addHeader(k, v)
                loader.enqueue(rb.build())
            }
            // Pre-resolve next 3 long video URLs in background
            for (nextIdx in (idx + 1)..minOf(list.lastIndex, idx + 3)) {
                val nextItem = list[nextIdx]
                if (nextItem.isLongVideoPost) {
                    scope.launch(Dispatchers.IO) {
                        try { LongVideoAPI.resolvePlayableURLs(nextItem) } catch (_: Throwable) {}
                    }
                }
            }
            prefetchIfNeeded(idx, list.size)
        }
    }

    fun prefetchIfNeeded(idx: Int = lastAppearedIndex, total: Int = items.value.size) {
        if ((total < 24 || total - idx <= 20) && canLoadMore && !isLoading.value) {
            scope.launch { loadMore() }
        }
    }

    suspend fun refresh(rotateCursor: Boolean = false, keepSavedCursor: Boolean = false) {
        if (source.value is FeedSource.CustomList) return
        ids.clear()
        mediaKeys.clear()
        seenSimKeys.clear()
        emptyPageStreak = 0
        mixOfCursor = null
        mixR34Cursor = null
        mixXCursor = null
        mixIGCursor = null
        errorText.value = null
        items.value = emptyList()
        hasMore = true
        afterCursor = when {
            rotateCursor && source.value is FeedSource.ForYou -> GoonedAPI.randomForYouCursor(Random.nextInt(0, 7) * 25)
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
        val maxAttempts = if (profileOrSearch || src is FeedSource.Following) 2 else 3

        try {
            var added = 0
            var attempts = 0
            val fallbackSeen = mutableListOf<Gif>()
            while (added < 8 && attempts < maxAttempts && hasMore) {
                coroutineContext.ensureActive()
                if (src.isXFeed && XWebEngine.isRateLimitedNow) break
                attempts++

                val resp = fetchPage(src, curSort, afterCursor)
                coroutineContext.ensureActive()
                afterCursor = resp.after
                UserStore.shared.saveCursor(resp.after, cursorKey(src, curSort))

                val playable = resp.posts.filter { post ->
                    post.hasPlayableMedia &&
                        !SmartTasteEngine.shared.isDisliked(post) &&
                        !(src.isDiscoverySource && UserStore.shared.isBlockedByAlgorithm(post)) &&
                        (profileOrSearch || UserStore.shared.isEligibleAdultPost(post, src))
                }

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

                val ranked = if (src.isDiscoverySource) {
                    SmartTasteEngine.shared.precomputeVisualSimilarity(batch)
                    UserStore.shared.rankWithAlgorithm(batch)
                } else batch
                if (ranked.isNotEmpty()) {
                    emptyPageStreak = 0
                    items.value = items.value + ranked
                    added += ranked.size
                    saveDiskCache(items.value.takeLast(18), cursorKey(src, curSort))
                    if (src.isXFeed || src.isIGFeed) break
                } else {
                    emptyPageStreak++
                    // Infinite cursor rotation & dry-streak fallbacks (exact iOS parity)
                    if (src is FeedSource.ForYou) {
                        afterCursor = GoonedAPI.randomForYouCursor(Random.nextInt(0, 13) * 25)
                    } else if (src is FeedSource.Rule34) {
                        val nextPage = (afterCursor?.toIntOrNull() ?: 0) + 1
                        afterCursor = "$nextPage"
                    } else if (src is FeedSource.LongVideos) {
                        val nextPage = (afterCursor?.toIntOrNull() ?: 1) + 1
                        afterCursor = "$nextPage"
                    } else if (src is FeedSource.XForYou && emptyPageStreak >= 2 && !XWebEngine.isRateLimitedNow) {
                        val fallbackTag = UserStore.shared.data.value.algorithm.boostedTags.firstOrNull() ?: "nsfw"
                        val extra = try { XAPI.search("nsfw $fallbackTag", "hot", null).posts } catch (_: Throwable) { emptyList() }
                        if (extra.isNotEmpty()) {
                            items.value = items.value + UserStore.shared.rankWithAlgorithm(extra.filter { ids.add(it.id) })
                            added += extra.size
                            break
                        }
                    } else if (src is FeedSource.IGReels && emptyPageStreak >= 2) {
                        val extra = try { InstagramAPI.reelsFeed(null).posts } catch (_: Throwable) { emptyList() }
                        if (extra.isNotEmpty()) {
                            items.value = items.value + UserStore.shared.rankWithAlgorithm(extra.filter { ids.add(it.id) })
                            added += extra.size
                            break
                        }
                    } else if (resp.after.isNullOrEmpty() && !src.isInfiniteSource) {
                        hasMore = false
                        break
                    }
                }
            }

            if (items.value.isEmpty() && fallbackSeen.isNotEmpty() && !src.isXFeed && !src.isIGFeed) {
                items.value = fallbackSeen.shuffled()
            }

            if (items.value.isEmpty()) {
                errorText.value = when {
                    src.isXFeed && !UserStore.shared.data.value.xSession.isConnected -> "Connect your personal 𝕏 account to load 𝕏 videos."
                    src.isXFeed && XWebEngine.isRateLimitedNow -> "𝕏 temporarily rate-limited. Wait ~45 seconds and tap Retry."
                    src.isIGFeed && !UserStore.shared.data.value.igSession.isConnected -> "Connect your personal Instagram account to load IG Reels."
                    src is FeedSource.Following -> "Follow creators, subreddits, or connect 𝕏/IG to build your Following feed."
                    else -> {
                        LicenseManager.reportError(src.displayTitle, "Empty feed load")
                        "Couldn't load ${src.displayTitle} yet. Tap Retry."
                    }
                }
            } else if ((items.value.size < 16 && emptyPageStreak == 0) || (lastAppearedIndex >= items.value.size - 6 && emptyPageStreak < 4)) {
                // Auto-prefetch continuation matching iOS
                scope.launch {
                    delay(280)
                    if (!isLoading.value && canLoadMore) loadMore()
                }
            }
        } catch (e: CancellationException) {
            throw e // CRITICAL FIX: never swallow CancellationException!
        } catch (e: Throwable) {
            if (items.value.isEmpty()) {
                errorText.value = e.localizedMessage ?: "Couldn't load ${src.displayTitle}."
            }
        } finally {
            isLoading.value = false
        }
    }

    private suspend fun fetchPage(src: FeedSource, s: FeedSort, cursor: String?): GoonedFeedResponse = when (src) {
        is FeedSource.ForYou -> fetchBalancedForYou(s, cursor)
        is FeedSource.Following -> fetchMultiFollowing()
        is FeedSource.Category -> {
            val seenTail = UserStore.shared.exportSnapshotForBackup().seenIDs.takeLast(120)
            val primary = GoonedAPI.category(src.name, s.rawValue, after = cursor, excludedHead = seenTail, limit = 25)
            if (primary.posts.isNotEmpty()) primary
            else {
                val cat = UserStore.shared.categories.value.firstOrNull { it.name.equals(src.name, ignoreCase = true) }
                val randSub = cat?.subreddits?.randomOrNull()
                if (randSub != null) GoonedAPI.subreddit(randSub, s.rawValue, after = null, limit = 25) else primary
            }
        }
        is FeedSource.Subreddit -> GoonedAPI.subreddit(src.name, s.rawValue, after = cursor)
        is FeedSource.User -> GoonedAPI.user(src.name, s.rawValue, after = cursor)
        is FeedSource.XForYou -> XAPI.forYou(cursor)
        is FeedSource.XFollowing -> XAPI.following(cursor)
        is FeedSource.XBookmarks -> XAPI.bookmarks(cursor)
        is FeedSource.XLikes -> XAPI.likes(cursor)
        is FeedSource.XSearch -> XAPI.search(src.query, s.rawValue, cursor)
        is FeedSource.XUser -> XAPI.userTweets(src.handle, cursor)
        is FeedSource.IGReels -> InstagramAPI.reelsFeed(cursor)
        is FeedSource.IGFollowing -> InstagramAPI.followingFeed(cursor)
        is FeedSource.IGSaved -> InstagramAPI.savedFeed(cursor)
        is FeedSource.IGUser -> InstagramAPI.userReels(src.handle, cursor)
        is FeedSource.Rule34 -> Rule34API.fetchFeed(src.tag, s.rawValue, cursor, UserStore.shared.data.value.r34Credentials)
        is FeedSource.OFForYou -> {
            val algo = UserStore.shared.data.value.algorithm
            val seeds = SmartTasteEngine.shared.topOnlyFansSeedHandles(8)
            val tags = SmartTasteEngine.shared.activeQueryTags(algo.boostedTags, algo.blockedTags, 6)
            OnlyFansAPI.fetchForYou(cursor, seedCreatorIds = seeds, tasteTags = tags)
        }
        is FeedSource.OFTrending -> OnlyFansAPI.fetchTrending(cursor)
        is FeedSource.OFLatest -> OnlyFansAPI.fetchLatest(cursor)
        is FeedSource.OFDMs -> OnlyFansAPI.fetchDMs(cursor)
        is FeedSource.OFCreator -> OnlyFansAPI.fetchCreatorPosts(src.id, src.handle, s.rawValue, cursor)
        is FeedSource.OFSearch -> OnlyFansAPI.searchPosts(src.query, cursor)
        is FeedSource.LongVideos -> LongVideoAPI.fetchFeed(src.site, s.rawValue, null, cursor)
        is FeedSource.LongSearch -> LongVideoAPI.fetchFeed(src.site, s.rawValue, src.query, cursor)
        is FeedSource.MultiSearch -> fetchMultiSearch(src.query, s, cursor)
        is FeedSource.CustomList -> GoonedFeedResponse()
    }

    // Multi-source Following feed matching iOS (Reddit + X + IG + OnlyFans)
    private suspend fun fetchMultiFollowing(): GoonedFeedResponse = coroutineScope {
        val d = UserStore.shared.data.value
        val pools = mutableListOf<String>()
        if (d.followedSubreddits.isNotEmpty() || d.followedUsers.isNotEmpty()) pools.add("reddit")
        if (d.xSession.isConnected) pools.add("x_following")
        if (d.igSession.isConnected) pools.add("ig_following")
        if (d.followedOFCreators.isNotEmpty()) pools.add("of")
        if (d.followedXUsers.isNotEmpty() && d.xSession.isConnected) pools.add("x_users")
        if (d.followedIGUsers.isNotEmpty() && d.igSession.isConnected) pools.add("ig_users")
        if (pools.isEmpty()) return@coroutineScope GoonedFeedResponse()

        val picks = (0 until minOf(2, pools.size)).map { i -> pools[(followingRoundRobin + i) % pools.size] }
        followingRoundRobin = (followingRoundRobin + picks.size) % pools.size

        val tasks = picks.map { pool ->
            async {
                val cur = followingCursors[pool]
                try {
                    val resp = when (pool) {
                        "reddit" -> GoonedAPI.following(d.followedSubreddits, d.followedUsers, cur)
                        "x_following" -> XAPI.following(cur)
                        "ig_following" -> InstagramAPI.followingFeed(cur)
                        "of" -> {
                            val c = d.followedOFCreators[followingRoundRobin % d.followedOFCreators.size]
                            OnlyFansAPI.fetchCreatorPosts(c.id, c.handle, "hot", cur)
                        }
                        "x_users" -> {
                            val u = d.followedXUsers[followingRoundRobin % d.followedXUsers.size]
                            XAPI.userTweets(u, cur)
                        }
                        "ig_users" -> {
                            val u = d.followedIGUsers[followingRoundRobin % d.followedIGUsers.size]
                            InstagramAPI.userReels(u, cur)
                        }
                        else -> GoonedFeedResponse()
                    }
                    resp.after?.let { followingCursors[pool] = it }
                    resp.posts
                } catch (_: Throwable) {
                    emptyList()
                }
            }
        }
        val buckets = tasks.map { it.await() }.filter { it.isNotEmpty() }
        val out = mutableListOf<Gif>()
        val maxLen = buckets.maxOfOrNull { it.size } ?: 0
        for (i in 0 until maxLen) {
            for (b in buckets) if (i < b.size) out.add(b[i])
        }
        GoonedFeedResponse(out, if (out.isEmpty()) null else "fol_$followingRoundRobin")
    }

    // MultiSearch with 3.5s per-source timeouts, Reddit search, relevance ranking & [x, of, r34, reddit, long] interleave
    private suspend fun fetchMultiSearch(query: String, s: FeedSort, cursor: String?): GoonedFeedResponse = coroutineScope {
        val pageNum = maxOf(1, cursor?.toIntOrNull() ?: 1)
        val d = UserStore.shared.data.value
        val r34Tag = query.trim().lowercase().replace(Regex("\\s+"), "_")

        val xDef: kotlinx.coroutines.Deferred<List<Gif>>? = if (d.xSession.isConnected) async {
            withTimeoutOrNull(3500L) { try { XAPI.search(query, s.rawValue, if (pageNum == 1) null else "$pageNum").posts } catch (_: Throwable) { emptyList() } } ?: emptyList()
        } else null
        val ofDef = async {
            withTimeoutOrNull(3500L) { try { OnlyFansAPI.searchPosts(query, "${(pageNum - 1) * 20}").posts } catch (_: Throwable) { emptyList() } } ?: emptyList()
        }
        val r34Def = async {
            withTimeoutOrNull(3500L) { try { Rule34API.fetchFeed(r34Tag, s.rawValue, "${pageNum - 1}", d.r34Credentials).posts } catch (_: Throwable) { emptyList() } } ?: emptyList()
        }
        val redditDef = async {
            withTimeoutOrNull(3500L) {
                try {
                    val sr = GoonedAPI.search(query)
                    val topSub = sr.subreddits.firstOrNull()?.name
                    if (!topSub.isNullOrEmpty()) GoonedAPI.subreddit(topSub, s.rawValue, limit = 20).posts
                    else GoonedAPI.category(query, s.rawValue, limit = 20).posts
                } catch (_: Throwable) { emptyList() }
            } ?: emptyList()
        }
        val longDef = async {
            withTimeoutOrNull(3500L) { try { LongVideoAPI.fetchFeed(LongVideoSite.ALL, s.rawValue, query, "$pageNum").posts } catch (_: Throwable) { emptyList() } } ?: emptyList()
        }

        val qLower = query.trim().lowercase()
        val tokens = qLower.split(Regex("\\s+")).filter { it.length >= 2 }
        fun rankBucket(list: List<Gif>): List<Gif> {
            return list.mapNotNull { post ->
                if (UserStore.shared.isBlockedByAlgorithm(post)) return@mapNotNull null
                val hay = "${post.title ?: ""} ${post.author ?: ""} ${post.subreddit ?: ""}".lowercase()
                var sc = UserStore.shared.scorePost(post) * 0.25
                if (hay.contains(qLower)) sc += 12.0
                for (tok in tokens) if (hay.contains(tok)) sc += 4.5
                post to sc
            }.sortedByDescending { it.second }.map { it.first }
        }

        val buckets = listOf(
            rankBucket(xDef?.await() ?: emptyList()),
            rankBucket(ofDef.await()),
            rankBucket(r34Def.await()),
            rankBucket(redditDef.await()),
            rankBucket(longDef.await())
        ).filter { it.isNotEmpty() }

        val mixed = mutableListOf<Gif>()
        val maxLen = buckets.maxOfOrNull { it.size } ?: 0
        for (i in 0 until maxLen) {
            for (b in buckets) if (i < b.size) mixed.add(b[i])
        }
        GoonedFeedResponse(mixed, if (mixed.isEmpty()) null else "${pageNum + 1}")
    }

    // Balanced For You with Deficit Round-Robin (DRR), redditTasteTask, and strict sourceSettings enforcement
    private suspend fun fetchBalancedForYou(s: FeedSort, cursor: String?): GoonedFeedResponse = coroutineScope {
        val tasteState = SmartTasteEngine.shared.state.value
        val fy = tasteState.sourceSettings
        val d = UserStore.shared.data.value
        val algo = d.algorithm

        val rDef: kotlinx.coroutines.Deferred<GoonedFeedResponse?>? = if (fy.includeReddit) async { try { GoonedAPI.forYou(s.rawValue, after = cursor) } catch (_: Throwable) { null } } else null
        val rTasteDef: kotlinx.coroutines.Deferred<List<Gif>>? = if (fy.includeReddit) async {
            val topSub = UserStore.shared.topAlgorithmSubreddits(4).randomOrNull()
            if (topSub != null) try { GoonedAPI.subreddit(topSub, s.rawValue, limit = 15).posts } catch (_: Throwable) { emptyList() }
            else emptyList()
        } else null
        val ofDef: kotlinx.coroutines.Deferred<GoonedFeedResponse?>? = if (fy.includeOnlyFans) async {
            val seeds = SmartTasteEngine.shared.topOnlyFansSeedHandles(6)
            val tags = SmartTasteEngine.shared.activeQueryTags(algo.boostedTags, algo.blockedTags, 6)
            try { OnlyFansAPI.fetchForYou(mixOfCursor, seedCreatorIds = seeds, tasteTags = tags) } catch (_: Throwable) { null }
        } else null
        val r34Def: kotlinx.coroutines.Deferred<GoonedFeedResponse?>? = if (fy.includeRule34) async { try { Rule34API.fetchFeed(null, s.rawValue, mixR34Cursor, d.r34Credentials) } catch (_: Throwable) { null } } else null
        val xDef: kotlinx.coroutines.Deferred<GoonedFeedResponse?>? = if (fy.includeX && d.xSession.isConnected && d.xSession.mixIntoForYou) async {
            try { XAPI.forYou(mixXCursor) } catch (_: Throwable) { null }
        } else null
        val igDef: kotlinx.coroutines.Deferred<GoonedFeedResponse?>? = if (fy.includeInstagram && d.igSession.isConnected && d.igSession.mixIntoForYou) async {
            try { InstagramAPI.reelsFeed(mixIGCursor) } catch (_: Throwable) { null }
        } else null

        val rResp = rDef?.await()
        val rTaste = rTasteDef?.await() ?: emptyList()
        val ofResp = ofDef?.await()
        val r34Resp = r34Def?.await()
        val xResp = xDef?.await()
        val igResp = igDef?.await()

        ofResp?.after?.let { mixOfCursor = it }
        r34Resp?.after?.let { mixR34Cursor = it }
        xResp?.after?.let { mixXCursor = it }
        igResp?.after?.let { mixIGCursor = it }

        fun prepBucket(list: List<Gif>?): MutableList<Gif> =
            (list ?: emptyList())
                .filter { !UserStore.shared.isBlockedByAlgorithm(it) }
                .sortedByDescending { UserStore.shared.scorePost(it) }
                .toMutableList()

        val redditBucket = prepBucket(((rResp?.posts ?: emptyList()) + rTaste).distinctBy { it.id })
        val ofBucket = prepBucket(ofResp?.posts)
        val r34Bucket = prepBucket(r34Resp?.posts)
        val xBucket = prepBucket(xResp?.posts)
        val igBucket = prepBucket(igResp?.posts)

        data class DRRBucket(val key: String, val queue: MutableList<Gif>, val weight: Double, var credit: Double = 0.0)
        val sw = tasteState.sourceWeights
        val active = listOf(
            DRRBucket("reddit", redditBucket, maxOf(0.20, sw["reddit"] ?: 1.0)),
            DRRBucket("onlyfans", ofBucket, maxOf(0.20, sw["onlyfans"] ?: 1.0)),
            DRRBucket("x", xBucket, maxOf(0.20, sw["x"] ?: 1.0)),
            DRRBucket("instagram", igBucket, maxOf(0.15, sw["instagram"] ?: 0.65)),
            DRRBucket("rule34", r34Bucket, maxOf(0.20, sw["rule34"] ?: 0.90))
        ).filter { it.queue.isNotEmpty() }

        val totalW = active.sumOf { it.weight }.coerceAtLeast(0.01)
        val mixed = mutableListOf<Gif>()
        var guard = 0
        while (mixed.size < 36 && active.any { it.queue.isNotEmpty() } && guard++ < 200) {
            for (b in active) {
                if (b.queue.isEmpty()) continue
                b.credit += (b.weight / totalW) * 1.24
                if (b.credit >= 0.24) {
                    b.credit -= 0.24
                    mixed.add(b.queue.removeAt(0))
                    if (mixed.size >= 36) break
                }
            }
        }
        val nextCursor = rResp?.after ?: GoonedAPI.randomForYouCursor(Random.nextInt(1, 9) * 25)
        GoonedFeedResponse(mixed, nextCursor)
    }

    private suspend fun loadDiskCache(key: String): List<Gif> = withContext(Dispatchers.IO) {
        val dir = File(TinyTinyApplication.instance.cacheDir, "FeedDiskCache")
        val f = File(dir, key.replace(Regex("[^A-Za-z0-9_-]"), "_").take(80) + ".json")
        if (!f.exists()) return@withContext emptyList()
        CryptoBox.openCodable<List<Gif>>(f.readBytes()) ?: emptyList()
    }

    private fun saveDiskCache(posts: List<Gif>, key: String) {
        scope.launch(Dispatchers.IO) {
            val dir = File(TinyTinyApplication.instance.cacheDir, "FeedDiskCache").apply { mkdirs() }
            val f = File(dir, key.replace(Regex("[^A-Za-z0-9_-]"), "_").take(80) + ".json")
            CryptoBox.sealCodable(posts)?.let { bytes ->
                val tmp = File(dir, f.name + ".tmp")
                tmp.writeBytes(bytes)
                if (f.exists()) f.delete()
                tmp.renameTo(f)
            }
        }
    }
}
