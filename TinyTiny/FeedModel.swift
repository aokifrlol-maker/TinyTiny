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
        case .category(let c): return c == "BigTits" ? "Big Tits" : (c == "Rule34" ? "Rule 34" : c)
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

    private var cursorKey: String {
        let k = source.swipeKey
        return "\(k.kind):\(k.name.lowercased()):\(sort.rawValue)"
    }

    func switchSource(_ newSource: FeedSource, initialItems: [Gif] = []) {
        guard newSource != source || !initialItems.isEmpty else {
            // If user re-selects the same feed, rotate/refresh with fresh unseen items
            Task { await refresh(rotateCursor: true) }
            return
        }
        source = newSource
        if !initialItems.isEmpty {
            items = initialItems
            ids = Set(initialItems.map(\.id))
            hasMore = false
            afterCursor = nil
            xMixAfterCursor = nil
            errorText = nil
        } else {
            // Restore saved cursor if available so returning to a category/subreddit picks up with new videos
            afterCursor = UserStore.shared.savedCursor(for: cursorKey)
            Task { await refresh(keepSavedCursor: true) }
        }
    }

    func setSort(_ newSort: FeedSort) {
        guard sort != newSort else { return }
        sort = newSort
        afterCursor = UserStore.shared.savedCursor(for: cursorKey)
        Task { await refresh(keepSavedCursor: true) }
    }

    /// Shuffles current items and pulls fresh unseen posts to the front.
    func shuffleItems() {
        let store = UserStore.shared
        if items.count > 2 {
            let unseen = items.filter { !store.isSeen($0.id) }.shuffled()
            let seen = items.filter { store.isSeen($0.id) }.shuffled()
            items = unseen + seen
        }
        Task { await loadMore() }
    }

    func onItemAppear(_ g: Gif) {
        if items.suffix(6).contains(where: { $0.id == g.id }) {
            Task { await loadMore() }
        }
    }

    func refresh(keepSavedCursor: Bool = false, rotateCursor: Bool = false) async {
        items = []
        ids = []
        if rotateCursor {
            // Advance or randomize cursor so refresh always shows brand new videos
            if case .forYou = source {
                afterCursor = GoonedAPI.randomForYouCursor(offset: Int.random(in: 0...4) * 50)
            } else if afterCursor == nil {
                afterCursor = UserStore.shared.savedCursor(for: cursorKey)
            }
        } else if !keepSavedCursor {
            afterCursor = UserStore.shared.savedCursor(for: cursorKey)
        }
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
            var collectedUnseen: [Gif] = []
            var fallbackSeen: [Gif] = []
            var attempts = 0

            // Up to 2 page hops if page 1 had mostly already-seen videos
            while collectedUnseen.count < 8 && attempts < 2 && hasMore {
                attempts += 1
                let resp = try await fetchPage(api: api, store: store, cursor: afterCursor)

                afterCursor = resp.after
                store.setSavedCursor(resp.after, for: cursorKey)

                if resp.posts.isEmpty && (resp.after == nil || resp.after?.isEmpty == true) {
                    // If we hit the end of a saved cursor, wrap around once with a fresh cursor
                    if attempts == 1 && store.savedCursor(for: cursorKey) != nil {
                        store.setSavedCursor(nil, for: cursorKey)
                        afterCursor = nil
                        continue
                    }
                    hasMore = false
                }

                for post in resp.posts {
                    guard ids.insert(post.id).inserted else { continue }
                    if store.isSeen(post.id) {
                        fallbackSeen.append(post)
                    } else {
                        collectedUnseen.append(post)
                    }
                }

                // For X feeds (which stream via WebView), 1 hop per scroll is sufficient
                if source.isXFeed { break }
                if resp.after == nil || resp.after?.isEmpty == true { break }
            }

            // Rotate/shuffle incoming batch on For You and Category feeds so order is always fresh
            switch source {
            case .forYou, .category:
                collectedUnseen.shuffle()
            default:
                break
            }

            if !collectedUnseen.isEmpty {
                items.append(contentsOf: collectedUnseen)
            } else if items.isEmpty && !fallbackSeen.isEmpty {
                // Only if a small subreddit/creator has zero unseen videos left, rotate their posts in random order
                items.append(contentsOf: fallbackSeen.shuffled())
            }

            // If personal X is connected and Mix is enabled on For You, asynchronously blend X videos
            if case .forYou = source, store.data.xSession.isConnected && store.data.xSession.mixIntoForYou {
                let currentXCursor = xMixAfterCursor
                Task { @MainActor [weak self] in
                    let xResp = await XAPI.forYou(after: currentXCursor)
                    guard let self, case .forYou = self.source else { return }
                    self.xMixAfterCursor = xResp.after
                    let freshX = xResp.posts.filter { !store.isSeen($0.id) && self.ids.insert($0.id).inserted }
                    guard !freshX.isEmpty else { return }
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

            if items.isEmpty && source.isXFeed && !store.data.xSession.isConnected {
                errorText = "Connect your personal X account to load X videos."
            } else {
                errorText = nil
            }
        } catch {
            errorText = "Couldn't load posts. Tap to retry."
        }
    }

    private func fetchPage(api: GoonedAPI, store: UserStore, cursor: String?) async throws -> GoonedFeedResponse {
        switch source {
        case .forYou:
            return try await api.forYou(sort: sort.rawValue, after: cursor, limit: 25)
        case .following:
            let subs = store.data.followedSubreddits
            let users = store.data.followedUsers
            let xUsers = store.data.followedXUsers
            if subs.isEmpty && users.isEmpty && xUsers.isEmpty && !store.data.xSession.isConnected {
                hasMore = false
                return GoonedFeedResponse(posts: [], after: nil)
            }
            if !subs.isEmpty || !users.isEmpty {
                return try await api.following(subreddits: subs, users: users, after: cursor)
            } else if let firstXUser = xUsers.first {
                return await XAPI.userMedia(firstXUser, after: cursor)
            } else {
                return await XAPI.following(after: cursor)
            }
        case .category(let name):
            let recentSeen = Array(store.data.seenIDs.suffix(120))
            let resp = try await api.category(
                name,
                sort: sort.rawValue,
                after: cursor,
                excludedHead: recentSeen,
                limit: 25
            )
            // If category endpoint returned empty, rotate into one of the category's constituent subreddits
            if resp.posts.isEmpty,
               let cat = store.categories.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
               let randomSub = cat.subreddits.randomElement() {
                return try await api.subreddit(randomSub, sort: sort.rawValue, after: nil, limit: 25)
            }
            return resp
        case .subreddit(let sub):
            return try await api.subreddit(sub, sort: sort.rawValue, after: cursor, limit: 25)
        case .user(let u):
            return try await api.user(u, sort: sort.rawValue, after: cursor, limit: 25)
        case .xForYou:
            return await XAPI.forYou(after: cursor)
        case .xFollowing:
            return await XAPI.following(after: cursor)
        case .xBookmarks:
            return await XAPI.bookmarks(after: cursor)
        case .xLikes:
            return await XAPI.likes(after: cursor)
        case .xSearch(let query):
            return await XAPI.search(query, sort: sort.rawValue, after: cursor)
        case .xUser(let handle):
            return await XAPI.userMedia(handle, after: cursor)
        case .list:
            return GoonedFeedResponse(posts: [], after: nil)
        }
    }
}
