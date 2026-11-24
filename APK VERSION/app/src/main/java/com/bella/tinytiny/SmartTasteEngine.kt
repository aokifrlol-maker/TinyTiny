package com.bella.tinytiny

import android.content.Context
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

// Exact iOS rawValues: reddit, x, onlyfans, instagram, rule34, long
enum class SourcePlatform(val rawValue: String, val label: String) {
    REDDIT("reddit", "Reddit"),
    X("x", "𝕏"),
    ONLYFANS("onlyfans", "OnlyFans"),
    IG("instagram", "Instagram"),
    RULE34("rule34", "Rule34"),
    LONGVIDEO("long", "Long Videos")
}

// Exact iOS JSON keys (includeReddit, includeX, includeOnlyFans, includeInstagram) + legacy Android @JsonNames
@OptIn(ExperimentalSerializationApi::class)
@Serializable
data class ForYouSourceSettings(
    @JsonNames("enableReddit") val includeReddit: Boolean = true,
    @JsonNames("enableX") val includeX: Boolean = true,
    @JsonNames("enableOnlyFans") val includeOnlyFans: Boolean = true,
    @JsonNames("enableIG") val includeInstagram: Boolean = false,
    @JsonNames("enableRule34") val includeRule34: Boolean = false,
    @JsonNames("enableLongVideos") val includeLongVideos: Boolean = false
) {
    val enableReddit: Boolean get() = includeReddit
    val enableX: Boolean get() = includeX
    val enableOnlyFans: Boolean get() = includeOnlyFans
    val enableIG: Boolean get() = includeInstagram
    val enableRule34: Boolean get() = includeRule34
    val enableLongVideos: Boolean get() = includeLongVideos
}

// Exact iOS TasteV2Data schema (sourceSettings, sourceWeights, creatorLatentClusters, creatorWatchStats, negative tagPenalties)
@OptIn(ExperimentalSerializationApi::class)
@Serializable
data class TasteV2Data(
    @JsonNames("forYouSources") val sourceSettings: ForYouSourceSettings = ForYouSourceSettings(),
    val sourceWeights: Map<String, Double> = mapOf(
        "reddit" to 1.0,
        "x" to 1.0,
        "onlyfans" to 1.0,
        "instagram" to 0.75,
        "rule34" to 0.9,
        "long" to 0.95
    ),
    val creatorLatentClusters: Map<String, Map<String, Double>> = emptyMap(),
    val creatorWatchStats: Map<String, Double> = emptyMap(),
    val dislikedIDs: List<String> = emptyList(),
    val dislikedMediaKeys: List<String> = emptyList(),
    val dislikedSimilarityKeys: List<String> = emptyList(),
    val seenSimilarityKeys: List<String> = emptyList(),
    val suppressedTags: List<String> = emptyList(),
    val suppressedCreators: List<String> = emptyList(),
    val tagDislikeCounts: Map<String, Int> = emptyMap(),
    val tagPenalties: Map<String, Double> = emptyMap(),
    val hiddenOFGenders: List<String> = emptyList()
) {
    val forYouSources: ForYouSourceSettings get() = sourceSettings
}

