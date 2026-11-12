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
    case igReels
    case igFollowing
    case igSaved
    case igUser(String)
    case rule34(String) // "" for general Rule34.xxx feed, or tag name
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
        case .igReels: return "IG Reels"
        case .igFollowing: return "IG Following"
        case .igSaved: return "IG Saved"
        case .igUser(let u): return "IG @\(u.replacingOccurrences(of: "@", with: ""))"
        case .rule34(let tag):
            return tag.isEmpty ? "Rule34.xxx" : "R34: \(tag)"
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

    var isIGFeed: Bool {
        switch self {
        case .igReels, .igFollowing, .igSaved, .igUser:
            return true
        default:
            return false
        }
    }

    var isRule34Feed: Bool {
        if case .rule34 = self { return true }
        return false
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
        case .igReels: return ("igreels", "igreels")
        case .igFollowing: return ("igfollowing", "igfollowing")
        case .igSaved: return ("igsaved", "igsaved")
        case .igUser(let u): return ("iguser", u)
        case .rule34(let tag): return ("rule34", tag.isEmpty ? "all" : tag)
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
    @Published private(set) var isSwitching = false
    @Published var errorText: String?
    @Published var source: FeedSource
    @Published var sort: FeedSort = .hot

    private var afterCursor: String? = nil
    private var xMixAfterCursor: String? = nil
    private var igMixAfterCursor: String? = nil
    private var hasMore = true
    private var ids = Set<String>()
    private var activeLoadTask: Task<Void, Never>?
    private var emptyPageStreak = 0

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

    private var isInfiniteSource: Bool {
        switch source {
        case .forYou, .following, .category, .rule34, .xForYou, .xFollowing, .igReels, .igFollowing:
            return true
        default:
            return false
        }
    }

    private var cursorKey: String {
        let k = source.swipeKey
        return "\(k.kind):\(k.name.lowercased()):\(sort.rawValue)"
    }

    func switchSource(_ newSource: FeedSource, initialItems: [Gif] = []) {
        guard newSource != source || !initialItems.isEmpty else {
            Task { await refresh(rotateCursor: true) }
            return
        }
        activeLoadTask?.cancel()
        source = newSource
        emptyPageStreak = 0
        if !initialItems.isEmpty {
            items = initialItems
            ids = Set(initialItems.map(\.id))
            hasMore = false
            isSwitching = false
            afterCursor = nil
            xMixAfterCursor = nil
            igMixAfterCursor = nil
            errorText = nil
        } else {
            items = []
            ids = []
            hasMore = true
            isSwitching = true
            isLoading = false
            errorText = nil
            afterCursor = UserStore.shared.savedCursor(for: cursorKey)
            activeLoadTask = Task {
                await refresh(keepSavedCursor: true)
            }
        }
    }

    func setSort(_ newSort: FeedSort) {
        guard sort != newSort else { return }
        activeLoadTask?.cancel()
        sort = newSort
        isSwitching = true
        isLoading = false
        afterCursor = UserStore.shared.savedCursor(for: cursorKey)
        activeLoadTask = Task {
            await refresh(keepSavedCursor: true)
        }
    }

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
        if items.suffix(10).contains(where: { $0.id == g.id }) {
            Task { await loadMore() }
        }
    }

    func refresh(keepSavedCursor: Bool = false, rotateCursor: Bool = false) async {
        items = []
        ids = []
        emptyPageStreak = 0
        if rotateCursor {
            if case .forYou = source {
                afterCursor = GoonedAPI.randomForYouCursor(offset: Int.random(in: 0...6) * 25)
            } else if afterCursor == nil {
                afterCursor = UserStore.shared.savedCursor(for: cursorKey)
            }
        } else if !keepSavedCursor {
            afterCursor = UserStore.shared.savedCursor(for: cursorKey)
        }
        xMixAfterCursor = nil
        igMixAfterCursor = nil
        hasMore = true
        errorText = nil
        if case .list = source { hasMore = false; isSwitching = false; return }
        await loadMore()
        isSwitching = false
    }

    func loadMore() async {
        guard !isLoading, canLoadMore else { return }
        isLoading = true
        defer {
            isLoading = false
            isSwitching = false
        }

        let api = GoonedAPI.shared
        let store = UserStore.shared
        do {
            var totalAddedThisCall = 0
            var attempts = 0

            while totalAddedThisCall < 8 && attempts < 2 && hasMore {
                if Task.isCancelled { return }
                attempts += 1
                let resp = try await fetchPage(api: api, store: store, cursor: afterCursor)

                afterCursor = resp.after
                store.setSavedCursor(resp.after, for: cursorKey)

                let playablePosts = resp.posts.filter { $0.hasPlayableMedia }

                if playablePosts.isEmpty && (resp.after == nil || resp.after?.isEmpty == true) {
                    if isInfiniteSource {
                        if case .forYou = source {
                            afterCursor = GoonedAPI.randomForYouCursor(offset: Int.random(in: 0...8) * 25)
                        } else if case .rule34 = source {
                            let nextP = (Int(afterCursor ?? "0") ?? 0) + 1
                            afterCursor = "\(nextP)"
                        } else {
                            store.setSavedCursor(nil, for: cursorKey)
                            afterCursor = nil
                        }
                        continue
                    } else if attempts == 1 && store.savedCursor(for: cursorKey) != nil {
                        store.setSavedCursor(nil, for: cursorKey)
                        afterCursor = nil
                        continue
                    } else {
                        hasMore = false
                    }
                }

                var batchUnseen: [Gif] = []
                var batchSeen: [Gif] = []
                for post in playablePosts {
                    guard ids.insert(post.id).inserted else { continue }
                    if store.isSeen(post.id) {
                        batchSeen.append(post)
                    } else {
                        batchUnseen.append(post)
                    }
                }

                switch source {
                case .forYou:
                    batchUnseen = store.rankWithAlgorithm(batchUnseen)
                case .category, .rule34:
                    batchUnseen.shuffle()
                default:
                    break
                }

                // Stream items into the feed immediately on the first response instead of blocking!
                if !batchUnseen.isEmpty {
                    emptyPageStreak = 0
                    items.append(contentsOf: batchUnseen)
                    totalAddedThisCall += batchUnseen.count
                    isSwitching = false
                } else if !batchSeen.isEmpty {
                    emptyPageStreak = 0
                    items.append(contentsOf: batchSeen.shuffled())
                    totalAddedThisCall += batchSeen.count
                    isSwitching = false
                } else {
                    emptyPageStreak += 1
                    if !isInfiniteSource && emptyPageStreak >= 2 {
                        hasMore = false
                    }
                    if isInfiniteSource {
                        if case .forYou = source {
                            afterCursor = GoonedAPI.randomForYouCursor(offset: Int.random(in: 0...10) * 25)
                        } else if resp.after == nil || resp.after?.isEmpty == true {
                            afterCursor = nil
                        }
                    }
                }

                if (source.isXFeed || source.isIGFeed) && !playablePosts.isEmpty { break }
                if resp.after == nil || resp.after?.isEmpty == true {
                    if !isInfiniteSource { break }
                }
            }

            // Algorithm Taste Boost: when enabled on For You, pull a small fresh batch from top-liked subreddit
            if case .forYou = source,
               store.data.settings.algorithmEnabled,
               let favSub = store.topAlgorithmSubreddits.randomElement() {
                Task { @MainActor [weak self] in
                    guard let self, case .forYou = self.source else { return }
                    if let subResp = try? await api.subreddit(favSub, sort: self.sort.rawValue, after: nil, limit: 8) {
                        let freshFavs = subResp.posts.filter {
                            $0.hasPlayableMedia && !store.isSeen($0.id) && self.ids.insert($0.id).inserted
                        }
                        guard !freshFavs.isEmpty else { return }
                        var combined = self.items
                        var idx = max(2, combined.count - 6)
                        for p in freshFavs.prefix(3) {
                            if idx <= combined.count {
                                combined.insert(p, at: idx)
                                idx += 3
                            } else {
                                combined.append(p)
                            }
                        }
                        self.items = combined
                    }
                }
            }

            // Blend X For You if enabled
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

            // Blend Instagram Reels if enabled
            if case .forYou = source, store.data.igSession.isConnected && store.data.igSession.mixIntoForYou {
                let currentIGCursor = igMixAfterCursor
                Task { @MainActor [weak self] in
                    let igResp = await InstagramAPI.reels(after: currentIGCursor)
                    guard let self, case .forYou = self.source else { return }
                    self.igMixAfterCursor = igResp.after
                    let freshIG = igResp.posts.filter { !store.isSeen($0.id) && self.ids.insert($0.id).inserted }
                    guard !freshIG.isEmpty else { return }
                    var combined = self.items
                    var insertIdx = max(3, combined.count - 6)
                    for igPost in freshIG {
                        if insertIdx <= combined.count {
                            combined.insert(igPost, at: insertIdx)
                            insertIdx += 4
                        } else {
                            combined.append(igPost)
                        }
                    }
                    self.items = combined
                }
            }

            if items.isEmpty && source.isXFeed && !store.data.xSession.isConnected {
                errorText = "Connect your personal X account to load X videos."
            } else if items.isEmpty && source.isIGFeed && !store.data.igSession.isConnected {
                errorText = "Connect your personal Instagram account to load Instagram Reels."
            } else {
                errorText = nil
            }
        } catch {
            // If offline and user has downloaded videos, let them know or fallback cleanly
            if !store.data.downloaded.isEmpty && items.isEmpty {
                errorText = "Offline — tap Likes/Vault tab to watch your \(store.data.downloaded.count) downloaded videos."
            } else {
                errorText = "Couldn't load posts. Tap to retry."
            }
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
            let igUsers = store.data.followedIGUsers
            if subs.isEmpty && users.isEmpty && xUsers.isEmpty && igUsers.isEmpty && !store.data.xSession.isConnected && !store.data.igSession.isConnected {
                hasMore = false
                return GoonedFeedResponse(posts: [], after: nil)
            }
            if !subs.isEmpty || !users.isEmpty {
                return try await api.following(subreddits: subs, users: users, after: cursor)
            } else if let firstXUser = xUsers.first {
                return await XAPI.userMedia(firstXUser, after: cursor)
            } else if let firstIGUser = igUsers.first {
                return await InstagramAPI.userReels(firstIGUser, after: cursor)
            } else if store.data.xSession.isConnected {
                return await XAPI.following(after: cursor)
            } else {
                return await InstagramAPI.following(after: cursor)
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
        case .igReels:
            return await InstagramAPI.reels(after: cursor)
        case .igFollowing:
            return await InstagramAPI.following(after: cursor)
        case .igSaved:
            return await InstagramAPI.saved(after: cursor)
        case .igUser(let handle):
            return await InstagramAPI.userReels(handle, after: cursor)
        case .rule34(let tag):
            return await Rule34API.shared.fetchFeed(
                tag: tag,
                sort: sort.rawValue,
                after: cursor,
                credentials: store.data.r34Credentials
            )
        case .list:
            return GoonedFeedResponse(posts: [], after: nil)
        }
    }
}
