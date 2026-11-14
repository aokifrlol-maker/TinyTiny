package com.bella.tinytiny

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeoutOrNull

class FeedModel(initialSource: FeedSource) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    private val _source = MutableStateFlow(initialSource)
    val source = _source.asStateFlow()

    private val _sort = MutableStateFlow(FeedSort.HOT)
    val sort = _sort.asStateFlow()

    private val _items = MutableStateFlow<List<Gif>>(emptyList())
    val items = _items.asStateFlow()

    private val _isLoading = MutableStateFlow(false)
    val isLoading = _isLoading.asStateFlow()

    private var afterCursor: String? = null
    private var hasMore: Boolean = true
    private var loadJob: Job? = null
    private val seenIds = HashSet<String>()

    fun switchSource(newSource: FeedSource, forceReload: Boolean = false) {
        if (_source.value == newSource && !forceReload && _items.value.isNotEmpty()) return
        loadJob?.cancel()
        _source.value = newSource
        if (newSource is FeedSource.CustomList) {
            _items.value = newSource.items
            hasMore = false
            _isLoading.value = false
            return
        }
        _items.value = emptyList()
        seenIds.clear()
        afterCursor = UserStore.savedCursor(newSource.swipeKey)
        hasMore = true
        loadMore()
    }

    fun setSort(newSort: FeedSort) {
        if (_sort.value == newSort) return
        _sort.value = newSort
        refresh(rotateCursor = false)
    }

    fun refresh(rotateCursor: Boolean = true) {
        loadJob?.cancel()
        if (rotateCursor) afterCursor = null
        seenIds.clear()
        _items.value = emptyList()
        hasMore = true
        loadMore()
    }

    fun shuffleItems() {
        _items.value = _items.value.shuffled()
    }

    fun purgeSuppressed(afterId: String?) {
        val algo = UserStore.data.value.algorithm
        val cur = _items.value
        val idx = if (afterId != null) cur.indexOfFirst { it.id == afterId } else -1
        if (idx < 0) return
        val head = cur.take(idx + 1)
        val tail = cur.drop(idx + 1).filterNot { SmartTasteEngine.isBlocked(it, algo) }
        _items.value = head + tail
    }

    fun prefetchIfNeeded(currentId: String?) {
        val cur = _items.value
        if (cur.isEmpty() || _isLoading.value || !hasMore) return
        val idx = cur.indexOfFirst { it.id == currentId }
        if (idx >= cur.size - 5) {
            loadMore()
        }
    }

    fun loadMore() {
        if (_isLoading.value || !hasMore) return
        loadJob = scope.launch {
            _isLoading.value = true
            try {
                val resp = fetchPage(_source.value, _sort.value, afterCursor)
                afterCursor = resp.after
                UserStore.setSavedCursor(resp.after, _source.value.swipeKey)

                val algo = UserStore.data.value.algorithm
                val filtered = resp.posts.filter { p ->
                    p.hasPlayableMedia &&
                        !SmartTasteEngine.isDisliked(p) &&
                        !SmartTasteEngine.isBlocked(p, algo) &&
                        seenIds.add(p.id)
                }
                val ranked = UserStore.rankWithAlgorithm(filtered)
                if (ranked.isNotEmpty()) {
                    _items.value = _items.value + ranked
                } else if (resp.after == null) {
                    hasMore = false
                }
            } finally {
                _isLoading.value = false
            }
        }
    }

    private suspend fun fetchPage(src: FeedSource, s: FeedSort, cursor: String?): GoonedFeedResponse {
        return when (src) {
            is FeedSource.ForYou -> fetchBalancedForYou(s, cursor)
            is FeedSource.Following -> {
                val subs = UserStore.data.value.followedSubreddits
                val sub = subs.randomOrNull() ?: "nsfwgifs"
                GoonedAPI.subreddit(sub, s.rawValue, cursor)
            }
            is FeedSource.XForYou -> XAPI.feed(followingOnly = false, after = cursor)
            is FeedSource.XFollowing -> XAPI.feed(followingOnly = true, after = cursor)
            is FeedSource.XBookmarks -> XAPI.feed(followingOnly = false, after = cursor)
            is FeedSource.XUser -> XAPI.search("from:${src.username}", s.rawValue, cursor)
            is FeedSource.IGReels -> InstagramAPI.reels(followingOnly = false, after = cursor)
            is FeedSource.IGFollowing -> InstagramAPI.reels(followingOnly = true, after = cursor)
            is FeedSource.IGSaved -> InstagramAPI.reels(followingOnly = false, after = cursor)
            is FeedSource.IGUser -> InstagramAPI.reels(followingOnly = false, after = cursor)
            is FeedSource.OFForYou -> {
                val algo = UserStore.data.value.algorithm
                val seeds = UserStore.data.value.followedOFCreators.map { it.name } + SmartTasteEngine.topOnlyFansSeedHandles(6)
                val taste = SmartTasteEngine.activeQueryTags(algo.boostedTags, algo.blockedTags, 6)
                OnlyFansAPI.forYou(cursor, seeds.distinct(), taste)
            }
            is FeedSource.OFTrending -> OnlyFansAPI.trending(cursor)
            is FeedSource.OFLatest -> OnlyFansAPI.latest(cursor)
            is FeedSource.OFDMs -> OnlyFansAPI.dms(cursor)
            is FeedSource.OFCreator -> OnlyFansAPI.creatorFeed(src.id, cursor)
            is FeedSource.Rule34 -> Rule34API.fetchFeed(src.tag, s.rawValue, cursor, UserStore.data.value.r34Credentials)
            is FeedSource.LongVideos -> LongVideoAPI.fetchFeed(src.site, s.rawValue, null, cursor)
            is FeedSource.LongSearch -> LongVideoAPI.fetchFeed(src.site, s.rawValue, src.query, cursor)
            is FeedSource.Subreddit -> GoonedAPI.subreddit(src.name, s.rawValue, cursor)
            is FeedSource.User -> GoonedAPI.user(src.name, cursor)
            is FeedSource.Category -> GoonedAPI.category(src.name, s.rawValue, cursor)
            is FeedSource.MultiSearch -> fetchMultiSearch(src.query, cursor)
            is FeedSource.CustomList -> GoonedFeedResponse(src.items, null)
        }
    }

    private suspend fun fetchBalancedForYou(s: FeedSort, cursor: String?): GoonedFeedResponse = coroutineScope {
        val algo = UserStore.data.value.algorithm
        val tasteTags = SmartTasteEngine.activeQueryTags(algo.boostedTags, algo.blockedTags, 5)
        val topSubs = UserStore.topAlgorithmSubreddits(3)
        val rdTask = async {
            val sub = topSubs.randomOrNull() ?: tasteTags.randomOrNull()
            if (sub != null) GoonedAPI.subreddit(sub, s.rawValue, cursor) else GoonedAPI.forYou(s.rawValue, cursor)
        }
        val ofTask = async {
            val seeds = UserStore.data.value.followedOFCreators.map { it.name } + SmartTasteEngine.topOnlyFansSeedHandles(4)
            OnlyFansAPI.forYou(cursor, seeds.distinct(), tasteTags)
        }
        val rd = withTimeoutOrNull(4500) { rdTask.await() } ?: GoonedFeedResponse(emptyList())
        val of = withTimeoutOrNull(4500) { ofTask.await() } ?: GoonedFeedResponse(emptyList())
        val combined = (rd.posts + of.posts).shuffled()
        GoonedFeedResponse(combined, rd.after ?: of.after)
    }

    private suspend fun fetchMultiSearch(query: String, cursor: String?): GoonedFeedResponse = coroutineScope {
        val clean = query.trim()
        if (clean.isEmpty()) return@coroutineScope GoonedFeedResponse(emptyList())
        val pageNum = (cursor?.toIntOrNull() ?: 1).coerceAtLeast(1)
        val r34Tag = clean.lowercase().replace(" ", "_")

        val ofTask = async { withTimeoutOrNull(3500) { OnlyFansAPI.searchPosts(clean, if (pageNum > 1) "${(pageNum - 1) * 20}" else null) } ?: GoonedFeedResponse(emptyList()) }
        val r34Task = async { withTimeoutOrNull(3500) { Rule34API.fetchFeed(r34Tag, _sort.value.rawValue, if (pageNum > 1) "${pageNum - 1}" else null, UserStore.data.value.r34Credentials) } ?: GoonedFeedResponse(emptyList()) }
        val longTask = async { withTimeoutOrNull(3500) { LongVideoAPI.fetchFeed(LongVideoSite.ALL, _sort.value.rawValue, clean, "$pageNum") } ?: GoonedFeedResponse(emptyList()) }
        val rdTask = async {
            withTimeoutOrNull(3500) {
                val subs = GoonedAPI.searchSubreddits(clean).take(2)
                if (subs.isEmpty()) GoonedAPI.subreddit(clean.replace(" ", ""), _sort.value.rawValue, null, 12)
                else GoonedAPI.subreddit(subs.first(), _sort.value.rawValue, null, 15)
            } ?: GoonedFeedResponse(emptyList())
        }

        val buckets = listOf(ofTask.await().posts, r34Task.await().posts, rdTask.await().posts, longTask.await().posts)
        val maxLen = buckets.maxOfOrNull { it.size } ?: 0
        val merged = mutableListOf<Gif>()
        for (i in 0 until maxLen) {
            for (b in buckets) if (i < b.size) merged.add(b[i])
        }
        GoonedFeedResponse(merged, if (merged.isEmpty()) null else "${pageNum + 1}")
    }
}
