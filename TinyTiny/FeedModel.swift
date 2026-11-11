import SwiftUI

enum FeedSource: Hashable {
    case forYou
    case following
    case category(GoonedCategory, order: String)
    case tag(String, order: String)
    case subreddit(String)
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
    private var redditCursor: Int? = nil
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
        redditCursor = nil
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
            case .subreddit(let sub):
                let res = try await api.subredditPosts(sub, before: redditCursor, limit: 28)
                redditCursor = res.nextCursor
                if res.gifs.isEmpty && res.nextCursor == nil { pages = 0 } else { page += 1 }
                new = res.gifs
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
            let fresh = new.filter { ids.insert($0.id).inserted }
            items.append(contentsOf: fresh)
            errorText = nil
        } catch {
            errorText = "Failed to load. Tap to retry."
        }
    }

    // MARK: For You Recommendation Engine (Blends RedGIFs + 18+ Reddit)

    enum Job: Sendable {
        case trending(Int)
        case category(GoonedCategory, String, Int)
        case tag(String, String, Int)
        case subreddit(String)
        case user(String)
    }

    nonisolated static func run(_ job: Job) async throws -> [Gif] {
        let api = RedGifsAPI.shared
        switch job {
        case .trending(let p):
            return try await api.trending(page: p).gifs
        case .category(let cat, let o, let p):
            return try await api.category(cat, order: o, page: p, count: 18).gifs
        case .tag(let t, let o, let p):
            return try await api.search(t, order: o, page: p, count: 18).gifs
        case .subreddit(let s):
            return try await api.subredditPosts(s, limit: 16).gifs
        case .user(let u):
            return try await api.user(u, page: 1, count: 12).gifs
        }
    }

    private func loadForYou() async -> [Gif] {
        let store = UserStore.shared
        let topCats = store.topCategories(6)
        let topTags = store.topTags(10)

        var jobs: [Job] = [.trending(trendingPage)]
        trendingPage += 1

        if !topCats.isEmpty {
            if let pickedCat = weightedPick(topCats) {
                jobs.append(.category(pickedCat, Bool.random() ? "top" : "latest", Int.random(in: 1...5)))
            }
        } else if let cat = GoonedCategory.all.randomElement() {
            jobs.append(.category(cat, "top", Int.random(in: 1...3)))
        }

        // Always blend in 18+ Reddit posts (either from a followed subreddit or a popular NSFW subreddit)
        if let followedSub = store.data.followedSubreddits.randomElement() {
            jobs.append(.subreddit(followedSub))
        } else if let randomSub = RedGifsAPI.popularNSFWSubreddits.randomElement()?.display_name {
            jobs.append(.subreddit(randomSub))
        }

        if let pickedTag = weightedPick(topTags) {
            jobs.append(.tag(pickedTag, Bool.random() ? "top" : "latest", Int.random(in: 1...5)))
        }
        if let f = store.data.following.randomElement(), Bool.random() {
            jobs.append(.user(f.username))
        }

        let results = await withTaskGroup(of: [Gif].self) { group -> [Gif] in
            for job in jobs {
                group.addTask { (try? await FeedModel.run(job)) ?? [] }
            }
            var all: [Gif] = []
            for await r in group { all += r }
            return all
        }

        var local = Set<String>()
        let unique = results.filter { !ids.contains($0.id) && local.insert($0.id).inserted }
        let unseen = unique.filter { !store.hasSeen($0.id) }
        let pool = unseen.count >= 4 ? unseen : unique

        return pool
            .map { ($0, store.score($0) + Double.random(in: 0..<3.0)) }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    // MARK: Following Feed (Followed Creators + Followed 18+ Subreddits)

    private func loadFollowing() async -> [Gif] {
        let store = UserStore.shared
        let names = store.data.following.map(\.username).filter { !followDone.contains($0) }
        let subs = store.data.followedSubreddits.filter { !followDone.contains("r_\($0)") }

        if names.isEmpty && subs.isEmpty { pages = 0; return [] }

        let userBatch = Array(names.shuffled().prefix(8))
        let subBatch = Array(subs.shuffled().prefix(4))

        var userReqs: [(String, Int)] = []
        for n in userBatch { userReqs.append((n, followPages[n] ?? 1)) }

        let userResults = await withTaskGroup(of: (String, GifPage?).self) { group -> [(String, GifPage?)] in
            for (n, p) in userReqs {
                group.addTask { (n, try? await RedGifsAPI.shared.user(n, page: p, count: 10)) }
            }
            var all: [(String, GifPage?)] = []
            for await r in group { all.append(r) }
            return all
        }

        let subResults = await withTaskGroup(of: (String, [Gif]).self) { group -> [(String, [Gif])] in
            for s in subBatch {
                group.addTask {
                    let g = (try? await RedGifsAPI.shared.subredditPosts(s, limit: 12).gifs) ?? []
                    return (s, g)
                }
            }
            var all: [(String, [Gif])] = []
            for await r in group { all.append(r) }
            return all
        }

        var all: [Gif] = []
        for (n, result) in userResults {
            guard let result else { followDone.insert(n); continue }
            let next = (followPages[n] ?? 1) + 1
            followPages[n] = next
            if next > result.pages || result.gifs.isEmpty { followDone.insert(n) }
            all += result.gifs
        }
        for (s, gifs) in subResults {
            followDone.insert("r_\(s)")
            all += gifs
        }
        return all.sorted { ($0.createDate ?? 0) > ($1.createDate ?? 0) }
    }
}
