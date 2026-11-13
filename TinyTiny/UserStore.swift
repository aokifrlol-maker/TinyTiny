import SwiftUI
import AVFoundation

struct AppSettings: Codable {
    var hd: Bool = true
    var muted: Bool = true
    var faceID: Bool = false
    var autoScroll: Bool = false
    var autoScrollDelay: Int = 6       // 3, 6, 10, 15 seconds (matches gooned.app Settings)
    var playVideosToEnd: Bool = true   // matches gooned.app Settings
    var tintedGlass: Bool = true       // Liquid Glass: Clear vs Tinted
    var videoFitScreen: Bool = true    // Fit entire video on screen by default (prevents weird cropping)
    var controlsCollapsed: Bool = false // Collapses bottom-left UI & dock down out of the way
    var algorithmEnabled: Bool = true  // Smart on-device For You personalization algorithm

    enum CodingKeys: String, CodingKey {
        case hd, muted, faceID, autoScroll, autoScrollDelay, playVideosToEnd, tintedGlass, videoFitScreen, controlsCollapsed, algorithmEnabled
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hd = (try? c.decode(Bool.self, forKey: .hd)) ?? true
        muted = (try? c.decode(Bool.self, forKey: .muted)) ?? true
        faceID = (try? c.decode(Bool.self, forKey: .faceID)) ?? false
        autoScroll = (try? c.decode(Bool.self, forKey: .autoScroll)) ?? false
        autoScrollDelay = (try? c.decode(Int.self, forKey: .autoScrollDelay)) ?? 6
        playVideosToEnd = (try? c.decode(Bool.self, forKey: .playVideosToEnd)) ?? true
        tintedGlass = (try? c.decode(Bool.self, forKey: .tintedGlass)) ?? true
        videoFitScreen = (try? c.decode(Bool.self, forKey: .videoFitScreen)) ?? true
        controlsCollapsed = (try? c.decode(Bool.self, forKey: .controlsCollapsed)) ?? false
        algorithmEnabled = (try? c.decode(Bool.self, forKey: .algorithmEnabled)) ?? true
    }
}

struct AlgorithmProfile: Codable {
    var subredditWeights: [String: Double] = [:]
    var creatorWeights: [String: Double] = [:]
    var tagWeights: [String: Double] = [:]
    var boostedTags: [String] = []
    var blockedTags: [String] = []
    var videoPreference: Double = 0.5   // > 0.5 favors videos over static images
    var totalSignals: Int = 0

    enum CodingKeys: String, CodingKey {
        case subredditWeights, creatorWeights, tagWeights, boostedTags, blockedTags, videoPreference, totalSignals
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subredditWeights = (try? c.decode([String: Double].self, forKey: .subredditWeights)) ?? [:]
        creatorWeights = (try? c.decode([String: Double].self, forKey: .creatorWeights)) ?? [:]
        tagWeights = (try? c.decode([String: Double].self, forKey: .tagWeights)) ?? [:]
        boostedTags = (try? c.decode([String].self, forKey: .boostedTags)) ?? []
        blockedTags = (try? c.decode([String].self, forKey: .blockedTags)) ?? []
        videoPreference = (try? c.decode(Double.self, forKey: .videoPreference)) ?? 0.5
        totalSignals = (try? c.decode(Int.self, forKey: .totalSignals)) ?? 0
    }
}

struct RecentFeedEntry: Codable, Hashable, Identifiable {
    var id: String { "\(kind):\(name)" }
    var kind: String
    var name: String
    var displayTitle: String
    var swipedCount: Int
    var updatedAt: Date
}

struct UserData: Codable {
    var liked: [Gif] = []
    var downloaded: [Gif] = []
    var followedSubreddits: [String] = []
    var followedUsers: [String] = []
    var followedXUsers: [String] = []
    var followedIGUsers: [String] = []
    var recentFeeds: [RecentFeedEntry] = []
    var seenIDs: [String] = []
    var savedCursors: [String: String] = [:]
    var swipedTotal: Int = 0
    var settings = AppSettings()
    var xSession = XAccountSession()
    var igSession = InstagramAccountSession()
    var r34Credentials = Rule34Credentials()
    var algorithm = AlgorithmProfile()

    enum CodingKeys: String, CodingKey {
        case liked, downloaded, followedSubreddits, followedUsers, followedXUsers, followedIGUsers
        case recentFeeds, seenIDs, savedCursors, swipedTotal, settings, xSession, igSession, r34Credentials, algorithm
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        liked = (try? c.decode([Gif].self, forKey: .liked)) ?? []
        downloaded = (try? c.decode([Gif].self, forKey: .downloaded)) ?? []
        followedSubreddits = (try? c.decode([String].self, forKey: .followedSubreddits)) ?? []
        followedUsers = (try? c.decode([String].self, forKey: .followedUsers)) ?? []
        followedXUsers = (try? c.decode([String].self, forKey: .followedXUsers)) ?? []
        followedIGUsers = (try? c.decode([String].self, forKey: .followedIGUsers)) ?? []
        recentFeeds = (try? c.decode([RecentFeedEntry].self, forKey: .recentFeeds)) ?? []
        seenIDs = (try? c.decode([String].self, forKey: .seenIDs)) ?? []
        savedCursors = (try? c.decode([String: String].self, forKey: .savedCursors)) ?? [:]
        swipedTotal = (try? c.decode(Int.self, forKey: .swipedTotal)) ?? 0
        settings = (try? c.decode(AppSettings.self, forKey: .settings)) ?? AppSettings()
        xSession = (try? c.decode(XAccountSession.self, forKey: .xSession)) ?? XAccountSession()
        igSession = (try? c.decode(InstagramAccountSession.self, forKey: .igSession)) ?? InstagramAccountSession()
        r34Credentials = (try? c.decode(Rule34Credentials.self, forKey: .r34Credentials)) ?? Rule34Credentials()
        algorithm = (try? c.decode(AlgorithmProfile.self, forKey: .algorithm)) ?? AlgorithmProfile()
    }
}

@MainActor
final class UserStore: ObservableObject {
    static let shared = UserStore()

