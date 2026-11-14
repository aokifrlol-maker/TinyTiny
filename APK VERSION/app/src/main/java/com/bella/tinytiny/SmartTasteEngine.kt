package com.bella.tinytiny

import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.io.File

@Serializable
data class TasteState(
    val dislikedIds: List<String> = emptyList(),
    val suppressedTags: List<String> = emptyList(),
    val suppressedCreators: List<String> = emptyList(),
    val hiddenOFGenders: List<String> = emptyList(),
    val tagPenalties: Map<String, Double> = emptyMap(),
    val tagDislikeCounts: Map<String, Int> = emptyMap(),
    val creatorLatentClusters: Map<String, Map<String, Double>> = emptyMap(),
    val creatorWatchStats: Map<String, Double> = emptyMap()
)

data class DislikeOutcome(
    val suppressedTag: String?,
    val autoBlocked: Boolean
)

object SmartTasteEngine {
    private val json = Json { ignoreUnknownKeys = true; encodeDefaults = true }
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private lateinit var tasteFile: File

    private val _state = MutableStateFlow(TasteState())
    val state = _state.asStateFlow()

    private val dislikedSet = HashSet<String>()
    private val suppressedTagSet = HashSet<String>()
    private val suppressedCreatorSet = HashSet<String>()
    private val sessionContextTags = HashMap<String, Double>()

    val protectedBroadTags = setOf(
        "ass", "boobs", "tits", "pussy", "cock", "dick", "cum", "cumshot", "sex",
        "nude", "naked", "girl", "woman", "female", "babe", "hot", "sexy", "cute",
        "amateur", "homemade", "solo", "pov", "masturbation", "orgasm", "riding",
        "doggystyle", "missionary", "cowgirl", "blowjob", "handjob", "creampie",
        "curvy", "thick", "petite", "blonde", "brunette", "redhead"
    )

    val immediateArchetypeTags = setOf(
        "gay", "men", "yaoi", "bara", "femboy", "trans", "trans_woman", "trans_man",
        "futanari", "nonbinary", "lesbian"
    )

    val mascMaleOnlyTags = setOf(
        "gay", "men", "m4m", "bara", "yaoi", "trans_man", "gaymen", "gaytwt", "gayporn"
    )

    val femboyOrTransRescueTags = setOf(
        "femboy", "sissy", "trap", "crossdresser", "crossdressing", "otokonoko", "josou",
        "boypussy", "bussy", "trans", "trans_woman", "tgirl", "shemale", "ladyboy", "mtf", "futanari", "futa"
    )

    private val nicheRules: List<Pair<String, List<String>>> = listOf(
        "femboy" to listOf("femboy", "femboys", "sissy", "trap", "bussy", "boypussy", "otokonoko", "crossdresser"),
        "trans_woman" to listOf("trans", "tgirl", "transgirl", "mtf", "shemale", "ladyboy", "ts"),
        "futanari" to listOf("futa", "futanari", "dickgirl"),
        "gay" to listOf("gay", "m4m", "gaymen", "gayporn", "gaytwt", "twink", "hunk", "dilf"),
        "yaoi" to listOf("yaoi", "bara", "bl"),
        "goth" to listOf("goth", "alt", "emo", "egirl"),
        "latina" to listOf("latina", "latin"),
        "asian" to listOf("asian", "japanese", "korean", "jav"),
        "ebony" to listOf("ebony", "blackgirl"),
        "cosplay" to listOf("cosplay", "cosplayer"),
        "hentai" to listOf("hentai", "anime", "rule34", "3d", "sfm"),
        "lesbian" to listOf("lesbian", "wlw", "yuri", "sapphic"),
        "bdsm" to listOf("bdsm", "bondage", "submissive", "shibari"),
        "femdom" to listOf("femdom", "domme", "mistress", "pegging"),
        "milf" to listOf("milf", "mommy", "mature", "cougar")
    )

    fun init(context: Context) {
        tasteFile = File(context.filesDir, "tinytiny_taste_v2.json")
        if (tasteFile.exists()) {
            runCatching {
                val loaded = json.decodeFromString<TasteState>(tasteFile.readText())
                _state.value = loaded
                dislikedSet.clear(); dislikedSet.addAll(loaded.dislikedIds)
                suppressedTagSet.clear(); suppressedTagSet.addAll(loaded.suppressedTags)
                suppressedCreatorSet.clear(); suppressedCreatorSet.addAll(loaded.suppressedCreators)
            }
        }
    }

    private fun save(next: TasteState) {
        _state.value = next
        scope.launch {
            if (::tasteFile.isInitialized) {
                runCatching { tasteFile.writeText(json.encodeToString(next)) }
            }
        }
    }

    fun resetAll() {
        dislikedSet.clear()
        suppressedTagSet.clear()
        suppressedCreatorSet.clear()
        sessionContextTags.clear()
        save(TasteState())
    }

    fun isDisliked(post: Gif): Boolean = dislikedSet.contains(post.id)