class SmartTasteEngine private constructor() {
    companion object {
        val shared = SmartTasteEngine()
        private const val TASTE_FILENAME = "gooned_taste_v2.json"
        private const val HIDDEN_GENDERS_PREF = "tinytiny.of.hidden_genders.v1"

        private val genericAuthors = setOf(
            "x_user", "instagram", "rule34", "eporner", "pornhub", "xhamster", "spankbang", "xvideos", "erome"
        )

        val protectedBroadTags = setOf(
            "amateur", "ass", "big_ass", "big_tits", "boobs", "tits", "pussy", "cock", "dick",
            "blowjob", "anal", "creampie", "cumshot", "squirt", "hardcore", "pov", "solo",
            "masturbation", "toys", "lingerie", "stockings", "petite", "curvy", "thick", "pawg",
            "milf", "asian", "latina", "ebony", "redhead", "blonde", "brunette", "goth", "cosplay",
            "hentai", "animated", "3d", "sound", "public", "lesbian", "threesome", "bdsm"
        )

        val immediateArchetypeTags = setOf(
            "gay", "yaoi", "bara", "male_only", "males_only", "femboy", "trans_woman",
            "futanari", "furry", "vore", "scat"
        )

        val mascMaleOnlyTags = setOf(
            "gay", "yaoi", "bara", "male_only", "males_only", "men", "muscle_men", "bear", "twink"
        )

        val femboyOrTransRescueTags = setOf(
            "femboy", "femboys", "sissy", "trap", "traps", "crossdresser", "crossdressing",
            "ladyboy", "shemale", "trans", "transgender", "transwoman", "trans_woman",
            "transgirl", "mtf", "tgirl", "futa", "futanari"
        )

        // 18-niche orientation & archetype rules matching iOS
        private val extraOrientationAndNicheRules: List<Pair<String, List<String>>> = listOf(
            "femboy" to listOf("femboy", "femboys", "sissy", "sissies", "trap", "traps", "crossdresser", "boywife", "bussy"),
            "trans_woman" to listOf("transgirl", "transwoman", "trans woman", "tgirl", "shemale", "ladyboy", "mtf", "ts "),
            "futanari" to listOf("futa", "futanari", "dickgirl", "shemale hentai"),
            "gay" to listOf("gay", "gayporn", "gaysex", "m4m", "male_only", "males_only", "twink", "bara", "yaoi", "boyxboy"),
            "yaoi" to listOf("yaoi", "bara", "boys_love", "shounen_ai"),
            "lesbian" to listOf("lesbian", "sapphic", "yuri", "girlxgirl", "scissoring", "tribbing"),
            "goth" to listOf("goth", "egirl", "altgirl", "emo", "alt_girl", "bigtiddygoth"),
            "cosplay" to listOf("cosplay", "cosplayer", "lewdcosplay", "nsfwcosplay"),
            "hentai" to listOf("hentai", "ecchi", "ahegao", "doujin", "anime_porn", "waifu"),
            "3d" to listOf("sfm", "blender", "3d_hentai", "overwatch_porn", "daz3d"),
            "asian" to listOf("asian", "jav", "japanese", "korean", "chinese", "abg"),
            "latina" to listOf("latina", "colombian", "mexican", "brazilian", "cuban"),
            "ebony" to listOf("ebony", "blackgirl", "lightskin", "chocolate"),
            "milf" to listOf("milf", "mommy", "cougar", "mature", "stepmom"),
            "petite" to listOf("petite", "tiny", "spinner", "small_tits", "flat_chest"),
            "bbw" to listOf("bbw", "chubby", "ssbbw", "plussize", "curvy"),
            "bdsm" to listOf("bdsm", "bondage", "femdom", "domme", "submissive", "choking", "spanking", "shibari"),
            "feet" to listOf("feet", "footjob", "soles", "toes", "footfetish")
        )

        fun platform(post: Gif): SourcePlatform = when {
            post.isXPost -> SourcePlatform.X
            post.isIGPost -> SourcePlatform.IG
            post.isOnlyFansPost -> SourcePlatform.ONLYFANS
            post.isRule34Post -> SourcePlatform.RULE34
            post.isLongVideoPost -> SourcePlatform.LONGVIDEO
            else -> SourcePlatform.REDDIT
        }

        fun creatorClusterKey(post: Gif): String? {
            if (post.isOnlyFansPost) {
                val cid = post.onlyFansCreatorId
                if (!cid.isNullOrEmpty()) return "of:$cid"
            }
            val author = post.author?.trim()?.lowercase()?.replace("@", "")
            if (!author.isNullOrEmpty() && author !in genericAuthors) return "creator:$author"
            val sub = post.subreddit?.trim()?.lowercase()
            if (!sub.isNullOrEmpty() && !MediaMetaRegistry.isStopTag(sub)) return "sub:$sub"
            return null
        }

        fun extractDirectTagsOnly(post: Gif, categories: List<GoonedCategory>): List<String> {
            val out = mutableListOf<String>()
            val seen = mutableSetOf<String>()
            fun add(raw: String) {
                val norm = PornTagCatalog.normalize(raw)
                if (norm.length >= 2 && !MediaMetaRegistry.isStopTag(norm) && seen.add(norm)) {
                    out.add(norm)
                }
            }
            for (t in MediaMetaRegistry.tags(post.id, post.author)) add(t)
            val title = post.title ?: ""
            for (m in Regex("#([A-Za-z0-9_]+)").findAll(title)) add(m.groupValues[1])
            post.subreddit?.let { sub ->
                val lowerSub = sub.lowercase()
                add(lowerSub)
                categories.firstOrNull { cat -> cat.subreddits.any { it.equals(lowerSub, ignoreCase = true) } }
                    ?.let { add(it.name) }
            }
            val combined = "$title ${post.author ?: ""} ${post.subreddit ?: ""}".lowercase()
            for (t in PornTagCatalog.extractRecognizedTagsFromQuery(combined)) add(t)
            for ((canonical, keywords) in extraOrientationAndNicheRules) {
                if (keywords.any { kw ->
                        if (kw.length >= 5) combined.contains(kw)
                        else Regex("\\b${Regex.escape(kw.trim())}\\b").containsMatchIn(combined)
                    }
                ) {
                    add(canonical)
                }
            }
            // Gender-derived tag (with femboy/trans rescue)
            val gender = MediaMetaRegistry.creatorGender(post.id, post.author)?.lowercase()
            if (gender == "man") {
                val hasRescue = out.any { it in femboyOrTransRescueTags }
                if (!hasRescue) add("gay")
            }
            return out
        }

        fun extractExtendedTags(post: Gif, categories: List<GoonedCategory>): List<String> {
            val direct = extractDirectTagsOnly(post, categories).toMutableList()
            val seen = direct.toMutableSet()
            val cKey = creatorClusterKey(post)
            if (cKey != null) {
                val cluster = shared.state.value.creatorLatentClusters[cKey]
                if (!cluster.isNullOrEmpty()) {
                    for ((k, v) in cluster.entries.sortedByDescending { it.value }.take(6)) {
                        if (v >= 1.5 && seen.add(k)) direct.add(k)
                    }
                }
            }
            return direct
        }
    }