    private(set) var seenSet: Set<String>
    @Published var data: UserData { didSet { scheduleSave() } }
    @Published var categories: [GoonedCategory] = GoonedCategory.defaultCategories
    private var saveTask: Task<Void, Never>?

    private static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("gooned_userdata.json")
    }

    init() {
        let loaded: UserData
        if let raw = try? Data(contentsOf: Self.fileURL),
           let decoded = try? JSONDecoder().decode(UserData.self, from: raw) {
            loaded = decoded
        } else {
            loaded = UserData()
        }
        self.seenSet = Set(loaded.seenIDs)
        self.data = loaded
        sanitizeLearnedProfile()
        Self.configureAudioSession(muted: loaded.settings.muted)
        Task { await refreshCategories() }
    }

    static func configureAudioSession(muted: Bool) {
        let session = AVAudioSession.sharedInstance()
        if muted {
            try? session.setCategory(.ambient, mode: .moviePlayback, options: [.mixWithOthers])
        } else {
            try? session.setCategory(.playback, mode: .moviePlayback, options: [])
            try? session.setActive(true)
        }
    }

    func refreshCategories() async {
        if let remote = try? await GoonedAPI.shared.categories(), !remote.isEmpty {
            self.categories = remote
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        if let raw = try? JSONEncoder().encode(data) {
            try? raw.write(to: Self.fileURL, options: [.atomic, .completeFileProtection])
        }
    }

    // MARK: - Seen History & Cursor Rotation (Prevents Repeating Videos)

    func isSeen(_ id: String) -> Bool {
        seenSet.contains(id)
    }

    func isSeen(_ post: Gif) -> Bool {
        seenSet.contains(post.id) || seenSet.contains(post.canonicalDedupeKey)
    }

    func markSeen(_ post: Gif) {
        markSeen(post.id)
        markSeen(post.canonicalDedupeKey)
    }

    func markSeen(_ id: String) {
        guard !id.isEmpty, seenSet.insert(id).inserted else { return }
        data.seenIDs.append(id)
        if data.seenIDs.count > 6000 {
            let overflow = data.seenIDs.count - 5200
            let removed = data.seenIDs.prefix(overflow)
            for r in removed { seenSet.remove(r) }
            data.seenIDs.removeFirst(overflow)
        }
    }

    func savedCursor(for key: String) -> String? {
        data.savedCursors[key]
    }

    func setSavedCursor(_ cursor: String?, for key: String) {
        if let cursor, !cursor.isEmpty {
            data.savedCursors[key] = cursor
        } else {
            data.savedCursors.removeValue(forKey: key)
        }
    }

    func clearSeenHistory() {
        seenSet.removeAll()
        data.seenIDs.removeAll()
        data.savedCursors.removeAll()
        saveNow()
    }

    // MARK: - Likes (Stash) & Offline Downloads

    func isLiked(_ g: Gif) -> Bool {
        data.liked.contains { $0.id == g.id }
    }

    func toggleLike(_ g: Gif) {
        if let i = data.liked.firstIndex(where: { $0.id == g.id }) {
            data.liked.remove(at: i)
            recordAlgorithmSignal(for: g, weight: -2.5)
        } else {
            data.liked.insert(g, at: 0)
            recordAlgorithmSignal(for: g, weight: 5.0)
        }
    }

    func like(_ g: Gif) {
        if !isLiked(g) { toggleLike(g) }
    }

    func recordDownload(_ g: Gif) {
        if let i = data.downloaded.firstIndex(where: { $0.id == g.id }) {
            data.downloaded[i] = g
        } else {
            data.downloaded.insert(g, at: 0)
            recordAlgorithmSignal(for: g, weight: 6.5)
        }
    }

    func removeDownloadedRecord(_ g: Gif) {
        data.downloaded.removeAll { $0.id == g.id }
    }

    // MARK: - Follows (Subreddits, Reddit Creators, X Creators & Instagram Creators)

    func isFollowingSubreddit(_ sub: String) -> Bool {
        data.followedSubreddits.contains { $0.caseInsensitiveCompare(sub) == .orderedSame }
    }

    func toggleFollowSubreddit(_ sub: String) {
        let clean = sub.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if let i = data.followedSubreddits.firstIndex(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) {
            data.followedSubreddits.remove(at: i)
        } else {
            data.followedSubreddits.insert(clean, at: 0)
        }
    }

    func isFollowingUser(_ user: String) -> Bool {
        data.followedUsers.contains { $0.caseInsensitiveCompare(user) == .orderedSame }
    }

    func toggleFollowUser(_ user: String) {
        let clean = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if let i = data.followedUsers.firstIndex(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) {
            data.followedUsers.remove(at: i)
        } else {
            data.followedUsers.insert(clean, at: 0)
        }
    }

    func isFollowingXUser(_ handle: String) -> Bool {
        let clean = handle.replacingOccurrences(of: "@", with: "")
        return data.followedXUsers.contains { $0.caseInsensitiveCompare(clean) == .orderedSame }
    }

    func toggleFollowXUser(_ handle: String) {
        let clean = handle
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "@", with: "")
        guard !clean.isEmpty else { return }
        if let i = data.followedXUsers.firstIndex(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) {
            data.followedXUsers.remove(at: i)
        } else {
            data.followedXUsers.insert(clean, at: 0)
        }
    }

    func isFollowingIGUser(_ handle: String) -> Bool {
        let clean = handle.replacingOccurrences(of: "@", with: "")
        return data.followedIGUsers.contains { $0.caseInsensitiveCompare(clean) == .orderedSame }
    }

    func toggleFollowIGUser(_ handle: String) {
        let clean = handle
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "@", with: "")
        guard !clean.isEmpty else { return }
        if let i = data.followedIGUsers.firstIndex(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) {
            data.followedIGUsers.remove(at: i)
        } else {
            data.followedIGUsers.insert(clean, at: 0)
        }
    }

    func disconnectX() {
        data.xSession = XAccountSession()
        Task { await XWebEngine.shared.resetSession() }
    }

    func disconnectIG() {
        data.igSession = InstagramAccountSession()
        Task { await InstagramWebEngine.shared.resetSession() }
    }

    // MARK: - Pick Up Where You Left Off (Swipe Tracking)

    func recordSwipe(kind: String, name: String, displayTitle: String, postID: String? = nil) {
        if let postID { markSeen(postID) }
        data.swipedTotal += 1
        if let idx = data.recentFeeds.firstIndex(where: { $0.kind == kind && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            var entry = data.recentFeeds.remove(at: idx)
            entry.swipedCount += 1
            entry.updatedAt = Date()
            data.recentFeeds.insert(entry, at: 0)
        } else {
            let entry = RecentFeedEntry(kind: kind, name: name, displayTitle: displayTitle, swipedCount: 1, updatedAt: Date())
            data.recentFeeds.insert(entry, at: 0)
        }
        if data.recentFeeds.count > 8 {
            data.recentFeeds = Array(data.recentFeeds.prefix(8))
        }
    }

    // MARK: - Porn-Specific Preference Learning & Content Filtering

    private func sanitizeLearnedProfile() {
        var normalizedTags: [String: Double] = [:]
        for (rawKey, weight) in data.algorithm.tagWeights {
            guard abs(weight) > 0.2,
                  let canonical = PornTagCatalog.normalize(rawKey, categories: categories) else { continue }
            normalizedTags[canonical] = min(max((normalizedTags[canonical] ?? 0) + weight, -12), 45)
        }
        data.algorithm.tagWeights = normalizedTags
    }

    func recordAlgorithmSignal(for post: Gif, weight: Double) {
        guard data.settings.algorithmEnabled else { return }

        // Time decay so recent preferences outweigh stale ones
        data.algorithm.totalSignals += 1
        if data.algorithm.totalSignals % 35 == 0 {
            data.algorithm.subredditWeights = data.algorithm.subredditWeights.mapValues { $0 * 0.92 }.filter { abs($0.value) > 0.2 }
            data.algorithm.creatorWeights = data.algorithm.creatorWeights.mapValues { $0 * 0.92 }.filter { abs($0.value) > 0.2 }
            data.algorithm.tagWeights = data.algorithm.tagWeights.mapValues { $0 * 0.92 }.filter { abs($0.value) > 0.2 }
        }

        if let sub = post.subreddit?.lowercased(), !sub.isEmpty,
           !AdultContentClassifier.sfwBlockedSubreddits.contains(sub) {
            let cur = data.algorithm.subredditWeights[sub] ?? 0
            data.algorithm.subredditWeights[sub] = min(max(cur + weight, -12), 45)
        }
        if let author = post.author?.lowercased(), !author.isEmpty,
           author != "instagram", author != "x_user", author != "rule34" {
            let cur = data.algorithm.creatorWeights[author] ?? 0
            data.algorithm.creatorWeights[author] = min(max(cur + weight * 1.15, -12), 45)
        }

        // Only learn recognized pornographic categories and verified adult tags — never arbitrary words!
        let recognized = PornTagCatalog.extractRecognizedTags(from: post, categories: categories)
        for tag in recognized {
            let cur = data.algorithm.tagWeights[tag] ?? 0
            let updated = min(max(cur + weight * 0.85, -12), 45)
            if abs(updated) < 0.15 {
                data.algorithm.tagWeights.removeValue(forKey: tag)
            } else {
                data.algorithm.tagWeights[tag] = updated
            }
        }

        let target: Double = post.isImage ? 0.0 : 1.0
        let alpha = weight > 0 ? 0.06 : 0.02
        data.algorithm.videoPreference = min(max(data.algorithm.videoPreference + (target - data.algorithm.videoPreference) * alpha, 0.1), 0.95)
    }

    func recordDwellSignal(for post: Gif, secondsWatched: TimeInterval) {
        if secondsWatched >= 9.0 {
            recordAlgorithmSignal(for: post, weight: 2.6)
        } else if secondsWatched >= 3.5 {
            recordAlgorithmSignal(for: post, weight: 1.4)
        } else if secondsWatched < 1.3 {
            // Immediate skip reduces relevance
            recordAlgorithmSignal(for: post, weight: -1.2)
        }
    }

    func recordLoopSignal(for post: Gif) {
        // Repeatedly watching / looping a clip strengthens its category affinity
        recordAlgorithmSignal(for: post, weight: 2.2)
    }

    func recordSearchSignal(_ rawQuery: String) {
        guard data.settings.algorithmEnabled else { return }
        let matched = PornTagCatalog.extractRecognizedTags(fromQuery: rawQuery, categories: categories)
        guard !matched.isEmpty else { return }
        data.algorithm.totalSignals += 1
        for tag in matched {
            let cur = data.algorithm.tagWeights[tag] ?? 0
            data.algorithm.tagWeights[tag] = min(max(cur + 3.5, -12), 45)
        }
    }

    func adjustLearnedTag(_ tag: String, delta: Double) {
        let key = PornTagCatalog.normalize(tag, categories: categories) ?? tag.lowercased()
        let next = (data.algorithm.tagWeights[key] ?? 0) + delta
        if next <= 0.25 {
            data.algorithm.tagWeights.removeValue(forKey: key)
        } else {
            data.algorithm.tagWeights[key] = min(next, 45)
        }
    }

    func scorePost(_ post: Gif) -> Double {
        guard data.settings.algorithmEnabled else { return 0 }
        var score = 0.0
        let subLower = post.subreddit?.lowercased() ?? ""
        let authorLower = post.author?.lowercased() ?? ""
        let titleLower = post.title?.lowercased() ?? ""

        if !subLower.isEmpty {
            score += (data.algorithm.subredditWeights[subLower] ?? 0) * 1.4
            if isFollowingSubreddit(subLower) { score += 3.5 }
        }
        if !authorLower.isEmpty {
            score += (data.algorithm.creatorWeights[authorLower] ?? 0) * 1.6
            if isFollowingUser(authorLower) || isFollowingXUser(authorLower) || isFollowingIGUser(authorLower) {
                score += 4.0
            }
        }

        let recognizedTags = PornTagCatalog.extractRecognizedTags(from: post, categories: categories)
        for tag in recognizedTags {
            let direct = data.algorithm.tagWeights[tag] ?? 0
            score += direct * 1.8

            // Cross-tag cluster synergy: consistent interest in related categories boosts companion tags
            if let related = PornTagCatalog.relatedTags[tag] {
                var clusterBonus = 0.0
                for rel in related {
                    let relWeight = data.algorithm.tagWeights[rel] ?? 0
                    if relWeight >= 3.0 {
                        clusterBonus += relWeight * 0.30
                    }
                }
                score += min(clusterBonus, 6.0)
            }
        }

        for pinned in data.algorithm.boostedTags {
            let p = pinned.lowercased()
            let cleanP = p.replacingOccurrences(of: "_", with: "")
            let canonicalPinned = PornTagCatalog.normalize(p, categories: categories) ?? p
            if recognizedTags.contains(canonicalPinned) || subLower.contains(cleanP) || authorLower.contains(cleanP) || titleLower.contains(p) {
                score += 15.0
            }
        }
        if !post.isImage {
            score += (data.algorithm.videoPreference - 0.5) * 4.0
        }
        if let up = post.upvotes, up > 0 {
            score += min(log10(Double(up)) * 0.55, 2.2)
        }
        return score
    }

    func isBlockedByAlgorithm(_ post: Gif) -> Bool {
        guard data.settings.algorithmEnabled, !data.algorithm.blockedTags.isEmpty else { return false }
        let sub = post.subreddit?.lowercased() ?? ""
        let author = post.author?.lowercased() ?? ""
        let title = post.title?.lowercased() ?? ""
        let postTags = PornTagCatalog.extractRecognizedTags(from: post, categories: categories)
        for blocked in data.algorithm.blockedTags {
            let b = blocked.lowercased()
            let canonicalBlocked = PornTagCatalog.normalize(b, categories: categories) ?? b
            if !b.isEmpty && (postTags.contains(canonicalBlocked) || sub.contains(b) || author.contains(b) || title.contains(b)) {
                return true
            }
        }
        return false
    }

    func addBoostedTags(_ rawInput: String) {
        let parsed = Rule34API.parseTags(rawInput)
        for tag in parsed {
            let key = PornTagCatalog.normalize(tag, categories: categories) ?? tag
            if !data.algorithm.boostedTags.contains(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) {
                data.algorithm.boostedTags.insert(key, at: 0)
            }
            data.algorithm.tagWeights[key] = max(data.algorithm.tagWeights[key] ?? 0, 15.0)
            let subKey = key.replacingOccurrences(of: "_", with: "")
            if !subKey.isEmpty {
                data.algorithm.subredditWeights[subKey] = max(data.algorithm.subredditWeights[subKey] ?? 0, 10.0)
            }
        }
    }

    func removeBoostedTag(_ tag: String) {
        let lower = tag.lowercased()
        let norm = PornTagCatalog.normalize(lower, categories: categories) ?? lower
        data.algorithm.boostedTags.removeAll { $0.lowercased() == lower || $0.lowercased() == norm }
        data.algorithm.tagWeights.removeValue(forKey: norm)
        data.algorithm.tagWeights.removeValue(forKey: lower)
        let subKey = norm.replacingOccurrences(of: "_", with: "")
        data.algorithm.subredditWeights.removeValue(forKey: subKey)
    }

    func removeLearnedSubreddit(_ sub: String) {
        data.algorithm.subredditWeights.removeValue(forKey: sub.lowercased())
    }

    func removeLearnedTag(_ tag: String) {
        data.algorithm.tagWeights.removeValue(forKey: tag.lowercased())
    }

    func addBlockedTags(_ rawInput: String) {
        let parsed = Rule34API.parseTags(rawInput)
        for tag in parsed {
            let key = PornTagCatalog.normalize(tag, categories: categories) ?? tag
            if !data.algorithm.blockedTags.contains(where: { $0.caseInsensitiveCompare(key) == .orderedSame }) {
                data.algorithm.blockedTags.insert(key, at: 0)
            }
            data.algorithm.tagWeights.removeValue(forKey: key)
            data.algorithm.tagWeights.removeValue(forKey: tag)
        }
    }

    func removeBlockedTag(_ tag: String) {
        let lower = tag.lowercased()
        data.algorithm.blockedTags.removeAll { $0.lowercased() == lower }
    }

    /// Ranks posts using an 80/20 Exploit-Explore mix so For You feels personalized yet never repetitive.
    func rankWithAlgorithm(_ posts: [Gif]) -> [Gif] {
        guard data.settings.algorithmEnabled, posts.count > 3 else {
            return posts.shuffled()
        }
        let scored = posts.map { ($0, scorePost($0) + Double.random(in: -0.75...0.75)) }
            .sorted { $0.1 > $1.1 }

        // Separate high-affinity matches from discovery posts, interleaving 1 discovery post every 4 items
        let splitIdx = max(1, (scored.count * 3) / 4)
        var topPool = Array(scored.prefix(splitIdx).map(\.0))
        var explorePool = Array(scored.dropFirst(splitIdx).map(\.0)).shuffled()

        var result: [Gif] = []
        var counter = 0
        while !topPool.isEmpty || !explorePool.isEmpty {
            if counter % 4 == 3, let exp = explorePool.first {
                explorePool.removeFirst()
                result.append(exp)
            } else if let top = topPool.first {
                topPool.removeFirst()
                result.append(top)
            } else if let exp = explorePool.first {
                explorePool.removeFirst()
                result.append(exp)
            }
            counter += 1
        }
        return result
    }

    var topAlgorithmSubreddits: [String] {
        var combined: [String] = []
        for pinned in data.algorithm.boostedTags {
            let key = PornTagCatalog.normalize(pinned, categories: categories) ?? pinned
            if let cat = categories.first(where: { $0.name.lowercased() == key.replacingOccurrences(of: "_", with: "") }),
               let sub = cat.subreddits.first,
               !combined.contains(sub) {
                combined.append(sub)
            } else {
                let clean = key.replacingOccurrences(of: "_", with: "")
                if !clean.isEmpty && !combined.contains(clean) { combined.append(clean) }
            }
        }
        let learned = data.algorithm.subredditWeights
            .filter { $0.value > 1.5 }
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map(\.key)
        for s in learned where !combined.contains(s) {
            combined.append(s)
        }
        return Array(combined.prefix(6))
    }

    var topAlgorithmTags: [(tag: String, score: Double)] {
        data.algorithm.tagWeights
            .filter { $0.value > 0.6 }
            .sorted { $0.value > $1.value }
            .prefix(16)
            .map { (tag: $0.key, score: $0.value) }
    }

    var topAlgorithmSubredditEntries: [(name: String, score: Double)] {
        data.algorithm.subredditWeights
            .filter { $0.value > 0.8 }
            .sorted { $0.value > $1.value }
            .prefix(12)
            .map { (name: $0.key, score: $0.value) }
    }

    var topTasteSummary: String {
        let pinned = data.algorithm.boostedTags.prefix(3).map { PornTagCatalog.displayTitle(for: $0) }
        if !pinned.isEmpty { return pinned.joined(separator: " · ") }
        let tags = data.algorithm.tagWeights.filter { $0.value > 1.0 }.sorted { $0.value > $1.value }.prefix(3).map { PornTagCatalog.displayTitle(for: $0.key) }
        if !tags.isEmpty { return tags.joined(separator: " · ") }
        let subs = topAlgorithmSubreddits.prefix(3).map { "r/\($0)" }
        if !subs.isEmpty { return subs.joined(separator: " · ") }
        return "Learning from your likes, loops & watch time"
    }

    func resetAlgorithm() {
        data.algorithm = AlgorithmProfile()
    }

    func eraseAll() {
        saveTask?.cancel()
        seenSet.removeAll()
        OfflineManager.shared.clearAllDownloads()
        var fresh = UserData()
        fresh.r34Credentials.resetToDefault()
        data = fresh
        try? FileManager.default.removeItem(at: Self.fileURL)
        Task {
            await XWebEngine.shared.resetSession()
            await InstagramWebEngine.shared.resetSession()
        }
    }
}

