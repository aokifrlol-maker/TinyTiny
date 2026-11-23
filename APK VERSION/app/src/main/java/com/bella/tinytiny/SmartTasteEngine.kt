package com.bella.tinytiny

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.ExperimentalSerializationApi
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonNames
import java.io.File
import java.util.concurrent.ConcurrentHashMap

enum class SourcePlatform(val rawValue: String, val label: String) {
    REDDIT("reddit", "Reddit"),
    X("x", "𝕏"),
    IG("ig", "Instagram"),
    ONLYFANS("of", "OnlyFans"),
    RULE34("r34", "Rule34"),
    LONGVIDEO("lv", "Long Videos")
}

@OptIn(ExperimentalSerializationApi::class)
@Serializable
data class ForYouSourceSettings(
    @JsonNames("includeReddit") var enableReddit: Boolean = true,
    @JsonNames("includeX") var enableX: Boolean = true,
    @JsonNames("includeInstagram") var enableIG: Boolean = true,
    @JsonNames("includeOnlyFans") var enableOnlyFans: Boolean = true,
    var enableRule34: Boolean = true,
    var enableLongVideos: Boolean = false
)

@Serializable
data class TasteV2Data(
    var tagScores: MutableMap<String, Double> = mutableMapOf(),
    var creatorScores: MutableMap<String, Double> = mutableMapOf(),
    var platformScores: MutableMap<String, Double> = mutableMapOf(),
    var dislikedIDs: MutableList<String> = mutableListOf(),
    var dislikedMediaKeys: MutableList<String> = mutableListOf(),
    var dislikedSimilarityKeys: MutableList<String> = mutableListOf(),
    var seenSimilarityKeys: MutableList<String> = mutableListOf(),
    var suppressedTags: MutableList<String> = mutableListOf(),
    var suppressedCreators: MutableList<String> = mutableListOf(),
    var tagDislikeCounts: MutableMap<String, Int> = mutableMapOf(),
    var tagPenalties: MutableMap<String, Double> = mutableMapOf(),
    var hiddenOFGenders: MutableList<String> = mutableListOf(),
    var forYouSources: ForYouSourceSettings = ForYouSourceSettings()
)

class SmartTasteEngine private constructor() {
    companion object {
        val shared = SmartTasteEngine()
        private const val TASTE_FILENAME = "gooned_taste_v2.json"

        fun platform(post: Gif): SourcePlatform = when {
            post.isXPost -> SourcePlatform.X
            post.isIGPost -> SourcePlatform.IG
            post.isOnlyFansPost -> SourcePlatform.ONLYFANS
            post.isRule34Post -> SourcePlatform.RULE34
            post.isLongVideoPost -> SourcePlatform.LONGVIDEO
            else -> SourcePlatform.REDDIT
        }

        fun extractDirectTagsOnly(post: Gif, categories: List<GoonedCategory>): List<String> {
            val out = mutableListOf<String>()
            val seen = mutableSetOf<String>()
            fun add(raw: String) {
                val clean = raw.lowercase().trim().removePrefix("#")
                if (clean.length >= 2 && !MediaMetaRegistry.isStopTag(clean) && seen.add(clean)) {
                    out.add(clean)
                }
            }
            for (t in MediaMetaRegistry.tags(post.id)) add(t)
            val title = post.title ?: ""
            for (m in Regex("#([A-Za-z0-9_]+)").findAll(title)) add(m.groupValues[1])
            post.subreddit?.let { sub ->
                val lowerSub = sub.lowercase()
                add(lowerSub)
                categories.firstOrNull { cat -> cat.subreddits.any { it.equals(lowerSub, ignoreCase = true) } }
                    ?.let { add(it.name) }
            }
            return out
        }
    }

    data class DislikeOutcome(
        val primaryTag: String? = null,
        val autoBlockedTag: String? = null,
        val newlyHiddenGenders: List<String> = emptyList()
    )

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var saveJob: Job? = null

    val state = MutableStateFlow(TasteV2Data())
    private val dislikedIDSet = ConcurrentHashMap.newKeySet<String>()
    private val dislikedMediaSet = ConcurrentHashMap.newKeySet<String>()
    private val dislikedSimSet = ConcurrentHashMap.newKeySet<String>()
    private val seenSimSet = ConcurrentHashMap.newKeySet<String>()
    private val suppressedTagSet = ConcurrentHashMap.newKeySet<String>()
    private val suppressedCreatorSet = ConcurrentHashMap.newKeySet<String>()
    private val hiddenOFGenderSet = ConcurrentHashMap.newKeySet<String>()

