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
    case ofForYou
    case ofTrending
    case ofLatest
    case ofDMs
    case ofCreator(id: String, handle: String, displayName: String?)
    case ofSearch(String)
    case longVideos(LongVideoSite)
    case longSearch(LongVideoSite, String)
    case multiSearch(String)
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
        case .ofForYou: return "OF For You"
        case .ofTrending: return "OF Trending"
        case .ofLatest: return "OF Latest"
        case .ofDMs: return "OF DMs"
        case .ofCreator(_, let handle, let displayName):
            let clean = handle.replacingOccurrences(of: "@", with: "")
            return (displayName?.isEmpty == false) ? "\(displayName!) (@\(clean))" : "OF @\(clean)"
        case .ofSearch(let q): return "OF: \(q)"
        case .longVideos(let site): return site == .all ? "Long Videos" : site.displayTitle
        case .longSearch(let site, let q): return site == .all ? "Long: \(q)" : "\(site.displayTitle): \(q)"
        case .multiSearch(let q): return "Search: \(q)"
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

    var isOFFeed: Bool {
        switch self {
        case .ofForYou, .ofTrending, .ofLatest, .ofDMs, .ofCreator, .ofSearch:
            return true
        default:
            return false
        }
    }

    var isLongVideoFeed: Bool {
        switch self {
        case .longVideos, .longSearch:
            return true
        default:
            return false
        }
    }

    var isList: Bool {
        if case .list = self { return true }
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
        case .ofForYou: return ("offoryou", "offoryou")
        case .ofTrending: return ("oftrending", "oftrending")
        case .ofLatest: return ("oflatest", "oflatest")
        case .ofDMs: return ("ofdms", "ofdms")
        case .ofCreator(let id, let handle, _): return ("ofcreator", "\(id)|\(handle)")
        case .ofSearch(let q): return ("ofsearch", q)
        case .longVideos(let site): return ("longvideos", site.rawValue)
        case .longSearch(let site, let q): return ("longsearch", "\(site.rawValue):\(q)")
        case .multiSearch(let q): return ("multisearch", q)
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
    private var ofMixOffset: Int = 0
    private var hasMore = true
    private var ids = Set<String>()
    private var mediaKeys = Set<String>()
    private var seenSimKeys = Set<String>()
    private var activeLoadTask: Task<Void, Never>?
    private var emptyPageStreak = 0
    private var followingRoundRobin = 0
    private var followingCursors: [String: String] = [:]

    init(source: FeedSource = .forYou, items: [Gif] = []) {
        self.source = source
        if !items.isEmpty {
            self.items = items
        } else if !source.isList {
            let key = "\(source.swipeKey.kind):\(source.swipeKey.name.lowercased()):\(FeedSort.hot.rawValue)"
            let cached = Self.loadDiskCache(for: key).filter { !UserStore.shared.isSeen($0) }
            self.items = cached
        } else {
            self.items = []
        }
        self.ids = Set(self.items.map(\.id))
        self.mediaKeys = Set(self.items.map(\.canonicalDedupeKey))
        self.seenSimKeys = Set(self.items.compactMap(\.contentSimilarityKey))
        if case .list = source { hasMore = false }
    }

    var canLoadMore: Bool {
        if case .list = source { return false }
        return hasMore
    }

    private var isInfiniteSource: Bool {
        if case .list = source { return false }
        return true
    }

    private static var cacheDirectory: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("FeedCache", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private static func cacheFileURL(for key: String) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let safe = String(key.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }.prefix(80))
        return cacheDirectory.appendingPathComponent("\(safe).json")
    }

    private static func loadDiskCache(for key: String) -> [Gif] {
        let url = cacheFileURL(for: key)
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Gif].self, from: data) else {
            return []
        }
        return decoded
    }

    private static func saveDiskCache(_ posts: [Gif], for key: String) {
        let slice = Array(posts.prefix(18))
        let url = cacheFileURL(for: key)
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(slice) {
                try? data.write(to: url, options: [.atomic])
            }
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
        followingRoundRobin = 0
        followingCursors = [:]
        if !initialItems.isEmpty {
            items = initialItems
            ids = Set(initialItems.map(\.id))
            mediaKeys = Set(initialItems.map(\.canonicalDedupeKey))
            hasMore = false
            isSwitching = false
            afterCursor = nil
            xMixAfterCursor = nil
            igMixAfterCursor = nil
            ofMixOffset = 0
            errorText = nil
        } else {
            items = []
            ids = []
            mediaKeys = []
            seenSimKeys = []
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
            let unseen = items.filter { !store.isSeen($0) }.shuffled()
            let seen = items.filter { store.isSeen($0) }.shuffled()
            items = unseen + seen
        }
        Task { await loadMore() }
    }

    func onItemAppear(_ g: Gif) {
        if items.suffix(20).contains(where: { $0.id == g.id }) {
            Task { await loadMore() }
        }
    }

    func prefetchIfNeeded(currentID: String?) {
        guard !isLoading, canLoadMore else { return }
        if items.count < 24 {
            Task { await loadMore() }
            return
        }
        guard let currentID,
              let idx = items.firstIndex(where: { $0.id == currentID }) else { return }
        if idx >= max(0, items.count - 18) {
            Task { await loadMore() }
        }
    }

    func refresh(keepSavedCursor: Bool = false, rotateCursor: Bool = false) async {
        items = []
        ids = []
        mediaKeys = []
        seenSimKeys = []
        emptyPageStreak = 0
        followingRoundRobin = 0
        followingCursors = [:]
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
        ofMixOffset = 0
        hasMore = true
        errorText = nil
        if case .list = source { hasMore = false; isSwitching = false; return }
        await loadMore()
        isSwitching = false
    }

    func removeDisliked(_ post: Gif, purgeUpcomingOF: Bool = false) {
        let dedupe = post.canonicalDedupeKey
        let sim = post.contentSimilarityKey
        let curIdx = items.firstIndex(where: { $0.id == post.id }) ?? -1
        let store = UserStore.shared
        var nextItems: [Gif] = []
        nextItems.reserveCapacity(items.count)
        for (i, item) in items.enumerated() {
            if item.id == post.id || item.canonicalDedupeKey == dedupe { continue }
            if let sim, let itemSim = item.contentSimilarityKey, sim == itemSim { continue }
            if store.isBlockedByAlgorithm(item) { continue }
            if purgeUpcomingOF && i > curIdx && item.isOnlyFansPost {
                ids.remove(item.id)
                mediaKeys.remove(item.canonicalDedupeKey)
                continue
            }
            nextItems.append(item)
        }
        items = nextItems
        ids.insert(post.id)
        mediaKeys.insert(dedupe)
        if let sim { seenSimKeys.insert(sim) }
    }

    func purgeSuppressedItems(afterCurrentID currentID: String?, purgeUpcomingOF: Bool) {
        let curIdx = currentID.flatMap { id in items.firstIndex(where: { $0.id == id }) } ?? -1
        let store = UserStore.shared
        var nextItems: [Gif] = []
        nextItems.reserveCapacity(items.count)
        for (i, item) in items.enumerated() {
            if store.isBlockedByAlgorithm(item) { continue }
            if purgeUpcomingOF && i > curIdx && item.isOnlyFansPost {
                ids.remove(item.id)
                mediaKeys.remove(item.canonicalDedupeKey)
                continue
            }
            nextItems.append(item)
        }
        items = nextItems
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
            var fallbackSeen: [Gif] = []
            let maxAttempts = (source.isXFeed || source.isIGFeed) ? 4 : (source == .following ? 2 : 3)

            while totalAddedThisCall < 8 && attempts < maxAttempts && hasMore {
                if Task.isCancelled { return }
                attempts += 1
                let resp = try await fetchPage(api: api, store: store, cursor: afterCursor)

                afterCursor = resp.after
                store.setSavedCursor(resp.after, for: cursorKey)

                let isDiscoverySource: Bool = {
                    switch source {
                    case .forYou, .xForYou, .igReels, .category, .rule34, .ofForYou, .ofTrending, .ofLatest, .ofDMs, .longVideos:
                        return true
                    default:
                        return false
                    }
                }()

                let playablePosts = resp.posts.filter { post in
                    guard post.hasPlayableMedia else { return false }
                    if SmartTasteEngine.shared.isDisliked(post) { return false }
                    if isDiscoverySource && store.isBlockedByAlgorithm(post) { return false }
                    return AdultContentClassifier.isEligible(post, source: source, categories: store.categories, store: store)
                }

                if playablePosts.isEmpty && (resp.after == nil || resp.after?.isEmpty == true) {
                    if isInfiniteSource {
                        if case .forYou = source {
                            afterCursor = GoonedAPI.randomForYouCursor(offset: Int.random(in: 0...12) * 25)
                        } else if case .rule34 = source {
                            let nextP = (Int(afterCursor ?? "0") ?? 0) + 1
                            afterCursor = "\(nextP)"
                        } else if case .longVideos = source {
                            let nextP = (Int(afterCursor ?? "1") ?? 1) + 1
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
                for post in playablePosts {
                    guard ids.insert(post.id).inserted else { continue }
                    guard mediaKeys.insert(post.canonicalDedupeKey).inserted else { continue }
                    if let sim = post.contentSimilarityKey, !seenSimKeys.insert(sim).inserted { continue }
                    if store.isSeen(post) {
                        fallbackSeen.append(post)
                    } else {
                        batchUnseen.append(post)
                    }
                }

                switch source {
                case .forYou, .xForYou, .igReels, .category, .rule34, .ofForYou, .ofTrending, .ofLatest, .ofDMs, .longVideos:
                    batchUnseen = store.rankWithAlgorithm(batchUnseen)
                default:
                    break
                }

                // Stream unseen items into the feed immediately
                if !batchUnseen.isEmpty {
                    emptyPageStreak = 0
                    items.append(contentsOf: batchUnseen)
                    totalAddedThisCall += batchUnseen.count
                    isSwitching = false
                    Self.saveDiskCache(Array(items.suffix(18)), for: cursorKey)
                } else {
                    emptyPageStreak += 1
                    if !isInfiniteSource && emptyPageStreak >= 3 {
                        hasMore = false
                    }
                    if isInfiniteSource {
                        if case .forYou = source {
                            afterCursor = GoonedAPI.randomForYouCursor(offset: Int.random(in: 0...16) * 25)
                        } else if case .rule34 = source {
                            let nextP = (Int(afterCursor ?? "0") ?? 0) + 1
                            afterCursor = "\(nextP)"
                        } else if case .longVideos = source {
                            let nextP = (Int(afterCursor ?? "1") ?? 1) + 1
                            afterCursor = "\(nextP)"
                        } else if source == .xForYou && store.data.xSession.isConnected && emptyPageStreak >= 2 {
                            let blocked = Set(store.data.algorithm.blockedTags + SmartTasteEngine.shared.state.suppressedTags)
                            let fallbackTag = store.data.algorithm.tagWeights
                                .filter { $0.value > 0 && !blocked.contains($0.key.lowercased()) }
                                .sorted { $0.value > $1.value }
                                .randomElement()?.key
                            let q = fallbackTag.map { "nsfw \($0)" } ?? "nsfw"
                            let xFallback = await XAPI.search(q, sort: sort.rawValue, after: nil)
                            let extra = xFallback.posts.filter {
                                $0.hasPlayableMedia
                                && !store.isBlockedByAlgorithm($0)
                                && AdultContentClassifier.isEligible($0, source: source, categories: store.categories, store: store)
                                && !store.isSeen($0)
                                && ids.insert($0.id).inserted
                                && mediaKeys.insert($0.canonicalDedupeKey).inserted
                            }
                            if !extra.isEmpty {
                                emptyPageStreak = 0
                                items.append(contentsOf: extra)
                                totalAddedThisCall += extra.count
                                isSwitching = false
                                Self.saveDiskCache(Array(items.suffix(18)), for: cursorKey)
                            }
                        } else if source == .igReels && store.data.igSession.isConnected && emptyPageStreak >= 2 {
                            let igFallback = await InstagramAPI.reels(after: nil)
                            let extra = igFallback.posts.filter {
                                $0.hasPlayableMedia
                                && !store.isBlockedByAlgorithm($0)
                                && AdultContentClassifier.isEligible($0, source: source, categories: store.categories, store: store)
                                && !store.isSeen($0)
                                && ids.insert($0.id).inserted
                                && mediaKeys.insert($0.canonicalDedupeKey).inserted
                            }
                            if !extra.isEmpty {
                                emptyPageStreak = 0
                                items.append(contentsOf: extra)
                                totalAddedThisCall += extra.count
                                isSwitching = false
                                Self.saveDiskCache(Array(items.suffix(18)), for: cursorKey)
                            }
                        } else if resp.after == nil || resp.after?.isEmpty == true {
                            afterCursor = nil
                        }
                    }
                }

                if (source.isXFeed || source.isIGFeed) && !batchUnseen.isEmpty { break }
                if resp.after == nil || resp.after?.isEmpty == true {
                    if !isInfiniteSource { break }
                }
            }

            // Never fall back to seen items on personal X/IG/Following/Search feeds
            if items.isEmpty && !fallbackSeen.isEmpty && !source.isIGFeed && !source.isXFeed && source != .following {
                items.append(contentsOf: fallbackSeen.shuffled())
            }

            if items.isEmpty && source.isXFeed && !store.data.xSession.isConnected {
                errorText = "Connect your personal X account to load X videos."
            } else if items.isEmpty && source.isIGFeed && !store.data.igSession.isConnected {
                errorText = "Connect your personal Instagram account to load Instagram Reels."
            } else if items.isEmpty && (source == .xFollowing || source == .igFollowing || source == .following) {
                errorText = "No recent videos from accounts you follow yet. Follow creators in For You / Reels or tap Retry."
            } else if items.isEmpty {
                errorText = "Couldn't load \(source.displayTitle) yet. Tap Retry."
            } else {
                errorText = nil
            }

            if !Task.isCancelled && items.count < 16 && canLoadMore && emptyPageStreak == 0 {
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    await self?.loadMore()
                }
            }
        } catch {
            // Keep existing playable items visible on transient errors; only show an error card if feed is empty
            if items.isEmpty {
                if !store.data.downloaded.isEmpty {
                    errorText = "Offline — tap Likes/Vault tab to watch your \(store.data.downloaded.count) downloaded videos."
                } else {
                    errorText = "Couldn't load posts. Tap to retry."
                }
            }
        }
    }

    private func fetchPage(api: GoonedAPI, store: UserStore, cursor: String?) async throws -> GoonedFeedResponse {
        switch source {
        case .forYou:
            return await fetchBalancedForYou(api: api, store: store, cursor: cursor)
        case .following:
            let subs = store.data.followedSubreddits
            let users = store.data.followedUsers
            let xUsers = store.data.followedXUsers
            let igUsers = store.data.followedIGUsers
            let ofCreators = store.data.followedOFCreators

            var poolKeys: [String] = []
            if !subs.isEmpty || !users.isEmpty { poolKeys.append("reddit") }
            if store.data.igSession.isConnected { poolKeys.append("ig_following") }
            if store.data.xSession.isConnected { poolKeys.append("x_following") }
            for xu in xUsers { poolKeys.append("x_user:\(xu)") }
            for iu in igUsers { poolKeys.append("ig_user:\(iu)") }
            for ofc in ofCreators { poolKeys.append("of_creator:\(ofc.id)|\(ofc.name)") }

            guard !poolKeys.isEmpty else {
                hasMore = false
                return GoonedFeedResponse(posts: [], after: nil)
            }

            // Fetch up to 2 distinct pools in parallel on each scroll batch so General Following is rich and responsive
            var selectedPools: [String] = []
            for _ in 0..<min(2, poolKeys.count) {
                let k = poolKeys[followingRoundRobin % poolKeys.count]
                followingRoundRobin += 1
                if !selectedPools.contains(k) { selectedPools.append(k) }
            }

            var collected: [Gif] = []
            for poolKey in selectedPools {
                let poolCursor = followingCursors[poolKey]
                let resp: GoonedFeedResponse
                if poolKey == "reddit" {
                    resp = (try? await api.following(subreddits: subs, users: users, after: poolCursor)) ?? GoonedFeedResponse(posts: [], after: nil)
                } else if poolKey == "ig_following" {
                    resp = await InstagramAPI.following(after: poolCursor)
                } else if poolKey == "x_following" {
                    resp = await XAPI.following(after: poolCursor)
                } else if poolKey.hasPrefix("x_user:") {
                    let handle = String(poolKey.dropFirst("x_user:".count))
                    resp = await XAPI.userMedia(handle, after: poolCursor)
                } else if poolKey.hasPrefix("ig_user:") {
                    let handle = String(poolKey.dropFirst("ig_user:".count))
                    resp = await InstagramAPI.userReels(handle, after: poolCursor)
                } else {
                    let raw = String(poolKey.dropFirst("of_creator:".count))
                    let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
                    let cid = parts.first ?? raw
                    let chandle = parts.count > 1 ? parts[1] : cid
                    resp = await OnlyFansAPI.shared.creatorFeed(id: cid, handle: chandle, sort: sort.rawValue, after: poolCursor)
                }
                if let next = resp.after, !next.isEmpty {
                    followingCursors[poolKey] = next
                }
                collected.append(contentsOf: resp.posts)
            }

            return GoonedFeedResponse(posts: collected.shuffled(), after: "following_\(followingRoundRobin)")
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
        case .ofForYou:
            var seeds: [String] = []
            for ofc in store.data.followedOFCreators {
                if !ofc.name.isEmpty { seeds.append(ofc.name) }
                if !ofc.id.isEmpty && !seeds.contains(ofc.id) { seeds.append(ofc.id) }
            }
            for s in SmartTasteEngine.shared.topOnlyFansSeedHandles(limit: 8) where !seeds.contains(s) {
                seeds.append(s)
            }
            let tasteTags = store.data.algorithm.enabled
                ? SmartTasteEngine.shared.activeQueryTags(
                    pinned: store.data.algorithm.pinnedTags,
                    blocked: store.data.algorithm.blockedTags,
                    count: 6
                )
                : []
            return await OnlyFansAPI.shared.forYou(
                after: cursor,
                seedCreatorIds: seeds,
                tasteTags: tasteTags
            )
        case .ofTrending:
            return await OnlyFansAPI.shared.trending(after: cursor)
        case .ofLatest:
            return await OnlyFansAPI.shared.latest(after: cursor)
        case .ofDMs:
            return await OnlyFansAPI.shared.dms(after: cursor)
        case .ofCreator(let id, let handle, let displayName):
            return await OnlyFansAPI.shared.creatorFeed(
                id: id,
                handle: handle,
                displayName: displayName,
                sort: sort.rawValue,
                after: cursor
            )
        case .ofSearch(let query):
            return await OnlyFansAPI.shared.searchPosts(query, after: cursor)
        case .longVideos(let site):
            return await LongVideoAPI.shared.fetchFeed(site: site, sort: sort.rawValue, query: nil, after: cursor)
        case .longSearch(let site, let query):
            return await LongVideoAPI.shared.fetchFeed(site: site, sort: sort.rawValue, query: query, after: cursor)
        case .multiSearch(let query):
            return await fetchMultiSearch(query: query, after: cursor, api: api, store: store)
        case .list:
            return GoonedFeedResponse(posts: [], after: nil)
        }
    }

    // MARK: - Balanced Multi-Source General For You

    private func fetchBalancedForYou(
        api: GoonedAPI,
        store: UserStore,
        cursor: String?
    ) async -> GoonedFeedResponse {
        let taste = SmartTasteEngine.shared.state
        let settings = taste.sourceSettings
        let rawWeights = taste.sourceWeights

        let wantReddit = settings.includeReddit
        let wantOF = settings.includeOnlyFans
        let wantX = settings.includeX && store.data.xSession.isConnected
        let wantIG = settings.includeInstagram && store.data.igSession.isConnected

        let curX = self.xMixAfterCursor
        let curIG = self.igMixAfterCursor
        let curOF = self.ofMixOffset

        let algo = store.data.algorithm
        let activeTasteTags = algo.enabled
            ? SmartTasteEngine.shared.activeQueryTags(pinned: algo.pinnedTags, blocked: algo.blockedTags, count: 6)
            : []
        let topLearnedSubs = algo.enabled ? store.topAlgorithmSubreddits(limit: 4) : []
        var ofSeeds: [String] = []
        for ofc in store.data.followedOFCreators {
            if !ofc.name.isEmpty { ofSeeds.append(ofc.name) }
            if !ofc.id.isEmpty && !ofSeeds.contains(ofc.id) { ofSeeds.append(ofc.id) }
        }
        for s in SmartTasteEngine.shared.topOnlyFansSeedHandles(limit: 6) where !ofSeeds.contains(s) {
            ofSeeds.append(s)
        }

        async let redditTask: GoonedFeedResponse? = wantReddit
            ? (try? await api.forYou(sort: sort.rawValue, after: cursor, limit: 20))
            : nil
        async let redditTasteTask: [Gif] = {
            guard wantReddit else { return [] }
            var tasteBatch: [Gif] = []
            if !activeTasteTags.isEmpty {
                let tagPick = activeTasteTags[curOF % activeTasteTags.count]
                    .replacingOccurrences(of: "_", with: "")
                if let catResp = try? await api.category(tagPick, sort: self.sort.rawValue, after: nil, limit: 14) {
                    tasteBatch.append(contentsOf: catResp.posts)
                }
            }
            if !topLearnedSubs.isEmpty {
                let subPick = topLearnedSubs[curOF % topLearnedSubs.count]
                if let subResp = try? await api.subreddit(subPick, sort: self.sort.rawValue, after: nil, limit: 12) {
                    tasteBatch.append(contentsOf: subResp.posts)
                }
            }
            return tasteBatch
        }()
        async let ofTask: GoonedFeedResponse? = wantOF
            ? await OnlyFansAPI.shared.forYou(
                after: curOF == 0 ? nil : "\(curOF * 24)",
                seedCreatorIds: ofSeeds,
                tasteTags: activeTasteTags
            )
            : nil
        async let xTask: GoonedFeedResponse? = wantX
            ? await XAPI.forYou(after: curX)
            : nil
        async let igTask: GoonedFeedResponse? = wantIG
            ? await InstagramAPI.reels(after: curIG)
            : nil

        let (rResp, rTastePosts, ofResp, xResp, igResp) = await (redditTask, redditTasteTask, ofTask, xTask, igTask)

        if let xa = xResp?.after { self.xMixAfterCursor = xa }
        if let ia = igResp?.after { self.igMixAfterCursor = ia }
        if ofResp != nil { self.ofMixOffset += 1 }

        func prep(_ posts: [Gif]?) -> [Gif] {
            guard let posts else { return [] }
            return posts
                .filter { !store.isBlockedByAlgorithm($0) }
                .sorted { store.scorePost($0) > store.scorePost($1) }
        }

        let rPosts = prep((rTastePosts + (rResp?.posts ?? [])))
        let ofPosts = prep(ofResp?.posts)
        let xPosts = prep(xResp?.posts)
        let igPosts = prep(igResp?.posts)

        var rawActive: [(key: String, weight: Double, posts: [Gif])] = []
        if !rPosts.isEmpty { rawActive.append(("reddit", max(0.20, rawWeights["reddit"] ?? 1.0), rPosts)) }
        if !ofPosts.isEmpty { rawActive.append(("onlyfans", max(0.20, rawWeights["onlyfans"] ?? 1.0), ofPosts)) }
        if !xPosts.isEmpty { rawActive.append(("x", max(0.20, rawWeights["x"] ?? 1.0), xPosts)) }
        if !igPosts.isEmpty { rawActive.append(("instagram", max(0.15, rawWeights["instagram"] ?? 0.65), igPosts)) }

        let totalW = max(0.1, rawActive.reduce(0.0) { $0 + $1.weight })
        var buckets = rawActive.map { (key: $0.key, weight: $0.weight / totalW, posts: $0.posts, index: 0) }

        // Deficit round-robin interleaving so every enabled source gets fair proportional visibility
        var mixed: [Gif] = []
        var credits = Array(repeating: 0.0, count: buckets.count)
        var remaining = buckets.reduce(0) { $0 + $1.posts.count }
        let targetCount = min(remaining, 36)

        while mixed.count < targetCount && remaining > 0 {
            var pickedAny = false
            for i in buckets.indices {
                guard buckets[i].index < buckets[i].posts.count else { continue }
                credits[i] += buckets[i].weight
                if credits[i] >= 0.24 {
                    credits[i] -= 0.24
                    mixed.append(buckets[i].posts[buckets[i].index])
                    buckets[i].index += 1
                    remaining -= 1
                    pickedAny = true
                    if mixed.count >= targetCount { break }
                }
            }
            if !pickedAny {
                for i in buckets.indices where buckets[i].index < buckets[i].posts.count {
                    credits[i] += buckets[i].weight
                }
            }
        }

        let nextCursor = rResp?.after ?? GoonedAPI.randomForYouCursor(offset: Int.random(in: 1...8) * 25)
        return GoonedFeedResponse(posts: mixed, after: nextCursor)
    }

    // MARK: - Unified Multi-Platform Search

    private func fetchMultiSearch(
        query: String,
        after cursor: String?,
        api: GoonedAPI,
        store: UserStore
    ) async -> GoonedFeedResponse {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            return GoonedFeedResponse(posts: [], after: nil)
        }
        let tokens = clean.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
        let r34Tag = clean.lowercased().replacingOccurrences(of: " ", with: "_")
        let pageNum = max(1, Int(cursor ?? "1") ?? 1)
        let xConnected = store.data.xSession.isConnected
        let r34Creds = store.data.r34Credentials
        let categories = store.categories

        // Fire all relevant platform searches in parallel
        async let ofPostsTask = OnlyFansAPI.shared.searchPosts(clean, after: pageNum > 1 ? "\((pageNum - 1) * 20)" : nil)
        async let r34PostsTask = Rule34API.shared.fetchFeed(tag: r34Tag, sort: sort.rawValue, after: pageNum > 1 ? "\(pageNum - 1)" : nil, credentials: r34Creds)
        async let longPostsTask = LongVideoAPI.shared.fetchFeed(site: .all, sort: sort.rawValue, query: clean, after: "\(pageNum)")
        async let xPostsTask: GoonedFeedResponse = xConnected
            ? await XAPI.search(clean, sort: sort.rawValue, after: pageNum > 1 ? "\(pageNum)" : nil)
            : GoonedFeedResponse(posts: [], after: nil)
        async let redditSearchTask: [Gif] = {
            var collected: [Gif] = []
            if let sr = try? await api.search(clean) {
                let topSubs = sr.subreddits.prefix(3).map(\.name)
                await withTaskGroup(of: [Gif].self) { group in
                    for sub in topSubs {
                        group.addTask {
                            (try? await api.subreddit(sub, sort: self.sort.rawValue, after: nil, limit: 10))?.posts ?? []
                        }
                    }
                    for await batch in group { collected.append(contentsOf: batch) }
                }
            }
            if collected.isEmpty {
                let catMatch = categories.first {
                    $0.name.localizedCaseInsensitiveContains(clean) || clean.localizedCaseInsensitiveContains($0.name)
                }
                if let cat = catMatch, let resp = try? await api.category(cat.name, sort: self.sort.rawValue, after: cursor, limit: 15) {
                    collected = resp.posts
                }
            }
            return collected
        }()

        let (ofResp, r34Resp, longResp, xResp, redditPosts) = await (
            ofPostsTask, r34PostsTask, longPostsTask, xPostsTask, redditSearchTask
        )

        func relevanceScore(_ g: Gif) -> Double {
            if store.isBlockedByAlgorithm(g) { return -9999 }
            let hay = [
                g.title ?? "",
                g.subreddit ?? "",
                g.author ?? "",
                g.permalink ?? ""
            ].joined(separator: " ").lowercased()

            var score = 0.0
            if hay.contains(clean.lowercased()) { score += 12.0 }
            for tok in tokens where hay.contains(tok) {
                score += 4.5
            }
            score += store.scorePost(g) * 0.25
            return score
        }

        let r34Ranked = r34Resp.posts.sorted { relevanceScore($0) > relevanceScore($1) }
        let ofRanked = ofResp.posts.sorted { relevanceScore($0) > relevanceScore($1) }
        let xRanked = xResp.posts.sorted { relevanceScore($0) > relevanceScore($1) }
        let longRanked = longResp.posts.sorted { relevanceScore($0) > relevanceScore($1) }
        let redditRanked = redditPosts.sorted { relevanceScore($0) > relevanceScore($1) }

        var combined: [Gif] = []
        let buckets = [xRanked, ofRanked, r34Ranked, redditRanked, longRanked]
        let maxLen = buckets.map(\.count).max() ?? 0
        for i in 0..<maxLen {
            for b in buckets where i < b.count {
                let item = b[i]
                if relevanceScore(item) > -500 {
                    combined.append(item)
                }
            }
        }
        return GoonedFeedResponse(posts: combined, after: combined.isEmpty ? nil : "\(pageNum + 1)")
    }
}
