import SwiftUI

enum FeedSource: Hashable {
    case forYou
    case following
    case category(String)
    case subreddit(String)
    case user(String)
    case xForYou
    case xFollowing
    case xBookmarks
    case xLikes
    case xSearch(String)
    case xUser(String)
    case list(title: String)

    var displayTitle: String {
        switch self {
        case .forYou: return "For You"
        case .following: return "Following"
        case .category(let c): return c == "BigTits" ? "Big Tits" : c
        case .subreddit(let s): return "r/\(s)"
        case .user(let u): return "u/\(u)"
        case .xForYou: return "𝕏 For You"
        case .xFollowing: return "𝕏 Following"
        case .xBookmarks: return "𝕏 Bookmarks"
        case .xLikes: return "𝕏 Likes"
        case .xSearch(let q): return "𝕏: \(q)"
        case .xUser(let u): return "@\(u.replacingOccurrences(of: "@", with: ""))"
        case .list(let t): return t
        }
    }

    var isXFeed: Bool {
        switch self {
        case .xForYou, .xFollowing, .xBookmarks, .xLikes, .xSearch, .xUser:
            return true
        default:
            return false
        }
    }

    var swipeKey: (kind: String, name: String) {
        switch self {
        case .forYou: return ("foryou", "foryou")
        case .following: return ("following", "following")
        case .category(let c): return ("category", c)
        case .subreddit(let s): return ("subreddit", s)
        case .user(let u): return ("user", u)
        case .xForYou: return ("xforyou", "xforyou")
        case .xFollowing: return ("xfollowing", "xfollowing")
        case .xBookmarks: return ("xbookmarks", "xbookmarks")
        case .xLikes: return ("xlikes", "xlikes")
        case .xSearch(let q): return ("xsearch", q)
        case .xUser(let u): return ("xuser", u)
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
    private var xMixAfterCursor: String? = nil
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
            xMixAfterCursor = nil
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
        xMixAfterCursor = nil
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
                // If personal X is connected and Mix is enabled, asynchronously blend in X For You videos
                if store.data.xSession.isConnected && store.data.xSession.mixIntoForYou {
                    let currentXCursor = xMixAfterCursor
                    Task { @MainActor [weak self] in
                        let xResp = await XAPI.forYou(after: currentXCursor)
                        guard let self, case .forYou = self.source else { return }
                        self.xMixAfterCursor = xResp.after
                        let freshX = xResp.posts.filter { self.ids.insert($0.id).inserted }
                        guard !freshX.isEmpty else { return }
                        // Interleave X posts every ~3 items from current end
                        var combined = self.items
                        var insertIdx = max(2, combined.count - 8)
                        for xPost in freshX {
                            if insertIdx <= combined.count {
                                combined.insert(xPost, at: insertIdx)
                                insertIdx += 3
                            } else {
                                combined.append(xPost)
                            }
                        }
                        self.items = combined
                    }
                }
            case .following:
                let subs = store.data.followedSubreddits
                let users = store.data.followedUsers
                let xUsers = store.data.followedXUsers
                if subs.isEmpty && users.isEmpty && xUsers.isEmpty && !store.data.xSession.isConnected {
                    hasMore = false
                    return
                }
                if !subs.isEmpty || !users.isEmpty {
                    resp = try await api.following(subreddits: subs, users: users, after: afterCursor)
                } else if let firstXUser = xUsers.first {
                    resp = await XAPI.userMedia(firstXUser, after: afterCursor)
                } else {
                    resp = await XAPI.following(after: afterCursor)
                }
            case .category(let name):
                resp = try await api.category(name, sort: sort.rawValue, after: afterCursor, limit: 15)
            case .subreddit(let sub):
                resp = try await api.subreddit(sub, sort: sort.rawValue, after: afterCursor, limit: 15)
            case .user(let u):
                resp = try await api.user(u, sort: sort.rawValue, after: afterCursor, limit: 15)
            case .xForYou:
                resp = await XAPI.forYou(after: afterCursor)
            case .xFollowing:
                resp = await XAPI.following(after: afterCursor)
            case .xBookmarks:
                resp = await XAPI.bookmarks(after: afterCursor)
            case .xLikes:
                resp = await XAPI.likes(after: afterCursor)
            case .xSearch(let query):
                resp = await XAPI.search(query, sort: sort.rawValue, after: afterCursor)
            case .xUser(let handle):
                resp = await XAPI.userMedia(handle, after: afterCursor)
            case .list:
                return
            }

            afterCursor = resp.after
            if resp.posts.isEmpty && (resp.after == nil || resp.after?.isEmpty == true) {
                hasMore = false
            }

            let fresh = resp.posts.filter { ids.insert($0.id).inserted }
            items.append(contentsOf: fresh)
            if items.isEmpty && source.isXFeed && !store.data.xSession.isConnected {
                errorText = "Connect your personal X account to load X videos."
            } else {
                errorText = nil
            }
        } catch {
            errorText = "Couldn't load posts. Tap to retry."
        }
    }
}