// MARK: - Canonical Porn-Specific Category & Tag Catalog

enum PornTagCatalog {
    static let quickPickerCategories: [String] = [
        "ebony", "femboy", "trans", "goth", "hentai", "rule34", "latina", "asian",
        "milf", "petite", "curvy", "big_tits", "ass", "anal", "blowjob", "creampie",
        "cumshot", "futanari", "ahegao", "cosplay", "bdsm", "femdom", "lesbian",
        "threesome", "pov", "amateur", "public", "solo", "squirt", "interracial"
    ]

    static let canonicalTags: Set<String> = [
        "ebony", "femboy", "trans", "futanari", "hentai", "rule34", "ahegao", "cosplay",
        "goth", "bimbo", "milf", "mature", "teen", "petite", "curvy", "thick", "pawg",
        "bbw", "latina", "asian", "jav", "indian", "interracial", "bbc", "redhead",
        "blonde", "brunette", "amateur", "homemade", "onlyfans", "tiktok_nsfw", "snapchat_nsfw",
        "lesbian", "gay", "twink", "bisexual", "threesome", "gangbang", "cuckold", "hotwife",
        "freeuse", "public", "pov", "solo", "masturbation", "joi", "vintage", "anal", "ass",
        "twerk", "big_tits", "boobs", "natural_tits", "blowjob", "deepthroat", "facefuck",
        "handjob", "titfuck", "paizuri", "creampie", "breeding", "cumshot", "facial",
        "cumslut", "squirt", "orgasm", "grool", "pussy", "innie", "gape", "fisting", "bdsm",
        "bondage", "femdom", "pegging", "facesitting", "spanking", "choking", "rough",
        "hardcore", "feet", "footjob", "stockings", "thigh_highs", "lingerie", "latex",
        "upskirt", "flashing", "oil", "tentacle", "hypno", "monster_girl", "elf",
        "succubus", "bunny_girl", "maid", "nurse", "flexible", "riding", "cowgirl",
        "doggystyle", "missionary", "prone_bone", "dildo", "vibrator", "fucking_machine",
        "gooning"
    ]

