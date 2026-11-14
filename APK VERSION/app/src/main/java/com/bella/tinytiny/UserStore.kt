package com.bella.tinytiny

import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File

@Serializable
data class AppSettings(
    val hd: Boolean = true,
    val muted: Boolean = false,
    val autoScroll: Boolean = false,
    val autoScrollDelay: Double = 6.0,
    val playVideosToEnd: Boolean = true,
    val algorithmEnabled: Boolean = true,
    val faceID: Boolean = false,
    val controlsCollapsed: Boolean = false
)

@Serializable
data class AlgorithmProfile(
    val subredditWeights: Map<String, Double> = emptyMap(),
    val creatorWeights: Map<String, Double> = emptyMap(),
    val tagWeights: Map<String, Double> = emptyMap(),
    val boostedTags: List<String> = emptyList(),
    val blockedTags: List<String> = emptyList(),
    val totalSignals: Int = 0
)

@Serializable
data class XSession(
    val authToken: String = "",
    val ct0: String = "",
    val username: String = ""
) {
    val isConnected: Boolean get() = authToken.isNotBlank() && ct0.isNotBlank()
}

@Serializable
data class IGSession(
    val sessionId: String = "",
    val csrfToken: String = "",
    val dsUserId: String = "",
    val username: String = ""
) {
    val isConnected: Boolean get() = sessionId.isNotBlank() && dsUserId.isNotBlank()
}

@Serializable
data class Rule34Credentials(
    val userId: String = "",
    val apiKey: String = ""
) {
    val isConnected: Boolean get() = userId.isNotBlank() && apiKey.isNotBlank()
}

@Serializable
data class FollowedOFCreator(
    val id: String,
    val name: String,
    val handle: String = ""
)

@Serializable
data class UserData(
    val likes: List<Gif> = emptyList(),
    val seenIds: List<String> = emptyList(),
    val followedSubreddits: List<String> = emptyList(),
    val followedUsers: List<String> = emptyList(),
    val followedOFCreators: List<FollowedOFCreator> = emptyList(),
    val savedCursors: Map<String, String> = emptyMap(),
    val settings: AppSettings = AppSettings(),
    val algorithm: AlgorithmProfile = AlgorithmProfile(),
    val xSession: XSession = XSession(),
    val igSession: IGSession = IGSession(),
    val r34Credentials: Rule34Credentials = Rule34Credentials()
)

object UserStore {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var saveJob: Job? = null
    private lateinit var storeFile: File

    private val _data = MutableStateFlow(UserData())
    val data = _data.asStateFlow()

    private val _categories = MutableStateFlow<List<GoonedCategory>>(emptyList())
    val categories = _categories.asStateFlow()

    private val seenSet = HashSet<String>()
    private val likedIdSet = HashSet<String>()

    fun init(context: Context) {
        storeFile = File(context.filesDir, "tinytiny_user_v1.json")
        if (storeFile.exists()) {
            runCatching {
                val loaded = json.decodeFromString<UserData>(storeFile.readText())
                _data.value = loaded
                seenSet.clear()
                seenSet.addAll(loaded.seenIds)
                likedIdSet.clear()
                likedIdSet.addAll(loaded.likes.map { it.id })
            }
        }
    }

    private fun update(transform: (UserData) -> UserData) {
        val next = transform(_data.value)
        _data.value = next
        scheduleSave(next)
    }

    private fun scheduleSave(snapshot: UserData) {
        saveJob?.cancel()
        saveJob = scope.launch {
            delay(450)
            if (::storeFile.isInitialized) {
                runCatching {
                    val tmp = File(storeFile.parentFile, "${storeFile.name}.tmp")
                    tmp.writeText(json.encodeToString(snapshot))
                    tmp.renameTo(storeFile)
                }
            }
        }
    }

    fun setCategories(list: List<GoonedCategory>) {
        _categories.value = list
    }

    fun updateSettings(transform: (AppSettings) -> AppSettings) {
        update { it.copy(settings = transform(it.settings)) }
    }

    fun updateAlgorithm(transform: (AlgorithmProfile) -> AlgorithmProfile) {
        update { it.copy(algorithm = transform(it.algorithm)) }
    }

    fun setXSession(session: XSession) {
        update { it.copy(xSession = session) }
    }

    fun setIGSession(session: IGSession) {
        update { it.copy(igSession = session) }
    }

    fun setR34Credentials(creds: Rule34Credentials) {
        update { it.copy(r34Credentials = creds) }
    }

    fun isLiked(id: String): Boolean = likedIdSet.contains(id)

