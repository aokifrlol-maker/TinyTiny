import Foundation

// MARK: - OnlyHaven (`cum.st`) Public API Models

struct OFCreator: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let displayName: String?
    let service: String?
    let bookmarked: Int?
    let dmCount: Int?
    let postCount: Int?
    let videoCount: Int?
    let imageCount: Int?
    let gender: String?
    let creatorTags: [String]?

    var displayTitle: String {
        if let d = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty {
            return d
        }
        return name
    }

    var avatarURL: URL? {
        URL(string: "https://img.cum.st/creator/\(service ?? "onlyfans")/\(id)/avatar.webp")
    }

    var headerURL: URL? {
        URL(string: "https://img.cum.st/creator/\(service ?? "onlyfans")/\(id)/header.webp")
    }
}

struct FollowedOFCreator: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let displayName: String?

    var avatarURL: URL? {
        URL(string: "https://img.cum.st/creator/onlyfans/\(id)/avatar.webp")
    }
}

struct OFVariant: Decodable {
    let name: String
    let bytes: Int?
}

struct OFAttachment: Decodable {
    let position: Int?
    let id: String?
    let sha256: String?
    let kind: String
    let mimeType: String?
    let width: Int?
    let height: Int?
    let durationMs: Int?
    let bytes: Int?
    let storageKey: String?
    let variants: [OFVariant]?
}

private struct OFPostRow: Decodable {
    let id: String
    let service: String?
    let creatorId: String?
    let creatorName: String?
    let title: String?
    let captionText: String?
    let added: Int?
    let published: Int?
    let bookmarked: Int?
    let attachments: [OFAttachment]
    let tags: [String]?
    let creatorTags: [String]?
}

private struct OFDmRow: Decodable {
    let id: String
    let service: String?
    let creatorId: String?
    let creatorName: String?
    let contentText: String?
    let bookmarked: Int?
    let attachments: [OFAttachment]
    let creatorTags: [String]?
}

private struct OFPostsResponse: Decodable {
    let total: Int?
    let posts: [OFPostRow]
}

private struct OFDmsResponse: Decodable {
    let total: Int?
    let dms: [OFDmRow]
}

private struct OFCreatorsResponse: Decodable {
    let total: Int?
    let creators: [OFCreator]
}

private struct OFSimilarCreatorsResponse: Decodable {
    let creators: [OFCreator]
}

// MARK: - OnlyFans Public API Client (`OnlyFansAPI`)