    private val tasteFile: File
        get() = File(TinyTinyApplication.instance.filesDir, TASTE_FILENAME)

    init {
        val loaded = try {
            if (tasteFile.exists()) {
                CryptoBox.openCodable<TasteV2Data>(tasteFile.readBytes()) ?: TasteV2Data()
            } else TasteV2Data()
        } catch (_: Throwable) {
            TasteV2Data()
        }
        state.value = loaded
        rebuildSets()
    }

    private fun rebuildSets() {
        val s = state.value
        dislikedIDSet.clear(); dislikedIDSet.addAll(s.dislikedIDs)
        dislikedMediaSet.clear(); dislikedMediaSet.addAll(s.dislikedMediaKeys)
        dislikedSimSet.clear(); dislikedSimSet.addAll(s.dislikedSimilarityKeys)
        seenSimSet.clear(); seenSimSet.addAll(s.seenSimilarityKeys)
        suppressedTagSet.clear(); suppressedTagSet.addAll(s.suppressedTags.map { it.lowercase() })
        suppressedCreatorSet.clear(); suppressedCreatorSet.addAll(s.suppressedCreators.map { it.lowercase() })
        hiddenOFGenderSet.clear(); hiddenOFGenderSet.addAll(s.hiddenOFGenders.map { it.lowercase() })
    }

    private fun scheduleSave() {
        saveJob?.cancel()
        saveJob = scope.launch {
            delay(2000)
            saveNow()
        }
    }

    fun saveNow() {
        val snapshot = state.value
        val f = tasteFile
        scope.launch {
            CryptoBox.sealCodable(snapshot)?.let { bytes ->
                val tmp = File(f.parentFile, f.name + ".tmp")
                tmp.writeBytes(bytes)
                tmp.renameTo(f)
            }
        }
    }

    fun currentHiddenOFGendersCSV(): String? =
        if (hiddenOFGenderSet.isEmpty()) null else hiddenOFGenderSet.sorted().joinToString(",")

    fun hideOFGender(gender: String) {
        val g = gender.lowercase().trim()
        if (g.isEmpty()) return
        val s = state.value
        if (!s.hiddenOFGenders.any { it.equals(g, ignoreCase = true) }) {
            s.hiddenOFGenders.add(g)
            hiddenOFGenderSet.add(g)
            state.value = s.copy()
            scheduleSave()
        }
    }

    fun unhideOFGender(gender: String) {
        val g = gender.lowercase().trim()
        val s = state.value
        s.hiddenOFGenders.removeAll { it.equals(g, ignoreCase = true) }
        hiddenOFGenderSet.remove(g)
        state.value = s.copy()
        scheduleSave()
    }

    fun recordPositiveEngagement(post: Gif, intensity: Double, categories: List<GoonedCategory>) {
        val s = state.value
        val tags = extractDirectTagsOnly(post, categories)
        for (t in tags) {
            val k = t.lowercase()
            s.tagScores[k] = (s.tagScores[k] ?: 0.0) + (1.2 * intensity)
        }
        post.author?.lowercase()?.let { s.creatorScores[it] = (s.creatorScores[it] ?: 0.0) + (1.5 * intensity) }
        val p = platform(post).rawValue
        s.platformScores[p] = (s.platformScores[p] ?: 0.0) + (0.25 * intensity)
        scheduleSave()
    }

    fun recordFastSkip(post: Gif, categories: List<GoonedCategory>) {
        val s = state.value
        for (t in extractDirectTagsOnly(post, categories)) {
            val k = t.lowercase()
            s.tagScores[k] = (s.tagScores[k] ?: 0.0) - 0.35
        }
        scheduleSave()
    }

    fun isSeenOrDuplicate(post: Gif): Boolean {
        if (isDisliked(post)) return true
        val sim = post.contentSimilarityKey
        if (sim != null && seenSimSet.contains(sim)) return true
        return false
    }

    fun markSeenSimilarity(post: Gif) {
        val sim = post.contentSimilarityKey ?: return
        if (!seenSimSet.add(sim)) return
        val s = state.value
        s.seenSimilarityKeys.add(sim)
        if (s.seenSimilarityKeys.size > 6000) {
            val overflow = s.seenSimilarityKeys.size - 5000
            repeat(overflow) { seenSimSet.remove(s.seenSimilarityKeys.removeAt(0)) }
        }
        scheduleSave()
    }

    fun isDisliked(post: Gif): Boolean {
        if (dislikedIDSet.contains(post.id)) return true
        if (dislikedMediaSet.contains(post.canonicalDedupeKey)) return true
        val sim = post.contentSimilarityKey
        if (sim != null && dislikedSimSet.contains(sim)) return true
        return false
    }

