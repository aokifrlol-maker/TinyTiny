import Foundation

enum APIError: LocalizedError {
    case badURL
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .badURL: return "Bad URL"
        case .http(let code): return "Server error (\(code))"
        }
    }
}

/// Dual-source API engine: RedGIFs v2 + 18+ Reddit (Arctic Shift NSFW index).
actor RedGifsAPI {
    static let shared = RedGifsAPI()

    private var token: String?
    private var tokenDate = Date.distantPast

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpAdditionalHeaders = ["User-Agent": Config.userAgent, "Accept": "application/json"]
        cfg.timeoutIntervalForRequest = 18
        return URLSession(configuration: cfg)
    }()

    private struct TokenResponse: Decodable { let token: String }

    private func validToken() async throws -> String {
        if let token, Date().timeIntervalSince(tokenDate) < 60 * 60 * 20 { return token }
        let url = URL(string: Config.apiBase + "auth/temporary")!
        let (data, resp) = try await session.data(from: url)
        try check(resp)
        let t = try JSONDecoder().decode(TokenResponse.self, from: data).token
        token = t
        tokenDate = Date()
        return t
    }

    private func check(_ resp: URLResponse) throws {
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            throw APIError.http(h.statusCode)
        }
    }

    func get<T: Decodable>(_ path: String, _ query: [String: String] = [:]) async throws -> T {
        guard var comps = URLComponents(string: Config.apiBase + path) else { throw APIError.badURL }
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else { throw APIError.badURL }

        var lastError: Error = APIError.badURL
        for _ in 0..<2 {
            let t = try await validToken()
            var req = URLRequest(url: url)
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
            let (data, resp) = try await session.data(for: req)
            if let h = resp as? HTTPURLResponse, h.statusCode == 401 || h.statusCode == 403 {
                token = nil
                lastError = APIError.http(h.statusCode)
                continue
            }
            try check(resp)
            return try JSONDecoder().decode(T.self, from: data)
        }
        throw lastError
    }

    private func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }

    // MARK: - RedGIFs Endpoints (Fixed: uses `tags` parameter so every tag/category returns unique results!)

    func trending(page: Int, count: Int = 30) async throws -> GifPage {
        try await get("gifs/search", ["order": "trending", "count": "\(count)", "page": "\(page)"])
    }

    /// Searches RedGIFs by tag or keyword. RedGIFs v2 requires `tags` to actually filter by tag!
    func search(_ text: String, order: String = "top", page: Int, count: Int = 30) async throws -> GifPage {
        let clean = text
            .replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            return try await trending(page: page, count: count)
        }

        let apiOrder = (order == "latest" || order == "new") ? "latest" : "top"

        // 1. Primary: query via `tags` parameter (returns distinct, accurate videos per tag)
        if let byTag: GifPage = try? await get("gifs/search", ["tags": clean, "order": apiOrder, "count": "\(count)", "page": "\(page)"]),
           !byTag.gifs.isEmpty {
            return byTag
        }

        // 2. Fallback: resolve closest matching tag via suggest endpoint, then query `tags`
        if let suggestions = try? await suggest(clean),
           let firstTag = suggestions.first(where: { ($0.type ?? "").lowercased() != "user" })?.text,
           let bySuggested: GifPage = try? await get("gifs/search", ["tags": firstTag, "order": apiOrder, "count": "\(count)", "page": "\(page)"]),
           !bySuggested.gifs.isEmpty {
            return bySuggested
        }

        // 3. Fallback: creator username search
        let userClean = clean.replacingOccurrences(of: "@", with: "").replacingOccurrences(of: " ", with: "")
        if let byUser = try? await user(userClean, page: page, count: count), !byUser.gifs.isEmpty {
            return byUser
        }

        return GifPage(gifs: [], users: [], page: page, pages: page)
    }

    func gifByID(_ id: String) async throws -> Gif {
        let r: SingleGifResponse = try await get("gifs/\(enc(id.lowercased()))")
        return r.gif
    }

    /// Fetches distinct category feed blending the category's dedicated RedGIFs tags AND its curated 18+ subreddits!
    func category(_ cat: GoonedCategory, order: String = "top", page: Int, count: Int = 28) async throws -> GifPage {
        let tagIndex = (page - 1) % max(1, cat.redgifsTags.count)
        let tagPage = ((page - 1) / max(1, cat.redgifsTags.count)) + 1
        let primaryTag = cat.redgifsTags[tagIndex]

        let subIndex = (page - 1) % max(1, cat.subreddits.count)
        let subName = cat.subreddits[subIndex].trimmingCharacters(in: .whitespaces)

        async let rgTask: GifPage? = try? search(primaryTag, order: order, page: tagPage, count: count)
        async let redditTask: (gifs: [Gif], nextCursor: Int?)? = try? subredditPosts(subName, before: nil, limit: 14)

        let rgPage = await rgTask
        let redditBatch = await redditTask

        var combined: [Gif] = []
        let rgGifs = rgPage?.gifs ?? []
        let rdGifs = redditBatch?.gifs ?? []

        // Interleave RedGIFs and 18+ Reddit posts for this category
        let maxLen = max(rgGifs.count, rdGifs.count)
        for i in 0..<maxLen {
            if i < rgGifs.count { combined.append(rgGifs[i]) }
            if i < rdGifs.count { combined.append(rdGifs[i]) }
        }

        return GifPage(gifs: combined, users: rgPage?.users ?? [], page: page, pages: max(rgPage?.pages ?? 50, 50))
    }

    func user(_ username: String, page: Int, count: Int = 30) async throws -> GifPage {
        try await get("users/\(enc(username))/search", ["order": "new", "count": "\(count)", "page": "\(page)"])
    }

    func trendingTags() async throws -> TagsResponse {
        try await get("tags/trending")
    }

    func suggest(_ query: String) async throws -> [Suggestion] {
        try await get("search/suggest", ["query": query])
    }

    // MARK: - Strictly 18+ Reddit API (Subreddit Search + Subreddit Video/Image Posts)

    func searchNSFWSubreddits(_ query: String, limit: Int = 25) async throws -> [SubredditInfo] {
        let clean = query
            .replacingOccurrences(of: "r/", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "/", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !clean.isEmpty else { return Self.popularNSFWSubreddits }

        var comps = URLComponents(string: Config.redditBase + "subreddits/search")!
        comps.queryItems = [
            URLQueryItem(name: "subreddit_prefix", value: clean),
            URLQueryItem(name: "over18", value: "true"),
            URLQueryItem(name: "sort_type", value: "subscribers"),
            URLQueryItem(name: "sort", value: "desc"),
            URLQueryItem(name: "limit", value: "\(limit)")
        ]
        guard let url = comps.url else { return [] }
        let (data, resp) = try await session.data(from: url)
        try check(resp)
        let decoded = try JSONDecoder().decode(SubredditSearchResponse.self, from: data)
        return decoded.data.compactMap { $0.value }.filter { $0.over18 != false }
    }

    /// Fetches strictly 18+ media posts from a subreddit (`r/subreddit`), converting Reddit videos, RedGIFs embeds, and images into playable `Gif` items.
    func subredditPosts(_ subreddit: String, before: Int? = nil, query: String? = nil, limit: Int = 30) async throws -> (gifs: [Gif], nextCursor: Int?) {
        let cleanSub = subreddit
            .replacingOccurrences(of: "r/", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "/", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var comps = URLComponents(string: Config.redditBase + "posts/search")!
        var items = [
            URLQueryItem(name: "subreddit", value: cleanSub),
            URLQueryItem(name: "limit", value: "\(min(limit, 50))")
        ]
        if let before {
            items.append(URLQueryItem(name: "before", value: "\(before)"))
        }
        if let query, !query.trimmingCharacters(in: .whitespaces).isEmpty {
            items.append(URLQueryItem(name: "title", value: query.trimmingCharacters(in: .whitespaces)))
        }
        comps.queryItems = items
        guard let url = comps.url else { throw APIError.badURL }

        let (data, resp) = try await session.data(from: url)
        try check(resp)

        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["data"] as? [[String: Any]] else {
            return ([], nil)
        }

        var oldestTimestamp: Int? = nil
        var parsed: [Gif] = []
        var unresolvedRedGifs: [(index: Int, rgID: String, post: [String: Any])] = []

        for row in rows {
            if let created = row["created_utc"] as? Int {
                if oldestTimestamp == nil || created < oldestTimestamp! {
                    oldestTimestamp = created
                }
            }
            guard let id = row["id"] as? String else { continue }
            let title = (row["title"] as? String) ?? ""
            if title.lowercased().contains("[ removed") || title.lowercased().contains("[deleted]") { continue }

            let author = (row["author"] as? String) ?? "redditor"
            let sub = (row["subreddit"] as? String) ?? cleanSub
            let score = (row["score"] as? Int) ?? 1
            let created = (row["created_utc"] as? Int) ?? 0
            let rawURL = ((row["url"] as? String) ?? "").replacingOccurrences(of: "&amp;", with: "&")
            let permalink = row["permalink"] as? String

            var videoMP4: String? = nil
            var poster: String? = nil
            var width: Int? = nil
            var height: Int? = nil
            var hasAudio = true

            if let media = row["media"] as? [String: Any],
               let rv = media["reddit_video"] as? [String: Any],
               let fb = rv["fallback_url"] as? String {
                videoMP4 = fb.replacingOccurrences(of: "&amp;", with: "&")
                width = rv["width"] as? Int
                height = rv["height"] as? Int
                hasAudio = (rv["has_audio"] as? Bool) ?? true
            }

            if let preview = row["preview"] as? [String: Any] {
                if videoMP4 == nil,
                   let rvp = preview["reddit_video_preview"] as? [String: Any],
                   let fb = rvp["fallback_url"] as? String {
                    videoMP4 = fb.replacingOccurrences(of: "&amp;", with: "&")
                    width = rvp["width"] as? Int
                    height = rvp["height"] as? Int
                    hasAudio = (rvp["has_audio"] as? Bool) ?? true
                }
                if let images = preview["images"] as? [[String: Any]],
                   let firstImg = images.first,
                   let source = firstImg["source"] as? [String: Any],
                   let srcURL = source["url"] as? String {
                    poster = srcURL.replacingOccurrences(of: "&amp;", with: "&")
                    if width == nil { width = source["width"] as? Int }
                    if height == nil { height = source["height"] as? Int }
                }
            }

            let lowerURL = rawURL.lowercased()
            if videoMP4 == nil && lowerURL.hasSuffix(".mp4") {
                videoMP4 = rawURL
            }

            let isDirectImage = lowerURL.hasSuffix(".jpg") || lowerURL.hasSuffix(".jpeg") || lowerURL.hasSuffix(".png") || lowerURL.hasSuffix(".gif") || lowerURL.contains("i.redd.it/") || lowerURL.contains("i.imgur.com/")

            if let videoMP4 {
                let g = Gif(
                    id: "reddit_\(id)",
                    createDate: created,
                    duration: 15,
                    hasAudio: hasAudio,
                    width: width,
                    height: height,
                    likes: score,
                    views: max(score * 14, 120),
                    niches: [sub],
                    tags: [sub],
                    type: 1,
                    urls: Gif.Urls(sd: videoMP4, hd: videoMP4, poster: poster, thumbnail: poster),
                    userName: author,
                    verified: false,
                    description: title,
                    subreddit: sub,
                    redditPermalink: permalink
                )
                parsed.append(g)
            } else if lowerURL.contains("redgifs.com/watch/") || lowerURL.contains("redgifs.com/ifr/") {
                if let rgID = rawURL.components(separatedBy: "/").last?.components(separatedBy: "?").first, !rgID.isEmpty {
                    let placeholder = Gif(
                        id: "reddit_\(id)",
                        createDate: created,
                        likes: score,
                        views: max(score * 14, 120),
                        tags: [sub],
                        type: 1,
                        urls: Gif.Urls(poster: poster, thumbnail: poster),
                        userName: author,
                        description: title,
                        subreddit: sub,
                        redditPermalink: permalink
                    )
                    unresolvedRedGifs.append((parsed.count, rgID, row))
                    parsed.append(placeholder)
                }
            } else if isDirectImage && !lowerURL.contains("/gallery/") {
                let imgURL = rawURL
                let g = Gif(
                    id: "reddit_\(id)",
                    createDate: created,
                    duration: nil,
                    hasAudio: false,
                    width: width,
                    height: height,
                    likes: score,
                    views: max(score * 12, 80),
                    niches: [sub],
                    tags: [sub],
                    type: 2,
                    urls: Gif.Urls(sd: imgURL, hd: imgURL, poster: poster ?? imgURL, thumbnail: poster ?? imgURL),
                    userName: author,
                    verified: false,
                    description: title,
                    subreddit: sub,
                    redditPermalink: permalink
                )
                parsed.append(g)
            }
        }

        // Resolve up to 8 embedded RedGIFs links in parallel so they play natively with audio
        if !unresolvedRedGifs.isEmpty {
            let slice = Array(unresolvedRedGifs.prefix(8))
            let resolved = await withTaskGroup(of: (Int, Gif?).self) { group -> [(Int, Gif?)] in
                for item in slice {
                    group.addTask {
                        let g = try? await RedGifsAPI.shared.gifByID(item.rgID)
                        return (item.index, g)
                    }
                }
                var out: [(Int, Gif?)] = []
                for await pair in group { out.append(pair) }
                return out
            }
            for (idx, rg) in resolved {
                if let rg {
                    var merged = parsed[idx]
                    merged.urls = rg.urls
                    merged.duration = rg.duration
                    merged.hasAudio = rg.hasAudio
                    merged.width = rg.width
                    merged.height = rg.height
                    parsed[idx] = merged
                }
            }
        }

        // Keep only playable video or valid image items
        let valid = parsed.filter { $0.videoURL(hd: true) != nil || ($0.isImage && $0.imageURL != nil) }
        let nextCursor = oldestTimestamp.map { $0 - 1 }
        return (valid, nextCursor)
    }

    static let popularNSFWSubreddits: [SubredditInfo] = [
        SubredditInfo(display_name: "gonewild", title: "GoneWild", subscribers: 4_850_000, public_description: "Amateur 18+ community", over18: true),
        SubredditInfo(display_name: "RealGirls", title: "RealGirls", subscribers: 6_100_000, public_description: "Real amateur girls", over18: true),
        SubredditInfo(display_name: "NSFW_GIF", title: "NSFW GIFs", subscribers: 3_086_000, public_description: "Top NSFW videos & GIFs", over18: true),
        SubredditInfo(display_name: "nsfwhardcore", title: "NSFW Hardcore", subscribers: 2_759_000, public_description: "Hardcore clips", over18: true),
        SubredditInfo(display_name: "BustyPetite", title: "Busty Petite", subscribers: 2_420_000, public_description: "Busty & petite", over18: true),
        SubredditInfo(display_name: "nsfwcosplay", title: "NSFW Cosplay", subscribers: 1_488_000, public_description: "18+ cosplay & outfits", over18: true),
        SubredditInfo(display_name: "PetiteGoneWild", title: "Petite GoneWild", subscribers: 2_190_000, public_description: "Petite amateur creators", over18: true),
        SubredditInfo(display_name: "pawg", title: "PAWG", subscribers: 2_310_000, public_description: "Curves & booty", over18: true),
        SubredditInfo(display_name: "milf", title: "MILF", subscribers: 2_640_000, public_description: "Mature & MILF", over18: true),
        SubredditInfo(display_name: "hentai", title: "Hentai", subscribers: 3_400_000, public_description: "2D & 3D animation", over18: true),
        SubredditInfo(display_name: "lesbians", title: "Lesbians", subscribers: 1_890_000, public_description: "Girl on girl", over18: true),
        SubredditInfo(display_name: "bigtiddygothgf", title: "Big Tiddy Goth GF", subscribers: 1_650_000, public_description: "Alt & goth", over18: true)
    ]
}
