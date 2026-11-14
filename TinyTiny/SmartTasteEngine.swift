import Foundation
import SwiftUI
import UIKit
import Vision
import NaturalLanguage

enum SourcePlatform: String, Codable, CaseIterable, Identifiable {
    case reddit
    case x
    case onlyfans
    case instagram
    case rule34
    case long

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .reddit: return "Reddit"
        case .x: return "𝕏"
        case .onlyfans: return "OnlyFans"
        case .instagram: return "Instagram"
        case .rule34: return "Rule34"
        case .long: return "Long Videos"
        }
    }
}

struct ForYouSourceSettings: Codable, Equatable {
    var includeReddit: Bool = true
    var includeX: Bool = true
    var includeOnlyFans: Bool = true
    var includeInstagram: Bool = false
}

struct TasteV2Data: Codable {
    var dislikedIDs: [String] = []
    var dislikedMediaKeys: [String] = []
    var dislikedSimilarityKeys: [String] = []
    var seenSimilarityKeys: [String] = []
    var tagDislikeCounts: [String: Int] = [:]
    var suppressedTags: [String] = []
    var suppressedCreators: [String] = []
    var hiddenOFGenders: [String] = []
    var tagPenalties: [String: Double] = [:]
    var creatorLatentClusters: [String: [String: Double]] = [:]
    var creatorWatchStats: [String: Double] = [:]
    var positiveVisualPrints: [Data] = []
    var negativeVisualPrints: [Data] = []
    var sourceWeights: [String: Double] = [
        "reddit": 1.0,
        "x": 1.0,
        "onlyfans": 1.0,
        "instagram": 0.75,
        "rule34": 0.9,
        "long": 0.95
    ]
    var sourceSettings: ForYouSourceSettings = ForYouSourceSettings()

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        dislikedIDs = (try? c.decodeIfPresent([String].self, forKey: .dislikedIDs)) ?? []
        dislikedMediaKeys = (try? c.decodeIfPresent([String].self, forKey: .dislikedMediaKeys)) ?? []
        dislikedSimilarityKeys = (try? c.decodeIfPresent([String].self, forKey: .dislikedSimilarityKeys)) ?? []
        seenSimilarityKeys = (try? c.decodeIfPresent([String].self, forKey: .seenSimilarityKeys)) ?? []
        tagDislikeCounts = (try? c.decodeIfPresent([String: Int].self, forKey: .tagDislikeCounts)) ?? [:]
        suppressedTags = (try? c.decodeIfPresent([String].self, forKey: .suppressedTags)) ?? []
        suppressedCreators = (try? c.decodeIfPresent([String].self, forKey: .suppressedCreators)) ?? []
        hiddenOFGenders = (try? c.decodeIfPresent([String].self, forKey: .hiddenOFGenders)) ?? []
        tagPenalties = (try? c.decodeIfPresent([String: Double].self, forKey: .tagPenalties)) ?? [:]
        creatorLatentClusters = (try? c.decodeIfPresent([String: [String: Double]].self, forKey: .creatorLatentClusters)) ?? [:]
        creatorWatchStats = (try? c.decodeIfPresent([String: Double].self, forKey: .creatorWatchStats)) ?? [:]
        positiveVisualPrints = (try? c.decodeIfPresent([Data].self, forKey: .positiveVisualPrints)) ?? []
        negativeVisualPrints = (try? c.decodeIfPresent([Data].self, forKey: .negativeVisualPrints)) ?? []
        sourceWeights = (try? c.decodeIfPresent([String: Double].self, forKey: .sourceWeights)) ?? [
            "reddit": 1.0, "x": 1.0, "onlyfans": 1.0, "instagram": 0.75, "rule34": 0.9, "long": 0.95
        ]
        sourceSettings = (try? c.decodeIfPresent(ForYouSourceSettings.self, forKey: .sourceSettings)) ?? ForYouSourceSettings()
    }
}

// MARK: - On-Device Neural Visual FeaturePrint & Semantic Vector Engine (Vision + NaturalLanguage)