    fun isSuppressedInDiscovery(post: Gif, categories: List<GoonedCategory>): Boolean {
        if (isDisliked(post)) return true
        post.author?.lowercase()?.let { if (suppressedCreatorSet.contains(it)) return true }
        val g = MediaMetaRegistry.creatorGender(post.id)?.lowercase()
        if (g != null && hiddenOFGenderSet.contains(g)) return true
        val tags = extractDirectTagsOnly(post, categories).map { it.lowercase() }
        if (tags.any { suppressedTagSet.contains(it) }) return true
        return false
    }

    fun recordDislike(post: Gif, categories: List<GoonedCategory>): DislikeOutcome {
        val s = state.value
        if (dislikedIDSet.add(post.id)) s.dislikedIDs.add(post.id)
        val mk = post.canonicalDedupeKey
        if (dislikedMediaSet.add(mk)) s.dislikedMediaKeys.add(mk)
        post.contentSimilarityKey?.let { if (dislikedSimSet.add(it)) s.dislikedSimilarityKeys.add(it) }
        post.author?.lowercase()?.let {
            s.creatorScores[it] = (s.creatorScores[it] ?: 0.0) - 4.0
        }
        val tags = extractDirectTagsOnly(post, categories)
        var autoBlocked: String? = null
        for (t in tags) {
            val k = t.lowercase()
            s.tagPenalties[k] = (s.tagPenalties[k] ?: 0.0) + 2.5
            val count = (s.tagDislikeCounts[k] ?: 0) + 1
            s.tagDislikeCounts[k] = count
            if (count >= 3 && !MediaMetaRegistry.isStopTag(k) && suppressedTagSet.add(k)) {
                s.suppressedTags.add(k)
                autoBlocked = k
            }
        }
        state.value = s.copy()
        scheduleSave()
        return DislikeOutcome(primaryTag = tags.firstOrNull(), autoBlockedTag = autoBlocked)
    }

    fun blockDislikedTag(tag: String): String {
        val clean = tag.lowercase().trim().removePrefix("#")
        if (clean.isEmpty()) return clean
        val s = state.value
        if (suppressedTagSet.add(clean)) s.suppressedTags.add(clean)
        state.value = s.copy()
        scheduleSave()
        return clean
    }

    fun unblockTag(tag: String) {
        val clean = tag.lowercase().trim().removePrefix("#")
        val s = state.value
        s.suppressedTags.removeAll { it.equals(clean, ignoreCase = true) }
        suppressedTagSet.remove(clean)
        state.value = s.copy()
        scheduleSave()
    }

    fun scoreAdjustment(post: Gif, categories: List<GoonedCategory>): Double {
        val s = state.value
        var score = s.platformScores[platform(post).rawValue] ?: 0.0
        post.author?.lowercase()?.let { score += (s.creatorScores[it] ?: 0.0) }
        for (t in extractDirectTagsOnly(post, categories)) {
            val k = t.lowercase()
            score += (s.tagScores[k] ?: 0.0) - (s.tagPenalties[k] ?: 0.0)
        }
        return score
    }

    fun activeQueryTags(pinned: List<String>, blocked: List<String>, count: Int = 6): List<String> {
        val blockedSet = (blocked.map { it.lowercase() } + suppressedTagSet).toSet()
        val out = mutableListOf<String>()
        for (p in pinned) {
            val clean = p.lowercase().trim()
            if (clean.isNotEmpty() && !MediaMetaRegistry.isStopTag(clean) && clean !in blockedSet && !out.contains(clean)) {
                out.add(clean)
            }
        }
        val ranked = state.value.tagScores.entries
            .filter { it.value > 0.5 && !MediaMetaRegistry.isStopTag(it.key) && it.key !in blockedSet }
            .sortedByDescending { it.value }
            .map { it.key }
        for (t in ranked) {
            if (out.size >= count) break
            if (!out.contains(t)) out.add(t)
        }
        return out.take(count)
    }

    fun topOnlyFansSeedHandles(limit: Int = 8): List<String> {
        val followed = UserStore.shared.data.value.followedOFCreators.map { it.name }.distinct()
        return followed.take(limit)
    }

    fun updateForYouSources(transform: (ForYouSourceSettings) -> ForYouSourceSettings) {
        val s = state.value
        state.value = s.copy(forYouSources = transform(s.forYouSources))
        scheduleSave()
    }

    fun applyImportedBackup(imported: TasteV2Data) {
        state.value = imported
        rebuildSets()
        saveNow()
    }

    fun reset() {
        state.value = TasteV2Data()
        rebuildSets()
        saveNow()
    }
}
