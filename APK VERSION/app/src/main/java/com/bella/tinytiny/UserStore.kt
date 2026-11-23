package com.bella.tinytiny

import android.content.Context
import android.webkit.WebStorage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.KSerializer
import kotlinx.serialization.Serializable
import kotlinx.serialization.descriptors.PrimitiveKind
import kotlinx.serialization.descriptors.PrimitiveSerialDescriptor
import kotlinx.serialization.descriptors.SerialDescriptor
import kotlinx.serialization.encoding.Decoder
import kotlinx.serialization.encoding.Encoder
import kotlinx.serialization.json.JsonDecoder
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import java.util.concurrent.ConcurrentHashMap

object FlexibleEpochSecondsSerializer : KSerializer<Double> {
    override val descriptor: SerialDescriptor = PrimitiveSerialDescriptor("FlexibleEpochSeconds", PrimitiveKind.DOUBLE)
    override fun serialize(encoder: Encoder, value: Double) = encoder.encodeDouble(value)
    override fun deserialize(decoder: Decoder): Double {
        return if (decoder is JsonDecoder) {
            val prim = decoder.decodeJsonElement().jsonPrimitive
            prim.content.toDoubleOrNull() ?: (System.currentTimeMillis() / 1000.0)
        } else {
            decoder.decodeDouble()
        }
    }
}

@Serializable
data class AppSettings(
    var hd: Boolean = true,
    var muted: Boolean = true,
    var faceID: Boolean = false,
    var autoScroll: Boolean = false,
    var autoScrollDelay: Int = 6,
    var playVideosToEnd: Boolean = true,
    var fillScreen: Boolean = false,
    var videoFitScreen: Boolean = true,
    var controlsCollapsed: Boolean = false,
    var tintedGlass: Boolean = false,
    var algorithmEnabled: Boolean = true
)

@Serializable
data class AlgorithmProfile(
    var boostedTags: List<String> = emptyList(),
    var blockedTags: List<String> = emptyList(),
    var tagWeights: MutableMap<String, Double> = mutableMapOf(),
    var preferredAuthors: MutableMap<String, Double> = mutableMapOf(),
    var preferredSubreddits: MutableMap<String, Double> = mutableMapOf(),
    var subredditWeights: MutableMap<String, Double> = mutableMapOf(),
    var creatorWeights: MutableMap<String, Double> = mutableMapOf(),
    var videoPreference: Double = 0.5,
    var totalSignals: Int = 0
)

@Serializable
data class RecentFeedEntry(
    val kind: String,
    val name: String,
    val displayTitle: String,
    var swipedCount: Int,
    @Serializable(with = FlexibleEpochSecondsSerializer::class)
    var updatedAt: Double = System.currentTimeMillis() / 1000.0
) {
    val id: String get() = "$kind:$name"
}

@Serializable
data class UserData(
    var liked: List<Gif> = emptyList(),
    var downloaded: List<Gif> = emptyList(),
    var followedUsers: List<String> = emptyList(),
    var followedSubreddits: List<String> = emptyList(),
    var followedXUsers: List<String> = emptyList(),
    var followedIGUsers: List<String> = emptyList(),
    var followedOFCreators: List<FollowedOFCreator> = emptyList(),
    var recentFeeds: List<RecentFeedEntry> = emptyList(),
    var seenIDs: List<String> = emptyList(),
    var savedCursors: MutableMap<String, String> = mutableMapOf(),
    var swipedTotal: Int = 0,
    var settings: AppSettings = AppSettings(),
    var xSession: XAccountSession = XAccountSession(),
    var igSession: InstagramAccountSession = InstagramAccountSession(),
    var r34Credentials: Rule34Credentials = Rule34Credentials(),
    var algorithm: AlgorithmProfile = AlgorithmProfile()
)