    fun extractTags(post: Gif, includeClusterFallback: Boolean = true): List<String> {
        val out = LinkedHashSet<String>()
        val regTags = MediaMetaRegistry.tags(post.id)
        out.addAll(regTags)

        val blob = listOfNotNull(post.title, post.subreddit, post.author, regTags.joinToString(" "))
            .joinToString(" ")
            .lowercase()
            .replace("#", " ")
        val words = blob.split(Regex("[^a-z0-9_]+")).filter { it.isNotBlank() }.toSet()

        for ((canonical, keywords) in nicheRules) {
            if (keywords.any { kw -> words.contains(kw) || (kw.length >= 5 && blob.contains(kw)) }) {
                out.add(canonical)
            }
        }

        if (includeClusterFallback) {
            val cKey = creatorClusterKey(post)
            if (cKey != null) {
                val cluster = _state.value.creatorLatentClusters[cKey]
                cluster?.entries?.sortedByDescending { it.value }?.take(3)?.forEach { out.add(it.key) }
            }
        }

        val isFemboyOrTrans = out.any { femboyOrTransRescueTags.contains(it) }
        val g = MediaMetaRegistry.creatorGender(post.id)?.lowercase()
        if (g == "man" && !isFemboyOrTrans) {
            out.add("gay"); out.add("men")
        } else if (g == "trans_woman") {
            out.add("trans"); out.add("trans_woman")
        }
        if (isFemboyOrTrans && !words.contains("gay") && !words.contains("yaoi") && !words.contains("m4m") && !words.contains("bara")) {
            out.remove("gay")
            out.remove("men")
        }
        return out.toList()
    }

    private fun creatorClusterKey(post: Gif): String? {
        val cid = post.onlyFansCreatorId
        if (!cid.isNullOrBlank()) return "of:${cid.lowercase()}"
        val author = post.author?.trim()?.lowercase()
        if (!author.isNullOrBlank() && author !in setOf("x_user", "instagram", "rule34", "eporner", "pornhub", "xhamster", "spankbang", "xvideos")) {
            return "creator:$author"
        }
        val sub = post.subreddit?.trim()?.lowercase()
        if (!sub.isNullOrBlank() && sub !in setOf("rule34.xxx", "onlyfans", "eporner", "pornhub", "xhamster", "spankbang", "xvideos")) {
            return "sub:$sub"
        }
        return null
    }

    fun ingestPost(post: Gif) {
        val direct = extractTags(post, includeClusterFallback = false).filter { !MediaMetaRegistry.isStopTag(it) }
        val cKey = creatorClusterKey(post) ?: return
        if (direct.isEmpty()) return
        val cur = _state.value
        val clusters = cur.creatorLatentClusters.toMutableMap()
        val entry = (clusters[cKey] ?: emptyMap()).toMutableMap()
        direct.forEach { t -> entry[t] = (entry[t] ?: 0.0) + 0.5 }
        clusters[cKey] = entry
        _state.value = cur.copy(creatorLatentClusters = clusters)
    }

    fun recordLike(post: Gif) {
        val tags = extractTags(post)
        tags.forEach { t -> sessionContextTags[t] = (sessionContextTags[t] ?: 0.0) + 1.0 }
        val cKey = creatorClusterKey(post)
        if (cKey != null) {
            val cur = _state.value
            val nextWatch = cur.creatorWatchStats.toMutableMap()
            nextWatch[cKey] = (nextWatch[cKey] ?: 0.0) + 2.0
            save(cur.copy(creatorWatchStats = nextWatch))
        }
    }

    fun recordWatch(post: Gif, seconds: Double) {
        if (seconds < 2.2) return
        val cKey = creatorClusterKey(post) ?: return
        val cur = _state.value
        val nextWatch = cur.creatorWatchStats.toMutableMap()
        nextWatch[cKey] = (nextWatch[cKey] ?: 0.0) + (seconds / 10.0).coerceIn(0.2, 1.5)
        save(cur.copy(creatorWatchStats = nextWatch))
    }

    fun recordDislike(post: Gif): DislikeOutcome {
        dislikedSet.add(post.id)
        val tags = extractTags(post).filter { !MediaMetaRegistry.isStopTag(it) }
        val cur = _state.value
        val nextCounts = cur.tagDislikeCounts.toMutableMap()
        val nextPenalties = cur.tagPenalties.toMutableMap()
        val nextSuppressed = cur.suppressedTags.toMutableList()
        val nextGenders = cur.hiddenOFGenders.toMutableList()
        var chosenTag: String? = null
        var autoBlocked = false

        val archetype = tags.firstOrNull { immediateArchetypeTags.contains(it) }
        if (archetype != null) {
            chosenTag = archetype
            autoBlocked = true
            if (!suppressedTagSet.contains(archetype)) {
                suppressedTagSet.add(archetype)
                nextSuppressed.add(archetype)
            }
            if (mascMaleOnlyTags.contains(archetype)) {
                if (!nextGenders.contains("man")) nextGenders.add("man")
                if (!nextGenders.contains("trans_man")) nextGenders.add("trans_man")
            }
        } else {
            val specific = tags.firstOrNull { !protectedBroadTags.contains(it) }
            if (specific != null) {
                chosenTag = specific
                val c = (nextCounts[specific] ?: 0) + 1
                nextCounts[specific] = c
                nextPenalties[specific] = (nextPenalties[specific] ?: 0.0) + 1.5
                if (c >= 2 && !suppressedTagSet.contains(specific)) {
                    suppressedTagSet.add(specific)
                    nextSuppressed.add(specific)
                    autoBlocked = true
                }
            }
        }

        val nextIds = (listOf(post.id) + cur.dislikedIds).distinct().take(1500)
        save(
            cur.copy(
                dislikedIds = nextIds,
                suppressedTags = nextSuppressed.distinct(),
                hiddenOFGenders = nextGenders.distinct(),
                tagDislikeCounts = nextCounts,
                tagPenalties = nextPenalties
            )
        )
        return DislikeOutcome(chosenTag, autoBlocked)
    }

