package com.bella.tinytiny

import android.webkit.WebStorage
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.update
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
import kotlin.math.log10
import kotlin.random.Random

// iOS Swift JSONEncoder encodes Date as seconds since Jan 1, 2001 (Apple Reference Date = Unix - 978307200.0).
object FlexibleEpochSecondsSerializer : KSerializer<Double> {
    private const val APPLE_REF_OFFSET = 978_307_200.0
    override val descriptor: SerialDescriptor = PrimitiveSerialDescriptor("FlexibleEpochSeconds", PrimitiveKind.DOUBLE)

    override fun serialize(encoder: Encoder, value: Double) {
        // Always serialize as Apple Reference Date seconds so iOS decodes exact dates!
        val appleSec = if (value > 1_200_000_000.0) value - APPLE_REF_OFFSET else value
        encoder.encodeDouble(appleSec)
    }

    override fun deserialize(decoder: Decoder): Double {
        val raw = if (decoder is JsonDecoder) {
            decoder.decodeJsonElement().jsonPrimitive.content.toDoubleOrNull()
                ?: ((System.currentTimeMillis() / 1000.0) - APPLE_REF_OFFSET)
        } else {
            decoder.decodeDouble()
        }
        // Normalize internally to Unix epoch seconds
        return if (raw > 1_200_000_000.0) raw else raw + APPLE_REF_OFFSET
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
    var tagWeights: Map<String, Double> = emptyMap(),
    var subredditWeights: Map<String, Double> = emptyMap(),
    var creatorWeights: Map<String, Double> = emptyMap(),
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
    var savedCursors: Map<String, String> = emptyMap(),
    var swipedTotal: Int = 0,
    var settings: AppSettings = AppSettings(),
    var xSession: XAccountSession = XAccountSession(),
    var igSession: InstagramAccountSession = InstagramAccountSession(),
    var redditSession: RedditAccountSession = RedditAccountSession(),
    var r34Credentials: Rule34Credentials = Rule34Credentials(),
    var algorithm: AlgorithmProfile = AlgorithmProfile(),
    var removedLikedIDs: Map<String, Double> = emptyMap(),
    var removedDownloadedIDs: Map<String, Double> = emptyMap(),
    var removedFollows: Map<String, Double> = emptyMap()
)

class UserStore private constructor() {
    companion object {
        val shared = UserStore()
        private const val DATA_FILENAME = "gooned_userdata.json"
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var saveJob: Job? = null
    private val saveFileLock = Any()

    private val seenSet = ConcurrentHashMap.newKeySet<String>()
    private val seenList = mutableListOf<String>()
    val localAddedTimestamps = ConcurrentHashMap<String, Double>()

    val data = MutableStateFlow(UserData())
    val categories = MutableStateFlow(GoonedCategory.defaultCategories)
    @Volatile private var suppressSaveDueToDecryptError = false

    private val dataFile: File
        get() = File(TinyTinyApplication.instance.filesDir, DATA_FILENAME)

    init {
        var decryptFailed = false
        val loaded = try {
            if (dataFile.exists() && dataFile.length() > 0L) {
                val raw = dataFile.readBytes()
                val decoded = CryptoBox.openCodable<UserData>(raw)
                if (decoded != null) {
                    decoded
                } else {
                    val bak = File(dataFile.parentFile, "$DATA_FILENAME.bak")
                    if (!bak.exists()) runCatching { bak.writeBytes(raw) }
                    decryptFailed = true
                    UserData()
                }
            } else UserData()
        } catch (_: Throwable) {
            if (dataFile.exists() && dataFile.length() > 0L) decryptFailed = true
            UserData()
        }
        suppressSaveDueToDecryptError = decryptFailed
        seenList.addAll(loaded.seenIDs)
        seenSet.addAll(loaded.seenIDs)
        data.value = sanitizeLoadedData(loaded)
        scope.launch {
            try {
                val remote = GoonedAPI.categories()
                if (remote.isNotEmpty()) categories.value = remote
            } catch (_: Throwable) {}
        }
    }

    private fun sanitizeLoadedData(d: UserData): UserData {
        val algo = d.algorithm
        val cleanTagW = algo.tagWeights.filterKeys { !MediaMetaRegistry.isStopTag(it) }
        val cleanBoost = algo.boostedTags.map { PornTagCatalog.normalize(it) }.filter { it.isNotEmpty() && !MediaMetaRegistry.isStopTag(it) }.distinct()
        val cleanBlock = algo.blockedTags.map { PornTagCatalog.normalize(it) }.filter { it.isNotEmpty() && !MediaMetaRegistry.isStopTag(it) }.distinct()
        return d.copy(algorithm = algo.copy(tagWeights = cleanTagW, boostedTags = cleanBoost, blockedTags = cleanBlock))
    }

    private fun scheduleSave() {
        saveJob?.cancel()
        saveJob = scope.launch {
            delay(500)
            saveNow()
        }
    }

    fun exportSnapshotForBackup(): UserData {
        val cur = data.value
        val copySeen = synchronized(seenList) { seenList.toList() }
        return cur.copy(seenIDs = copySeen)
    }

    fun saveNow() {
        if (suppressSaveDueToDecryptError) return
        val f = dataFile
        scope.launch {
            synchronized(saveFileLock) {
                if (suppressSaveDueToDecryptError) return@synchronized
                val snapshot = exportSnapshotForBackup()
                CryptoBox.sealCodable(snapshot)?.let { bytes ->
                    val tmp = File(f.parentFile, "${f.name}.${java.util.UUID.randomUUID()}.tmp")
                    try {
                        tmp.writeBytes(bytes)
                        if (!tmp.renameTo(f)) {
                            tmp.copyTo(f, overwrite = true)
                            tmp.delete()
                        }
                    } catch (_: Throwable) {
                        tmp.delete()
                    }
                }
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

    fun clearSeenHistory() {
        synchronized(seenList) {
            seenList.clear()
            seenSet.clear()
        }
        data.value = data.value.copy(seenIDs = emptyList(), savedCursors = emptyMap())
        saveNow()
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

    fun like(gif: Gif) {
        if (!isLiked(gif)) toggleLike(gif)
    }

    private fun trimTombstones(map: Map<String, Double>, maxCount: Int = 400): Map<String, Double> {
        if (map.size <= maxCount) return map
        return map.entries.sortedByDescending { it.value }.take(maxCount).associate { it.key to it.value }
    }

    fun toggleLike(gif: Gif) {
        val cur = data.value
        val next = cur.liked.toMutableList()
        val nextRemoved = cur.removedLikedIDs.toMutableMap()
        val now = System.currentTimeMillis() / 1000.0
        val idx = next.indexOfFirst { it.id == gif.id }
        if (idx >= 0) {
            next.removeAt(idx)
            nextRemoved[gif.id] = now
            localAddedTimestamps.remove("like:${gif.id}")
            data.value = cur.copy(liked = next, removedLikedIDs = trimTombstones(nextRemoved))
            recordAlgorithmSignal(gif, -2.5)
        } else {
            next.add(0, gif)
            nextRemoved.remove(gif.id)
            localAddedTimestamps["like:${gif.id}"] = now
            data.value = cur.copy(liked = next, removedLikedIDs = nextRemoved)
            markSeen(gif)
            recordAlgorithmSignal(gif, 5.0)
        }
        scheduleSave()
        LicenseManager.scheduleCloudSync()
    }

    fun recordDownloaded(gif: Gif) {
        val cur = data.value
        val now = System.currentTimeMillis() / 1000.0
        val existed = cur.downloaded.any { it.id == gif.id }
        val next = cur.downloaded.filterNot { it.id == gif.id }.toMutableList()
        next.add(0, gif)
        val nextRemDl = cur.removedDownloadedIDs.toMutableMap().apply { remove(gif.id) }
        localAddedTimestamps["dl:${gif.id}"] = now
        data.value = cur.copy(downloaded = next, removedDownloadedIDs = nextRemDl)
        if (!existed) recordAlgorithmSignal(gif, 6.5)
        scheduleSave()
        LicenseManager.scheduleCloudSync()
    }

    fun removeDownloaded(id: String) {
        val cur = data.value
        val now = System.currentTimeMillis() / 1000.0
        val nextRemDl = cur.removedDownloadedIDs.toMutableMap().apply { put(id, now) }
        localAddedTimestamps.remove("dl:$id")
        data.value = cur.copy(
            downloaded = cur.downloaded.filterNot { it.id == id },
            removedDownloadedIDs = trimTombstones(nextRemDl)
        )
        scheduleSave()
        LicenseManager.scheduleCloudSync()
    }

    fun clearAllDownloaded() {
        val cur = data.value
        val now = System.currentTimeMillis() / 1000.0
        val nextRemDl = cur.removedDownloadedIDs.toMutableMap()
        for (g in cur.downloaded) {
            nextRemDl[g.id] = now
            localAddedTimestamps.remove("dl:${g.id}")
        }
        data.value = cur.copy(
            downloaded = emptyList(),
            removedDownloadedIDs = trimTombstones(nextRemDl)
        )
        saveNow()
        LicenseManager.scheduleCloudSync()
    }

    fun isFollowingUser(u: String): Boolean {
        val clean = u.trim().replace("@", "")
        return data.value.followedUsers.any { it.equals(clean, ignoreCase = true) }
    }

    fun toggleFollowUser(u: String) {
        val clean = u.trim().replace("@", "")
        if (clean.isEmpty()) return
        val cur = data.value
        val next = cur.followedUsers.toMutableList()
        val nextRem = cur.removedFollows.toMutableMap()
        val key = "u:${clean.lowercase()}"
        val now = System.currentTimeMillis() / 1000.0
        val idx = next.indexOfFirst { it.equals(clean, ignoreCase = true) }
        if (idx >= 0) {
            next.removeAt(idx)
            nextRem[key] = now
            localAddedTimestamps.remove("follow:$key")
        } else {
            next.add(0, clean)
            nextRem.remove(key)
            localAddedTimestamps["follow:$key"] = now
        }
        data.value = cur.copy(followedUsers = next, removedFollows = trimTombstones(nextRem))
        scheduleSave()
        LicenseManager.scheduleCloudSync()
    }

    fun isFollowingSubreddit(s: String): Boolean {
        val clean = s.trim().removePrefix("r/").removePrefix("R/")
        return data.value.followedSubreddits.any { it.equals(clean, ignoreCase = true) }
    }

    fun toggleFollowSubreddit(s: String) {
        val clean = s.trim().removePrefix("r/").removePrefix("R/")
        if (clean.isEmpty()) return
        val cur = data.value
        val next = cur.followedSubreddits.toMutableList()
        val nextRem = cur.removedFollows.toMutableMap()
        val key = "sub:${clean.lowercase()}"
        val now = System.currentTimeMillis() / 1000.0
        val idx = next.indexOfFirst { it.equals(clean, ignoreCase = true) }
        if (idx >= 0) {
            next.removeAt(idx)
            nextRem[key] = now
            localAddedTimestamps.remove("follow:$key")
        } else {
            next.add(0, clean)
            nextRem.remove(key)
            localAddedTimestamps["follow:$key"] = now
        }
        data.value = cur.copy(followedSubreddits = next, removedFollows = trimTombstones(nextRem))
        scheduleSave()
        LicenseManager.scheduleCloudSync()
    }

    fun isFollowingXUser(handle: String): Boolean {
        val clean = handle.trim().replace("@", "")
        return data.value.followedXUsers.any { it.equals(clean, ignoreCase = true) }
    }

    fun toggleFollowXUser(handle: String) {
        val clean = handle.trim().replace("@", "")
        if (clean.isEmpty()) return
        val cur = data.value
        val next = cur.followedXUsers.toMutableList()
        val nextRem = cur.removedFollows.toMutableMap()
        val key = "x:${clean.lowercase()}"
        val idx = next.indexOfFirst { it.equals(clean, ignoreCase = true) }
        val now = System.currentTimeMillis() / 1000.0
        val nowFollowing = if (idx >= 0) {
            next.removeAt(idx)
            nextRem[key] = now
            localAddedTimestamps.remove("follow:$key")
            false
        } else {
            next.add(0, clean)
            nextRem.remove(key)
            localAddedTimestamps["follow:$key"] = now
            true
        }
        data.value = cur.copy(followedXUsers = next, removedFollows = trimTombstones(nextRem))
        scheduleSave()
        LicenseManager.scheduleCloudSync()
        if (cur.xSession.isConnected) {
            scope.launch { XWebEngine.followUser(clean, nowFollowing) }
        }
    }

    fun isFollowingIGUser(handle: String): Boolean {
        val clean = handle.trim().replace("@", "")
        return data.value.followedIGUsers.any { it.equals(clean, ignoreCase = true) }
    }

    fun toggleFollowIGUser(handle: String) {
        val clean = handle.trim().replace("@", "")
        if (clean.isEmpty()) return
        val cur = data.value
        val next = cur.followedIGUsers.toMutableList()
        val nextRem = cur.removedFollows.toMutableMap()
        val key = "ig:${clean.lowercase()}"
        val idx = next.indexOfFirst { it.equals(clean, ignoreCase = true) }
        val now = System.currentTimeMillis() / 1000.0
        val nowFollowing = if (idx >= 0) {
            next.removeAt(idx)
            nextRem[key] = now
            localAddedTimestamps.remove("follow:$key")
            false
        } else {
            next.add(0, clean)
            nextRem.remove(key)
            localAddedTimestamps["follow:$key"] = now
            true
        }
        data.value = cur.copy(followedIGUsers = next, removedFollows = trimTombstones(nextRem))
        scheduleSave()
        LicenseManager.scheduleCloudSync()
        if (cur.igSession.isConnected) {
            scope.launch { InstagramWebEngine.followUser(clean, nowFollowing) }
        }
    }

    fun isFollowingOFCreator(id: String?, handle: String?): Boolean {
        val cleanH = handle?.trim()?.replace("@", "")
        return data.value.followedOFCreators.any {
            (!id.isNullOrEmpty() && it.id == id) || (!cleanH.isNullOrEmpty() && it.handle.equals(cleanH, ignoreCase = true))
        }
    }

    fun toggleFollowOFCreator(id: String, name: String, displayName: String? = null, avatarURL: String? = null) {
        val cleanName = name.trim().replace("@", "")
        if (id.isEmpty() && cleanName.isEmpty()) return
        val key = "of:${id.ifEmpty { cleanName }.lowercase()}"
        val now = System.currentTimeMillis() / 1000.0
        data.update { cur ->
            val next = cur.followedOFCreators.toMutableList()
            val nextRem = cur.removedFollows.toMutableMap()
            val idx = next.indexOfFirst { (id.isNotEmpty() && it.id == id) || it.handle.equals(cleanName, ignoreCase = true) }
            if (idx >= 0) {
                val removed = next.removeAt(idx)
                val remKey = "of:${removed.id.ifEmpty { removed.handle }.lowercase()}"
                nextRem[remKey] = now
                localAddedTimestamps.remove("follow:$remKey")
            } else {
                next.add(0, FollowedOFCreator(id, cleanName, displayName, avatarURL))
                nextRem.remove(key)
                localAddedTimestamps["follow:$key"] = now
            }
            cur.copy(followedOFCreators = next, removedFollows = trimTombstones(nextRem))
        }
        scheduleSave()
        LicenseManager.scheduleCloudSync()
    }

    fun updateSettings(transform: (AppSettings) -> AppSettings) {
        data.update { cur -> cur.copy(settings = transform(cur.settings)) }
        scheduleSave()
    }

    fun updateXSession(session: XAccountSession) {
        data.value = data.value.copy(xSession = session)
        saveNow()
        LicenseManager.scheduleCloudSync()
    }

    fun disconnectX() {
        data.value = data.value.copy(xSession = XAccountSession())
        XWebEngine.resetSession()
        saveNow()
        LicenseManager.scheduleCloudSync()
    }

    fun updateIGSession(session: InstagramAccountSession) {
        data.value = data.value.copy(igSession = session)
        saveNow()
        LicenseManager.scheduleCloudSync()
    }

    fun disconnectIG() {
        data.value = data.value.copy(igSession = InstagramAccountSession())
        InstagramWebEngine.resetSession()
        saveNow()
        LicenseManager.scheduleCloudSync()
    }

    fun updateRedditSession(session: RedditAccountSession) {
        data.value = data.value.copy(redditSession = session)
        saveNow()
        LicenseManager.scheduleCloudSync()
    }

    fun disconnectReddit() {
        data.value = data.value.copy(redditSession = RedditAccountSession())
        RedditPersonalAPI.clearCookies()
        saveNow()
        LicenseManager.scheduleCloudSync()
    }

    fun updateR34Credentials(creds: Rule34Credentials) {
        data.value = data.value.copy(r34Credentials = creds)
        saveNow()
        LicenseManager.scheduleCloudSync()
    }

    fun updateAlgorithm(transform: (AlgorithmProfile) -> AlgorithmProfile) {
        val cur = data.value
        data.value = cur.copy(algorithm = transform(cur.algorithm))
        saveNow()
        LicenseManager.scheduleCloudSync()
    }

    fun recordSwipe(kind: String, name: String, displayTitle: String, postID: String? = null) {
        if (!postID.isNullOrEmpty()) markSeen(postID)
        val cur = data.value
        val nextRecent = cur.recentFeeds.toMutableList()
        val idx = nextRecent.indexOfFirst { it.kind == kind && it.name.equals(name, ignoreCase = true) }
        val now = System.currentTimeMillis() / 1000.0
        if (idx >= 0) {
            val existing = nextRecent.removeAt(idx)
            nextRecent.add(0, existing.copy(swipedCount = existing.swipedCount + 1, updatedAt = now))
        } else {
            nextRecent.add(0, RecentFeedEntry(kind, name, displayTitle, 1, now))
        }
        data.value = cur.copy(swipedTotal = cur.swipedTotal + 1, recentFeeds = nextRecent.take(8))
        scheduleSave()
    }

    // Full iOS algorithm signal pipeline with 35-signal 0.92 decay, contrastive protection & videoPreference EMA
    fun recordAlgorithmSignal(post: Gif, weight: Double) {
        val cur = data.value
        if (!cur.settings.algorithmEnabled) return
        val cats = categories.value
        val algo = cur.algorithm
        var total = algo.totalSignals + 1
        var subW = algo.subredditWeights.toMutableMap()
        var creW = algo.creatorWeights.toMutableMap()
        var tagW = algo.tagWeights.toMutableMap()

        if (total % 35 == 0) {
            subW = subW.mapValues { (_, v) -> v * 0.92 }.filterValues { kotlin.math.abs(it) > 0.08 }.toMutableMap()
            creW = creW.mapValues { (_, v) -> v * 0.92 }.filterValues { kotlin.math.abs(it) > 0.08 }.toMutableMap()
            tagW = tagW.mapValues { (_, v) -> v * 0.92 }.filterValues { kotlin.math.abs(it) > 0.08 }.toMutableMap()
        }

        post.subreddit?.trim()?.lowercase()?.takeIf { it.isNotEmpty() && !MediaMetaRegistry.isStopTag(it) }?.let { sub ->
            subW[sub] = ((subW[sub] ?: 0.0) + weight).coerceIn(-12.0, 45.0)
        }
        post.author?.trim()?.lowercase()?.replace("@", "")?.takeIf { it.isNotEmpty() }?.let { author ->
            creW[author] = ((creW[author] ?: 0.0) + weight).coerceIn(-12.0, 45.0)
        }

        val tags = SmartTasteEngine.extractDirectTagsOnly(post, cats)
        val pinnedSet = algo.boostedTags.map { it.lowercase() }.toSet()
        for (t in tags) {
            if (weight < 0 && (t in pinnedSet || (tagW[t] ?: 0.0) >= 2.2)) continue // contrastive protection
            tagW[t] = ((tagW[t] ?: 0.0) + weight * 0.75).coerceIn(-12.0, 45.0)
        }

        val isVid = !post.isImage
        val alpha = if (weight > 0) 0.06 else 0.02
        val target = if (isVid) (if (weight > 0) 1.0 else 0.0) else (if (weight > 0) 0.0 else 1.0)
        val nextVidPref = (algo.videoPreference * (1.0 - alpha) + target * alpha).coerceIn(0.1, 0.95)

        data.value = cur.copy(
            algorithm = algo.copy(
                tagWeights = tagW,
                subredditWeights = subW,
                creatorWeights = creW,
                videoPreference = nextVidPref,
                totalSignals = total
            )
        )
        if (weight > 0) {
            SmartTasteEngine.shared.recordPositiveEngagement(post, weight, cats)
        }
        scheduleSave()
    }

    fun recordDwellSignal(post: Gif, secondsWatched: Double) {
        if (!data.value.settings.algorithmEnabled) return
        when {
            secondsWatched >= 9.0 -> recordAlgorithmSignal(post, 3.2)
            secondsWatched >= 3.8 -> recordAlgorithmSignal(post, 1.6)
            secondsWatched < 1.6 -> {
                recordAlgorithmSignal(post, -1.1)
                SmartTasteEngine.shared.recordFastSkip(post, categories.value)
            }
        }
    }

    fun recordLoopSignal(post: Gif) {
        if (!data.value.settings.algorithmEnabled) return
        recordAlgorithmSignal(post, 3.8)
    }

    fun recordSearchSignal(query: String) {
        if (!data.value.settings.algorithmEnabled) return
        val tags = PornTagCatalog.extractRecognizedTagsFromQuery(query)
        if (tags.isEmpty()) return
        val cur = data.value
        val tagW = cur.algorithm.tagWeights.toMutableMap()
        for (t in tags) tagW[t] = ((tagW[t] ?: 0.0) + 4.5).coerceIn(-12.0, 45.0)
        data.value = cur.copy(algorithm = cur.algorithm.copy(tagWeights = tagW))
        scheduleSave()
    }

    fun dislike(post: Gif): SmartTasteEngine.DislikeOutcome {
        markSeen(post)
        val outcome = SmartTasteEngine.shared.recordDislike(post, categories.value)
        recordAlgorithmSignal(post, -8.0)
        return outcome
    }

    fun isBlockedByAlgorithm(post: Gif): Boolean {
        if (SmartTasteEngine.shared.isDisliked(post)) return true
        if (!data.value.settings.algorithmEnabled) return false
        val algo = data.value.algorithm
        val cats = categories.value
        if (SmartTasteEngine.shared.isSuppressedInDiscovery(post, cats)) return true
        if (algo.blockedTags.isEmpty()) return false
        val blockedSet = algo.blockedTags.map { PornTagCatalog.normalize(it) }.toSet()
        val tags = SmartTasteEngine.extractDirectTagsOnly(post, cats)
        if (tags.any { it in blockedSet }) return true
        val hay = "${post.title ?: ""} ${post.subreddit ?: ""} ${post.author ?: ""}".lowercase()
        return blockedSet.any { b -> b.length >= 4 && hay.contains(b.replace("_", " ")) }
    }

    fun adjustLearnedTag(tag: String, delta: Double) {
        val clean = PornTagCatalog.normalize(tag)
        if (clean.isEmpty()) return
        updateAlgorithm { algo ->
            val nextW = algo.tagWeights.toMutableMap()
            nextW[clean] = ((nextW[clean] ?: 0.0) + delta).coerceIn(-12.0, 45.0)
            algo.copy(tagWeights = nextW)
        }
    }

    fun addBoostedTags(raw: String) {
        val tokens = raw.split(Regex("[\\s,]+")).map { PornTagCatalog.normalize(it) }
            .filter { it.isNotEmpty() && !MediaMetaRegistry.isStopTag(it) }
        if (tokens.isEmpty()) return
        updateAlgorithm { algo ->
            val nextBoost = (algo.boostedTags + tokens).distinct()
            val nextBlock = algo.blockedTags.filterNot { it in tokens }
            tokens.forEach { SmartTasteEngine.shared.unblockTag(it) }
            algo.copy(boostedTags = nextBoost, blockedTags = nextBlock)
        }
    }

    fun removeBoostedTag(tag: String) {
        val clean = PornTagCatalog.normalize(tag)
        updateAlgorithm { algo -> algo.copy(boostedTags = algo.boostedTags.filterNot { it.equals(clean, ignoreCase = true) }) }
    }

    fun addBlockedTags(raw: String) {
        val tokens = raw.split(Regex("[\\s,]+")).map { PornTagCatalog.normalize(it) }
            .filter { it.isNotEmpty() && !MediaMetaRegistry.isStopTag(it) }
        if (tokens.isEmpty()) return
        updateAlgorithm { algo ->
            val nextBlock = (algo.blockedTags + tokens).distinct()
            val nextBoost = algo.boostedTags.filterNot { it in tokens }
            tokens.forEach { SmartTasteEngine.shared.blockDislikedTag(it) }
            algo.copy(blockedTags = nextBlock, boostedTags = nextBoost)
        }
    }

    fun removeBlockedTag(tag: String) {
        val clean = PornTagCatalog.normalize(tag)
        SmartTasteEngine.shared.unblockTag(clean)
        updateAlgorithm { algo -> algo.copy(blockedTags = algo.blockedTags.filterNot { it.equals(clean, ignoreCase = true) }) }
    }

    fun removeLearnedTag(tag: String) {
        updateAlgorithm { algo -> algo.copy(tagWeights = algo.tagWeights - tag) }
    }

    fun removeLearnedSubreddit(sub: String) {
        updateAlgorithm { algo -> algo.copy(subredditWeights = algo.subredditWeights - sub) }
    }

    fun topAlgorithmTags(limit: Int = 12): List<Pair<String, Double>> =
        data.value.algorithm.tagWeights.entries
            .filter { it.value > 0.4 && !MediaMetaRegistry.isStopTag(it.key) }
            .sortedByDescending { it.value }
            .take(limit)
            .map { it.key to it.value }

    fun topAlgorithmSubredditEntries(limit: Int = 8): List<Pair<String, Double>> =
        data.value.algorithm.subredditWeights.entries
            .filter { it.value > 0.5 }
            .sortedByDescending { it.value }
            .take(limit)
            .map { it.key to it.value }

    fun topAlgorithmSubreddits(limit: Int = 6): List<String> =
        topAlgorithmSubredditEntries(limit).map { it.first }

    val topTasteSummary: String
        get() {
            val algo = data.value.algorithm
            val picks = (algo.boostedTags.take(3) + topAlgorithmTags(4).map { it.first }).distinct().take(4)
            return if (picks.isEmpty()) "Learning your taste as you watch & like"
            else "Tuned for: ${picks.joinToString(" · ") { "#$it" }}"
        }

    fun resetAlgorithm() {
        updateAlgorithm { AlgorithmProfile() }
        SmartTasteEngine.shared.reset()
    }

    fun scorePost(post: Gif): Double {
        val cur = data.value
        val algo = cur.algorithm
        val cats = categories.value
        val engine = SmartTasteEngine.shared
        var score = engine.scoreAdjustment(post, cats)

        val sub = post.subreddit?.trim()?.lowercase()
        if (!sub.isNullOrEmpty()) {
            score += (algo.subredditWeights[sub] ?: 0.0) * 1.4
            if (cur.followedSubreddits.any { it.equals(sub, ignoreCase = true) }) score += 3.5
        }
        val author = post.author?.trim()?.lowercase()?.replace("@", "")
        if (!author.isNullOrEmpty()) {
            score += (algo.creatorWeights[author] ?: 0.0) * 1.6
            if (cur.followedUsers.any { it.equals(author, ignoreCase = true) } ||
                cur.followedXUsers.any { it.equals(author, ignoreCase = true) } ||
                cur.followedIGUsers.any { it.equals(author, ignoreCase = true) } ||
                cur.followedOFCreators.any { it.handle.equals(author, ignoreCase = true) }
            ) score += 4.0
        }

        val tags = SmartTasteEngine.extractExtendedTags(post, cats)
        val boostedSet = algo.boostedTags.map { PornTagCatalog.normalize(it) }.toSet()
        val hay = "${post.title ?: ""} ${post.subreddit ?: ""} ${post.author ?: ""}".lowercase()
        var relatedSynergy = 0.0
        for (t in tags) {
            if (t in boostedSet) score += 48.0
            score += (algo.tagWeights[t] ?: 0.0) * 1.9
            PornTagCatalog.relatedTags[t]?.forEach { rel ->
                val rw = algo.tagWeights[rel] ?: 0.0
                if (rw >= 2.5) relatedSynergy += rw * 0.32
            }
        }
        for (b in boostedSet) {
            if (b !in tags && b.length >= 3 && hay.contains(b.replace("_", " "))) score += 48.0
        }
        score += minOf(7.0, relatedSynergy)

        if (!post.isImage) score += (algo.videoPreference - 0.5) * 4.0
        val up = post.upvotes ?: 0
        if (up > 1) score += minOf(2.2, log10(up.toDouble()) * 0.55)
        score += Random.nextDouble(-0.65, 0.65)
        return score
    }

    // Full iOS 75/25 Exploit-Explore ranking with jitter & blocked filtering
    fun rankWithAlgorithm(posts: List<Gif>): List<Gif> {
        val filtered = posts.filter { !isBlockedByAlgorithm(it) }
        if (!data.value.settings.algorithmEnabled || filtered.size <= 3) return filtered.shuffled()
        val cats = categories.value
        for (p in filtered) SmartTasteEngine.shared.ingestPostIntoCreatorGraph(p, cats, boost = 0.4)

        val scored = filtered.map { it to scorePost(it) }.sortedByDescending { it.second }.map { it.first }
        val exploitCut = maxOf(1, (scored.size * 3) / 4)
        val exploit = scored.take(exploitCut).toMutableList()
        val explore = scored.drop(exploitCut).shuffled().toMutableList()

        val result = mutableListOf<Gif>()
        var counter = 0
        while (exploit.isNotEmpty() || explore.isNotEmpty()) {
            val pickExplore = (counter % 4 == 3) && explore.isNotEmpty()
            if (pickExplore) result.add(explore.removeAt(0))
            else if (exploit.isNotEmpty()) result.add(exploit.removeAt(0))
            else result.add(explore.removeAt(0))
            counter++
        }
        return result
    }

    fun isEligibleAdultPost(post: Gif, source: FeedSource = FeedSource.ForYou): Boolean =
        AdultContentClassifier.isEligible(post, source, categories.value, this)

    fun replaceWithBackup(restored: UserData) {
        suppressSaveDueToDecryptError = false
        synchronized(seenList) {
            seenList.clear()
            seenList.addAll(restored.seenIDs)
            seenSet.clear()
            seenSet.addAll(restored.seenIDs)
        }
        val deduped = restored.copy(
            liked = restored.liked.distinctBy { it.id },
            downloaded = restored.downloaded.distinctBy { it.id }
        )
        data.value = sanitizeLoadedData(deduped)
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
        suppressSaveDueToDecryptError = false
        val cur = data.value
        val now = System.currentTimeMillis() / 1000.0
        val remLikes = cur.removedLikedIDs.toMutableMap()
        val remDl = cur.removedDownloadedIDs.toMutableMap()
        val remFollows = cur.removedFollows.toMutableMap()
        if (!options.keepLikes) {
            for (item in cur.liked) remLikes[item.id] = now
        }
        if (!options.keepOfflineVault) {
            for (item in cur.downloaded) remDl[item.id] = now
        }
        if (!options.keepFollowing) {
            for (u in cur.followedUsers) remFollows["u:${u.lowercase()}"] = now
            for (s in cur.followedSubreddits) remFollows["sub:${s.lowercase()}"] = now
            for (x in cur.followedXUsers) remFollows["x:${x.lowercase()}"] = now
            for (ig in cur.followedIGUsers) remFollows["ig:${ig.lowercase()}"] = now
            for (of in cur.followedOFCreators) remFollows["of:${of.id.ifEmpty { of.handle }.lowercase()}"] = now
        }
        localAddedTimestamps.clear()
        val fresh = UserData(
            liked = if (options.keepLikes) cur.liked else emptyList(),
            downloaded = if (options.keepOfflineVault) cur.downloaded else emptyList(),
            followedUsers = if (options.keepFollowing) cur.followedUsers else emptyList(),
            followedSubreddits = if (options.keepFollowing) cur.followedSubreddits else emptyList(),
            followedXUsers = if (options.keepFollowing) cur.followedXUsers else emptyList(),
            followedIGUsers = if (options.keepFollowing) cur.followedIGUsers else emptyList(),
            followedOFCreators = if (options.keepFollowing) cur.followedOFCreators else emptyList(),
            removedLikedIDs = trimTombstones(remLikes),
            removedDownloadedIDs = trimTombstones(remDl),
            removedFollows = trimTombstones(remFollows),
            xSession = if (options.keepAccounts) cur.xSession else XAccountSession(),
            igSession = if (options.keepAccounts) cur.igSession else InstagramAccountSession(),
            redditSession = if (options.keepAccounts) cur.redditSession else RedditAccountSession(),
            r34Credentials = if (options.keepAccounts) cur.r34Credentials else Rule34Credentials(),
            algorithm = if (options.keepAlgorithm) cur.algorithm else AlgorithmProfile(),
            settings = cur.settings
        )
        synchronized(seenList) {
            seenList.clear()
            seenSet.clear()
        }
        if (!options.keepAlgorithm) SmartTasteEngine.shared.reset()
        data.value = fresh
        if (!options.keepOfflineVault) OfflineManager.clearAllDownloads()
        if (!options.keepPasscode) AppState.removePasscodeKeepingData()

        val ctx = TinyTinyApplication.instance
        File(ctx.cacheDir, "FeedDiskCache").deleteRecursively()
        File(ctx.cacheDir, "http_cache").deleteRecursively()
        ctx.cacheDir.listFiles()?.forEach { if (it.name.startsWith("tt_")) it.deleteRecursively() }

        if (!options.keepAccounts) {
            withContext(Dispatchers.Main) {
                XWebEngine.resetSession()
                InstagramWebEngine.resetSession()
                RedditPersonalAPI.clearCookies()
                android.webkit.CookieManager.getInstance().removeAllCookies(null)
                android.webkit.CookieManager.getInstance().flush()
                WebStorage.getInstance().deleteAllData()
            }
        }
        saveNow()
    }
}

object AdultContentClassifier {
    val sfwBlockedSubreddits = setOf(
        "earthporn", "foodporn", "carporn", "fightporn", "spaceporn", "cityporn",
        "natureporn", "historyporn", "mapporn", "designporn", "roomporn", "houseporn",
        "powerwashingporn", "artporn", "movieporn", "abandonedporn", "architectureporn",
        "humanporn", "animalporn", "weatherporn", "botanicalporn", "mechanicalgifs",
        "gaming", "funny", "memes", "dankmemes", "videos", "pics", "news", "worldnews",
        "politics", "sports", "nba", "nfl", "soccer", "ufc", "mma", "formula1",
        "minecraft", "fortnitebr", "valorant", "leagueoflegends", "callofduty",
        "tiktokcringe", "publicfreakout", "nextfuckinglevel", "interestingasfuck",
        "damnthatsinteresting", "wholesomememes", "aww", "animals", "eyebleach",
        "teenagers", "livestreamfail", "cryptocurrency", "wallstreetbets", "stocks",
        "technology", "science", "askreddit", "movies", "television", "music", "hiphopheads"
    )

    val sfwBlockedTerms = listOf(
        "#nba", "#nfl", "#ufc", "#fifa", "#mlb", "#nhl", "#premierleague", "#championsleague",
        "#election", "#trump", "#biden", "#kamala", "#breakingnews", "#foxnews", "#cnn", "#msnbc",
        "#minecraft", "#roblox", "#valorant", "#warzone", "#esports", "#callofduty", "#fortnitebr",
        "#bitcoin", "#ethereum", "#crypto", "#stockmarket", "#forex", "#tradingview",
        "#recipe", "#cooking", "#baking", "#mealprep", "#workoutroutine", "#gymmotivation",
        "street fight", "knockout", "car crash", "dashcam", "bodycam", "police shooting",
        "press conference", "box score", "touchdown", "home run", "earnings report",
        "sponsored", "promoted", "airdrop", "giveaway", "retweet to win"
    )

    private val sfwIGNoise = listOf(
        "recipe", "cooking", "baby", "toddler", "kindergarten", "homework",
        "stock market", "real estate", "mortgage", "nfl", "nba", "premier league",
        "unboxing", "tech review", "sermon", "bible study", "tutorial", "coding",
        "excel", "tax", "insurance", "dentist", "minecraft", "fortnite",
        "politics", "election", "news", "weather forecast"
    )

    private val explicitAdultMarkers = listOf(
        "nsfw", "18+", "onlyfans", "fansly", "manyvids", "pornhub", "xvideos", "xhamster",
        "redgifs", "brazzers", "chaturbate", "camgirl", "xxx", "porn", "nude", "nudes",
        "lewd", "hentai", "rule34", "r34", "futanari", "femboy", "tgirl", "shemale",
        "ladyboy", "ebony", "milf", "anal", "blowjob", "deepthroat", "facefuck", "creampie",
        "cumshot", "cumslut", "gangbang", "threesome", "cuckold", "hotwife", "bdsm",
        "femdom", "pegging", "boobs", "tits", "pussy", "cock", "dick", "sucking",
        "riding", "doggystyle", "squirt", "orgasm", "masturbat", "nsfwtwt", "hornytwt",
        "lewdtok", "18plus", "uncensored", "goon", "gooned", "gooning", "edging",
        "fisting", "ahegao", "paizuri", "bukkake", "freeuse", "bimbo", "slut",
        "link in bio", "vip page", "full video", "dm for"
    )

    fun containsSFWBlockedTerm(text: String): Boolean {
        val lower = text.lowercase()
        return sfwBlockedTerms.any { it in lower }
    }

    fun hasExplicitAdultIndicators(text: String): Boolean {
        val lower = text.lowercase()
        if (explicitAdultMarkers.any { it in lower }) return true
        return PornTagCatalog.extractRecognizedTagsFromQuery(lower).isNotEmpty()
    }

    fun isEligibleXTweet(
        text: String,
        author: String,
        authorBio: String,
        possiblySensitive: Boolean,
        hasAdultWarning: Boolean,
        hasGraphicViolenceOnly: Boolean,
        routeKey: String = ""
    ): Boolean {
        if (hasGraphicViolenceOnly) return false
        val combined = "$text $author $authorBio"
        if (containsSFWBlockedTerm(combined)) return false
        return hasAdultWarning || possiblySensitive || hasExplicitAdultIndicators(combined)
    }

    fun isEligibleIGReel(caption: String, author: String, routeKey: String = ""): Boolean {
        val combined = "$caption $author".lowercase()
        if (containsSFWBlockedTerm(combined)) return false
        if (routeKey == "ig_following" || routeKey == "ig_saved" || routeKey.startsWith("ig_user_")) return true
        if (sfwIGNoise.any { it in combined }) return false
        return true
    }

    fun isEligible(post: Gif, source: FeedSource, categories: List<GoonedCategory>, store: UserStore): Boolean {
        if (!post.hasPlayableMedia) return false
        if (source.isList || source.isRedditPersonalFeed) return true
        val sub = (post.subreddit ?: "").lowercase()
        if (sub in sfwBlockedSubreddits) return false
        val combined = "${post.title ?: ""} ${post.author ?: ""} $sub"
        if (containsSFWBlockedTerm(combined)) return false
        if (post.isRule34Post || post.isXPost || post.isIGPost || post.isOnlyFansPost || post.isLongVideoPost) return true
        // Verify Reddit/Gooned posts are genuinely adult
        if (sub.contains("porn") || sub.contains("nsfw") || sub.contains("gonewild") ||
            sub.contains("hentai") || sub.contains("rule34") || sub.contains("xxx") ||
            sub.contains("sluts") || sub.contains("fetish") || sub.contains("goon")
        ) return true
        if ((post.mediaUrl ?: "").contains("redgifs.com", ignoreCase = true) ||
            (post.sourceUrl ?: "").contains("redgifs.com", ignoreCase = true)
        ) return true
        if (categories.any { cat -> cat.subreddits.any { it.equals(sub, ignoreCase = true) } }) return true
        return hasExplicitAdultIndicators(combined)
    }
}

object PornTagCatalog {
    val quickPickerCategories: List<Pair<String, List<String>>> = listOf(
        "Popular" to listOf("amateur", "asian", "latina", "ebony", "milf", "petite", "curvy", "goth", "redhead", "bbw", "pawg", "interracial"),
        "Actions" to listOf("blowjob", "anal", "creampie", "cumshot", "squirt", "hardcore", "pov", "threesome", "bdsm", "femdom", "deepthroat", "doggystyle"),
        "Animated" to listOf("hentai", "rule34", "ahegao", "futanari", "3d", "animated", "sound", "cosplay"),
        "Body & Vibes" to listOf("ass", "big_tits", "pussy", "solo", "toys", "public", "lesbian", "femboy", "trans_woman", "lingerie", "feet")
    )

    val canonicalTags: Set<String> = setOf(
        "amateur", "anal", "asian", "ass", "ahegao", "bbw", "bdsm", "big_ass", "big_cock",
        "big_tits", "bimbo", "blonde", "blowjob", "bondage", "boobs", "brunette", "bukkake",
        "camgirl", "chubby", "college", "cosplay", "couple", "creampie", "cuckold", "cumshot",
        "curvy", "deepthroat", "doggystyle", "dp", "ebony", "edging", "exhibitionist", "facefuck",
        "facial", "feet", "femboy", "femdom", "fisting", "footjob", "freeuse", "furry", "futanari",
        "gangbang", "gay", "goth", "group", "handjob", "hardcore", "hentai", "homemade", "hotwife",
        "indian", "interracial", "jav", "joi", "latina", "lesbian", "lingerie", "masturbation",
        "mature", "milf", "natural_tits", "nude", "office", "oiled", "orgasm", "orgy", "outdoor",
        "paizuri", "panties", "pawg", "pegging", "petite", "pierced", "pov", "pregnant", "public",
        "pussy", "redhead", "riding", "rimjob", "rough", "rule34", "selfie", "shemale", "shibari",
        "shower", "sissy", "small_tits", "solo", "sound", "spanking", "squirt", "stepmom",
        "stockings", "striptease", "tattooed", "tattoos", "tease", "threesome", "titfuck",
        "toys", "trans_woman", "uniform", "vintage", "voyeur", "yaoi", "3d", "animated"
    )

    val aliases: Map<String, String> = mapOf(
        "bj" to "blowjob", "oral" to "blowjob", "sucking" to "blowjob", "head" to "blowjob",
        "dt" to "deepthroat", "throatpie" to "deepthroat", "gagging" to "deepthroat",
        "booty" to "ass", "butt" to "ass", "buttocks" to "ass", "cake" to "ass",
        "bigass" to "big_ass", "phatass" to "big_ass", "fatass" to "big_ass", "hugeass" to "big_ass",
        "bigtits" to "big_tits", "bigboobs" to "big_tits", "busty" to "big_tits", "hugetits" to "big_tits", "stacked" to "big_tits",
        "tits" to "boobs", "titties" to "boobs", "breasts" to "boobs",
        "smalltits" to "small_tits", "ittybitty" to "small_tits", "flatchest" to "small_tits",
        "bbc" to "interracial", "bwc" to "big_cock", "bigdick" to "big_cock", "hung" to "big_cock",
        "redheads" to "redhead", "ginger" to "redhead",
        "trans" to "trans_woman", "tgirl" to "trans_woman", "transgirl" to "trans_woman", "transwoman" to "trans_woman", "mtf" to "trans_woman", "ladyboy" to "trans_woman",
        "futa" to "futanari", "dickgirl" to "futanari",
        "femboys" to "femboy", "trap" to "femboy", "traps" to "femboy", "crossdresser" to "femboy",
        "egirl" to "goth", "altgirl" to "goth", "emo" to "goth",
        "black" to "ebony", "blackgirl" to "ebony",
        "japanese" to "asian", "korean" to "asian", "chinese" to "asian",
        "mexican" to "latina", "colombian" to "latina", "brazilian" to "latina",
        "mommy" to "milf", "cougar" to "milf",
        "dildo" to "toys", "vibrator" to "toys", "buttplug" to "toys",
        "cum" to "cumshot", "jizz" to "cumshot", "load" to "cumshot",
        "squirting" to "squirt",
        "cowgirl" to "riding", "reversecowgirl" to "riding",
        "doggy" to "doggystyle", "frombehind" to "doggystyle",
        "tittyfuck" to "titfuck", "boobjob" to "titfuck",
        "fishnets" to "stockings", "thighhighs" to "stockings", "pantyhose" to "stockings", "nylons" to "stockings",
        "ffm" to "threesome", "mmf" to "threesome", "3some" to "threesome",
        "f4f" to "lesbian", "girlxgirl" to "lesbian", "sapphic" to "lesbian", "yuri" to "lesbian",
        "sfm" to "3d", "blender" to "3d",
        "r34" to "rule34", "anime" to "hentai", "ecchi" to "hentai", "doujin" to "hentai",
        "foot" to "feet", "soles" to "feet", "toes" to "feet",
        "tattoo" to "tattoos", "inked" to "tattoos", "alt" to "goth",
        "tiny" to "petite", "spinner" to "petite",
        "thick" to "curvy", "thicc" to "curvy", "slimthick" to "curvy",
        "bara" to "yaoi", "m4m" to "gay", "twink" to "gay"
    )

    val relatedTags: Map<String, List<String>> = mapOf(
        "blowjob" to listOf("deepthroat", "facefuck", "facial", "cumshot", "pov"),
        "anal" to listOf("ass", "big_ass", "doggystyle", "creampie", "hardcore"),
        "ass" to listOf("big_ass", "pawg", "doggystyle", "anal", "curvy"),
        "big_tits" to listOf("boobs", "titfuck", "paizuri", "milf", "curvy"),
        "creampie" to listOf("cumshot", "pussy", "breeding", "amateur", "homemade"),
        "hentai" to listOf("rule34", "ahegao", "futanari", "animated", "3d"),
        "rule34" to listOf("hentai", "3d", "animated", "ahegao", "futanari"),
        "femboy" to listOf("sissy", "trans_woman", "stockings", "lingerie", "anal"),
        "trans_woman" to listOf("femboy", "shemale", "futanari", "lingerie", "anal"),
        "goth" to listOf("tattoos", "pierced", "cosplay", "stockings", "femdom"),
        "cosplay" to listOf("goth", "hentai", "ahegao", "lingerie", "uniform"),
        "bdsm" to listOf("bondage", "femdom", "spanking", "shibari", "rough"),
        "milf" to listOf("mature", "big_tits", "curvy", "hotwife", "stepmom"),
        "asian" to listOf("jav", "petite", "cosplay", "schoolgirl", "amateur"),
        "latina" to listOf("big_ass", "curvy", "pawg", "amateur", "doggystyle"),
        "ebony" to listOf("big_ass", "curvy", "twerk", "interracial", "amateur"),
        "petite" to listOf("small_tits", "amateur", "asian", "pov", "riding"),
        "lesbian" to listOf("threesome", "toys", "squirt", "lingerie", "orgasm"),
        "amateur" to listOf("homemade", "pov", "couple", "creampie", "riding"),
        "feet" to listOf("footjob", "stockings", "femdom", "lingerie")
    )

    fun normalize(raw: String): String {
        val clean = raw.trim().lowercase().replace("#", "").replace("-", "_").replace(Regex("\\s+"), "_")
        return aliases[clean] ?: clean
    }

    fun extractRecognizedTagsFromQuery(query: String): List<String> {
        if (query.isBlank()) return emptyList()
        val lower = query.lowercase()
        val words = lower.split(Regex("[^a-z0-9_]+")).filter { it.length >= 2 }
        val out = mutableListOf<String>()
        val seen = mutableSetOf<String>()
        fun tryAdd(token: String) {
            val mapped = aliases[token] ?: token
            if (mapped in canonicalTags && seen.add(mapped)) out.add(mapped)
        }
        for (i in words.indices) {
            tryAdd(words[i])
            if (i + 1 < words.size) {
                tryAdd("${words[i]}_${words[i + 1]}")
                tryAdd("${words[i]}${words[i + 1]}")
            }
        }
        return out
    }

    fun displayTitle(tag: String): String =
        tag.replace("_", " ").split(" ").joinToString(" ") { w ->
            w.replaceFirstChar { if (it.isLowerCase()) it.titlecase() else it.toString() }
        }
}