class UserStore private constructor() {
    companion object {
        val shared = UserStore()
        private const val DATA_FILENAME = "gooned_userdata.json"
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var saveJob: Job? = null

    private val seenSet = ConcurrentHashMap.newKeySet<String>()
    private val seenList = mutableListOf<String>()

    val data = MutableStateFlow(UserData())
    val categories = MutableStateFlow(GoonedCategory.defaultCategories)

    private val dataFile: File
        get() = File(TinyTinyApplication.instance.filesDir, DATA_FILENAME)

    init {
        val loaded = try {
            if (dataFile.exists()) {
                CryptoBox.openCodable<UserData>(dataFile.readBytes()) ?: UserData()
            } else UserData()
        } catch (_: Throwable) {
            UserData()
        }
        seenList.addAll(loaded.seenIDs)
        seenSet.addAll(loaded.seenIDs)
        data.value = loaded
        scope.launch {
            try {
                val remote = GoonedAPI.categories()
                if (remote.isNotEmpty()) categories.value = remote
            } catch (_: Throwable) {}
        }
    }

    private fun scheduleSave() {
        saveJob?.cancel()
        saveJob = scope.launch {
            delay(1500)
            saveNow()
        }
    }

    fun exportSnapshotForBackup(): UserData {
        val cur = data.value
        val copySeen = synchronized(seenList) { seenList.toList() }
        return cur.copy(seenIDs = copySeen)
    }

    fun saveNow() {
        val snapshot = exportSnapshotForBackup()
        val f = dataFile
        scope.launch {
            CryptoBox.sealCodable(snapshot)?.let { bytes ->
                val tmp = File(f.parentFile, f.name + ".tmp")
                tmp.writeBytes(bytes)
                tmp.renameTo(f)
            }
        }
    }

    fun isSeen(id: String): Boolean = seenSet.contains(id)

    fun isSeen(post: Gif): Boolean =
        seenSet.contains(post.id) ||
            seenSet.contains(post.canonicalDedupeKey) ||
            SmartTasteEngine.shared.isSeenOrDuplicate(post)

    fun markSeen(post: Gif) {
        markSeen(post.id)
        markSeen(post.canonicalDedupeKey)
        SmartTasteEngine.shared.markSeenSimilarity(post)
    }

    fun markSeen(id: String) {
        if (id.isEmpty() || !seenSet.add(id)) return
        synchronized(seenList) {
            seenList.add(id)
            if (seenList.size > 12_000) {
                val overflow = seenList.size - 10_000
                repeat(overflow) {
                    val rem = seenList.removeAt(0)
                    seenSet.remove(rem)
                }
            }
        }
        scheduleSave()
    }

    fun savedCursor(key: String): String? = data.value.savedCursors[key]

    fun saveCursor(cursor: String?, key: String) {
        val cur = data.value
        val nextMap = cur.savedCursors.toMutableMap()
        if (!cursor.isNullOrEmpty()) nextMap[key] = cursor else nextMap.remove(key)
        data.value = cur.copy(savedCursors = nextMap)
        scheduleSave()
    }

    fun isLiked(gif: Gif): Boolean = data.value.liked.any { it.id == gif.id }

    fun toggleLike(gif: Gif) {
        val cur = data.value
        val next = cur.liked.toMutableList()
        val idx = next.indexOfFirst { it.id == gif.id }
        if (idx >= 0) {
            next.removeAt(idx)
        } else {
            next.add(0, gif)
            markSeen(gif)
            SmartTasteEngine.shared.recordPositiveEngagement(gif, 1.0, categories.value)
        }
        data.value = cur.copy(liked = next)
        scheduleSave()
    }

    fun recordDownloaded(gif: Gif) {
        val cur = data.value
        val next = cur.downloaded.filterNot { it.id == gif.id }.toMutableList()
        next.add(0, gif)
        data.value = cur.copy(downloaded = next)
        scheduleSave()
    }

    fun removeDownloaded(id: String) {
        val cur = data.value
        data.value = cur.copy(downloaded = cur.downloaded.filterNot { it.id == id })
        scheduleSave()
    }

    fun clearAllDownloaded() {
        data.value = data.value.copy(downloaded = emptyList())
        scheduleSave()
    }

    fun isFollowingUser(u: String): Boolean =
        data.value.followedUsers.any { it.equals(u, ignoreCase = true) }

    fun toggleFollowUser(u: String) {
        val cur = data.value
        val next = cur.followedUsers.toMutableList()
        val idx = next.indexOfFirst { it.equals(u, ignoreCase = true) }
        if (idx >= 0) next.removeAt(idx) else next.add(u)
        data.value = cur.copy(followedUsers = next)
        scheduleSave()
    }

    fun isFollowingSubreddit(s: String): Boolean =
        data.value.followedSubreddits.any { it.equals(s, ignoreCase = true) }

    fun toggleFollowSubreddit(s: String) {
        val cur = data.value
        val next = cur.followedSubreddits.toMutableList()
        val idx = next.indexOfFirst { it.equals(s, ignoreCase = true) }
        if (idx >= 0) next.removeAt(idx) else next.add(s)
        data.value = cur.copy(followedSubreddits = next)
        scheduleSave()
    }

    fun isFollowingXUser(handle: String): Boolean {
        val clean = handle.removePrefix("@")
        return data.value.followedXUsers.any { it.equals(clean, ignoreCase = true) }
    }

    fun toggleFollowXUser(handle: String) {
        val clean = handle.removePrefix("@")
        val cur = data.value
        val next = cur.followedXUsers.toMutableList()
        val idx = next.indexOfFirst { it.equals(clean, ignoreCase = true) }
        if (idx >= 0) next.removeAt(idx) else next.add(clean)
        data.value = cur.copy(followedXUsers = next)
        scheduleSave()
    }

    fun isFollowingIGUser(handle: String): Boolean {
        val clean = handle.removePrefix("@")
        return data.value.followedIGUsers.any { it.equals(clean, ignoreCase = true) }
    }

    fun toggleFollowIGUser(handle: String) {
        val clean = handle.removePrefix("@")
        val cur = data.value
        val next = cur.followedIGUsers.toMutableList()
        val idx = next.indexOfFirst { it.equals(clean, ignoreCase = true) }
        if (idx >= 0) next.removeAt(idx) else next.add(clean)
        data.value = cur.copy(followedIGUsers = next)
        scheduleSave()
    }

    fun isFollowingOFCreator(id: String?, handle: String?): Boolean {
        return data.value.followedOFCreators.any {
            (!id.isNullOrEmpty() && it.id == id) || (!handle.isNullOrEmpty() && it.name.equals(handle, ignoreCase = true))
        }
    }

    fun toggleFollowOFCreator(id: String, name: String, displayName: String? = null) {
        val cur = data.value
        val next = cur.followedOFCreators.toMutableList()
        val idx = next.indexOfFirst { it.id == id || it.name.equals(name, ignoreCase = true) }
        if (idx >= 0) next.removeAt(idx) else next.add(FollowedOFCreator(id, name, displayName))
        data.value = cur.copy(followedOFCreators = next)
        scheduleSave()
    }

    fun updateSettings(transform: (AppSettings) -> AppSettings) {
        val cur = data.value
        data.value = cur.copy(settings = transform(cur.settings))
        scheduleSave()
    }

    fun updateXSession(session: XAccountSession) {
        data.value = data.value.copy(xSession = session)
        saveNow()
    }

    fun updateIGSession(session: InstagramAccountSession) {
        data.value = data.value.copy(igSession = session)
        saveNow()
    }

    fun updateR34Credentials(creds: Rule34Credentials) {
        data.value = data.value.copy(r34Credentials = creds)
        saveNow()
    }

    fun updateAlgorithm(transform: (AlgorithmProfile) -> AlgorithmProfile) {
        val cur = data.value
        data.value = cur.copy(algorithm = transform(cur.algorithm))
        saveNow()
    }

    fun recordSwipe(kind: String, name: String, displayTitle: String, postID: String? = null) {
        if (!postID.isNullOrEmpty()) markSeen(postID)
        val cur = data.value
        val nextRecent = cur.recentFeeds.toMutableList()
        val idx = nextRecent.indexOfFirst { it.kind == kind && it.name.equals(name, ignoreCase = true) }
        val now = System.currentTimeMillis() / 1000L
        if (idx >= 0) {
            val existing = nextRecent.removeAt(idx)
            nextRecent.add(0, existing.copy(swipedCount = existing.swipedCount + 1, updatedAt = now))
        } else {
            nextRecent.add(0, RecentFeedEntry(kind, name, displayTitle, 1, now))
        }
        data.value = cur.copy(swipedTotal = cur.swipedTotal + 1, recentFeeds = nextRecent.take(24))
        scheduleSave()
    }

    fun recordDwellSignal(post: Gif, secondsWatched: Double) {
        if (secondsWatched >= 3.8) {
            SmartTasteEngine.shared.recordPositiveEngagement(post, if (secondsWatched >= 9.0) 1.0 else 0.5, categories.value)
        } else if (secondsWatched < 1.6) {
            SmartTasteEngine.shared.recordFastSkip(post, categories.value)
        }
    }

    fun dislike(post: Gif): SmartTasteEngine.DislikeOutcome {
        markSeen(post)
        return SmartTasteEngine.shared.recordDislike(post, categories.value)
    }

    fun rankWithAlgorithm(posts: List<Gif>): List<Gif> {
        if (!data.value.settings.algorithmEnabled) return posts
        val algo = data.value.algorithm
        val boosted = algo.boostedTags.map { it.lowercase() }.toSet()
        val blocked = algo.blockedTags.map { it.lowercase() }.toSet()
        val engine = SmartTasteEngine.shared
        val cats = categories.value

        val filtered = posts.filter { post ->
            if (engine.isSuppressedInDiscovery(post, cats)) return@filter false
            val tags = SmartTasteEngine.extractDirectTagsOnly(post, cats).map { it.lowercase() }
            if (tags.any { it in blocked }) return@filter false
            true
        }
        return filtered.sortedByDescending { post ->
            var score = engine.scoreAdjustment(post, cats)
            val tags = SmartTasteEngine.extractDirectTagsOnly(post, cats).map { it.lowercase() }
            for (t in tags) {
                if (t in boosted) score += 2.5
                score += (algo.tagWeights[t] ?: 0.0)
            }
            post.author?.lowercase()?.let { score += (algo.preferredAuthors[it] ?: 0.0) }
            post.subreddit?.lowercase()?.let { score += (algo.preferredSubreddits[it] ?: 0.0) }
            score
        }
    }

    fun replaceWithBackup(restored: UserData) {
        synchronized(seenList) {
            seenList.clear()
            seenList.addAll(restored.seenIDs)
            seenSet.clear()
            seenSet.addAll(restored.seenIDs)
        }
        data.value = restored
        saveNow()
    }

    data class WipeOptions(
        val keepLikes: Boolean = true,
        val keepFollowing: Boolean = true,
        val keepOfflineVault: Boolean = true,
        val keepAccounts: Boolean = true,
        val keepAlgorithm: Boolean = true,
        val keepPasscode: Boolean = true
    )

    suspend fun performSelectiveWipe(options: WipeOptions) = withContext(Dispatchers.IO) {
        val cur = data.value
        val fresh = UserData(
            liked = if (options.keepLikes) cur.liked else emptyList(),
            downloaded = if (options.keepOfflineVault) cur.downloaded else emptyList(),
            followedUsers = if (options.keepFollowing) cur.followedUsers else emptyList(),
            followedSubreddits = if (options.keepFollowing) cur.followedSubreddits else emptyList(),
            followedXUsers = if (options.keepFollowing) cur.followedXUsers else emptyList(),
            followedIGUsers = if (options.keepFollowing) cur.followedIGUsers else emptyList(),
            followedOFCreators = if (options.keepFollowing) cur.followedOFCreators else emptyList(),
            xSession = if (options.keepAccounts) cur.xSession else XAccountSession(),
            igSession = if (options.keepAccounts) cur.igSession else InstagramAccountSession(),
            r34Credentials = if (options.keepAccounts) cur.r34Credentials else Rule34Credentials(),
            algorithm = if (options.keepAlgorithm) cur.algorithm else AlgorithmProfile(),
            settings = cur.settings
        )
        if (!options.keepAlgorithm) {
            synchronized(seenList) {
                seenList.clear()
                seenSet.clear()
            }
            SmartTasteEngine.shared.reset()
        } else {
            val copySeen = synchronized(seenList) { seenList.toList() }
            fresh.seenIDs = copySeen
        }
        data.value = fresh
        if (!options.keepOfflineVault) OfflineManager.clearAllDownloads()
        if (!options.keepPasscode) AppState.removePasscodeKeepingData()

        val ctx = TinyTinyApplication.instance
        File(ctx.cacheDir, "FeedDiskCache").deleteRecursively()
        ctx.cacheDir.listFiles()?.forEach { if (it.name.startsWith("tt_")) it.deleteRecursively() }

        if (!options.keepAccounts) {
            withContext(Dispatchers.Main) {
                XWebEngine.resetSession()
                InstagramWebEngine.resetSession()
                android.webkit.CookieManager.getInstance().removeAllCookies(null)
                android.webkit.CookieManager.getInstance().flush()
                WebStorage.getInstance().deleteAllData()
            }
        }
        saveNow()
    }
}

object PornTagCatalog {
    val quickPickerCategories: List<Pair<String, List<String>>> = listOf(
        "Popular" to listOf("amateur", "asian", "latina", "ebony", "milf", "petite", "curvy", "goth", "redheads", "bbw"),
        "Actions" to listOf("blowjob", "anal", "creampie", "cumshot", "squirt", "hardcore", "pov", "threesome", "bdsm", "femdom"),
        "Animated" to listOf("hentai", "rule34", "ahegao", "futanari", "3d", "animated", "sound", "cosplay"),
        "Body & Vibes" to listOf("ass", "big_tits", "pussy", "solo", "toys", "public", "lesbian", "femboy", "trans")
    )
}
