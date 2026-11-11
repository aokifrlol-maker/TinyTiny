import SwiftUI

enum FeedSource: Hashable {
    case forYou
    case following
    case category(String)
    case subreddit(String)
    case user(String)
    case list(title: String)

    var displayTitle: String {
        switch self {
        case .forYou: return "For You"
        case .following: return "Following"
        case .category(let c): return c == "BigTits" ? "Big Tits" : c
        case .subreddit(let s): return "r/\(s)"
        case .user(let u): return "u/\(u)"
        case .list(let t): return t
        }
    }

    var swipeKey: (kind: String, name: String) {
        switch self {
        case .forYou: return ("foryou", "foryou")
        case .following: return ("following", "following")
        case .category(let c): return ("category", c)
        case .subreddit(let s): return ("subreddit", s)
        case .user(let u): return ("user", u)
        case .list(let t): return ("list", t)
        }
    }
}

enum FeedSort: String, CaseIterable, Identifiable {
    case hot = "hot"
    case new = "new"
    case top = "top"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .hot: return "Hot"
        case .new: return "New"
        case .top: return "Top"
        }
    }
    var icon: String {
        switch self {
        case .hot: return "flame"
        case .new: return "sparkles"
        case .top: return "trophy"
        }
    }
}

@MainActor
final class FeedModel: ObservableObject {
    @Published var items: [Gif] = []
    @Published private(set) var isLoading = false
    @Published var errorText: String?
    @Published var source: FeedSource
    @Published var sort: FeedSort = .hot

    private var afterCursor: String? = nil
    private var hasMore = true
    private var ids = Set<String>()

    init(source: FeedSource = .forYou, items: [Gif] = []) {
        self.source = source
        self.items = items
        self.ids = Set(items.map(\.id))
        if case .list = source { hasMore = false }
    }

    var canLoadMore: Bool {
        if case .list = source { return false }
        return hasMore
    }

    func switchSource(_ newSource: FeedSource, initialItems: [Gif] = []) {
        guard newSource != source || !initialItems.isEmpty else { return }
        source = newSource
        if !initialItems.isEmpty {
            items = initialItems
            ids = Set(initialItems.map(\.id))
            hasMore = false
            afterCursor = nil
            errorText = nil
        } else {
            Task { await refresh() }
        }
    }

    func setSort(_ newSort: FeedSort) {
        guard sort != newSort else { return }
        sort = newSort
        Task { await refresh() }
    }

    func shuffleItems() {
        guard items.count > 1 else { return }
        items.shuffle()
    }

    func onItemAppear(_ g: Gif) {
        if items.suffix(5).contains(where: { $0.id == g.id }) {
            Task { await loadMore() }
        }
    }

    func refresh() async {
        items = []
        ids = []
        afterCursor = nil
        hasMore = true
        errorText = nil
        if case .list = source { hasMore = false; return }
        await loadMore()
    }

    func loadMore() async {
        guard !isLoading, canLoadMore else { return }
        isLoading = true
        defer { isLoading = false }

        let api = GoonedAPI.shared
        let store = UserStore.shared
        do {
            let resp: GoonedFeedResponse
            switch source {
            case .forYou:
                resp = try await api.forYou(sort: sort.rawValue, after: afterCursor, limit: 15)
            case .following:
                let subs = store.data.followedSubreddits
                let users = store.data.followedUsers
                if subs.isEmpty && users.isEmpty {
                    hasMore = false
                    return
                }
                resp = try await api.following(subreddits: subs, users: users, after: afterCursor)
            case .category(let name):
                resp = try await api.category(name, sort: sort.rawValue, after: afterCursor, limit: 15)
            case .subreddit(let sub):
                resp = try await api.subreddit(sub, sort: sort.rawValue, after: afterCursor, limit: 15)
            case .user(let u):
                resp = try await api.user(u, sort: sort.rawValue, after: afterCursor, limit: 15)
            case .list:
                return
            }

            afterCursor = resp.after
            if resp.posts.isEmpty && (resp.after == nil || resp.after?.isEmpty == true) {
                hasMore = false
            }

            let fresh = resp.posts.filter { ids.insert($0.id).inserted }
            items.append(contentsOf: fresh)
            errorText = nil
        } catch {
            errorText = "Couldn't load posts. Tap to retry."
        }
    }
}