    data class DislikeOutcome(
        val primaryTag: String? = null,
        val autoSuppressedTag: String? = null,
        val newlyHiddenGenders: List<String> = emptyList()
    ) {
        val autoBlockedTag: String? get() = autoSuppressedTag
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var saveJob: Job? = null

    val state = MutableStateFlow(TasteV2Data())
    private val sessionContextTags = ConcurrentHashMap<String, Double>()

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
        state.value = sanitizeStopTags(loaded)
        rebuildSets()
        mirrorHiddenGendersToPrefs()
    }

    private fun sanitizeStopTags(raw: TasteV2Data): TasteV2Data {
        // Normalize any legacy Android positive tagPenalties to negative iOS sign convention!
        val fixedPenalties = raw.tagPenalties
            .filterKeys { !MediaMetaRegistry.isStopTag(it) }
            .mapValues { (_, v) -> if (v > 0.0) -v else v }
        val fixedSuppressed = raw.suppressedTags.filter { !MediaMetaRegistry.isStopTag(it) }.distinct()
        return raw.copy(tagPenalties = fixedPenalties, suppressedTags = fixedSuppressed)
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

    private fun mirrorHiddenGendersToPrefs() {
        try {
            TinyTinyApplication.instance
                .getSharedPreferences("tt_ui_prefs", Context.MODE_PRIVATE)
                .edit()
                .putString(HIDDEN_GENDERS_PREF, currentHiddenOFGendersCSV() ?: "")
                .apply()
        } catch (_: Throwable) {}
    }

    private fun scheduleSave() {
        saveJob?.cancel()
        saveJob = scope.launch {
            delay(1500)
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
                if (f.exists()) f.delete()
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
        if (s.hiddenOFGenders.none { it.equals(g, ignoreCase = true) }) {
            val next = s.hiddenOFGenders + g
            hiddenOFGenderSet.add(g)
            state.value = s.copy(hiddenOFGenders = next)
            mirrorHiddenGendersToPrefs()
            scheduleSave()
            LicenseManager.scheduleCloudSync()
        }
    }

    fun unhideOFGender(gender: String) {
        val g = gender.lowercase().trim()
        val s = state.value
        val next = s.hiddenOFGenders.filterNot { it.equals(g, ignoreCase = true) }
        hiddenOFGenderSet.remove(g)
        // Also unblock related archetype tags if unhiding men
        val nextSuppressed = if (g == "man") s.suppressedTags.filterNot { it in mascMaleOnlyTags } else s.suppressedTags
        if (g == "man") mascMaleOnlyTags.forEach { suppressedTagSet.remove(it) }
        state.value = s.copy(hiddenOFGenders = next, suppressedTags = nextSuppressed)
        mirrorHiddenGendersToPrefs()
        scheduleSave()
        LicenseManager.scheduleCloudSync()
    }

    fun ingestPostIntoCreatorGraph(post: Gif, categories: List<GoonedCategory>, boost: Double = 1.0) {
        val cKey = creatorClusterKey(post) ?: return
        val tags = extractDirectTagsOnly(post, categories)
        if (tags.isEmpty()) return
        val s = state.value
        val clusters = s.creatorLatentClusters.toMutableMap()
        val inner = (clusters[cKey] ?: emptyMap()).toMutableMap()
        for (t in tags) {
            inner[t] = minOf(25.0, (inner[t] ?: 0.0) + boost)
        }
        val trimmed = inner.entries.sortedByDescending { it.value }.take(16).associate { it.key to it.value }
        clusters[cKey] = trimmed
        if (clusters.size > 800) {
            val dropKeys = clusters.keys.take(clusters.size - 750)
            for (dk in dropKeys) clusters.remove(dk)
        }
        state.value = s.copy(creatorLatentClusters = clusters)
    }

    fun recordPositiveEngagement(post: Gif, intensity: Double, categories: List<GoonedCategory>) {
        val s = state.value
        val plat = platform(post).rawValue
        val nextWeights = s.sourceWeights.toMutableMap()
        nextWeights[plat] = minOf(2.4, (nextWeights[plat] ?: 1.0) + minOf(0.22, intensity * 0.03))

        // Decay rolling session context tags & add current post's tags
        val it = sessionContextTags.entries.iterator()
        while (it.hasNext()) {
            val e = it.next()
            val decayed = e.value * 0.88
            if (decayed <= 0.25) it.remove() else e.setValue(decayed)
        }
        val tags = extractDirectTagsOnly(post, categories)
        for (t in tags) {
            sessionContextTags[t] = minOf(15.0, (sessionContextTags[t] ?: 0.0) + intensity * 0.65)
        }

        // Update creatorWatchStats & SimClusters
        val nextWatch = s.creatorWatchStats.toMutableMap()
        val nextClusters = s.creatorLatentClusters.toMutableMap()
        val cKey = creatorClusterKey(post)
        if (cKey != null) {
            nextWatch[cKey] = minOf(50.0, (nextWatch[cKey] ?: 0.0) + intensity * 1.4)
            val inner = (nextClusters[cKey] ?: emptyMap()).toMutableMap()
            if (tags.isNotEmpty()) {
                for (t in tags) inner[t] = minOf(25.0, (inner[t] ?: 0.0) + intensity * 0.5)
            } else {
                // Tagless co-visitation transfer from rolling session context
                for ((st, sv) in sessionContextTags.entries.sortedByDescending { it.value }.take(5)) {
                    inner[st] = minOf(20.0, (inner[st] ?: 0.0) + sv * 0.45)
                }
            }
            nextClusters[cKey] = inner.entries.sortedByDescending { it.value }.take(16).associate { it.key to it.value }
        }

        state.value = s.copy(
            sourceWeights = nextWeights,
            creatorWatchStats = nextWatch,
            creatorLatentClusters = nextClusters
        )
        scheduleSave()
    }

    fun recordFastSkip(post: Gif, categories: List<GoonedCategory>) {
        val cKey = creatorClusterKey(post) ?: return
        val s = state.value
        val nextWatch = s.creatorWatchStats.toMutableMap()
        nextWatch[cKey] = maxOf(-18.0, (nextWatch[cKey] ?: 0.0) - 1.1)
        state.value = s.copy(creatorWatchStats = nextWatch)
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
        val next = s.seenSimilarityKeys.toMutableList()
        next.add(sim)
        if (next.size > 6000) {
            val overflow = next.size - 5000
            repeat(overflow) { seenSimSet.remove(next.removeAt(0)) }
        }
        state.value = s.copy(seenSimilarityKeys = next)
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
        val author = post.author?.trim()?.lowercase()?.replace("@", "")
        if (!author.isNullOrEmpty() && author !in genericAuthors && suppressedCreatorSet.contains(author)) return true

        val tags = extractDirectTagsOnly(post, categories)
        val hasRescue = tags.any { it in femboyOrTransRescueTags }

        val g = MediaMetaRegistry.creatorGender(post.id, post.author)?.lowercase()
        if (g != null && hiddenOFGenderSet.contains(g)) {
            if (!((g == "man" || g == "nonbinary") && hasRescue)) return true
        }
        if (tags.any { t -> suppressedTagSet.contains(t) && !(t in mascMaleOnlyTags && hasRescue) }) return true
        return false
    }

    private fun isUserLikedOrPinnedTag(tag: String): Boolean {
        val algo = UserStore.shared.data.value.algorithm
        if (algo.boostedTags.any { it.equals(tag, ignoreCase = true) }) return true
        if ((algo.tagWeights[tag] ?: 0.0) >= 2.2) return true
        return false
    }

    fun recordDislike(post: Gif, categories: List<GoonedCategory>): DislikeOutcome {
        val s = state.value
        val nextDislikedIds = s.dislikedIDs.toMutableList()
        if (dislikedIDSet.add(post.id)) nextDislikedIds.add(post.id)
        if (nextDislikedIds.size > 4000) {
            val drop = nextDislikedIds.size - 3500
            repeat(drop) { dislikedIDSet.remove(nextDislikedIds.removeAt(0)) }
        }

        val nextMediaKeys = s.dislikedMediaKeys.toMutableList()
        val mk = post.canonicalDedupeKey
        if (dislikedMediaSet.add(mk)) nextMediaKeys.add(mk)

        val nextSimKeys = s.dislikedSimilarityKeys.toMutableList()
        post.contentSimilarityKey?.let { if (dislikedSimSet.add(it)) nextSimKeys.add(it) }

        val nextSuppressedCreators = s.suppressedCreators.toMutableList()
        val nextWatch = s.creatorWatchStats.toMutableMap()
        val authorClean = post.author?.trim()?.lowercase()?.replace("@", "")
        if (!authorClean.isNullOrEmpty() && authorClean !in genericAuthors) {
            if (suppressedCreatorSet.add(authorClean)) nextSuppressedCreators.add(authorClean)
        }
        creatorClusterKey(post)?.let { nextWatch[it] = -30.0 }

        val plat = platform(post).rawValue
        val nextSourceWeights = s.sourceWeights.toMutableMap()
        nextSourceWeights[plat] = maxOf(0.35, (nextSourceWeights[plat] ?: 1.0) * 0.93)

        val tags = extractDirectTagsOnly(post, categories)
        val nextPenalties = s.tagPenalties.toMutableMap()
        val nextCounts = s.tagDislikeCounts.toMutableMap()
        val nextSuppressedTags = s.suppressedTags.toMutableList()
        var autoSuppressed: String? = null

        for (t in tags) {
            val k = t.lowercase()
            if (MediaMetaRegistry.isStopTag(k)) continue
            if (isUserLikedOrPinnedTag(k)) continue
            val isImmediate = k in immediateArchetypeTags
            val isProtected = k in protectedBroadTags
            nextPenalties[k] = (nextPenalties[k] ?: 0.0) - (if (isImmediate) 16.0 else 4.0)
            val count = (nextCounts[k] ?: 0) + 1
            nextCounts[k] = count
            val threshold = if (isImmediate) 1 else 2
            if (!isProtected && count >= threshold && suppressedTagSet.add(k)) {
                nextSuppressedTags.add(k)
                if (autoSuppressed == null) autoSuppressed = k
            }
        }

        val newlyHiddenGenders = mutableListOf<String>()
        val nextHiddenGenders = s.hiddenOFGenders.toMutableList()
        val g = MediaMetaRegistry.creatorGender(post.id, post.author)?.lowercase()
        if (g == "man" && !tags.any { it in femboyOrTransRescueTags } && !isUserLikedOrPinnedTag("gay")) {
            if (hiddenOFGenderSet.add("man")) {
                nextHiddenGenders.add("man")
                newlyHiddenGenders.add("man")
            }
        }

        state.value = s.copy(
            dislikedIDs = nextDislikedIds,
            dislikedMediaKeys = nextMediaKeys,
            dislikedSimilarityKeys = nextSimKeys,
            suppressedCreators = nextSuppressedCreators,
            creatorWatchStats = nextWatch,
            sourceWeights = nextSourceWeights,
            tagPenalties = nextPenalties,
            tagDislikeCounts = nextCounts,
            suppressedTags = nextSuppressedTags,
            hiddenOFGenders = nextHiddenGenders
        )
        if (newlyHiddenGenders.isNotEmpty()) mirrorHiddenGendersToPrefs()
        scheduleSave()
        LicenseManager.scheduleCloudSync()
        return DislikeOutcome(
            primaryTag = tags.firstOrNull { it !in protectedBroadTags } ?: tags.firstOrNull(),
            autoSuppressedTag = autoSuppressed,
            newlyHiddenGenders = newlyHiddenGenders
        )
    }

    fun applyCreatorDislikeResolution(creator: OFCreator): List<String> {
        val g = creator.gender?.lowercase()?.trim() ?: return emptyList()
        val tags = (creator.creatorTags ?: emptyList()).map { it.lowercase() }
        if (g == "man" && !tags.any { it in femboyOrTransRescueTags } && !isUserLikedOrPinnedTag("gay")) {
            hideOFGender("man")
            return listOf("man")
        }
        return emptyList()
    }

    fun blockDislikedTag(tag: String): String {
        val clean = PornTagCatalog.normalize(tag)
        if (clean.isEmpty() || MediaMetaRegistry.isStopTag(clean)) return clean
        val s = state.value
        val nextSup = if (suppressedTagSet.add(clean)) s.suppressedTags + clean else s.suppressedTags
        val nextPen = s.tagPenalties.toMutableMap().apply { put(clean, -45.0) }
        state.value = s.copy(suppressedTags = nextSup, tagPenalties = nextPen)
        scheduleSave()
        LicenseManager.scheduleCloudSync()
        return clean
    }

    fun unblockTag(tag: String) {
        val clean = PornTagCatalog.normalize(tag)
        val s = state.value
        suppressedTagSet.remove(clean)
        val nextSup = s.suppressedTags.filterNot { it.equals(clean, ignoreCase = true) }
        val nextPen = s.tagPenalties.toMutableMap().apply { remove(clean) }
        val nextCnt = s.tagDislikeCounts.toMutableMap().apply { remove(clean) }
        state.value = s.copy(suppressedTags = nextSup, tagPenalties = nextPen, tagDislikeCounts = nextCnt)
        scheduleSave()
        LicenseManager.scheduleCloudSync()
    }

    fun scoreAdjustment(post: Gif, categories: List<GoonedCategory>): Double {
        if (isDisliked(post)) return -1000.0
        val s = state.value
        var score = 0.0
        val tags = extractDirectTagsOnly(post, categories)
        for (t in tags) {
            score += (s.tagPenalties[t] ?: 0.0) // negative values added directly like iOS!
            if (suppressedTagSet.contains(t)) score -= 40.0
        }
        val cKey = creatorClusterKey(post)
        if (cKey != null) {
            score += (s.creatorWatchStats[cKey] ?: 0.0) * 1.35
            val cluster = s.creatorLatentClusters[cKey]
            if (!cluster.isNullOrEmpty()) {
                val userTagWeights = UserStore.shared.data.value.algorithm.tagWeights
                var clusterMatch = 0.0
                for ((ct, cw) in cluster) {
                    val uw = userTagWeights[ct] ?: 0.0
                    if (uw != 0.0) clusterMatch += (uw * minOf(1.0, cw / 5.0))
                }
                score += clusterMatch.coerceIn(-30.0, 24.0)
            }
        }
        val authorClean = post.author?.trim()?.lowercase()?.replace("@", "")
        if (!authorClean.isNullOrEmpty() && suppressedCreatorSet.contains(authorClean)) {
            score -= 35.0
        }
        val sw = s.sourceWeights[platform(post).rawValue] ?: 1.0
        score += (sw - 1.0) * 3.5
        return score
    }

    fun activeQueryTags(pinned: List<String>, blocked: List<String>, count: Int = 6): List<String> {
        val blockedSet = (blocked.map { it.lowercase() } + suppressedTagSet).toSet()
        val out = mutableListOf<String>()
        fun addIfOk(raw: String) {
            val clean = raw.lowercase().trim().replace(" ", "_")
            if (clean.isNotEmpty() && !MediaMetaRegistry.isStopTag(clean) && clean !in blockedSet && !out.contains(clean)) {
                out.add(clean)
            }
        }
        for (p in pinned) addIfOk(p)
        val algoWeights = UserStore.shared.data.value.algorithm.tagWeights
        for ((k, v) in algoWeights.entries.filter { it.value > 0.35 }.sortedByDescending { it.value }) {
            if (out.size >= count) break
            addIfOk(k)
        }
        for ((k, v) in sessionContextTags.entries.filter { it.value > 0.25 }.sortedByDescending { it.value }) {
            if (out.size >= count) break
            addIfOk(k)
        }
        return out.take(count)
    }

    fun topOnlyFansSeedHandles(limit: Int = 8): List<String> {
        val s = state.value
        val out = mutableListOf<String>()
        for ((k, v) in s.creatorWatchStats.entries.filter { it.key.startsWith("of:") && it.value > 0.3 }.sortedByDescending { it.value }) {
            val cid = k.removePrefix("of:")
            if (cid.isNotEmpty() && !out.contains(cid)) out.add(cid)
        }
        for (c in UserStore.shared.data.value.followedOFCreators) {
            if (c.id.isNotEmpty() && !out.contains(c.id)) out.add(c.id)
        }
        return out.take(limit)
    }

    fun updateForYouSources(transform: (ForYouSourceSettings) -> ForYouSourceSettings) {
        val s = state.value
        state.value = s.copy(sourceSettings = transform(s.sourceSettings))
        scheduleSave()
        LicenseManager.scheduleCloudSync()
    }

    fun applyImportedBackup(imported: TasteV2Data) {
        state.value = sanitizeStopTags(imported)
        rebuildSets()
        mirrorHiddenGendersToPrefs()
        saveNow()
    }

    fun reset() {
        sessionContextTags.clear()
        state.value = TasteV2Data()
        rebuildSets()
        mirrorHiddenGendersToPrefs()
        tasteFile.delete()
    }
}