    static let aliases: [String: String] = [
        // Identities / Orientations / Niches
        "ebony": "ebony", "ebonycuties": "ebony", "ebonyhomemade": "ebony",
        "ebonythroatqueens": "ebony", "blacktittyworld": "ebony", "blackgirl": "ebony", "darkskin": "ebony",
        "femboy": "femboy", "femboys": "femboy", "sissy": "femboy", "sissies": "femboy",
        "trap": "femboy", "traps": "femboy", "trapsgonewild": "femboy", "straighttosissy": "femboy", "boypussy": "femboy",
        "trans": "trans", "transgender": "trans", "tgirl": "trans", "tgirls": "trans",
        "transgirl": "trans", "transgirls": "trans", "transporn": "trans", "gonewildtrans": "trans",
        "mtf": "trans", "shemale": "trans", "ladyboy": "trans", "transwoman": "trans",
        "futa": "futanari", "futanari": "futanari", "futanarigifs": "futanari", "dickgirl": "futanari",
        "hentai": "hentai", "hentai_gif": "hentai", "hentai__videos": "hentai", "doujinshi": "hentai", "ecchi": "hentai",
        "rule34": "rule34", "r34": "rule34", "overwatch_porn": "rule34",
        "ahegao": "ahegao", "realahegao": "ahegao", "ahegao_irl": "ahegao", "ahegaogirls": "ahegao", "ahegaos": "ahegao", "ahegaohardcore": "ahegao",
        "cosplay": "cosplay", "cosplaygirls": "cosplay", "nsfwcosplay": "cosplay", "cosplaybabes": "cosplay", "cosplaypornvideos": "cosplay", "cosplaylewd": "cosplay",
        "goth": "goth", "gothgirl": "goth", "gothgf": "goth", "bigtiddygothgf": "goth", "gothsluts": "goth", "altgonewild": "goth", "gothgirlsgw": "goth", "suicidegirls": "goth",
        "bimbo": "bimbo", "bimbofetish": "bimbo", "bimbocumsluts": "bimbo", "bimbolovers": "bimbo", "enhancedfucktoys": "bimbo",
        // Ages / Builds / Ethnicities
        "milf": "milf", "milfs": "milf", "maturemilf": "milf", "realmoms": "milf", "gonewild30plus": "milf", "mommy": "milf",
        "teen": "teen", "teens": "teen", "legalteens": "teen", "barelylegalteens": "teen", "18_19": "teen", "teenbeauties": "teen", "collegeamateurs": "teen",
        "petite": "petite", "petitegonewild": "petite", "bustypetite": "petite", "lipsthatgrip": "petite", "tiny": "petite",
        "curvy": "curvy", "massivetitsnass": "curvy", "slimthick": "curvy", "thickwhitegirls": "curvy",
        "pawg": "pawg", "thick": "thick", "thicc": "thick", "chubby": "bbw", "bbw": "bbw", "bbwhardcore": "bbw", "bbwvideos": "bbw",
        "latina": "latina", "latinas": "latina", "latinacuties": "latina", "mexicana": "latina", "latinchickswhitedicks": "latina",
        "asian": "asian", "asiansgonewild": "asian", "asianhotties": "asian", "bustyasians": "asian", "nsfw_japan": "asian", "asiancumsluts": "asian",
        "jav": "jav", "indian": "indian", "indiansgonewild": "indian", "indianhotwife": "indian", "desiindiansex": "indian",
        "interracial": "interracial", "blacked": "interracial", "blackedpawgs": "interracial", "blackchickswhitedicks": "interracial",
        "bbc": "bbc", "bbcparadise": "bbc",
        "redhead": "redhead", "redheads": "redhead", "ginger": "redhead", "gingerbeauties": "redhead", "petitegingers": "redhead", "redheadmilfs": "redhead", "redheadsporn": "redhead",
        // Styles / Platforms
        "amateur": "amateur", "realgirls": "amateur", "homemadexxx": "homemade", "homemade": "homemade", "onoff": "amateur", "gonewild": "amateur",
        "onlyfans": "onlyfans", "onlyfans101": "onlyfans", "slutsofonlyfans": "onlyfans", "onlyfanshottest": "onlyfans", "onlyfans_blessed": "onlyfans", "onlyfans_wild": "onlyfans",
        "tiktokporn": "tiktok_nsfw", "tiktoknsfw": "tiktok_nsfw", "tiktokthots": "tiktok_nsfw", "tiktok_ass": "tiktok_nsfw", "tiktok_tits": "tiktok_nsfw",
        "slutsofsnapchat": "snapchat_nsfw", "nsfw_snapchat": "snapchat_nsfw",
        "lesbian": "lesbian", "lesbians": "lesbian", "girlskissing": "lesbian", "girlswithgirls": "lesbian", "lesbian_gifs": "lesbian", "cutelesbians": "lesbian", "wlw": "lesbian",
        "gay": "gay", "gayporn": "gay", "malesmasturbating": "gay", "gaybrosgonewild": "gay", "twink": "twink",
        "threesome": "threesome", "threesomesnsfw": "threesome", "threesomegw": "threesome",
        "gangbang": "gangbang", "groupsex_gw": "gangbang", "groupsexnsfw": "gangbang",
        "cuckold": "cuckold", "hotwife": "hotwife", "hotwifecuckolds": "cuckold", "wifesharing": "cuckold",
        "freeuse": "freeuse", "public": "public", "publicsexporn": "public", "publicflashing": "public", "flashing": "flashing", "upskirt": "upskirt",
        "pov": "pov", "cheatingpov": "pov", "femalepov": "pov", "doggystylepov": "pov",
        "solo": "solo", "gettingherselfoff": "solo", "jilling": "solo", "fingering": "solo", "masturbation": "masturbation", "joi": "joi",
        "vintage": "vintage", "vintagebabes": "vintage", "vintagesmut": "vintage",
        // Body Parts & Acts
        "anal": "anal", "analgw": "anal", "analgonewild": "anal", "anal_gifs": "anal", "upherbutt": "anal", "buttsex": "anal", "asshole": "anal",
        "ass": "ass", "bigass": "ass", "bigasses": "ass", "booty": "ass", "twerk": "twerk", "twerking": "twerk",
        "bigtits": "big_tits", "big_tits": "big_tits", "big_breasts": "big_tits", "large_breasts": "big_tits", "tittydrop": "big_tits", "boobbounce": "big_tits", "stacked": "big_tits", "busty": "big_tits",
        "boobs": "boobs", "tits": "boobs", "boobies": "boobs", "breasts": "boobs", "natural_tits": "natural_tits",
        "blowjob": "blowjob", "blowjobs": "blowjob", "oral": "blowjob", "sucking": "blowjob", "girlsfinishingthejob": "blowjob", "gawkgawkgawk": "blowjob",
        "deepthroat": "deepthroat", "facefuck": "facefuck", "handjob": "handjob", "femdomhandjob": "handjob", "titfuck": "titfuck", "paizuri": "paizuri",
        "creampie": "creampie", "creampies": "creampie", "creampieflowingout": "creampie", "breeding": "breeding", "breeding_her": "breeding", "breedmedaddy": "breeding", "breedingmaterial": "breeding",
        "cumshot": "cumshot", "cumshots": "cumshot", "cum": "cumshot", "coveredincum": "cumshot", "facial": "facial", "facials": "facial", "cumslut": "cumslut", "cumsluts": "cumslut",
        "squirt": "squirt", "squirting": "squirt", "orgasm": "orgasm", "orgasms": "orgasm", "grool": "grool",
        "pussy": "pussy", "rearpussy": "pussy", "pussy_perfection": "pussy", "innie": "innie", "innies": "innie", "gape": "gape", "fisting": "fisting", "pussystretching": "fisting",
        // Kinks / Positions / Fantasy
        "bdsm": "bdsm", "bdsmgw": "bdsm", "bondage": "bondage", "sheLikesitrough": "bdsm", "shelikesitrough": "bdsm", "dominated": "bdsm",
        "femdom": "femdom", "pegging": "pegging", "facesitting": "facesitting", "spanking": "spanking", "strapon": "femdom",
        "hardcore": "hardcore", "hardcorensfw": "hardcore", "nsfwhardcore": "hardcore", "roughporn": "rough", "rough": "rough", "rough_sex": "rough",
        "feet": "feet", "feetfuckers": "feet", "feet_nsfw": "feet", "feetinyourface": "feet", "vipfeet": "feet", "footjob": "footjob",
        "stockings": "stockings", "thighhighs": "thigh_highs", "thigh_highs": "thigh_highs", "lingerie": "lingerie", "latex": "latex",
        "oilporn": "oil", "wetoil": "oil", "oil": "oil", "tentai": "tentacle", "tentacle": "tentacle", "tentacles": "tentacle",
        "hypno": "hypno", "monstergirl": "monster_girl", "monster_girl": "monster_girl", "elf": "elf", "succubus": "succubus", "bunny_girl": "bunny_girl", "maid": "maid", "nurse": "nurse",
        "cowgirl": "cowgirl", "riding": "riding", "doggystyle": "doggystyle", "missionary": "missionary", "pronebone": "prone_bone", "prone_bone": "prone_bone",
        "dildo": "dildo", "hugedildos": "dildo", "vibrator": "vibrator", "fuckingmachine": "fucking_machine", "fuckingmachines": "fucking_machine", "fucking_machine": "fucking_machine",
        "gooned": "gooning", "gooning": "gooning", "pornrelapsed": "gooning"
    ]

