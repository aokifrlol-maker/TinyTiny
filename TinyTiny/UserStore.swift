import SwiftUI

struct AppSettings: Codable {
    var hd = false
    var muted = false
    var faceID = false
    var autoplayFeed = true
}

struct UserData: Codable {
    var liked: [Gif] = []                  // newest first (Likes = your recommendation signal)
    var saved: [Gif] = []                  // bookmarked / saved posts
    var following: [RGUser] = []           // followed creators
    var followedSubreddits: [String] = []  // followed 18+ subreddits (e.g. "gonewild")
    var favoriteCategoryIDs: [String] = [] // pinned predefined categories
    var recentSearches: [String] = []      // search history
    var categoryAff: [String: Double] = [:]
    var tagAff: [String: Double] = [:]
    var creatorAff: [String: Double] = [:]
    var seen: [String] = []
    var settings = AppSettings()
}

@MainActor
final class UserStore: ObservableObject {
    static let shared = UserStore()

    @Published var data: UserData { didSet { scheduleSave() } }
    private var seenSet: Set<String>
    private var saveTask: Task<Void, Never>?

    private static var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("userdata.json")
    }

    init() {
        let loaded: UserData
        if let raw = try? Data(contentsOf: Self.fileURL),
           let decoded = try? JSONDecoder().decode(UserData.self, from: raw) {
            loaded = decoded
        } else {
            loaded = UserData()
        }
        self.data = loaded
        self.seenSet = Set(loaded.seen)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        if let raw = try? JSONEncoder().encode(data) {
            try? raw.write(to: Self.fileURL, options: [.atomic, .completeFileProtection])
        }
    }

    // MARK: Likes (Primary Interest Signal)

    func isLiked(_ g: Gif) -> Bool { data.liked.contains { $0.id == g.id } }

    func toggleLike(_ g: Gif) {
        if let i = data.liked.firstIndex(where: { $0.id == g.id }) {
            data.liked.remove(at: i)
            adjust(g, by: -3.5)
        } else {
            data.liked.insert(g, at: 0)
            adjust(g, by: 5.0)
        }
    }

    func like(_ g: Gif) {
        if !isLiked(g) { toggleLike(g) }
    }

    // MARK: Saved / Bookmarks

    func isSaved(_ g: Gif) -> Bool { data.saved.contains { $0.id == g.id } }

    func toggleSave(_ g: Gif) {
        if let i = data.saved.firstIndex(where: { $0.id == g.id }) {
            data.saved.remove(at: i)
            adjust(g, by: -2.0)
        } else {
            data.saved.insert(g, at: 0)
            adjust(g, by: 4.5)
        }
    }

    // MARK: Following Creators & Subreddits

    func isFollowing(_ name: String) -> Bool {
        data.following.contains { $0.username.caseInsensitiveCompare(name) == .orderedSame }
    }

    func toggleFollow(_ name: String, user: RGUser? = nil) {
        if let i = data.following.firstIndex(where: { $0.username.caseInsensitiveCompare(name) == .orderedSame }) {
            data.following.remove(at: i)
            data.creatorAff[name, default: 0] -= 4
        } else {
            data.following.insert(user ?? RGUser(username: name), at: 0)
            data.creatorAff[name, default: 0] += 6
        }
    }

    func updateFollowedUser(_ u: RGUser) {
        if let i = data.following.firstIndex(where: { $0.username.caseInsensitiveCompare(u.username) == .orderedSame }) {
            if data.following[i] != u { data.following[i] = u }
        }
    }

    func isFollowingSubreddit(_ sub: String) -> Bool {
        data.followedSubreddits.contains { $0.caseInsensitiveCompare(sub) == .orderedSame }
    }

    func toggleFollowSubreddit(_ sub: String) {
        if let i = data.followedSubreddits.firstIndex(where: { $0.caseInsensitiveCompare(sub) == .orderedSame }) {
            data.followedSubreddits.remove(at: i)
        } else {
            data.followedSubreddits.insert(sub, at: 0)
        }
    }

    // MARK: Predefined Categories (Fixed 10)

    func isFavoriteCategory(_ id: String) -> Bool {
        data.favoriteCategoryIDs.contains(id)
    }

    func toggleFavoriteCategory(_ cat: GoonedCategory) {
        if let i = data.favoriteCategoryIDs.firstIndex(of: cat.id) {
            data.favoriteCategoryIDs.remove(at: i)
            data.categoryAff[cat.id, default: 0] -= 4
        } else {
            data.favoriteCategoryIDs.insert(cat.id, at: 0)
            data.categoryAff[cat.id, default: 0] += 6
        }
    }

    var favoriteCategories: [GoonedCategory] {
        data.favoriteCategoryIDs.compactMap { id in GoonedCategory.all.first { $0.id == id } }
    }

    // MARK: Recent Searches

    func addRecentSearch(_ q: String) {
        let trimmed = q.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        data.recentSearches.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        data.recentSearches.insert(trimmed, at: 0)
        if data.recentSearches.count > 12 {
            data.recentSearches = Array(data.recentSearches.prefix(12))
        }
    }

    func clearRecentSearches() {
        data.recentSearches = []
    }

    // MARK: Recommendation Engine (Driven by Likes & Watch Time)

    func adjust(_ g: Gif, by w: Double) {
        var d = data
        let cat = g.category
        d.categoryAff[cat.id] = clamp((d.categoryAff[cat.id] ?? 0) + w * 1.4)
        for t in g.allTags { d.tagAff[t] = clamp((d.tagAff[t] ?? 0) + w * 0.8) }
        if let u = g.userName { d.creatorAff[u] = clamp((d.creatorAff[u] ?? 0) + w * 1.2) }
        prune(&d.tagAff, max: 500)
        prune(&d.creatorAff, max: 400)
        data = d
    }

    func recordWatch(_ g: Gif, seconds: Double) {
        markSeen(g.id)
        let dur = max(g.duration ?? 8, 1)
        if seconds >= min(dur * 0.85, 18) {
            adjust(g, by: seconds > dur * 1.7 ? 1.8 : 1.0)
        } else if seconds < 1.2 {
            adjust(g, by: -0.4)
        }
    }

    func markSeen(_ id: String) {
        guard seenSet.insert(id).inserted else { return }
        data.seen.append(id)
        if data.seen.count > 4000 {
            data.seen.removeFirst(800)
            seenSet = Set(data.seen)
        }
    }

    func hasSeen(_ id: String) -> Bool { seenSet.contains(id) }

    func score(_ g: Gif) -> Double {
        var s = 0.0
        let cat = g.category
        s += (data.categoryAff[cat.id] ?? 0) * 1.3
        if isFavoriteCategory(cat.id) { s += 3.5 }

        let tags = g.allTags
        if !tags.isEmpty {
            s += tags.reduce(0) { $0 + (data.tagAff[$1] ?? 0) } / Double(tags.count).squareRoot()
        }
        if let u = g.userName {
            s += data.creatorAff[u] ?? 0
            if isFollowing(u) { s += 4.0 }
        }
        if let sub = g.subreddit, isFollowingSubreddit(sub) {
            s += 4.5
        }
        return s
    }

    func topCategories(_ n: Int = 5) -> [(GoonedCategory, Double)] {
        var aff = data.categoryAff
        for id in data.favoriteCategoryIDs {
            aff[id] = max(aff[id] ?? 0, 6.0)
        }
        return GoonedCategory.all
            .compactMap { cat -> (GoonedCategory, Double)? in
                let val = aff[cat.id] ?? 0
                return val > 0 ? (cat, val) : nil
            }
            .sorted { $0.1 > $1.1 }
            .prefix(n)
            .map { $0 }
    }

    func topTags(_ n: Int) -> [(String, Double)] {
        data.tagAff.filter { $0.value > 0 }.sorted { $0.value > $1.value }.prefix(n).map { ($0.key, $0.value) }
    }

    func resetAlgorithm() {
        data.categoryAff = [:]
        data.tagAff = [:]
        data.creatorAff = [:]
        data.seen = []
        seenSet = []
    }

    func eraseAll() {
        saveTask?.cancel()
        data = UserData()
        seenSet = []
        try? FileManager.default.removeItem(at: Self.fileURL)
    }

    private func clamp(_ v: Double) -> Double { min(max(v, -20), 75) }

    private func prune(_ dict: inout [String: Double], max count: Int) {
        guard dict.count > count else { return }
        let keep = dict.sorted { abs($0.value) > abs($1.value) }.prefix(count)
        dict = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }
}

func weightedPick<T>(_ items: [(T, Double)]) -> T? {
    guard !items.isEmpty else { return nil }
    let total = items.reduce(0) { $0 + max($1.1, 0.1) }
    var r = Double.random(in: 0..<total)
    for (k, v) in items {
        r -= max(v, 0.1)
        if r <= 0 { return k }
    }
    return items.last?.0
}
