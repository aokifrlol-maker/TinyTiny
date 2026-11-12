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

    enum CodingKeys: String, CodingKey {
        case hd, muted, faceID, autoScroll, autoScrollDelay, playVideosToEnd, tintedGlass, videoFitScreen, controlsCollapsed
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
    }
}

struct RecentFeedEntry: Codable, Hashable, Identifiable {
    var id: String { "\(kind):\(name)" }
    var kind: String // "foryou", "category", "subreddit", "user", "xforyou", "xuser", "xsearch"
    var name: String
    var displayTitle: String
    var swipedCount: Int
    var updatedAt: Date
}

struct UserData: Codable {
    var liked: [Gif] = []
    var followedSubreddits: [String] = []
    var followedUsers: [String] = []
    var followedXUsers: [String] = []
    var recentFeeds: [RecentFeedEntry] = []
    var seenIDs: [String] = []
    var savedCursors: [String: String] = [:]
    var swipedTotal: Int = 0
    var settings = AppSettings()
    var xSession = XAccountSession()

    enum CodingKeys: String, CodingKey {
        case liked, followedSubreddits, followedUsers, followedXUsers, recentFeeds, seenIDs, savedCursors, swipedTotal, settings, xSession
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        liked = (try? c.decode([Gif].self, forKey: .liked)) ?? []
        followedSubreddits = (try? c.decode([String].self, forKey: .followedSubreddits)) ?? []
        followedUsers = (try? c.decode([String].self, forKey: .followedUsers)) ?? []
        followedXUsers = (try? c.decode([String].self, forKey: .followedXUsers)) ?? []
        recentFeeds = (try? c.decode([RecentFeedEntry].self, forKey: .recentFeeds)) ?? []
        seenIDs = (try? c.decode([String].self, forKey: .seenIDs)) ?? []
        savedCursors = (try? c.decode([String: String].self, forKey: .savedCursors)) ?? [:]
        swipedTotal = (try? c.decode(Int.self, forKey: .swipedTotal)) ?? 0
        settings = (try? c.decode(AppSettings.self, forKey: .settings)) ?? AppSettings()
        xSession = (try? c.decode(XAccountSession.self, forKey: .xSession)) ?? XAccountSession()
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

    // MARK: - Likes (Stash)

    func isLiked(_ g: Gif) -> Bool {
        data.liked.contains { $0.id == g.id }
    }

    func toggleLike(_ g: Gif) {
        if let i = data.liked.firstIndex(where: { $0.id == g.id }) {
            data.liked.remove(at: i)
        } else {
            data.liked.insert(g, at: 0)
        }
    }

    func like(_ g: Gif) {
        if !isLiked(g) { toggleLike(g) }
    }

    // MARK: - Follows (Subreddits, Reddit Creators & X Creators)

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

    func disconnectX() {
        data.xSession = XAccountSession()
        Task { await XWebEngine.shared.resetSession() }
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

    func eraseAll() {
        saveTask?.cancel()
        seenSet.removeAll()
        data = UserData()
        try? FileManager.default.removeItem(at: Self.fileURL)
        Task { await XWebEngine.shared.resetSession() }
    }
}