    fun toggleArchetypeGuardrail(tag: String, block: Boolean) {
        val norm = tag.lowercase()
        val cur = _state.value
        val nextSuppressed = cur.suppressedTags.toMutableList()
        val nextGenders = cur.hiddenOFGenders.toMutableList()
        if (block) {
            if (!nextSuppressed.contains(norm)) nextSuppressed.add(norm)
            suppressedTagSet.add(norm)
            if (mascMaleOnlyTags.contains(norm)) {
                if (!nextGenders.contains("man")) nextGenders.add("man")
                if (!nextGenders.contains("trans_man")) nextGenders.add("trans_man")
            }
        } else {
            nextSuppressed.remove(norm)
            suppressedTagSet.remove(norm)
            if (mascMaleOnlyTags.contains(norm)) {
                nextGenders.remove("man")
                nextGenders.remove("trans_man")
            }
        }
        save(cur.copy(suppressedTags = nextSuppressed, hiddenOFGenders = nextGenders))
    }

    fun isBlocked(post: Gif, algo: AlgorithmProfile): Boolean {
        if (dislikedSet.contains(post.id)) return true
        val blocked = algo.blockedTags.map { it.lowercase() }.toSet() + suppressedTagSet
        if (blocked.isEmpty()) return false
        val postTags = extractTags(post).toSet()
        val pinned = algo.boostedTags.map { it.lowercase() }.toSet()
        for (b in blocked) {
            if (pinned.contains(b)) continue
            if (postTags.contains(b)) return true
        }
        return false
    }

    fun scorePost(post: Gif, algo: AlgorithmProfile): Double {
        var score = 0.0
        val tags = extractTags(post)
        val pinned = algo.boostedTags.map { it.lowercase() }.toSet()
        for (t in tags) {
            if (pinned.contains(t)) score += 3.2
            score += (algo.tagWeights[t] ?: 0.0) * 0.45
            score -= (_state.value.tagPenalties[t] ?: 0.0) * 0.8
            score += (sessionContextTags[t] ?: 0.0) * 0.3
        }
        post.author?.lowercase()?.let { a ->
            score += (algo.creatorWeights[a] ?: 0.0) * 0.8
        }
        post.subreddit?.lowercase()?.let { s ->
            score += (algo.subredditWeights[s] ?: 0.0) * 0.6
        }
        if (!post.isImage) score += 0.4
        return score
    }

    fun activeQueryTags(pinned: List<String>, blocked: List<String>, count: Int = 6): List<String> {
        val blockedLower = blocked.map { it.lowercase() }.toSet() + suppressedTagSet
        val out = LinkedHashSet<String>()
        for (p in pinned) {
            val clean = p.trim().lowercase().replace(" ", "_")
            if (clean.isNotBlank() && !blockedLower.contains(clean) && !MediaMetaRegistry.isStopTag(clean)) {
                out.add(clean)
                if (out.size >= count) return out.toList()
            }
        }
        UserStore.data.value.algorithm.tagWeights.entries
            .filter { it.value > 0.35 }
            .sortedByDescending { it.value }
            .forEach { (k, _) ->
                if (!blockedLower.contains(k) && !MediaMetaRegistry.isStopTag(k)) {
                    out.add(k)
                    if (out.size >= count) return out.toList()
                }
            }
        return out.toList()
    }

    fun topOnlyFansSeedHandles(limit: Int = 8): List<String> {
        val scores = HashMap<String, Double>()
        _state.value.creatorWatchStats.forEach { (raw, w) ->
            if (w > 0.3 && !raw.startsWith("r/") && !raw.startsWith("x:") && !raw.startsWith("ig:")) {
                val clean = raw.removePrefix("of:").trim()
                if (clean.isNotBlank() && !suppressedCreatorSet.contains(clean.lowercase())) {
                    scores[clean] = (scores[clean] ?: 0.0) + w
                }
            }
        }
        return scores.entries.sortedByDescending { it.value }.take(limit).map { it.key }
    }
}