actor OnlyFansAPI {
    static let shared = OnlyFansAPI()

    private let base = Config.onlyHavenBase
    private let mediaCDN = "https://cdn.cum.st/media"
    private let thumbCDN = "https://img.cum.st/thumbnail"

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 16
        cfg.httpAdditionalHeaders = [
            "User-Agent": Config.userAgent,
            "Accept": "application/json",
            "Referer": "https://cum.st/"
        ]
        return URLSession(configuration: cfg)
    }()

    private var cachedTopCreators: [OFCreator] = []
    private var topCreatorsFetchedAt: Date? = nil
    private var creatorSearchCache: [String: [OFCreator]] = [:]
    private var creatorById: [String: OFCreator] = [:]
    private var creatorByName: [String: OFCreator] = [:]

    private func cacheCreators(_ creators: [OFCreator]) {
        for c in creators {
            creatorById[c.id] = c
            creatorByName[c.name.lowercased()] = c
            MediaMetaRegistry.registerCreatorGender(creatorId: c.id, creatorName: c.name, gender: c.gender)
        }
    }

    nonisolated private func withHiddenGenders(_ params: [String: String]) -> [String: String] {
        var out = params
        if let hg = SmartTasteEngine.currentHiddenOFGendersCSV {
            out["hide_gender"] = hg
        }
        return out
    }

    /// Resolves a creator's `gender` and community `creatorTags` from cache or `cum.st` `/creators`.
    func lookupCreator(creatorId: String?, creatorName: String?) async -> OFCreator? {
        if let cid = creatorId, let hit = creatorById[cid] { return hit }
        let cleanName = creatorName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !cleanName.isEmpty, let hit = creatorByName[cleanName.lowercased()] { return hit }
        guard !cleanName.isEmpty,
              let resp: OFCreatorsResponse = try? await get("/creators", [
                  "service": "onlyfans",
                  "q": cleanName,
                  "n": "10"
              ]) else {
            return nil
        }
        cacheCreators(resp.creators)
        if let cid = creatorId, let exactId = resp.creators.first(where: { $0.id == cid }) {
            return exactId
        }
        return resp.creators.first(where: { $0.name.caseInsensitiveCompare(cleanName) == .orderedSame })
            ?? resp.creators.first
    }

    // MARK: - Low-Level HTTP

    private func get<T: Decodable>(_ path: String, _ query: [String: String] = [:]) async throws -> T {
        guard var comps = URLComponents(string: base + path) else { throw APIError.badURL }
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else { throw APIError.badURL }
        let (data, resp) = try await session.data(from: url)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIError.http(http.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Cursor Helpers

    nonisolated private func encodeCursor(_ dict: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: []) else { return nil }
        return data.base64EncodedString()
    }

    nonisolated private func decodeCursor(_ cursor: String?) -> [String: Any]? {
        guard let cursor, !cursor.isEmpty,
              let data = Data(base64Encoded: cursor),
              let obj = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return nil
        }
        return obj
    }

    private static func utcDateString(daysAgo: Int) -> String {
        let fmt = DateFormatter()
        fmt.calendar = Calendar(identifier: .gregorian)
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "yyyy-MM-dd"
        let target = Date().addingTimeInterval(Double(-daysAgo) * 86_400)
        return fmt.string(from: target)
    }

    // MARK: - Media Mapping

    private func defaultFilename(for mime: String?, kind: String) -> String {
        let lower = (mime ?? "").lowercased()
        if lower.contains("mp4") || kind == "video" { return "original.mp4" }
        if lower.contains("webm") { return "original.webm" }
        if lower.contains("quicktime") || lower.contains("mov") { return "original.mov" }
        if lower.contains("png") { return "original.png" }
        if lower.contains("webp") { return "original.webp" }
        if lower.contains("gif") || kind == "gif" { return "original.gif" }
        return "original.jpg"
    }

    private func mapAttachmentToGif(
        _ att: OFAttachment,
        postId: String,
        creatorId: String,
        creatorName: String,
        caption: String?,
        bookmarked: Int?,
        published: Int?,
        prefix: String
    ) -> Gif? {
        let kind = att.kind.lowercased()
        guard kind == "video" || kind == "image" || kind == "gif" else { return nil }
        guard let sk = att.storageKey, !sk.isEmpty else { return nil }

        let thumbURL = "\(thumbCDN)/\(sk)/preview.webp"
        let variantNames = (att.variants ?? []).map(\.name)
        let pos = att.position ?? 0
        let cleanTitle = caption?.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleText = (cleanTitle?.isEmpty == false) ? cleanTitle : "@\(creatorName)"

        let isoDate: String? = published.flatMap { ts in
            guard ts > 0 else { return nil }
            return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
        }

        let permalink = "https://cum.st/creators/onlyfans/\(creatorId)/post/\(postId)"
        let sourceUrl = "https://cum.st/creators/onlyfans/\(creatorId)"

        if kind == "video" {
            let hdName = variantNames.first(where: { $0 == "original.mp4" })
                ?? variantNames.first(where: { $0.contains("1080") })
                ?? variantNames.first(where: { $0 == "720p.mp4" })
                ?? variantNames.first
                ?? defaultFilename(for: att.mimeType, kind: kind)

            let sdName = variantNames.first(where: { $0 == "720p.mp4" })
                ?? variantNames.first(where: { $0 == "original.mp4" })
                ?? variantNames.first(where: { $0 == "240p.mp4" })
                ?? hdName

            let lowName = variantNames.first(where: { $0 == "240p.mp4" }) ?? sdName

            return Gif(
                id: "of_\(prefix)\(postId)_\(pos)",
                title: titleText,
                author: creatorName,
                subreddit: nil,
                upvotes: bookmarked ?? 0,
                duration: att.durationMs.map { Double($0) / 1000.0 },
                width: att.width,
                height: att.height,
                mediaType: "video",
                mediaUrl: "\(mediaCDN)/\(sk)/\(lowName)",
                muxedUrl: "\(mediaCDN)/\(sk)/\(sdName)",
                muxedUrlHd: "\(mediaCDN)/\(sk)/\(hdName)",
                hlsUrl: nil,
                posterUrl: thumbURL,
                thumbnailUrl: thumbURL,
                sourceUrl: sourceUrl,
                permalink: permalink,
                createdUtc: isoDate
            )
        } else {
            let imgName = variantNames.first(where: { $0.hasPrefix("original") })
                ?? variantNames.first
                ?? defaultFilename(for: att.mimeType, kind: kind)

            return Gif(
                id: "of_\(prefix)\(postId)_\(pos)",
                title: titleText,
                author: creatorName,
                subreddit: nil,
                upvotes: bookmarked ?? 0,
                duration: nil,
                width: att.width,
                height: att.height,
                mediaType: "image",
                mediaUrl: "\(mediaCDN)/\(sk)/\(imgName)",
                muxedUrl: nil,
                muxedUrlHd: nil,
                hlsUrl: nil,
                posterUrl: thumbURL,
                thumbnailUrl: thumbURL,
                sourceUrl: sourceUrl,
                permalink: permalink,
                createdUtc: isoDate
            )
        }
    }

    private func mapPosts(
        _ rows: [OFPostRow],
        fallbackCreatorId: String? = nil,
        fallbackCreatorName: String? = nil,
        videosOnly: Bool = true
    ) -> [Gif] {
        let hiddenGenders = Set(SmartTasteEngine.currentHiddenOFGenders.map { $0.lowercased() })
        var out: [Gif] = []
        for row in rows {
            let cid = row.creatorId ?? fallbackCreatorId ?? "0"
            let cname = row.creatorName ?? fallbackCreatorName ?? "creator"
            let cachedCreator = creatorById[cid] ?? creatorByName[cname.lowercased()]
            let resolvedGender = cachedCreator?.gender?.lowercased()
            let mergedTags = (row.tags ?? []) + (row.creatorTags ?? []) + (cachedCreator?.creatorTags ?? [])
            let lowerTags = Set(mergedTags.map { $0.lowercased().replacingOccurrences(of: "#", with: "") })
            let isFemboyOrTrans = !lowerTags.isDisjoint(with: SmartTasteEngine.femboyOrTransRescueTags)

            if let g = resolvedGender, hiddenGenders.contains(g) {
                if (g == "man" || g == "nonbinary") && isFemboyOrTrans {
                    // Rescued: Femboy / Trans creator labeled as `man` in raw cum.st DB
                } else {
                    continue
                }
            }
            let text = (row.captionText?.isEmpty == false) ? row.captionText : row.title
            let candidates = videosOnly
                ? row.attachments.filter { $0.kind.lowercased() == "video" }
                : row.attachments
            for att in candidates {
                if let g = mapAttachmentToGif(
                    att,
                    postId: row.id,
                    creatorId: cid,
                    creatorName: cname,
                    caption: text,
                    bookmarked: row.bookmarked,
                    published: row.published ?? row.added,
                    prefix: ""
                ) {
                    MediaMetaRegistry.register(
                        postId: g.id,
                        tags: mergedTags,
                        creatorGender: resolvedGender,
                        creatorId: cid,
                        creatorName: cname
                    )
                    out.append(g)
                }
            }
        }
        return out
    }

    private func mapDms(
        _ rows: [OFDmRow],
        fallbackCreatorId: String? = nil,
        fallbackCreatorName: String? = nil,
        videosOnly: Bool = true
    ) -> [Gif] {
        let hiddenGenders = Set(SmartTasteEngine.currentHiddenOFGenders.map { $0.lowercased() })
        var out: [Gif] = []
        for row in rows {
            let cid = row.creatorId ?? fallbackCreatorId ?? "0"
            let cname = row.creatorName ?? fallbackCreatorName ?? "creator"
            let cachedCreator = creatorById[cid] ?? creatorByName[cname.lowercased()]
            let resolvedGender = cachedCreator?.gender?.lowercased()
            if let g = resolvedGender, hiddenGenders.contains(g) { continue }

            let mergedTags = (row.creatorTags ?? []) + (cachedCreator?.creatorTags ?? [])
            let candidates = videosOnly
                ? row.attachments.filter { $0.kind.lowercased() == "video" }
                : row.attachments
            for att in candidates {
                if let g = mapAttachmentToGif(
                    att,
                    postId: row.id,
                    creatorId: cid,
                    creatorName: cname,
                    caption: row.contentText,
                    bookmarked: row.bookmarked,
                    published: nil,
                    prefix: "dm_"
                ) {
                    MediaMetaRegistry.register(
                        postId: g.id,
                        tags: mergedTags,
                        creatorGender: resolvedGender,
                        creatorId: cid,
                        creatorName: cname
                    )
                    out.append(g)
                }
            }
        }
        return out
    }

    // MARK: - Public Discovery Feeds (Infinite Scroll)

    /// Personalized OnlyFans "For You" Feed:
    /// Blends (1) Similar-Creator Graph (`/onlyfans/user/{id}/similar`) from liked/followed OF creators,
    /// (2) Active `creator_tag` & keyword searches for the user's top/pinned Smart Personalization tags,
    /// and (3) Filtered Popular/Recent discovery.
    func forYou(
        after: String?,
        seedCreatorIds: [String],
        tasteTags: [String]
    ) async -> GoonedFeedResponse {
        let cur = decodeCursor(after)
        let page = (cur?["page"] as? Int) ?? 0
        let cleanTags = tasteTags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "#", with: "") }
            .filter { !$0.isEmpty && !MediaMetaRegistry.isStopTag($0) }

        var buckets: [[Gif]] = []

        await withTaskGroup(of: [Gif].self) { group in
            // 1. Taste-Tag & Creator-Tag Queries (e.g., femboy, goth, latina, ebony, milf, cosplay, trans)
            if !cleanTags.isEmpty {
                let tagPick1 = cleanTags[page % cleanTags.count]
                let tagPick2 = cleanTags.count > 1 ? cleanTags[(page + 1) % cleanTags.count] : nil
                for tag in [tagPick1, tagPick2].compactMap({ $0 }) {
                    group.addTask {
                        let isFemboyQuery = SmartTasteEngine.femboyOrTransRescueTags.contains(tag)
                        var params: [String: String] = [
                            "service": "onlyfans",
                            "type": "videos",
                            "q": tag,
                            "sort": page % 2 == 0 ? "popular" : "recent",
                            "o": "\((page / max(1, cleanTags.count)) * 24)",
                            "n": "24"
                        ]
                        if !isFemboyQuery {
                            params = self.withHiddenGenders(params)
                        }
                        if let resp: OFPostsResponse = try? await self.get("/posts", params), !resp.posts.isEmpty {
                            return await self.mapPosts(resp.posts, videosOnly: true)
                        }
                        var tagParams: [String: String] = [
                            "service": "onlyfans",
                            "type": "videos",
                            "creator_tag": tag,
                            "sort": "recent",
                            "o": "\((page / max(1, cleanTags.count)) * 24)",
                            "n": "24"
                        ]
                        if !isFemboyQuery {
                            tagParams = self.withHiddenGenders(tagParams)
                        }
                        if let resp2: OFPostsResponse = try? await self.get("/posts", tagParams) {
                            return await self.mapPosts(resp2.posts, videosOnly: true)
                        }
                        return []
                    }
                }
            }

            // 2. Similar-Creators Graph (`SimClusters`) seeded from Liked & Followed OF Creators
            if !seedCreatorIds.isEmpty {
                let seedId = seedCreatorIds[page % seedCreatorIds.count]
                group.addTask {
                    if let sim: OFSimilarCreatorsResponse = try? await self.get("/onlyfans/user/\(seedId)/similar"),
                       !sim.creators.isEmpty {
                        await self.cacheCreators(sim.creators)
                        let pick = sim.creators[(page / max(1, seedCreatorIds.count)) % sim.creators.count]
                        if let resp: OFPostsResponse = try? await self.get("/onlyfans/user/\(pick.id)/posts", [
                            "type": "videos",
                            "sort": "popular",
                            "o": "0",
                            "n": "16"
                        ]) {
                            return await self.mapPosts(resp.posts, fallbackCreatorId: pick.id, fallbackCreatorName: pick.name, videosOnly: true)
                        }
                    }
                    if let direct: OFPostsResponse = try? await self.get("/onlyfans/user/\(seedId)/posts", [
                        "type": "videos",
                        "sort": "recent",
                        "o": "\((page / max(1, seedCreatorIds.count)) * 12)",
                        "n": "12"
                    ]) {
                        return await self.mapPosts(direct.posts, fallbackCreatorId: seedId, fallbackCreatorName: nil, videosOnly: true)
                    }
                    return []
                }
            }

            // 3. Popular + Fresh Discovery Backbone
            group.addTask {
                let popCursor = self.encodeCursor([
                    "mode": "pop",
                    "period": page % 3 == 2 ? "month" : "week",
                    "daysAgo": 0,
                    "o": (page * 24) % 240
                ])
                let pop = await self.trending(after: popCursor)
                return pop.posts
            }

            group.addTask {
                let recCursor = self.encodeCursor(["mode": "recent", "o": page * 24])
                let rec = await self.latest(after: recCursor)
                return Array(rec.posts.prefix(16))
            }

            for await batch in group where !batch.isEmpty {
                buckets.append(batch)
            }
        }

        var merged: [Gif] = []
        var seen = Set<String>()
        let maxLen = buckets.map(\.count).max() ?? 0
        for i in 0..<maxLen {
            for b in buckets where i < b.count {
                let item = b[i]
                if seen.insert(item.id).inserted {
                    merged.append(item)
                }
            }
        }

        let nextCursor = encodeCursor(["page": page + 1])
        return GoonedFeedResponse(posts: merged, after: nextCursor)
    }

    /// Trending OnlyFans videos: fast cached leaderboards (week -> month -> stepping back -> recent 1.98M archive).
    func trending(after: String?) async -> GoonedFeedResponse {
        let cur = decodeCursor(after)
        let mode = (cur?["mode"] as? String) ?? "pop"

        if mode == "recent" {
            let o = (cur?["o"] as? Int) ?? 0
            if let resp: OFPostsResponse = try? await get("/posts", withHiddenGenders([
                "service": "onlyfans",
                "type": "videos",
                "sort": "recent",
                "o": "\(o)",
                "n": "40"
            ])) {
                let gifs = mapPosts(resp.posts, videosOnly: true)
                let nextCursor = encodeCursor(["mode": "recent", "o": o + 40])
                return GoonedFeedResponse(posts: gifs, after: nextCursor)
            }
            return GoonedFeedResponse(posts: [], after: after)
        }

        let period = (cur?["period"] as? String) ?? "week"
        let daysAgo = (cur?["daysAgo"] as? Int) ?? 0
        let o = (cur?["o"] as? Int) ?? 0
        let dateStr = Self.utcDateString(daysAgo: daysAgo)

        if let resp: OFPostsResponse = try? await get("/posts/popular", withHiddenGenders([
            "service": "onlyfans",
            "type": "videos",
            "period": period,
            "date": dateStr,
            "o": "\(o)",
            "n": "50"
        ])) {
            let gifs = mapPosts(resp.posts, videosOnly: true)
            let nextOffset = o + resp.posts.count
            let maxCap = min(resp.total ?? 500, 500)
            let nextDict: [String: Any]
            if !resp.posts.isEmpty && nextOffset < maxCap {
                nextDict = ["mode": "pop", "period": period, "daysAgo": daysAgo, "o": nextOffset]
            } else if period == "week" {
                nextDict = ["mode": "pop", "period": "month", "daysAgo": 0, "o": 0]
            } else if period == "month" && daysAgo < 180 {
                nextDict = ["mode": "pop", "period": "month", "daysAgo": daysAgo + 30, "o": 0]
            } else {
                nextDict = ["mode": "recent", "o": 0]
            }
            return GoonedFeedResponse(posts: gifs, after: encodeCursor(nextDict))
        }

        // Fast fallback to recent videos if leaderboard hiccups
        return await latest(after: nil)
    }

    /// Latest OnlyFans videos sorted newest-first across the full ~1.98M video catalog.
    func latest(after: String?) async -> GoonedFeedResponse {
        let cur = decodeCursor(after)
        let o = (cur?["o"] as? Int) ?? (Int(after ?? "0") ?? 0)
        guard let resp: OFPostsResponse = try? await get("/posts", withHiddenGenders([
            "service": "onlyfans",
            "type": "videos",
            "sort": "recent",
            "o": "\(o)",
            "n": "40"
        ])) else {
            return GoonedFeedResponse(posts: [], after: after)
        }
        let gifs = mapPosts(resp.posts, videosOnly: true)
        let nextO = resp.posts.isEmpty ? 0 : o + resp.posts.count
        return GoonedFeedResponse(posts: gifs, after: encodeCursor(["mode": "recent", "o": nextO]))
    }

    /// Unlocked OnlyFans DM / PPV videos: popular DMs (week -> month) then infinite recent DMs.
    func dms(after: String?) async -> GoonedFeedResponse {
        let cur = decodeCursor(after)
        let mode = (cur?["mode"] as? String) ?? "pop"

        if mode == "recent" {
            let o = (cur?["o"] as? Int) ?? 0
            guard let resp: OFDmsResponse = try? await get("/dms", withHiddenGenders([
                "service": "onlyfans",
                "type": "videos",
                "sort": "recent",
                "o": "\(o)",
                "n": "40"
            ])) else {
                return GoonedFeedResponse(posts: [], after: after)
            }
            let gifs = mapDms(resp.dms, videosOnly: true)
            let nextO = resp.dms.isEmpty ? 0 : o + resp.dms.count
            return GoonedFeedResponse(posts: gifs, after: encodeCursor(["mode": "recent", "o": nextO]))
        }

        let period = (cur?["period"] as? String) ?? "week"
        let daysAgo = (cur?["daysAgo"] as? Int) ?? 0
        let o = (cur?["o"] as? Int) ?? 0
        let dateStr = Self.utcDateString(daysAgo: daysAgo)

        if let resp: OFDmsResponse = try? await get("/dms/popular", withHiddenGenders([
            "service": "onlyfans",
            "type": "videos",
            "period": period,
            "date": dateStr,
            "o": "\(o)",
            "n": "50"
        ])) {
            let gifs = mapDms(resp.dms, videosOnly: true)
            let nextOffset = o + resp.dms.count
            let maxCap = min(resp.total ?? 500, 500)
            let nextDict: [String: Any]
            if !resp.dms.isEmpty && nextOffset < maxCap {
                nextDict = ["mode": "pop", "period": period, "daysAgo": daysAgo, "o": nextOffset]
            } else if period == "week" {
                nextDict = ["mode": "pop", "period": "month", "daysAgo": 0, "o": 0]
            } else {
                nextDict = ["mode": "recent", "o": 0]
            }
            return GoonedFeedResponse(posts: gifs, after: encodeCursor(nextDict))
        }

        return GoonedFeedResponse(posts: [], after: encodeCursor(["mode": "recent", "o": 0]))
    }

    // MARK: - Per-Creator Feed & Similar-Creator Infinite Continuation

    func creatorFeed(
        id creatorId: String,
        handle: String,
        displayName: String? = nil,
        sort: String = "hot",
        after: String?
    ) async -> GoonedFeedResponse {
        let cur = decodeCursor(after)
        let stage = (cur?["stage"] as? String) ?? "posts"
        let o = (cur?["o"] as? Int) ?? 0
        let apiSort = (sort == "new") ? "recent" : "popular"

        if stage == "posts" {
            if let resp: OFPostsResponse = try? await get("/onlyfans/user/\(creatorId)/posts", [
                "type": "videos",
                "sort": apiSort,
                "o": "\(o)",
                "n": "40"
            ]) {
                let gifs = mapPosts(resp.posts, fallbackCreatorId: creatorId, fallbackCreatorName: handle, videosOnly: true)
                let nextOffset = o + resp.posts.count
                let total = resp.total ?? 0
                if !resp.posts.isEmpty && nextOffset < total {
                    return GoonedFeedResponse(
                        posts: gifs,
                        after: encodeCursor(["stage": "posts", "o": nextOffset])
                    )
                }
                return GoonedFeedResponse(
                    posts: gifs,
                    after: encodeCursor(["stage": "dms", "o": 0])
                )
            }
            return GoonedFeedResponse(posts: [], after: encodeCursor(["stage": "dms", "o": 0]))
        }

        if stage == "dms" {
            if let resp: OFDmsResponse = try? await get("/onlyfans/user/\(creatorId)/dms", [
                "type": "videos",
                "sort": apiSort,
                "o": "\(o)",
                "n": "40"
            ]) {
                let gifs = mapDms(resp.dms, fallbackCreatorId: creatorId, fallbackCreatorName: handle, videosOnly: true)
                let nextOffset = o + resp.dms.count
                let total = resp.total ?? 0
                if !resp.dms.isEmpty && nextOffset < total {
                    return GoonedFeedResponse(
                        posts: gifs,
                        after: encodeCursor(["stage": "dms", "o": nextOffset])
                    )
                }
                if let sim: OFSimilarCreatorsResponse = try? await get("/onlyfans/user/\(creatorId)/similar"),
                   !sim.creators.isEmpty {
                    let simIds = sim.creators.map { "\($0.id)|\($0.name)" }
                    return GoonedFeedResponse(
                        posts: gifs,
                        after: encodeCursor(["stage": "similar", "simIdx": 0, "o": 0, "simIds": simIds])
                    )
                }
                return GoonedFeedResponse(posts: gifs, after: encodeCursor(["stage": "fallback", "o": 0]))
            }
            return GoonedFeedResponse(posts: [], after: encodeCursor(["stage": "fallback", "o": 0]))
        }

        if stage == "similar", let simList = cur?["simIds"] as? [String], !simList.isEmpty {
            let simIdx = (cur?["simIdx"] as? Int) ?? 0
            if simIdx < simList.count {
                let parts = simList[simIdx].split(separator: "|", maxSplits: 1).map(String.init)
                let simId = parts.first ?? ""
                let simHandle = parts.count > 1 ? parts[1] : simId
                if let resp: OFPostsResponse = try? await get("/onlyfans/user/\(simId)/posts", [
                    "type": "videos",
                    "sort": "popular",
                    "o": "\(o)",
                    "n": "30"
                ]) {
                    let gifs = mapPosts(resp.posts, fallbackCreatorId: simId, fallbackCreatorName: simHandle, videosOnly: true)
                    return GoonedFeedResponse(
                        posts: gifs,
                        after: encodeCursor(["stage": "similar", "simIdx": simIdx + 1, "o": 0, "simIds": simList])
                    )
                }
            }
        }

        // After exhausting creator + similar creators, keep scroll endless with trending OF videos
        let fallbackOffset = (cur?["o"] as? Int) ?? 0
        return await trending(after: fallbackOffset > 0 ? encodeCursor(["mode": "pop", "period": "week", "daysAgo": 0, "o": fallbackOffset]) : nil)
    }

    // MARK: - Search (Creators + Posts)

    func topCreators(limit: Int = 50) async -> [OFCreator] {
        let hidden = Set(SmartTasteEngine.currentHiddenOFGenders.map { $0.lowercased() })
        if let fetchedAt = topCreatorsFetchedAt,
           Date().timeIntervalSince(fetchedAt) < 300,
           !cachedTopCreators.isEmpty {
            return Array(cachedTopCreators.filter { !hidden.contains(($0.gender ?? "").lowercased()) }.prefix(limit))
        }

        async let p1: OFCreatorsResponse? = try? await get("/creators", withHiddenGenders([
            "service": "onlyfans",
            "sort": "bookmarked",
            "content": "imported",
            "o": "0",
            "n": "50"
        ]))
        async let p2: OFCreatorsResponse? = try? await get("/creators", withHiddenGenders([
            "service": "onlyfans",
            "sort": "bookmarked",
            "content": "imported",
            "o": "50",
            "n": "50"
        ]))

        let (r1, r2) = await (p1, p2)
        var merged: [OFCreator] = []
        var seen = Set<String>()
        for c in (r1?.creators ?? []) + (r2?.creators ?? []) {
            if seen.insert(c.id).inserted {
                merged.append(c)
            }
        }
        if !merged.isEmpty {
            cacheCreators(merged)
            cachedTopCreators = merged
            topCreatorsFetchedAt = Date()
        }
        return Array(cachedTopCreators.filter { !hidden.contains(($0.gender ?? "").lowercased()) }.prefix(limit))
    }

    func searchCreators(_ query: String, limit: Int = 30) async -> [OFCreator] {
        let hidden = Set(SmartTasteEngine.currentHiddenOFGenders.map { $0.lowercased() })
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "@", with: "")
            .replacingOccurrences(of: "of:", with: "", options: .caseInsensitive)
        guard !q.isEmpty else { return await topCreators(limit: limit) }

        let cacheKey = "\(q.lowercased())|\(hidden.sorted().joined(separator: ","))"
        if let cached = creatorSearchCache[cacheKey] {
            return Array(cached.prefix(limit))
        }

        // OnlyHaven API requires >= 3 characters for /creators?q=;
        // for 1-2 character queries, filter our cached top 100 bookmarked creators locally in 0ms.
        let topPool = await topCreators(limit: 100)
        let localMatches = topPool.filter {
            !hidden.contains(($0.gender ?? "").lowercased()) && (
                $0.name.localizedCaseInsensitiveContains(q) ||
                ($0.displayName?.localizedCaseInsensitiveContains(q) == true)
            )
        }
        guard q.count >= 3 else {
            return Array(localMatches.prefix(limit))
        }

        if let resp: OFCreatorsResponse = try? await get("/creators", withHiddenGenders([
            "service": "onlyfans",
            "q": q,
            "sort": "bookmarked",
            "o": "0",
            "n": "\(min(max(limit, 1), 50))"
        ])) {
            cacheCreators(resp.creators)
            var merged: [OFCreator] = []
            var seen = Set<String>()
            // Prioritize creators with actual imported videos first
            let apiSorted = resp.creators
                .filter { !hidden.contains(($0.gender ?? "").lowercased()) }
                .sorted { ($0.videoCount ?? 0) > ($1.videoCount ?? 0) }
            for c in apiSorted + localMatches {
                if seen.insert(c.id).inserted {
                    merged.append(c)
                }
            }
            if !merged.isEmpty {
                creatorSearchCache[cacheKey] = merged
            }
            return Array(merged.prefix(limit))
        }
        return Array(localMatches.prefix(limit))
    }

    /// Searches OnlyFans videos by caption/tag query and blends matching creators' videos when sparse.
    func searchPosts(_ query: String, after: String?) async -> GoonedFeedResponse {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "@", with: "")
        guard !q.isEmpty else { return await trending(after: after) }

        let cur = decodeCursor(after)
        let o = (cur?["o"] as? Int) ?? 0

        var results: [Gif] = []
        var totalNextOffset = o

        if q.count >= 3,
           let resp: OFPostsResponse = try? await get("/posts", withHiddenGenders([
               "service": "onlyfans",
               "q": q,
               "type": "videos",
               "sort": "relevance",
               "o": "\(o)",
               "n": "40"
           ])) {
            results.append(contentsOf: mapPosts(resp.posts, videosOnly: true))
            totalNextOffset = o + resp.posts.count
        }

        // On first page or if caption search had < 8 matches, also pull videos from matching creators!
        if o == 0 && results.count < 8 {
            let matchingCreators = await searchCreators(q, limit: 4)
            await withTaskGroup(of: [Gif].self) { group in
                for creator in matchingCreators.prefix(3) {
                    group.addTask {
                        let cFeed = await self.creatorFeed(
                            id: creator.id,
                            handle: creator.name,
                            displayName: creator.displayName,
                            sort: "hot",
                            after: nil
                        )
                        return Array(cFeed.posts.prefix(6))
                    }
                }
                for await batch in group {
                    results.append(contentsOf: batch)
                }
            }
        }

        return GoonedFeedResponse(
            posts: results,
            after: encodeCursor(["mode": "search", "o": max(totalNextOffset, o + 40)])
        )
    }
}
