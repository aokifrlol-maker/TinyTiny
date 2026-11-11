import SwiftUI

enum FeedSource: Hashable {
    case forYou
    case following
    case category(GoonedCategory, order: String)
    case tag(String, order: String)
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

    func removeItem(_ id: String) {
        items.removeAll { $0.id == id }
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
        let store = UserStore.shared
        do {
            var new: [Gif] = []
            switch source {
            case .forYou:
                new = await loadForYou()
                if new.isEmpty && items.isEmpty { throw APIError.http(0) }
            case .following:
                new = await loadFollowing()
            case .category(let cat, let order):
                let p = try await api.category(cat, order: order, page: page)
                pages = p.pages; page += 1; new = p.gifs
            case .tag(let t, let order):
                let p = try await api.search(t, order: order, page: page)
                pages = p.pages; page += 1; new = p.gifs
            case .user(let name):
                let p = try await api.user(name, page: page)
                pages = p.pages; page += 1; new = p.gifs
                if user == nil {
                    let u = p.users.first { $0.username.caseInsensitiveCompare(name) == .orderedSame } ?? p.users.first
                    if let u { user = u; store.updateFollowedUser(u) }
                }
            case .list:
                break
            }
            let fresh = new.filter { !store.isDisliked($0.id) && ids.insert($0.id).inserted }
            items.append(contentsOf: fresh)
            errorText = nil
        } catch {
            errorText = "Unable to load feed. Check your connection and try again."
        }
    }

    // MARK: For You Recommendation Engine

    enum Job: Sendable {
        case trending(Int)
        case category(GoonedCategory, String, Int)
        case tag(String, String, Int)
        case user(String)
    }

    nonisolated static func run(_ job: Job) async throws -> GifPage {
        let api = RedGifsAPI.shared
        switch job {
        case .trending(let p):
            return try await api.trending(page: p)
        case .category(let cat, let o, let p):
            return try await api.category(cat, order: o, page: p, count: 22)
        case .tag(let t, let o, let p):
            return try await api.search(t, order: o, page: p, count: 18)
        case .user(let u):
            return try await api.user(u, page: 1, count: 12)
        }
    }

    private func loadForYou() async -> [Gif] {
        let store = UserStore.shared
        let topCats = store.topCategories(6)
        let topTags = store.topTags(10)

        var jobs: [Job] = [.trending(trendingPage)]
        trendingPage += 1

        if !topCats.isEmpty {
            for _ in 0..<2 {
                if let pickedCat = weightedPick(topCats) {
                    jobs.append(.category(pickedCat, Bool.random() ? "top" : "latest", Int.random(in: 1...6)))
                }
            }
        } else {
            // Seed discovery from a random predefined category
            if let cat = GoonedCategory.all.randomElement() {
                jobs.append(.category(cat, "top", Int.random(in: 1...3)))
            }
        }

        if let pickedTag = weightedPick(topTags) {
            jobs.append(.tag(pickedTag, Bool.random() ? "top" : "latest", Int.random(in: 1...6)))
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
        let unique = results.filter { !ids.contains($0.id) && !store.isDisliked($0.id) && local.insert($0.id).inserted }
        let unseen = unique.filter { !store.hasSeen($0.id) }
        let pool = unseen.count >= 4 ? unseen : unique

        return pool
            .map { ($0, store.score($0) + Double.random(in: 0..<3.0)) }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    // MARK: Following Feed

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
