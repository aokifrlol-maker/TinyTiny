import Foundation
import SwiftUI

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
    var sourceWeights: [String: Double] = [
        "reddit": 1.0,
        "x": 1.0,
        "onlyfans": 1.0,
        "instagram": 0.65
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
        sourceWeights = (try? c.decodeIfPresent([String: Double].self, forKey: .sourceWeights)) ?? [
            "reddit": 1.0, "x": 1.0, "onlyfans": 1.0, "instagram": 0.65
        ]
        sourceSettings = (try? c.decodeIfPresent(ForYouSourceSettings.self, forKey: .sourceSettings)) ?? ForYouSourceSettings()
    }
}

/// Manages explicit Dislike / "Not Interested" suppression, cross-account similarity deduping,
/// and per-platform General For You balance without mutating legacy Codable schemas.
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
    private var saveTask: Task<Void, Never>?

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
        rebuildSets()
    }

    private func rebuildSets() {
        dislikedIDSet = Set(state.dislikedIDs)
        dislikedMediaSet = Set(state.dislikedMediaKeys)
        dislikedSimSet = Set(state.dislikedSimilarityKeys)
        seenSimSet = Set(state.seenSimilarityKeys)
        suppressedTagSet = Set(state.suppressedTags.map { $0.lowercased() })
        suppressedCreatorSet = Set(state.suppressedCreators.map { $0.lowercased() })
        let normGenders = Array(Set(state.hiddenOFGenders.map { $0.lowercased() })).sorted()
        hiddenOFGenderSet = Set(normGenders)
        UserDefaults.standard.set(normGenders, forKey: Self.hiddenOFGendersDefaultsKey)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
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

    // MARK: - Dislike / "Not Interested" Learning & Suppression

    func isDisliked(_ post: Gif) -> Bool {
        if dislikedIDSet.contains(post.id) { return true }
        if dislikedMediaSet.contains(post.canonicalDedupeKey) { return true }
        if let sim = post.contentSimilarityKey, dislikedSimSet.contains(sim) { return true }
        return false
    }

    func isSuppressedInDiscovery(_ post: Gif, categories: [GoonedCategory]) -> Bool {
        if isDisliked(post) { return true }
        if let author = post.author?.lowercased(), !author.isEmpty,
           author != "x_user", author != "instagram", author != "rule34",
           suppressedCreatorSet.contains(author) {
            return true
        }
        if let gender = MediaMetaRegistry.creatorGender(for: post.id, author: post.author),
           hiddenOFGenderSet.contains(gender.lowercased()) {
            return true
        }
        let tags = Self.extractExtendedTags(from: post, categories: categories)
        for tag in tags where suppressedTagSet.contains(tag.lowercased()) {
            return true
        }
        return false
    }

    struct DislikeOutcome {
        let primaryTag: String?
        let autoSuppressedTag: String?
        let newlyHiddenGenders: [String]
    }

    private static let immediateCategoryTags: Set<String> = [
        "gay", "men", "bara", "yaoi", "trans", "trans_man", "trans_woman",
        "nonbinary", "femboy", "futanari", "lesbian"
    ]

    private static let immediateMaleCategoryTags: Set<String> = [
        "gay", "men", "bara", "yaoi", "trans_man", "gaymen", "gaytwt", "gayporn"
    ]

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

        // Suppress this specific creator from unrequested discovery feeds
        if let author = post.author?.lowercased(), !author.isEmpty,
           author != "x_user", author != "instagram", author != "rule34",
           suppressedCreatorSet.insert(author).inserted {
            state.suppressedCreators.append(author)
        }

        // Slightly shift platform weight down on explicit dislike
        let plat = Self.platform(for: post).rawValue
        let curSourceW = state.sourceWeights[plat] ?? 1.0
        state.sourceWeights[plat] = max(0.25, curSourceW * 0.90)

        let tags = Self.extractExtendedTags(from: post, categories: categories)
        let knownGender = MediaMetaRegistry.creatorGender(for: post.id, author: post.author)

        var newlySuppressed: String? = nil
        var newlyHiddenGenders: [String] = []

        // 1. If we already know the creator's gender or saw a clear orientation/gender tag,
        //    suppress that entire category IMMEDIATELY on first dislike.
        if let gender = knownGender {
            let gRes = applyGenderSuppressionRules(gender: gender, extraTags: tags)
            newlyHiddenGenders.append(contentsOf: gRes.newlyHiddenGenders)
            if newlySuppressed == nil { newlySuppressed = gRes.autoTag }
        }

        for tag in tags {
            let lower = tag.lowercased()
            let curPen = state.tagPenalties[lower] ?? 0
            state.tagPenalties[lower] = max(-45.0, curPen - 16.0)

            let nextCount = (state.tagDislikeCounts[lower] ?? 0) + 1
            state.tagDislikeCounts[lower] = nextCount

            let isImmediate = Self.immediateCategoryTags.contains(lower)
            if (isImmediate || nextCount >= 2) && suppressedTagSet.insert(lower).inserted {
                state.suppressedTags.append(lower)
                if newlySuppressed == nil { newlySuppressed = lower }
            } else if isImmediate && newlySuppressed == nil {
                newlySuppressed = lower
            }

            if Self.immediateMaleCategoryTags.contains(lower) {
                for g in ["man", "trans_man"] where !hiddenOFGenderSet.contains(g) {
                    hideOFGender(g)
                    newlyHiddenGenders.append(g)
                }
            }
        }

        // Trim oldest disliked IDs above 4000
        if state.dislikedIDs.count > 4000 {
            state.dislikedIDs.removeFirst(state.dislikedIDs.count - 3500)
            dislikedIDSet = Set(state.dislikedIDs)
        }

        // Prefer orientation/gender or explicit creator tags for toast label over generic caption words
        let explicitTags = MediaMetaRegistry.tags(for: post.id)
        let preferredPrimary = tags.first(where: { Self.immediateCategoryTags.contains($0.lowercased()) })
            ?? explicitTags.first
            ?? tags.first

        return DislikeOutcome(
            primaryTag: preferredPrimary,
            autoSuppressedTag: newlySuppressed,
            newlyHiddenGenders: newlyHiddenGenders
        )
    }

    /// Called right after resolving creator metadata on cum.st for an OnlyFans post
    /// so male / gay / other disliked gender categories get hidden immediately.
    @discardableResult
    func applyCreatorDislikeResolution(
        for post: Gif,
        gender: String?,
        creatorTags: [String],
        categories: [GoonedCategory]
    ) -> DislikeOutcome {
        let lowerTags = creatorTags.map { $0.lowercased() }
        var newlySuppressed: String? = nil
        var newlyHiddenGenders: [String] = []

        if let gender, !gender.isEmpty {
            let res = applyGenderSuppressionRules(gender: gender, extraTags: lowerTags)
            newlyHiddenGenders.append(contentsOf: res.newlyHiddenGenders)
            if newlySuppressed == nil { newlySuppressed = res.autoTag }
        }

        for t in lowerTags {
            let curPen = state.tagPenalties[t] ?? 0
            state.tagPenalties[t] = max(-45.0, curPen - 16.0)
            if Self.immediateCategoryTags.contains(t) && suppressedTagSet.insert(t).inserted {
                state.suppressedTags.append(t)
                if newlySuppressed == nil { newlySuppressed = t }
            }
            if Self.immediateMaleCategoryTags.contains(t) {
                for g in ["man", "trans_man"] where !hiddenOFGenderSet.contains(g) {
                    hideOFGender(g)
                    newlyHiddenGenders.append(g)
                }
            }
        }

        let primary = newlySuppressed
            ?? lowerTags.first(where: { Self.immediateCategoryTags.contains($0) })
            ?? lowerTags.first
        return DislikeOutcome(
            primaryTag: primary,
            autoSuppressedTag: newlySuppressed,
            newlyHiddenGenders: newlyHiddenGenders
        )
    }

    private func applyGenderSuppressionRules(gender: String, extraTags: [String]) -> (autoTag: String?, newlyHiddenGenders: [String]) {
        let g = gender.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var newlyHidden: [String] = []
        var autoTag: String? = nil

        switch g {
        case "man", "trans_man":
            for target in ["man", "trans_man"] where !hiddenOFGenderSet.contains(target) {
                hideOFGender(target)
                newlyHidden.append(target)
            }
            for t in ["gay", "men"] {
                _ = blockDislikedTag(t)
            }
            autoTag = "gay"
        case "trans_woman":
            if !hiddenOFGenderSet.contains("trans_woman") {
                hideOFGender("trans_woman")
                newlyHidden.append("trans_woman")
            }
            _ = blockDislikedTag("trans")
            autoTag = "trans_woman"
        case "nonbinary":
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
        }
    }

    @discardableResult
    func blockDislikedTag(_ tag: String) -> String {
        let lower = tag.lowercased()
        if suppressedTagSet.insert(lower).inserted {
            state.suppressedTags.append(lower)
        }
        state.tagPenalties[lower] = -45.0
        return lower
    }

    func unblockTag(_ tag: String) {
        let lower = tag.lowercased()
        suppressedTagSet.remove(lower)
        state.suppressedTags.removeAll { $0.lowercased() == lower }
        state.tagDislikeCounts.removeValue(forKey: lower)
        state.tagPenalties.removeValue(forKey: lower)
    }

    func recordPositivePlatformSignal(_ post: Gif, boost: Double = 0.08) {
        let plat = Self.platform(for: post).rawValue
        let cur = state.sourceWeights[plat] ?? 1.0
        state.sourceWeights[plat] = min(2.2, cur + boost)
    }

    func scoreAdjustment(for post: Gif, categories: [GoonedCategory]) -> Double {
        if isDisliked(post) { return -1000.0 }
        var adj = 0.0
        let tags = Self.extractExtendedTags(from: post, categories: categories)
        for t in tags {
            let lower = t.lowercased()
            if let pen = state.tagPenalties[lower] {
                adj += pen
            }
            if suppressedTagSet.contains(lower) {
                adj -= 35.0
            }
        }
        if let author = post.author?.lowercased(), suppressedCreatorSet.contains(author) {
            adj -= 30.0
        }
        let plat = Self.platform(for: post).rawValue
        let sw = state.sourceWeights[plat] ?? 1.0
        adj += (sw - 1.0) * 3.0
        return adj
    }

    func reset() {
        state = TasteV2Data()
        rebuildSets()
        try? FileManager.default.removeItem(at: Self.fileURL)
    }

    func applyImportedBackup(_ imported: TasteV2Data) {
        state = imported
        rebuildSets()
        saveNow()
    }

    // MARK: - Richer Tag Detection (Including Gay / Niche Keywords in Captions & Bios)

    private static let extraOrientationAndNicheRules: [(canonical: String, keywords: [String])] = [
        ("gay", ["gay", "gayporn", "gaytwt", "gaysex", "gaycouple", "gaymen", "menonly", "menfuckingmen", "dudeondude", "cockoncock", "boyonboy", "gaybros", "twink", "twinks", "bara", "yaoi", "daddybear", "hunk", "gaymer", "gaynsfw", "dilf", "gayonlyfans", "malecreator"]),
        ("trans", ["trans", "tgirl", "shemale", "ladyboy", "ts", "transwoman", "transgirl", "trans_woman"]),
        ("trans_man", ["trans_man", "transman", "ftm", "transguy"]),
        ("femboy", ["femboy", "sissy", "trap", "boypussy", "bussy"]),
        ("lesbian", ["lesbian", "wlw", "girlsonly", "scissoring", "girlkissing"]),
        ("ebony", ["ebony", "blackgirl", "darkskin", "chocolate"]),
        ("latina", ["latina", "mexicana", "colombiana", "mamacita"]),
        ("asian", ["asian", "jav", "japanese", "korean", "filipina"]),
        ("hentai", ["hentai", "anime", "ecchi", "doujin"]),
        ("futanari", ["futa", "futanari", "dickgirl"]),
        ("bdsm", ["bdsm", "bondage", "submissive", "collar", "choking"]),
        ("femdom", ["femdom", "findom", "mistress", "pegging", "cuckold", "sissification"]),
        ("feet", ["feet", "footjob", "toes", "soles"]),
        ("bbw", ["bbw", "ssbbw", "chubby", "plussize"])
    ]

    nonisolated static func extractExtendedTags(from post: Gif, categories: [GoonedCategory]) -> [String] {
        var tags: [String] = []
        var seen = Set<String>()
        func add(_ raw: String) {
            let norm = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !norm.isEmpty else { return }
            if seen.insert(norm).inserted { tags.append(norm) }
        }

        // 1. Prioritize known creator gender + explicit post/creator tags first
        if let g = MediaMetaRegistry.creatorGender(for: post.id, author: post.author)?.lowercased() {
            switch g {
            case "man":
                add("gay"); add("men")
            case "trans_man":
                add("gay"); add("trans_man"); add("men")
            case "trans_woman":
                add("trans"); add("trans_woman")
            case "nonbinary":
                add("nonbinary")
            default:
                break
            }
        }
        let registryTags = MediaMetaRegistry.tags(for: post.id)
        for t in registryTags { add(t) }

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
        return tags
    }
}