actor VisualTasteAnalyzer {
    static let shared = VisualTasteAnalyzer()

    private var positiveObs: [VNFeaturePrintObservation] = []
    private var negativeObs: [VNFeaturePrintObservation] = []
    private var postScoreCache: [String: Double] = [:]
    private var inFlightPosts = Set<String>()

    func hydrate(positiveData: [Data], negativeData: [Data]) {
        positiveObs = positiveData.compactMap {
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: $0)
        }
        negativeObs = negativeData.compactMap {
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: $0)
        }
    }

    func cachedScore(for postId: String) -> Double? {
        postScoreCache[postId]
    }

    func extractFeaturePrint(from image: UIImage) -> (obs: VNFeaturePrintObservation, data: Data)? {
        guard let cg = image.cgImage else { return nil }
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        let req = VNGenerateImageFeaturePrintRequest()
        do {
            try handler.perform([req])
            guard let obs = req.results?.first as? VNFeaturePrintObservation,
                  let archived = try? NSKeyedArchiver.archivedData(withRootObject: obs, requiringSecureCoding: true) else {
                return nil
            }
            return (obs, archived)
        } catch {
            return nil
        }
    }

    func registerPrototype(from image: UIImage, isPositive: Bool) -> Data? {
        guard let res = extractFeaturePrint(from: image) else { return nil }
        if isPositive {
            positiveObs.insert(res.obs, at: 0)
            if positiveObs.count > 24 { positiveObs.removeLast(positiveObs.count - 24) }
        } else {
            negativeObs.insert(res.obs, at: 0)
            if negativeObs.count > 16 { negativeObs.removeLast(negativeObs.count - 16) }
        }
        return res.data
    }

    func evaluateCandidate(postId: String, image: UIImage) -> Double {
        if let existing = postScoreCache[postId] { return existing }
        guard (!positiveObs.isEmpty || !negativeObs.isEmpty),
              let res = extractFeaturePrint(from: image) else {
            return 0
        }
        let obs = res.obs
        var bestPosSim: Double = 0
        for p in positiveObs {
            var dist: Float = 999
            if (try? obs.computeDistance(&dist, to: p)) != nil {
                // Vision feature print distance typically spans 0.0 (identical) to ~25.0
                let sim = max(0, 1.0 - Double(dist) / 18.0)
                if sim > bestPosSim { bestPosSim = sim }
            }
        }
        var bestNegSim: Double = 0
        for n in negativeObs {
            var dist: Float = 999
            if (try? obs.computeDistance(&dist, to: n)) != nil {
                let sim = max(0, 1.0 - Double(dist) / 18.0)
                if sim > bestNegSim { bestNegSim = sim }
            }
        }
        let score = (bestPosSim * 12.5) - (bestNegSim * 11.0)
        postScoreCache[postId] = score
        if postScoreCache.count > 1500, let k = postScoreCache.keys.first {
            postScoreCache.removeValue(forKey: k)
        }
        return score
    }
}

/// Instagram Reels / X-Grade Multi-Signal Recommendation Engine:
/// - SimClusters Creator & Community Graph (recommends tagless videos via creator cluster inheritance + co-visitation)
/// - Orthogonal Micro-Identity & Coupling Separation (never conflating Femboy / Trans / Futa with Masc Gay / Yaoi)
/// - Contrastive Dislike Learning (protects tags/identities the user already likes while suppressing only the disliked dimension)
/// - On-Device Neural Vision FeaturePrint & NaturalLanguage Semantic Matching
@MainActor
final class SmartTasteEngine: ObservableObject {
    static let shared = SmartTasteEngine()

    @Published var state: TasteV2Data {
        didSet { scheduleSave() }
    }

    private static let hiddenOFGendersDefaultsKey = "tinytiny.of.hidden_genders.v1"

    nonisolated static var currentHiddenOFGenders: [String] {
        UserDefaults.standard.stringArray(forKey: hiddenOFGendersDefaultsKey) ?? []
    }

    nonisolated static var currentHiddenOFGendersCSV: String? {
        let list = currentHiddenOFGenders
        return list.isEmpty ? nil : list.joined(separator: ",")
    }

    private var dislikedIDSet = Set<String>()
    private var dislikedMediaSet = Set<String>()
    private var dislikedSimSet = Set<String>()
    private var seenSimSet = Set<String>()
    private var suppressedTagSet = Set<String>()
    private var suppressedCreatorSet = Set<String>()
    private var hiddenOFGenderSet = Set<String>()
    private var visualScoreMirror: [String: Double] = [:]
    private var sessionContextTags: [String: Double] = [:] // Rolling co-visitation vector for tagless videos
    private var saveTask: Task<Void, Never>?

    /// Broad anatomical / generic descriptors that can shift ranking weight slightly
    /// but must NEVER be auto-blocked by pressing Dislike on a video.
    static let protectedBroadTags: Set<String> = [
        "ass", "boobs", "tits", "pussy", "cock", "dick", "cum", "cumshot", "sex",
        "nude", "naked", "girl", "woman", "female", "babe", "hot", "sexy", "cute",
        "amateur", "homemade", "solo", "pov", "masturbation", "orgasm", "riding",
        "doggystyle", "missionary", "cowgirl", "blowjob", "handjob", "creampie",
        "curvy", "thick", "petite", "blonde", "brunette", "redhead", "big_tits",
        "natural_tits", "lingerie", "stockings", "thigh_highs"
    ]

    /// Distinct identity / coupling archetypes treated orthogonally so liking `femboy`, `trans`, or `futanari`
    /// never cross-contaminates with `gay` (Masc M/M) or `yaoi` / `bara`.
    static let immediateArchetypeTags: Set<String> = [
        "gay", "men", "yaoi", "bara", "femboy", "trans", "trans_woman", "trans_man",
        "futanari", "nonbinary", "lesbian"
    ]

    static let mascMaleOnlyTags: Set<String> = [
        "gay", "men", "m4m", "bara", "yaoi", "trans_man", "gaymen", "gaytwt", "gayporn"
    ]

    static let femboyOrTransRescueTags: Set<String> = [
        "femboy", "sissy", "trap", "crossdresser", "crossdressing", "otokonoko", "josou",
        "boypussy", "bussy", "trans", "trans_woman", "tgirl", "shemale", "ladyboy", "mtf", "futanari", "futa"
    ]