    static let relatedTags: [String: [String]] = [
        "ebony": ["curvy", "ass", "interracial", "bbc", "big_tits"],
        "femboy": ["trans", "anal", "thigh_highs", "solo", "dildo"],
        "trans": ["femboy", "anal", "blowjob", "solo", "threesome"],
        "futanari": ["hentai", "rule34", "creampie", "big_tits"],
        "hentai": ["rule34", "ahegao", "futanari", "tentacle", "paizuri"],
        "rule34": ["hentai", "futanari", "cosplay", "ahegao"],
        "goth": ["alt", "amateur", "big_tits", "bdsm", "stockings"],
        "latina": ["curvy", "ass", "pawg", "big_tits"],
        "asian": ["petite", "jav", "amateur", "cosplay"],
        "milf": ["mature", "curvy", "big_tits", "creampie"],
        "petite": ["teen", "anal", "blowjob", "pov"],
        "curvy": ["thick", "pawg", "ass", "big_tits"],
        "big_tits": ["boobs", "natural_tits", "titfuck", "milf", "curvy"],
        "anal": ["ass", "gape", "creampie", "doggystyle", "femboy"],
        "blowjob": ["deepthroat", "facefuck", "facial", "cumshot", "cumslut"],
        "creampie": ["breeding", "pussy", "hardcore", "cumshot"],
        "bdsm": ["femdom", "bondage", "rough", "hardcore", "spanking"],
        "femdom": ["bdsm", "pegging", "facesitting", "handjob"],
        "cosplay": ["ahegao", "hentai", "rule34", "stockings"],
        "lesbian": ["solo", "facesitting", "pussy", "squirt"]
    ]