    fun toggleLike(post: Gif) {
        val currentlyLiked = likedIdSet.contains(post.id)
        if (currentlyLiked) {
            likedIdSet.remove(post.id)
            update { it.copy(likes = it.likes.filterNot { g -> g.id == post.id }) }
        } else {
            likedIdSet.add(post.id)
            SmartTasteEngine.recordLike(post)
            val tags = SmartTasteEngine.extractTags(post)
            update { cur ->
                val nextTags = cur.algorithm.tagWeights.toMutableMap()
                tags.forEach { t -> nextTags[t] = (nextTags[t] ?: 0.0) + 1.4 }
                val nextCreators = cur.algorithm.creatorWeights.toMutableMap()
                post.author?.takeIf { it.isNotBlank() }?.let { a ->
                    nextCreators[a.lowercase()] = (nextCreators[a.lowercase()] ?: 0.0) + 1.5
                }
                val nextSubs = cur.algorithm.subredditWeights.toMutableMap()
                post.subreddit?.takeIf { it.isNotBlank() }?.let { s ->
                    nextSubs[s.lowercase()] = (nextSubs[s.lowercase()] ?: 0.0) + 1.2
                }
                cur.copy(
                    likes = listOf(post) + cur.likes.filterNot { it.id == post.id },
                    algorithm = cur.algorithm.copy(
                        tagWeights = nextTags,
                        creatorWeights = nextCreators,
                        subredditWeights = nextSubs,
                        totalSignals = cur.algorithm.totalSignals + 1
                    )
                )
            }
        }
    }

    fun isSeen(post: Gif): Boolean {
        return seenSet.contains(post.id) ||
            seenSet.contains(post.canonicalDedupeKey) ||
            SmartTasteEngine.isDisliked(post)
    }

    fun markSeen(post: Gif) {
        val added1 = seenSet.add(post.id)
        val added2 = seenSet.add(post.canonicalDedupeKey)
        if (!added1 && !added2) return
        update { cur ->
            val trimmed = (listOf(post.id, post.canonicalDedupeKey) + cur.seenIds).distinct().take(2500)
            cur.copy(seenIds = trimmed)
        }
    }

    fun recordDwellSignal(post: Gif, secondsWatched: Double) {
        if (secondsWatched < 2.2) return
        SmartTasteEngine.recordWatch(post, secondsWatched)
        val boost = (secondsWatched / 8.0).coerceIn(0.25, 1.3)
        val tags = SmartTasteEngine.extractTags(post)
        update { cur ->
            val nextTags = cur.algorithm.tagWeights.toMutableMap()
            tags.forEach { t -> nextTags[t] = (nextTags[t] ?: 0.0) + boost * 0.5 }
            cur.copy(
                algorithm = cur.algorithm.copy(
                    tagWeights = nextTags,
                    totalSignals = cur.algorithm.totalSignals + 1
                )
            )
        }
    }

    fun recordLoopSignal(post: Gif) {
        SmartTasteEngine.recordWatch(post, 10.0)
    }

    fun savedCursor(key: String): String? = _data.value.savedCursors[key]

    fun setSavedCursor(cursor: String?, key: String) {
        update { cur ->
            val next = cur.savedCursors.toMutableMap()
            if (cursor.isNullOrBlank()) next.remove(key) else next[key] = cursor
            cur.copy(savedCursors = next)
        }
    }

    fun isBlockedByAlgorithm(post: Gif): Boolean {
        return SmartTasteEngine.isBlocked(post, _data.value.algorithm)
    }

    fun scorePost(post: Gif): Double {
        return SmartTasteEngine.scorePost(post, _data.value.algorithm)
    }

    fun rankWithAlgorithm(posts: List<Gif>): List<Gif> {
        posts.forEach { SmartTasteEngine.ingestPost(it) }
        if (!_data.value.settings.algorithmEnabled || posts.size <= 3) {
            return posts.shuffled()
        }
        val scored = posts.map { it to (scorePost(it) + (-0.6..0.6).random()) }
            .sortedByDescending { it.second }
        val split = (scored.size * 3 / 4).coerceAtLeast(1)
        val topPool = scored.take(split).map { it.first }.toMutableList()
        val explorePool = scored.drop(split).map { it.first }.shuffled().toMutableList()
        val result = ArrayList<Gif>(posts.size)
        var i = 0
        while (topPool.isNotEmpty() || explorePool.isNotEmpty()) {
            if (i % 4 == 3 && explorePool.isNotEmpty()) {
                result.add(explorePool.removeAt(0))
            } else if (topPool.isNotEmpty()) {
                result.add(topPool.removeAt(0))
            } else if (explorePool.isNotEmpty()) {
                result.add(explorePool.removeAt(0))
            }
            i++
        }
        return result
    }

    fun topAlgorithmSubreddits(limit: Int = 4): List<String> {
        return _data.value.algorithm.subredditWeights
            .entries
            .filter { it.value > 0.3 }
            .sortedByDescending { it.value }
            .take(limit)
            .map { it.key }
    }

    fun eraseAll() {
        seenSet.clear()
        likedIdSet.clear()
        _data.value = UserData()
        SmartTasteEngine.resetAll()
        if (::storeFile.isInitialized && storeFile.exists()) {
            storeFile.delete()
        }
    }

    private fun ClosedFloatingPointRange<Double>.random(): Double =
        start + Math.random() * (endInclusive - start)
}
