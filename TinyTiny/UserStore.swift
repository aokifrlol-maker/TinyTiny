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
    var videoPreference: Double = 0.5   // > 0.5 favors videos over static images
    var totalSignals: Int = 0

    enum CodingKeys: String, CodingKey {
        case subredditWeights, creatorWeights, tagWeights, videoPreference, totalSignals
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subredditWeights = (try? c.decode([String: Double].self, forKey: .subredditWeights)) ?? [:]
        creatorWeights = (try? c.decode([String: Double].self, forKey: .creatorWeights)) ?? [:]
        tagWeights = (try? c.decode([String: Double].self, forKey: .tagWeights)) ?? [:]
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

    func markSeen(_ id: String) {
        guard !id.isEmpty, seenSet.insert(id).inserted else { return }
        data.seenIDs.append(id)
        if data.seenIDs.count > 4000 {
            let overflow = data.seenIDs.count - 3500
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
            recordAlgorithmSignal(for: g, weight: -2.0)
        } else {
            data.liked.insert(g, at: 0)
            recordAlgorithmSignal(for: g, weight: 4.5)
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
            recordAlgorithmSignal(for: g, weight: 5.5)
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

    // MARK: - Smart On-Device For You Algorithm

    private static let algoStopWords: Set<String> = [
        "the", "and", "for", "with", "you", "your", "this", "that", "from", "have",
        "just", "like", "what", "when", "here", "more", "some", "out", "all", "are",
        "was", "but", "not", "can", "who", "how", "she", "her", "his", "him", "its"
    ]

    private static func extractTokens(from post: Gif) -> [String] {
        guard let raw = post.title?.lowercased(), !raw.isEmpty else { return [] }
        let cleaned = raw
            .replacingOccurrences(of: "#", with: " ")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_")).inverted)
        var tokens: [String] = []
        for t in cleaned where t.count >= 3 && t.count <= 24 && !algoStopWords.contains(t) {
            tokens.append(t)
        }
        return Array(tokens.prefix(8))
    }

    func recordAlgorithmSignal(for post: Gif, weight: Double) {
        guard data.settings.algorithmEnabled else { return }

        // Periodic gentle time-decay so recent tastes always outweigh stale ones
        data.algorithm.totalSignals += 1
        if data.algorithm.totalSignals % 40 == 0 {
            data.algorithm.subredditWeights = data.algorithm.subredditWeights.mapValues { $0 * 0.94 }.filter { abs($0.value) > 0.15 }
            data.algorithm.creatorWeights = data.algorithm.creatorWeights.mapValues { $0 * 0.94 }.filter { abs($0.value) > 0.15 }
            data.algorithm.tagWeights = data.algorithm.tagWeights.mapValues { $0 * 0.94 }.filter { abs($0.value) > 0.15 }
        }

        if let sub = post.subreddit?.lowercased(), !sub.isEmpty {
            let cur = data.algorithm.subredditWeights[sub] ?? 0
            data.algorithm.subredditWeights[sub] = min(max(cur + weight, -10), 40)
        }
        if let author = post.author?.lowercased(), !author.isEmpty {
            let cur = data.algorithm.creatorWeights[author] ?? 0
            data.algorithm.creatorWeights[author] = min(max(cur + weight * 1.15, -10), 40)
        }
        for token in Self.extractTokens(from: post) {
            let cur = data.algorithm.tagWeights[token] ?? 0
            data.algorithm.tagWeights[token] = min(max(cur + weight * 0.45, -8), 30)
        }

        // Track video vs image preference smoothly
        let target: Double = post.isImage ? 0.0 : 1.0
        let alpha = weight > 0 ? 0.06 : 0.02
        data.algorithm.videoPreference = min(max(data.algorithm.videoPreference + (target - data.algorithm.videoPreference) * alpha, 0.1), 0.95)
    }

    func recordDwellSignal(for post: Gif, secondsWatched: TimeInterval) {
        if secondsWatched >= 4.0 {
            recordAlgorithmSignal(for: post, weight: 1.4)
        } else if secondsWatched < 1.2 {
            recordAlgorithmSignal(for: post, weight: -0.6)
        }
    }

    func scorePost(_ post: Gif) -> Double {
        guard data.settings.algorithmEnabled else { return 0 }
        var score = 0.0
        if let sub = post.subreddit?.lowercased() {
            score += (data.algorithm.subredditWeights[sub] ?? 0) * 1.4
            if isFollowingSubreddit(sub) { score += 3.5 }
        }
        if let author = post.author?.lowercased() {
            score += (data.algorithm.creatorWeights[author] ?? 0) * 1.6
            if isFollowingUser(author) || isFollowingXUser(author) || isFollowingIGUser(author) {
                score += 4.0
            }
        }
        for token in Self.extractTokens(from: post) {
            score += (data.algorithm.tagWeights[token] ?? 0) * 0.8
        }
        if !post.isImage {
            score += (data.algorithm.videoPreference - 0.5) * 4.0
        }
        if let up = post.upvotes, up > 0 {
            score += min(log10(Double(up)) * 0.6, 2.5)
        }
        return score
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
        data.algorithm.subredditWeights
            .filter { $0.value > 1.5 }
            .sorted { $0.value > $1.value }
            .prefix(5)
            .map(\.key)
    }

    var topTasteSummary: String {
        let subs = topAlgorithmSubreddits.prefix(3).map { "r/\($0)" }
        if !subs.isEmpty { return subs.joined(separator: " · ") }
        let tags = data.algorithm.tagWeights.filter { $0.value > 1.0 }.sorted { $0.value > $1.value }.prefix(3).map { "#\($0.key)" }
        if !tags.isEmpty { return tags.joined(separator: " · ") }
        return "Learning from your likes & watch time"
    }

    func resetAlgorithm() {
        data.algorithm = AlgorithmProfile()
    }

    func eraseAll() {
        saveTask?.cancel()
        seenSet.removeAll()
        OfflineManager.shared.clearAllDownloads()
        data = UserData()
        try? FileManager.default.removeItem(at: Self.fileURL)
        Task {
            await XWebEngine.shared.resetSession()
            await InstagramWebEngine.shared.resetSession()
        }
    }
}
