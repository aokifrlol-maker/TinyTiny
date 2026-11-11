import SwiftUI

struct AppSettings: Codable {
    var hd = false
    var muted = false
    var faceID = false
}

struct UserData: Codable {
    var liked: [Gif] = []          // newest first
    var following: [RGUser] = []   // creators
    var joinedNiches: [Niche] = [] // categories
    var tagAff: [String: Double] = [:]
    var nicheAff: [String: Double] = [:]
    var creatorAff: [String: Double] = [:]
    var seen: [String] = []
    var settings = AppSettings()
}

/// Everything about "you" lives here, on-device only.
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
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        if let raw = try? JSONEncoder().encode(data) {
            try? raw.write(to: Self.fileURL, options: [.atomic, .completeFileProtection])
        }
    }

    // MARK: Likes

    func isLiked(_ g: Gif) -> Bool { data.liked.contains { $0.id == g.id } }

    func toggleLike(_ g: Gif) {
        if let i = data.liked.firstIndex(where: { $0.id == g.id }) {
            data.liked.remove(at: i)
            adjust(g, by: -2)
        } else {
            data.liked.insert(g, at: 0)
            adjust(g, by: 3)
        }
    }

    func like(_ g: Gif) {
        if !isLiked(g) { toggleLike(g) }
    }

    func notInterested(_ g: Gif) {
        markSeen(g.id)
        adjust(g, by: -3)
    }

    // MARK: Following

    func isFollowing(_ name: String) -> Bool {
        data.following.contains { $0.username.caseInsensitiveCompare(name) == .orderedSame }
    }

    func toggleFollow(_ name: String, user: RGUser? = nil) {
        if let i = data.following.firstIndex(where: { $0.username.caseInsensitiveCompare(name) == .orderedSame }) {
            data.following.remove(at: i)
            data.creatorAff[name, default: 0] -= 4
        } else {
            data.following.insert(user ?? RGUser(username: name), at: 0)
            data.creatorAff[name, default: 0] += 5
        }
    }

    func updateFollowedUser(_ u: RGUser) {
        if let i = data.following.firstIndex(where: { $0.username.caseInsensitiveCompare(u.username) == .orderedSame }) {
            if data.following[i] != u { data.following[i] = u }
        }
    }

    // MARK: Categories

    func isJoined(_ id: String) -> Bool { data.joinedNiches.contains { $0.id == id } }

    func toggleJoin(_ n: Niche) {
        if let i = data.joinedNiches.firstIndex(where: { $0.id == n.id }) {
            data.joinedNiches.remove(at: i)
            data.nicheAff[n.id, default: 0] -= 4
        } else {
            data.joinedNiches.insert(n, at: 0)
            data.nicheAff[n.id, default: 0] += 5
        }
    }

    // MARK: Algorithm

    /// Nudges your interest in everything about a post (its tags, categories and creator).
    func adjust(_ g: Gif, by w: Double) {
        var d = data
        for t in g.allTags { d.tagAff[t] = clamp((d.tagAff[t] ?? 0) + w) }
        for n in g.allNiches { d.nicheAff[n] = clamp((d.nicheAff[n] ?? 0) + w) }
        if let u = g.userName { d.creatorAff[u] = clamp((d.creatorAff[u] ?? 0) + w * 1.2) }
        prune(&d.tagAff, max: 600)
        prune(&d.nicheAff, max: 300)
        prune(&d.creatorAff, max: 400)
        data = d
    }

    /// Called when you scroll away from a post. Watching it through = interest, instant skip = disinterest.
    func recordWatch(_ g: Gif, seconds: Double) {
        markSeen(g.id)
        let dur = max(g.duration ?? 8, 1)
        if seconds >= min(dur * 0.9, 20) {
            adjust(g, by: seconds > dur * 1.8 ? 1.5 : 1.0) // rewatched = extra signal
        } else if seconds < 1.5 {
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
        let tags = g.allTags
        if !tags.isEmpty {
            s += tags.reduce(0) { $0 + (data.tagAff[$1] ?? 0) } / Double(tags.count).squareRoot()
        }
        let niches = g.allNiches
        if !niches.isEmpty {
            s += niches.reduce(0) { $0 + (data.nicheAff[$1] ?? 0) } / Double(niches.count).squareRoot()
        }
        if let u = g.userName {
            s += data.creatorAff[u] ?? 0
            if isFollowing(u) { s += 3 }
        }
        return s
    }

    func topTags(_ n: Int) -> [(String, Double)] {
        data.tagAff.filter { $0.value > 0 }.sorted { $0.value > $1.value }.prefix(n).map { ($0.key, $0.value) }
    }

    func topNiches(_ n: Int) -> [(String, Double)] {
        var aff = data.nicheAff
        for j in data.joinedNiches { aff[j.id] = max(aff[j.id] ?? 0, 5) }
        return aff.filter { $0.value > 0 }.sorted { $0.value > $1.value }.prefix(n).map { ($0.key, $0.value) }
    }

    func resetAlgorithm() {
        data.tagAff = [:]
        data.nicheAff = [:]
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

    private func clamp(_ v: Double) -> Double { min(max(v, -15), 60) }

    private func prune(_ dict: inout [String: Double], max count: Int) {
        guard dict.count > count else { return }
        let keep = dict.sorted { abs($0.value) > abs($1.value) }.prefix(count)
        dict = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
    }
}

func weightedPick(_ items: [(String, Double)]) -> String? {
    guard !items.isEmpty else { return nil }
    let total = items.reduce(0) { $0 + max($1.1, 0.1) }
    var r = Double.random(in: 0..<total)
    for (k, v) in items {
        r -= max(v, 0.1)
        if r <= 0 { return k }
    }
    return items.last?.0
}

