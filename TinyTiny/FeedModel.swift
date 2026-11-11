import SwiftUI

enum FeedSource: Hashable {
    case forYou
    case following
    case tag(String, order: String)
    case niche(String, order: String?)
    case user(String)
    case list
}

@MainActor
final class FeedModel: ObservableObject {
    @Published private(set) var items: [Gif] = []
    @Published private(set) var isLoading = false
    @Published var errorText: String?
    @Published var user: RGUser?

    let source: FeedSource
    private var page = 1
    private var pages = Int.max
    private var ids = Set<String>()
    private var trendingPage = 1
    private var followPages: [String: Int] = [:]
    private var followDone = Set<String>()

    init(source: FeedSource, items: [Gif] = []) {
        self.source = source
        self.items = items
        self.ids = Set(items.map(\.id))
        if case .list = source { pages = 0 }
    }

    var canLoadMore: Bool {
        if case .list = source { return false }
        return page <= pages
    }

    func onItemAppear(_ g: Gif) {
        if items.suffix(5).contains(where: { $0.id == g.id }) {
            Task { await loadMore() }
        }
    }

    func refresh() async {
        items = []
        ids = []
        page = 1
        pages = .max
        trendingPage = 1
        followPages = [:]
        followDone = []
        errorText = nil
        await loadMore()
    }

    func loadMore() async {
        guard !isLoading, canLoadMore else { return }
        isLoading = true
        defer { isLoading = false }
        let api = RedGifsAPI.shared
        do {
            var new: [Gif] = []
            switch source {
            case .forYou:
                new = await loadForYou()
                if new.isEmpty { throw APIError.http(0) }
            case .following:
                new = await loadFollowing()
            case .tag(let t, let order):
                let p = try await api.search(t, order: order, page: page)
                pages = p.pages; page += 1; new = p.gifs
            case .niche(let id, let order):
                let p = try await api.niche(id, order: order, page: page)
                pages = p.pages; page += 1; new = p.gifs
            case .user(let name):
                let p = try await api.user(name, page: page)
                pages = p.pages; page += 1; new = p.gifs
                if user == nil {
                    let u = p.users.first { $0.username.caseInsensitiveCompare(name) == .orderedSame } ?? p.users.first
                    if let u { user = u; UserStore.shared.updateFollowedUser(u) }
                }
            case .list:
                break
            }
            let fresh = new.filter { ids.insert($0.id).inserted }
            items.append(contentsOf: fresh)
            errorText = nil
        } catch {
            errorText = "Couldn't load. Check your connection."
        }
    }

    // MARK: For You algorithm

    enum Job: Sendable {
        case trending(Int)
        case tag(String, String, Int)
        case niche(String, Int)
        case user(String)
    }

    nonisolated static func run(_ job: Job) async throws -> GifPage {
        let api = RedGifsAPI.shared
        switch job {
        case .trending(let p): return try await api.trending(page: p)
        case .tag(let t, let o, let p): return try await api.search(t, order: o, page: p, count: 20)
        case .niche(let n, let p): return try await api.niche(n, page: p, count: 20)
        case .user(let u): return try await api.user(u, page: 1, count: 10)
        }
    }

    /// Mixes trending with posts from your favourite tags, categories and creators, then ranks by your taste.
    private func loadForYou() async -> [Gif] {
        let store = UserStore.shared
        let tags = store.topTags(12)
        let niches = store.topNiches(8)
        let interestLevel = tags.reduce(0) { $0 + $1.1 } // how much we know about you

        var jobs: [Job] = [.trending(trendingPage)]
        trendingPage += 1

        let personalJobs = interestLevel > 30 ? 3 : (interestLevel > 5 ? 2 : (tags.isEmpty ? 0 : 1))
        for _ in 0..<personalJobs {
            if let t = weightedPick(tags) {
                jobs.append(.tag(t, Bool.random() ? "top" : "latest", Int.random(in: 1...8)))
            }
        }
        if let n = weightedPick(niches) {
            jobs.append(.niche(n, Int.random(in: 1...6)))
        }
        if let f = store.data.following.randomElement(), Bool.random() {
            jobs.append(.user(f.username))
        }

        let results = await withTaskGroup(of: [Gif].self) { group -> [Gif] in
            for job in jobs {
                group.addTask { (try? await FeedModel.run(job))?.gifs ?? [] }
            }
            var all: [Gif] = []
            for await r in group { all += r }
            return all
        }

        var local = Set<String>()
        let unique = results.filter { !ids.contains($0.id) && local.insert($0.id).inserted }
        let unseen = unique.filter { !store.hasSeen($0.id) }
        let pool = unseen.count >= 4 ? unseen : unique
        // Score by taste + randomness so you still discover new stuff.
        return pool
            .map { ($0, store.score($0) + Double.random(in: 0..<3)) }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    // MARK: Following feed

    private func loadFollowing() async -> [Gif] {
        let names = UserStore.shared.data.following.map(\.username).filter { !followDone.contains($0) }
        if names.isEmpty { pages = 0; return [] }
        let batch = Array(names.shuffled().prefix(10))
        var requests: [(String, Int)] = []
        for n in batch { requests.append((n, followPages[n] ?? 1)) }

        let results = await withTaskGroup(of: (String, GifPage?).self) { group -> [(String, GifPage?)] in
            for (n, p) in requests {
                group.addTask { (n, try? await RedGifsAPI.shared.user(n, page: p, count: 10)) }
            }
            var all: [(String, GifPage?)] = []
            for await r in group { all.append(r) }
            return all
        }

        var all: [Gif] = []
        for (n, result) in results {
            guard let result else { followDone.insert(n); continue }
            let next = (followPages[n] ?? 1) + 1
            followPages[n] = next
            if next > result.pages || result.gifs.isEmpty { followDone.insert(n) }
            all += result.gifs
        }
        return all.sorted { ($0.createDate ?? 0) > ($1.createDate ?? 0) }
    }
}

