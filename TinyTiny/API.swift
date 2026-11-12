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

/// Direct client for `https://api.gooned.app` — exact same backend powering gooned.app.
actor GoonedAPI {
    static let shared = GoonedAPI()

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.httpAdditionalHeaders = [
            "User-Agent": Config.userAgent,
            "Accept": "application/json",
            "Origin": Config.origin,
            "Referer": Config.referer,
            "Cache-Control": "no-cache"
        ]
        cfg.timeoutIntervalForRequest = 18
        return URLSession(configuration: cfg)
    }()

    private func get<T: Decodable>(_ path: String, _ query: [String: String] = [:]) async throws -> T {
        guard var comps = URLComponents(string: Config.goonedBase + path) else { throw APIError.badURL }
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = comps.url else { throw APIError.badURL }
        let (data, resp) = try await session.data(from: url)
        if let h = resp as? HTTPURLResponse, !(200..<300).contains(h.statusCode) {
            throw APIError.http(h.statusCode)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }

    /// Generates a fresh random seed cursor `{"seed":"<random>","offset":0}` so `/reddit/foryou` rotates on every load instead of returning the static `foryou-ssr` cache.
    static func randomForYouCursor(offset: Int = 0) -> String {
        let seed = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(10))
        let json = #"{"seed":"\#(seed)","offset":\#(offset)}"#
        return Data(json.utf8).base64EncodedString()
    }

    /// Encodes a category exclusion cursor `{"categoryPool":{"from":null,"head":[...]}}` so `/reddit/category/{name}` excludes already-seen video IDs on the server.
    static func categoryExclusionCursor(seenIDs: [String]) -> String? {
        let clean = Array(seenIDs.filter { !$0.hasPrefix("x_") }.prefix(120))
        guard !clean.isEmpty else { return nil }
        let payload: [String: Any] = [
            "categoryPool": [
                "from": NSNull(),
                "head": clean
            ]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []) else { return nil }
        return data.base64EncodedString()
    }

    // MARK: - Feed Endpoints

    func forYou(sort: String = "hot", time: String = "all", after: String? = nil, limit: Int = 25) async throws -> GoonedFeedResponse {
        var q = ["sort": sort, "limit": "\(limit)"]
        if sort == "top" { q["t"] = time }
        if let after, !after.isEmpty {
            q["after"] = after
        } else {
            q["after"] = Self.randomForYouCursor(offset: 0)
        }
        return try await get("/reddit/foryou", q)
    }

    func category(
        _ name: String,
        sort: String = "hot",
        time: String = "all",
        after: String? = nil,
        excludedHead: [String] = [],
        limit: Int = 25
    ) async throws -> GoonedFeedResponse {
        var q = ["sort": sort, "limit": "\(limit)"]
        if sort == "top" { q["t"] = time }
        if let after, !after.isEmpty {
            q["after"] = after
        } else if let cursor = Self.categoryExclusionCursor(seenIDs: excludedHead) {
            q["after"] = cursor
        }
        return try await get("/reddit/category/\(enc(name))", q)
    }

    func subreddit(_ name: String, sort: String = "hot", time: String = "all", after: String? = nil, limit: Int = 25) async throws -> GoonedFeedResponse {
        let clean = name.replacingOccurrences(of: "r/", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "/", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var q = ["sort": sort, "limit": "\(limit)"]
        if sort == "top" { q["t"] = time }
        if let after, !after.isEmpty { q["after"] = after }
        return try await get("/reddit/subreddit/\(enc(clean))", q)
    }

    func user(_ username: String, sort: String = "hot", time: String = "all", after: String? = nil, limit: Int = 25) async throws -> GoonedFeedResponse {
        let clean = username.replacingOccurrences(of: "u/", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "@", with: "")
            .replacingOccurrences(of: "/", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var q = ["sort": sort, "limit": "\(limit)"]
        if sort == "top" { q["t"] = time }
        if let after, !after.isEmpty { q["after"] = after }
        return try await get("/reddit/user/\(enc(clean))", q)
    }

    func following(subreddits: [String], users: [String], after: String? = nil) async throws -> GoonedFeedResponse {
        var q: [String: String] = [:]
        if !subreddits.isEmpty { q["subreddits"] = subreddits.joined(separator: ",") }
        if !users.isEmpty { q["users"] = users.joined(separator: ",") }
        if let after, !after.isEmpty { q["after"] = after }
        return try await get("/reddit/following", q)
    }

    // MARK: - Search & Categories

    func search(_ query: String) async throws -> GoonedSearchResponse {
        let clean = query
            .replacingOccurrences(of: "r/", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "u/", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "@", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else {
            return try JSONDecoder().decode(GoonedSearchResponse.self, from: Data("{\"subreddits\":[],\"users\":[]}".utf8))
        }
        return try await get("/reddit/search", ["q": clean])
    }

    func categories() async throws -> [GoonedCategory] {
        let resp: GoonedCategoriesResponse = try await get("/reddit/categories")
        var list: [GoonedCategory] = []
        for (k, v) in resp.categories {
            list.append(GoonedCategory(name: k, subscribers: v.subscribers, subreddits: v.subreddits))
        }
        return list.isEmpty ? GoonedCategory.defaultCategories : list
    }
}