    static func normalize(_ raw: String, categories: [GoonedCategory]) -> String? {
        let cleaned = raw.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
            .replacingOccurrences(of: "r/", with: "")
        guard !cleaned.isEmpty else { return nil }
        if canonicalTags.contains(cleaned) { return cleaned }
        if let mapped = aliases[cleaned] { return mapped }
        for cat in categories {
            if cat.name.lowercased() == cleaned { return cat.name.lowercased() }
            if cat.subreddits.contains(where: { $0.lowercased() == cleaned }) {
                let cName = cat.name.lowercased()
                return aliases[cName] ?? (canonicalTags.contains(cName) ? cName : nil)
            }
        }
        return nil
    }

    static func extractRecognizedTags(from post: Gif, categories: [GoonedCategory]) -> [String] {
        var found = Set<String>()

        if let sub = post.subreddit, !sub.isEmpty {
            if let norm = normalize(sub, categories: categories) {
                found.insert(norm)
            } else {
                let subLower = sub.lowercased()
                for key in ["ebony", "femboy", "trans", "futanari", "hentai", "rule34", "latina", "asian", "milf", "goth", "cosplay", "lesbian", "bdsm", "femdom", "anal", "blowjob", "creampie", "cumshot", "squirt", "petite", "curvy", "pawg", "bbw", "amateur", "redhead", "interracial", "threesome", "onlyfans"] {
                    if subLower.contains(key) {
                        found.insert(key)
                    }
                }
            }
        }

        if let title = post.title?.lowercased(), !title.isEmpty {
            let rawTokens = title
                .replacingOccurrences(of: "#", with: " ")
                .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).inverted)
                .filter { !$0.isEmpty }