    private static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("gooned_taste_v2.json")
    }

    private init() {
        if let raw = try? Data(contentsOf: Self.fileURL),
           let decoded = try? JSONDecoder().decode(TasteV2Data.self, from: raw) {
            self.state = decoded
        } else {
            self.state = TasteV2Data()
        }
        sanitizeStopTagsFromState()
        rebuildSets()
        let pos = state.positiveVisualPrints
        let neg = state.negativeVisualPrints
        Task.detached(priority: .utility) {
            await VisualTasteAnalyzer.shared.hydrate(positiveData: pos, negativeData: neg)
        }
    }

    /// Cleans out any previously polluted stop-tags (like `#onlyfans`, `#rule34`, `#ass`) from auto-suppressed lists.
    private func sanitizeStopTagsFromState() {
        state.suppressedTags.removeAll { MediaMetaRegistry.isStopTag($0) || Self.protectedBroadTags.contains($0.lowercased()) }
        for k in state.tagPenalties.keys where MediaMetaRegistry.isStopTag(k) {
            state.tagPenalties.removeValue(forKey: k)
        }
        for k in state.tagDislikeCounts.keys where MediaMetaRegistry.isStopTag(k) {
            state.tagDislikeCounts.removeValue(forKey: k)
        }
    }

    private func rebuildSets() {
        dislikedIDSet = Set(state.dislikedIDs)
        dislikedMediaSet = Set(state.dislikedMediaKeys)
        dislikedSimSet = Set(state.dislikedSimilarityKeys)
        seenSimSet = Set(state.seenSimilarityKeys)
        suppressedTagSet = Set(state.suppressedTags.map { $0.lowercased() }.filter { !MediaMetaRegistry.isStopTag($0) })
        suppressedCreatorSet = Set(state.suppressedCreators.map { $0.lowercased() })
        let normGenders = Array(Set(state.hiddenOFGenders.map { $0.lowercased() })).sorted()
        hiddenOFGenderSet = Set(normGenders)
        UserDefaults.standard.set(normGenders, forKey: Self.hiddenOFGendersDefaultsKey)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: Self.fileURL, options: [.atomic, .completeFileProtection])
        }
    }

    // MARK: - Platform Classification

    nonisolated static func platform(for post: Gif) -> SourcePlatform {
        if post.isLongVideoPost { return .long }
        if post.isOnlyFansPost { return .onlyfans }
        if post.isXPost { return .x }
        if post.isIGPost { return .instagram }
        if post.isRule34Post { return .rule34 }
        return .reddit
    }

    // MARK: - Creator Latent Cluster Graph (`SimClusters` Co-Visitation for Tagless Videos)

    private static func creatorClusterKey(for post: Gif) -> String? {
        if let cid = post.onlyFansCreatorId ?? MediaMetaRegistry.creatorId(for: post.id), !cid.isEmpty {
            return "of:\(cid.lowercased())"
        }
        if let author = post.author?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !author.isEmpty,
           !["x_user", "instagram", "rule34", "eporner", "pornhub", "xhamster", "spankbang", "xvideos"].contains(author) {
            return "creator:\(author)"
        }
        if let sub = post.subreddit?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !sub.isEmpty,
           !["rule34.xxx", "onlyfans", "eporner", "pornhub", "xhamster", "spankbang", "xvideos"].contains(sub) {
            return "sub:\(sub)"
        }
        return nil
    }

    /// Observes a post's metadata and updates its creator's latent cluster vector so future tagless posts
    /// from the same creator or co-engaged cluster automatically inherit those taste dimensions.
    func ingestPostIntoCreatorGraph(_ post: Gif, categories: [GoonedCategory]) {
        guard let cKey = Self.creatorClusterKey(for: post) else { return }
        let directTags = Self.extractDirectTagsOnly(from: post, categories: categories)
        guard !directTags.isEmpty else { return }
        var cluster = state.creatorLatentClusters[cKey] ?? [:]
        for tag in directTags where !MediaMetaRegistry.isStopTag(tag) {
            cluster[tag] = min(25.0, (cluster[tag] ?? 0) + 1.0)
        }
        if cluster.count > 16 {
            let top = cluster.sorted { $0.value > $1.value }.prefix(16)
            cluster = Dictionary(uniqueKeysWithValues: top.map { ($0.key, $0.value) })
        }
        state.creatorLatentClusters[cKey] = cluster
        if state.creatorLatentClusters.count > 800, let oldest = state.creatorLatentClusters.keys.first {
            state.creatorLatentClusters.removeValue(forKey: oldest)
        }
    }

    /// Called when the user positively engages (Like, Loop, Full Watch >= 8s, Bookmark, Download).
    /// Performs Co-Visitation transfer onto tagless posts & extracts Neural Vision FeaturePrint prototype.
    func recordPositiveEngagement(for post: Gif, intensity: Double, categories: [GoonedCategory]) {
        recordPositivePlatformSignal(post, boost: min(0.22, intensity * 0.03))
        let directTags = Self.extractDirectTagsOnly(from: post, categories: categories)

        // Decay rolling session context vector slightly, then inject current post's tags
        sessionContextTags = sessionContextTags.mapValues { $0 * 0.88 }.filter { $0.value > 0.25 }
        for t in directTags where !MediaMetaRegistry.isStopTag(t) {
            sessionContextTags[t] = min(15.0, (sessionContextTags[t] ?? 0) + intensity)
        }

        if let cKey = Self.creatorClusterKey(for: post) {
            state.creatorWatchStats[cKey] = min(50.0, (state.creatorWatchStats[cKey] ?? 0) + intensity * 1.4)
            var cluster = state.creatorLatentClusters[cKey] ?? [:]
            if !directTags.isEmpty {
                for t in directTags where !MediaMetaRegistry.isStopTag(t) {
                    cluster[t] = min(30.0, (cluster[t] ?? 0) + intensity * 0.9)
                }
            } else if !sessionContextTags.isEmpty {
                // TAGLESS VIDEO CO-VISITATION: bind active session taste vector to this tagless creator!
                for (sTag, sWeight) in sessionContextTags.sorted(by: { $0.value > $1.value }).prefix(5) {
                    cluster[sTag] = min(20.0, (cluster[sTag] ?? 0) + min(intensity, sWeight) * 0.45)
                }
            }
            state.creatorLatentClusters[cKey] = cluster
        }

        // Register positive Visual FeaturePrint prototype from thumbnail in background
        if intensity >= 2.2, let thumbURL = post.thumbURL ?? post.posterURL {
            captureVisualPrototype(postId: post.id, thumbURL: thumbURL, isPositive: true)
        }
    }

    func recordFastSkip(for post: Gif, categories: [GoonedCategory]) {
        if let cKey = Self.creatorClusterKey(for: post) {
            let cur = state.creatorWatchStats[cKey] ?? 0
            state.creatorWatchStats[cKey] = max(-18.0, cur - 1.1)
        }
    }

    private func captureVisualPrototype(postId: String, thumbURL: URL, isPositive: Bool) {
        Task {
            let img: UIImage?
            if let cached = MediaImageLoader.shared.cached(thumbURL) {
                img = cached
            } else {
                img = await MediaImageLoader.shared.load(thumbURL)
            }
            guard let img else { return }
            if let archived = await VisualTasteAnalyzer.shared.registerPrototype(from: img, isPositive: isPositive) {
                if isPositive {
                    state.positiveVisualPrints.insert(archived, at: 0)
                    if state.positiveVisualPrints.count > 24 {
                        state.positiveVisualPrints.removeLast(state.positiveVisualPrints.count - 24)
                    }
                } else {
                    state.negativeVisualPrints.insert(archived, at: 0)
                    if state.negativeVisualPrints.count > 16 {
                        state.negativeVisualPrints.removeLast(state.negativeVisualPrints.count - 16)
                    }
                }
            }
        }
    }

    /// Pre-evaluates visual feature-print similarity for a batch of candidate posts in background.
    func precomputeVisualSimilarity(for posts: [Gif]) {
        guard !state.positiveVisualPrints.isEmpty || !state.negativeVisualPrints.isEmpty else { return }
        for post in posts.prefix(16) {
            guard visualScoreMirror[post.id] == nil,
                  let thumbURL = post.thumbURL ?? post.posterURL else { continue }
            let pid = post.id
            Task {
                let img: UIImage?
                if let cached = MediaImageLoader.shared.cached(thumbURL) {
                    img = cached
                } else {
                    img = await MediaImageLoader.shared.load(thumbURL)
                }
                guard let img else { return }
                let s = await VisualTasteAnalyzer.shared.evaluateCandidate(postId: pid, image: img)
                self.visualScoreMirror[pid] = s
            }
        }
    }

    // MARK: - Fuzzy Similarity & Seen Deduplication

    func isSeenOrDuplicate(_ post: Gif) -> Bool {
        if isDisliked(post) { return true }
        if let sim = post.contentSimilarityKey, seenSimSet.contains(sim) {
            return true
        }
        return false
    }

    func markSeenSimilarity(_ post: Gif) {
        guard let sim = post.contentSimilarityKey, seenSimSet.insert(sim).inserted else { return }
        state.seenSimilarityKeys.append(sim)
        if state.seenSimilarityKeys.count > 6000 {
            let drop = state.seenSimilarityKeys.count - 5000
            for k in state.seenSimilarityKeys.prefix(drop) { seenSimSet.remove(k) }
            state.seenSimilarityKeys.removeFirst(drop)
        }
    }

    // MARK: - Dislike / "Not Interested" Contrastive Learning & Orthogonal Suppression

    func isDisliked(_ post: Gif) -> Bool {
        if dislikedIDSet.contains(post.id) { return true }
        if dislikedMediaSet.contains(post.canonicalDedupeKey) { return true }
        if let sim = post.contentSimilarityKey, dislikedSimSet.contains(sim) { return true }
        return false
    }

    /// Checks whether the user has positive affinity for a tag/archetype (via Likes, Watch Time, or Pinned Tags).
    /// Protected tags are NEVER auto-blocked or penalized when the user dislikes a mixed-tag video.
    func isUserLikedOrPinnedTag(_ tag: String) -> Bool {
        let lower = tag.lowercased()
        let algo = UserStore.shared.data.algorithm
        if algo.boostedTags.contains(where: { $0.caseInsensitiveCompare(lower) == .orderedSame }) {
            return true
        }
        if (algo.tagWeights[lower] ?? 0) >= 2.2 {
            return true
        }
        return false
    }

    func isSuppressedInDiscovery(_ post: Gif, categories: [GoonedCategory]) -> Bool {
        if isDisliked(post) { return true }
        if let author = post.author?.lowercased(), !author.isEmpty,
           !["x_user", "instagram", "rule34", "eporner", "pornhub", "xhamster", "spankbang", "xvideos"].contains(author),
           suppressedCreatorSet.contains(author) {
            return true
        }

        let tags = Set(Self.extractExtendedTags(from: post, categories: categories).map { $0.lowercased() })
        let hasFemboyOrTransRescue = !tags.isDisjoint(with: Self.femboyOrTransRescueTags)

        // Check creator gender on OnlyFans / cum.st, WITH Femboy/Trans cross-protection:
        // If `man` is hidden because the user disliked Masc Gay (M/M), do NOT suppress a post
        // that is actually Femboy or Trans Woman unless the user also suppressed femboy/trans!
        if let gender = MediaMetaRegistry.creatorGender(for: post.id, author: post.author)?.lowercased() {
            if hiddenOFGenderSet.contains(gender) {
                if (gender == "man" || gender == "nonbinary") && hasFemboyOrTransRescue {
                    let femboyBlocked = suppressedTagSet.contains("femboy")
                    let transBlocked = suppressedTagSet.contains("trans") || suppressedTagSet.contains("trans_woman")
                    if (tags.contains("femboy") && !femboyBlocked) || ((tags.contains("trans") || tags.contains("trans_woman")) && !transBlocked) {
                        // Rescued! User likes/allows Femboy or Trans, only blocked Masc Male-on-Male.
                    } else {
                        return true
                    }
                } else {
                    return true
                }
            }
        }

        for tag in tags where suppressedTagSet.contains(tag) {
            // If a post was tagged `gay`/`men` solely from raw gender metadata, rescue it if it's Femboy/Trans and user likes Femboy/Trans
            if (tag == "gay" || tag == "men") && hasFemboyOrTransRescue && (isUserLikedOrPinnedTag("femboy") || isUserLikedOrPinnedTag("trans")) {
                continue
            }
            return true
        }
        return false
    }

    struct DislikeOutcome {
        let primaryTag: String?
        let autoSuppressedTag: String?
        let newlyHiddenGenders: [String]
    }

    @discardableResult
    func recordDislike(_ post: Gif, categories: [GoonedCategory]) -> DislikeOutcome {
        if dislikedIDSet.insert(post.id).inserted {
            state.dislikedIDs.append(post.id)
        }
        let dedupe = post.canonicalDedupeKey
        if dislikedMediaSet.insert(dedupe).inserted {
            state.dislikedMediaKeys.append(dedupe)
        }
        if let sim = post.contentSimilarityKey, dislikedSimSet.insert(sim).inserted {
            state.dislikedSimilarityKeys.append(sim)
        }

        // Mute this specific creator from unrequested discovery feeds
        if let author = post.author?.lowercased(), !author.isEmpty,
           !["x_user", "instagram", "rule34", "eporner", "pornhub", "xhamster", "spankbang", "xvideos"].contains(author),
           suppressedCreatorSet.insert(author).inserted {
            state.suppressedCreators.append(author)
        }
        if let cKey = Self.creatorClusterKey(for: post) {
            state.creatorWatchStats[cKey] = -30.0
        }

        // Record negative visual prototype from thumbnail
        if let thumbURL = post.thumbURL ?? post.posterURL {
            captureVisualPrototype(postId: post.id, thumbURL: thumbURL, isPositive: false)
        }

        let plat = Self.platform(for: post).rawValue
        let curSourceW = state.sourceWeights[plat] ?? 1.0
        state.sourceWeights[plat] = max(0.35, curSourceW * 0.93)

        let rawTags = Self.extractExtendedTags(from: post, categories: categories)
            .map { $0.lowercased() }
            .filter { !MediaMetaRegistry.isStopTag($0) }
        let knownGender = MediaMetaRegistry.creatorGender(for: post.id, author: post.author)

        var newlySuppressed: String? = nil
        var newlyHiddenGenders: [String] = []

        // 1. Orthogonal Gender / Archetype Resolution (protecting Femboy / Trans / Futa from Masc Gay blocks)
        if let gender = knownGender {
            let gRes = applyGenderSuppressionRules(gender: gender, extraTags: rawTags)
            newlyHiddenGenders.append(contentsOf: gRes.newlyHiddenGenders)
            if newlySuppressed == nil { newlySuppressed = gRes.autoTag }
        }

        // 2. Contrastive Dislike Learning:
        //    Separate tags into (a) unliked/divergent tags vs (b) tags the user already loves.
        for tag in rawTags {
            // Never penalize or auto-block a tag/archetype the user has already liked/pinned!
            if isUserLikedOrPinnedTag(tag) {
                continue
            }
            // Broad anatomy words (`ass`, `boobs`, `pussy`) get a tiny nudge (-2.5) and NEVER auto-block
            if Self.protectedBroadTags.contains(tag) {
                let curPen = state.tagPenalties[tag] ?? 0
                state.tagPenalties[tag] = max(-8.0, curPen - 2.0)
                continue
            }

            let curPen = state.tagPenalties[tag] ?? 0
            state.tagPenalties[tag] = max(-45.0, curPen - 16.0)

            let nextCount = (state.tagDislikeCounts[tag] ?? 0) + 1
            state.tagDislikeCounts[tag] = nextCount

            let isImmediateArchetype = Self.immediateArchetypeTags.contains(tag)
            if (isImmediateArchetype || nextCount >= 2) && suppressedTagSet.insert(tag).inserted {
                state.suppressedTags.append(tag)
                if newlySuppressed == nil { newlySuppressed = tag }
            } else if isImmediateArchetype && newlySuppressed == nil {
                newlySuppressed = tag
            }

            // Only hide `man` / `trans_man` on OnlyFans if the disliked tag is Masc Male-on-Male (`gay`, `men`, `yaoi`, `bara`)
            if Self.mascMaleOnlyTags.contains(tag) && !rawTags.contains("femboy") {
                for g in ["man", "trans_man"] where !hiddenOFGenderSet.contains(g) {
                    hideOFGender(g)
                    newlyHiddenGenders.append(g)
                }
            }
        }

        if state.dislikedIDs.count > 4000 {
            state.dislikedIDs.removeFirst(state.dislikedIDs.count - 3500)
            dislikedIDSet = Set(state.dislikedIDs)
        }

        let actionableTags = rawTags.filter { !Self.protectedBroadTags.contains($0) && !isUserLikedOrPinnedTag($0) }
        let preferredPrimary = newlySuppressed
            ?? actionableTags.first(where: { Self.immediateArchetypeTags.contains($0) })
            ?? actionableTags.first

        return DislikeOutcome(
            primaryTag: preferredPrimary,
            autoSuppressedTag: newlySuppressed,
            newlyHiddenGenders: newlyHiddenGenders
        )
    }

    /// Called right after resolving creator metadata on cum.st for an OnlyFans post.
    @discardableResult
    func applyCreatorDislikeResolution(
        for post: Gif,
        gender: String?,
        creatorTags: [String],
        categories: [GoonedCategory]
    ) -> DislikeOutcome {
        let lowerTags = creatorTags
            .map { $0.lowercased().replacingOccurrences(of: "#", with: "") }
            .filter { !MediaMetaRegistry.isStopTag($0) }
        var newlySuppressed: String? = nil
        var newlyHiddenGenders: [String] = []

        if let gender, !gender.isEmpty {
            let res = applyGenderSuppressionRules(gender: gender, extraTags: lowerTags)
            newlyHiddenGenders.append(contentsOf: res.newlyHiddenGenders)
            if newlySuppressed == nil { newlySuppressed = res.autoTag }
        }

        for t in lowerTags {
            if isUserLikedOrPinnedTag(t) || Self.protectedBroadTags.contains(t) { continue }
            let curPen = state.tagPenalties[t] ?? 0
            state.tagPenalties[t] = max(-45.0, curPen - 16.0)
            if Self.immediateArchetypeTags.contains(t) && suppressedTagSet.insert(t).inserted {
                state.suppressedTags.append(t)
                if newlySuppressed == nil { newlySuppressed = t }
            }
            if Self.mascMaleOnlyTags.contains(t) && !lowerTags.contains("femboy") {
                for g in ["man", "trans_man"] where !hiddenOFGenderSet.contains(g) {
                    hideOFGender(g)
                    newlyHiddenGenders.append(g)
                }
            }
        }

        let actionable = lowerTags.filter { !Self.protectedBroadTags.contains($0) && !isUserLikedOrPinnedTag($0) }
        let primary = newlySuppressed
            ?? actionable.first(where: { Self.immediateArchetypeTags.contains($0) })
            ?? actionable.first
        return DislikeOutcome(
            primaryTag: primary,
            autoSuppressedTag: newlySuppressed,
            newlyHiddenGenders: newlyHiddenGenders
        )
    }

    private func applyGenderSuppressionRules(gender: String, extraTags: [String]) -> (autoTag: String?, newlyHiddenGenders: [String]) {
        let g = gender.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let tagSet = Set(extraTags.map { $0.lowercased() })
        var newlyHidden: [String] = []
        var autoTag: String? = nil

        switch g {
        case "man":
            // Crucial Orthogonal Separation:
            // On cum.st, some Femboy creators have `gender == "man"`.
            // Check whether this creator is actually a Femboy (`#femboy`, `#sissy`, `#trap`, etc.):
            let isFemboyPost = !tagSet.isDisjoint(with: ["femboy", "sissy", "trap", "crossdresser", "crossdressing", "boypussy", "bussy"])
            if isFemboyPost {
                if !isUserLikedOrPinnedTag("femboy") {
                    _ = blockDislikedTag("femboy")
                    autoTag = "femboy"
                }
            } else {
                for target in ["man", "trans_man"] where !hiddenOFGenderSet.contains(target) {
                    hideOFGender(target)
                    newlyHidden.append(target)
                }
                for t in ["gay", "men", "yaoi", "bara"] {
                    _ = blockDislikedTag(t)
                }
                autoTag = "gay"
            }
        case "trans_man":
            if !hiddenOFGenderSet.contains("trans_man") {
                hideOFGender("trans_man")
                newlyHidden.append("trans_man")
            }
            _ = blockDislikedTag("trans_man")
            autoTag = "trans_man"
        case "trans_woman":
            if !isUserLikedOrPinnedTag("trans") && !isUserLikedOrPinnedTag("trans_woman") {
                if !hiddenOFGenderSet.contains("trans_woman") {
                    hideOFGender("trans_woman")
                    newlyHidden.append("trans_woman")
                }
                _ = blockDislikedTag("trans_woman")
                autoTag = "trans_woman"
            }
        case "nonbinary":
            let isFemboyPost = !tagSet.isDisjoint(with: ["femboy", "sissy", "trap"])
            if isFemboyPost && isUserLikedOrPinnedTag("femboy") {
                break
            }
            if !hiddenOFGenderSet.contains("nonbinary") {
                hideOFGender("nonbinary")
                newlyHidden.append("nonbinary")
            }
            _ = blockDislikedTag("nonbinary")
            autoTag = "nonbinary"
        default:
            break
        }
        return (autoTag, newlyHidden)
    }

    func hideOFGender(_ gender: String) {
        let norm = gender.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !norm.isEmpty else { return }
        if hiddenOFGenderSet.insert(norm).inserted {
            state.hiddenOFGenders.append(norm)
            let sorted = Array(hiddenOFGenderSet).sorted()
            UserDefaults.standard.set(sorted, forKey: Self.hiddenOFGendersDefaultsKey)
        }
    }

    func unhideOFGender(_ gender: String) {
        let norm = gender.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        hiddenOFGenderSet.remove(norm)
        state.hiddenOFGenders.removeAll { $0.lowercased() == norm }
        let sorted = Array(hiddenOFGenderSet).sorted()
        UserDefaults.standard.set(sorted, forKey: Self.hiddenOFGendersDefaultsKey)
        if norm == "man" || norm == "trans_man" {
            unblockTag("gay")
            unblockTag("men")
            unblockTag("yaoi")
            unblockTag("bara")
        } else if norm == "trans_woman" {
            unblockTag("trans")
            unblockTag("trans_woman")
        }
    }

    @discardableResult
    func blockDislikedTag(_ tag: String) -> String {
        let lower = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "#", with: "")
        guard !lower.isEmpty, !MediaMetaRegistry.isStopTag(lower) else { return lower }
        if suppressedTagSet.insert(lower).inserted {
            state.suppressedTags.append(lower)
        }
        state.tagPenalties[lower] = -45.0
        return lower
    }

    func unblockTag(_ tag: String) {
        let lower = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "#", with: "")
        suppressedTagSet.remove(lower)
        state.suppressedTags.removeAll { $0.lowercased() == lower }
        state.tagDislikeCounts.removeValue(forKey: lower)
        state.tagPenalties.removeValue(forKey: lower)
    }

    func recordPositivePlatformSignal(_ post: Gif, boost: Double = 0.08) {
        let plat = Self.platform(for: post).rawValue
        let cur = state.sourceWeights[plat] ?? 1.0
        state.sourceWeights[plat] = min(2.4, cur + boost)
    }

    // MARK: - Instagram Reels / X Multi-Head Heavy Ranker Score Adjustment

    func scoreAdjustment(for post: Gif, categories: [GoonedCategory]) -> Double {
        if isDisliked(post) { return -1000.0 }
        var adj = 0.0

        // 1. Direct + Inherited Creator-Cluster Tags (`SimClusters`)
        let tags = Self.extractExtendedTags(from: post, categories: categories)
        let algoWeights = UserStore.shared.data.algorithm.tagWeights

        for t in tags {
            let lower = t.lowercased()
            if let pen = state.tagPenalties[lower] {
                adj += pen
            }
            if suppressedTagSet.contains(lower) {
                adj -= 40.0
            }
        }

        // 2. Tagless Video Recovery via Creator Latent Cluster & Session Co-Visitation
        if let cKey = Self.creatorClusterKey(for: post) {
            if let watchScore = state.creatorWatchStats[cKey] {
                adj += watchScore * 1.35
            }
            if let cluster = state.creatorLatentClusters[cKey] {
                var clusterMatch = 0.0
                for (cTag, cStrength) in cluster {
                    let userW = algoWeights[cTag] ?? 0
                    if userW > 0 {
                        clusterMatch += min(userW * (cStrength / 10.0), 8.0)
                    } else if suppressedTagSet.contains(cTag) {
                        clusterMatch -= 18.0
                    }
                    if let sW = sessionContextTags[cTag] {
                        clusterMatch += min(sW * 0.45, 4.5)
                    }
                }
                adj += min(max(clusterMatch, -30.0), 24.0)
            }
        }

        // 3. On-Device Neural Vision FeaturePrint Similarity (matches visual aesthetic even with 0 text/tags)
        if let visScore = visualScoreMirror[post.id] {
            adj += visScore
        }

        if let author = post.author?.lowercased(), suppressedCreatorSet.contains(author) {
            adj -= 35.0
        }
        let plat = Self.platform(for: post).rawValue
        let sw = state.sourceWeights[plat] ?? 1.0
        adj += (sw - 1.0) * 3.5
        return adj
    }

    func reset() {
        state = TasteV2Data()
        sessionContextTags.removeAll()
        visualScoreMirror.removeAll()
        rebuildSets()
        try? FileManager.default.removeItem(at: Self.fileURL)
    }

    func applyImportedBackup(_ imported: TasteV2Data) {
        state = imported
        sanitizeStopTagsFromState()
        rebuildSets()
        saveNow()
    }

    // MARK: - Richer Tag & Semantic Detection (With Orthogonal Femboy / Trans / Futa / Gay Separation)

    private static let extraOrientationAndNicheRules: [(canonical: String, keywords: [String])] = [
        ("femboy", ["femboy", "femboys", "sissy", "sissies", "trap", "traps", "boypussy", "bussy", "crossdresser", "crossdressing", "otokonoko", "josou", "femboyfriday"]),
        ("trans_woman", ["trans", "tgirl", "tgirls", "shemale", "ladyboy", "ts", "transwoman", "transgirl", "trans_woman", "mtf", "transfeminine", "girlcock", "gock"]),
        ("trans_man", ["trans_man", "transman", "ftm", "transguy", "cuntboy"]),
        ("futanari", ["futa", "futanari", "dickgirl", "futanarigifs", "futadom"]),
        ("yaoi", ["yaoi", "bara", "boyslove", "shounenai"]),
        ("gay", ["gay", "gayporn", "gaytwt", "gaysex", "gaycouple", "gaymen", "menonly", "menfuckingmen", "dudeondude", "cockoncock", "boyonboy", "gaybros", "twink", "twinks", "daddybear", "hunk", "gaymer", "gaynsfw", "dilf", "gayonlyfans", "malecreator", "m4m"]),
        ("lesbian", ["lesbian", "wlw", "girlsonly", "scissoring", "girlkissing", "yuri"]),
        ("ebony", ["ebony", "blackgirl", "darkskin", "chocolate"]),
        ("latina", ["latina", "mexicana", "colombiana", "mamacita", "brazilian"]),
        ("asian", ["asian", "jav", "japanese", "korean", "filipina", "chinese"]),
        ("hentai", ["hentai", "anime", "ecchi", "doujin"]),
        ("goth", ["goth", "gothgirl", "gothgf", "altgirl", "emo", "egirl", "fishnets"]),
        ("cosplay", ["cosplay", "cosplayer", "costume", "bunnygirl", "maidoutfit"]),
        ("milf", ["milf", "mommy", "mature", "cougar", "stepmom"]),
        ("bdsm", ["bdsm", "bondage", "submissive", "collar", "choking", "shibari"]),
        ("femdom", ["femdom", "findom", "mistress", "pegging", "cuckold", "sissification", "domme"]),
        ("feet", ["feet", "footjob", "toes", "soles", "pedicure"]),
        ("bbw", ["bbw", "ssbbw", "chubby", "plussize"])
    ]

    /// Extracts tags directly present on the post (without creator-cluster fallback) for graph ingestion.
    nonisolated static func extractDirectTagsOnly(from post: Gif, categories: [GoonedCategory]) -> [String] {
        return extractTagsInternal(from: post, categories: categories, includeCreatorClusterFallback: false)
    }

    /// Extracts all explicit + semantic + creator-cluster inherited tags for a post.
    nonisolated static func extractExtendedTags(from post: Gif, categories: [GoonedCategory]) -> [String] {
        return extractTagsInternal(from: post, categories: categories, includeCreatorClusterFallback: true)
    }

    nonisolated private static func extractTagsInternal(
        from post: Gif,
        categories: [GoonedCategory],
        includeCreatorClusterFallback: Bool
    ) -> [String] {
        var tags: [String] = []
        var seen = Set<String>()
        func add(_ raw: String) {
            let norm = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "#", with: "")
            guard !norm.isEmpty, !MediaMetaRegistry.isStopTag(norm) else { return }
            if seen.insert(norm).inserted { tags.append(norm) }
        }

        // 1. Registry tags (including creator-cluster inheritance when enabled for tagless posts!)
        let registryTags = MediaMetaRegistry.tags(for: post.id, author: includeCreatorClusterFallback ? post.author : nil)
        for t in registryTags { add(t) }

        // 2. Text / Handle / Subreddit keyword & semantic matching
        let tagStr = registryTags.joined(separator: " ")
        let blob = "\(post.title ?? "") \(post.subreddit ?? "") \(post.author ?? "") \(tagStr)"
            .lowercased()
            .replacingOccurrences(of: "#", with: " ")
        let words = Set(
            blob.components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).inverted)
                .filter { !$0.isEmpty }
        )
        for rule in extraOrientationAndNicheRules {
            for kw in rule.keywords {
                if words.contains(kw) || (kw.count >= 5 && blob.contains(kw)) {
                    add(rule.canonical)
                    break
                }
            }
        }

        for t in PornTagCatalog.extractRecognizedTags(from: post, categories: categories) {
            add(t)
        }

        // 3. NaturalLanguage Semantic Word Embedding Fallback for Tagless Natural-Language Captions
        if tags.isEmpty, let title = post.title, title.count >= 6,
           let embedding = NLEmbedding.wordEmbedding(for: .english) {
            let candidateSeeds: [(word: String, canonical: String)] = [
                ("goth", "goth"), ("latina", "latina"), ("asian", "asian"), ("ebony", "ebony"),
                ("femboy", "femboy"), ("transgender", "trans_woman"), ("cosplay", "cosplay"),
                ("milf", "milf"), ("lesbian", "lesbian"), ("bondage", "bdsm"), ("anime", "hentai")
            ]
            for token in words where token.count >= 4 && !MediaMetaRegistry.isStopTag(token) {
                for seed in candidateSeeds {
                    let dist = embedding.distance(between: token, and: seed.word)
                    if dist < 0.68 {
                        add(seed.canonical)
                    }
                }
            }
        }

        // 4. Orthogonal Creator Gender Resolution (ONLY label `man` as `gay`/`men` if NOT `femboy` or `trans_woman`!)
        let currentSet = Set(tags)
        let isFemboyOrTrans = !currentSet.isDisjoint(with: femboyOrTransRescueTags)
        if let g = MediaMetaRegistry.creatorGender(for: post.id, author: post.author)?.lowercased() {
            switch g {
            case "man":
                if !isFemboyOrTrans {
                    add("gay")
                    add("men")
                }
            case "trans_man":
                add("trans_man")
                if !isFemboyOrTrans { add("gay") }
            case "trans_woman":
                add("trans")
                add("trans_woman")
            case "nonbinary":
                if !isFemboyOrTrans { add("nonbinary") }
            default:
                break
            }
        }

        // If the post has explicit `femboy` or `trans_woman` tags, strip any accidental `gay`/`men` conflation
        // unless the post explicitly contained `gay` or `yaoi` or `m4m` in its text!
        if isFemboyOrTrans && !words.contains("gay") && !words.contains("yaoi") && !words.contains("m4m") && !words.contains("bara") {
            tags.removeAll { $0 == "gay" || $0 == "men" }
        }

        return tags
    }
}