            for i in rawTokens.indices {
                let t = rawTokens[i]
                if let norm = normalize(t, categories: categories) {
                    found.insert(norm)
                }
                if i + 1 < rawTokens.count {
                    let pair = "\(t)_\(rawTokens[i + 1])"
                    if let normPair = normalize(pair, categories: categories) {
                        found.insert(normPair)
                    }
                }
            }
        }

        return Array(found)
    }

    static func extractRecognizedTags(fromQuery rawQuery: String, categories: [GoonedCategory]) -> [String] {
        var found = Set<String>()
        let tokens = rawQuery.lowercased()
            .replacingOccurrences(of: "#", with: " ")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).inverted)
            .filter { !$0.isEmpty }
        for i in tokens.indices {
            if let norm = normalize(tokens[i], categories: categories) {
                found.insert(norm)
            }
            if i + 1 < tokens.count {
                let pair = "\(tokens[i])_\(tokens[i + 1])"
                if let normPair = normalize(pair, categories: categories) {
                    found.insert(normPair)
                }
            }
        }
        return Array(found)
    }

    static func displayTitle(for tag: String) -> String {
        switch tag.lowercased() {
        case "femboy": return "Femboys"
        case "ebony": return "Ebony"
        case "trans": return "Trans"
        case "milf": return "MILF"
        case "bdsm": return "BDSM"
        case "pov": return "POV"
        case "bbw": return "BBW"
        case "bbc": return "BBC"
        case "pawg": return "PAWG"
        case "jav": return "JAV"
        case "joi": return "JOI"
        case "big_tits": return "Big Tits"
        case "natural_tits": return "Natural Tits"
        case "thigh_highs": return "Thigh Highs"
        case "monster_girl": return "Monster Girl"
        case "bunny_girl": return "Bunny Girl"
        case "fucking_machine": return "Fucking Machine"
        case "prone_bone": return "Prone Bone"
        case "tiktok_nsfw": return "TikTok NSFW"
        case "snapchat_nsfw": return "Snapchat NSFW"
        default:
            return tag.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

// MARK: - Strict Porn-Only Content Eligibility Classifier

enum AdultContentClassifier {
    static let sfwBlockedSubreddits: Set<String> = [
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
    ]

    static let sfwBlockedTerms: [String] = [
        "#nba", "#nfl", "#ufc", "#fifa", "#mlb", "#nhl", "#premierleague", "#championsleague",
        "#election", "#trump", "#biden", "#kamala", "#breakingnews", "#foxnews", "#cnn", "#msnbc",
        "#minecraft", "#roblox", "#valorant", "#warzone", "#esports", "#callofduty", "#fortnitebr",
        "#bitcoin", "#ethereum", "#crypto", "#stockmarket", "#forex", "#tradingview",
        "#recipe", "#cooking", "#baking", "#mealprep", "#workoutroutine", "#gymmotivation",
        "street fight", "knockout", "car crash", "dashcam", "bodycam", "police shooting",
        "press conference", "box score", "touchdown", "home run", "earnings report"
    ]

    private static let explicitAdultMarkers: [String] = [
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
    ]

    static func containsSFWBlockedTerm(_ text: String) -> Bool {
        let lower = text.lowercased()
        return sfwBlockedTerms.contains { lower.contains($0) }
    }

    static func hasExplicitAdultIndicators(_ text: String) -> Bool {
        let lower = text.lowercased()
        if explicitAdultMarkers.contains(where: { lower.contains($0) }) {
            return true
        }
        return !PornTagCatalog.extractRecognizedTags(fromQuery: lower, categories: GoonedCategory.defaultCategories).isEmpty
    }

    static func isEligibleXTweet(
        text: String,
        author: String,
        authorBio: String,
        possiblySensitive: Bool,
        hasAdultWarning: Bool,
        hasGraphicViolenceOnly: Bool,
        routeKey: String
    ) -> Bool {
        if hasGraphicViolenceOnly { return false }
        let combined = "\(text) \(author) \(authorBio)"
        if containsSFWBlockedTerm(combined) { return false }

        // User-curated bookmarks/likes or direct creator feeds still undergo SFW blocklist check,
        // while discovery timelines (x_foryou, x_following, x_search) enforce strict adult verification.
        if routeKey == "x_bookmarks" || routeKey.hasPrefix("x_likes_") || routeKey.hasPrefix("x_user_") {
            return hasAdultWarning || possiblySensitive || hasExplicitAdultIndicators(combined)
        }
        return hasAdultWarning || possiblySensitive || hasExplicitAdultIndicators(combined)
    }

    static func isEligibleIGReel(caption: String, author: String, routeKey: String) -> Bool {
        let combined = "\(caption) \(author)"
        if containsSFWBlockedTerm(combined) { return false }
        // Exclude blatantly non-adult everyday content across all IG feeds
        let sfwIGNoise = ["recipe", "cooking", "baby", "toddler", "kindergarten", "homework", "stock market", "real estate", "mortgage", "nfl", "nba", "premier league", "unboxing", "tech review", "sermon", "bible study"]
        let lower = combined.lowercased()
        if sfwIGNoise.contains(where: { lower.contains($0) }) { return false }

        if routeKey == "ig_reels" {
            // Public Reels discovery must carry explicit adult/creator/glamour markers
            return hasExplicitAdultIndicators(combined)
        }
        // Personal Following, Saved, and explicit @user feeds are allowed once SFW-clean
        return true
    }

    @MainActor
    static func isEligible(_ post: Gif, source: FeedSource, categories: [GoonedCategory], store: UserStore) -> Bool {
        guard post.hasPlayableMedia else { return false }
        guard !store.isBlockedByAlgorithm(post) else { return false }

        if let sub = post.subreddit?.lowercased(), !sub.isEmpty {
            if sfwBlockedSubreddits.contains(sub) { return false }
        }

        let combinedText = "\(post.title ?? "") \(post.author ?? "") \(post.subreddit ?? "")"
        if containsSFWBlockedTerm(combinedText) { return false }

        if post.isRule34Post {
            return true
        }
        if post.isXPost {
            // Tweets already passed XTweetParser verification, re-check against blocked terms
            return !containsSFWBlockedTerm(combinedText)
        }
        if post.isIGPost {
            return !containsSFWBlockedTerm(combinedText)
        }

        // Personal saved lists (Liked / Offline Vault) were explicitly chosen by user
        if source.isList { return true }

        // Reddit / Gooned posts: verify known adult subreddit, redgifs host, or recognized porn tags
        if let sub = post.subreddit?.lowercased(), !sub.isEmpty {
            if categories.contains(where: { $0.subreddits.contains { $0.lowercased() == sub } }) {
                return true
            }
            if sub.contains("porn") || sub.contains("nsfw") || sub.contains("gonewild") || sub.contains("hentai") || sub.contains("rule34") || sub.contains("xxx") || sub.contains("sluts") || sub.contains("fetish") || sub.contains("goon") {
                return true
            }
        }
        if let media = post.mediaUrl?.lowercased(), media.contains("redgifs.com") {
            return true
        }
        if !PornTagCatalog.extractRecognizedTags(from: post, categories: categories).isEmpty {
            return true
        }
        return hasExplicitAdultIndicators(combinedText)
    }
}
