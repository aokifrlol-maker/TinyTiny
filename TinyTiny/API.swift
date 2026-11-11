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

/// Talks to RedGIFs' free public API using an anonymous temporary token.
actor RedGifsAPI {
    static let shared = RedGifsAPI()

    private var token: String?
    private var tokenDate = Date.distantPast

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.httpAdditionalHeaders = ["User-Agent": Config.userAgent, "Accept": "application/json"]
        cfg.timeoutIntervalForRequest = 20
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

    // MARK: Endpoints

    func trending(page: Int, count: Int = 30) async throws -> GifPage {
        try await get("gifs/search", ["order": "trending", "count": "\(count)", "page": "\(page)"])
    }

    /// order: "top" or "latest"
    func search(_ text: String, order: String = "top", page: Int, count: Int = 30) async throws -> GifPage {
        try await get("gifs/search", ["search_text": text, "order": order, "count": "\(count)", "page": "\(page)"])
    }

    /// order: nil (hot), "new" or "top"
    func niche(_ id: String, order: String? = nil, page: Int, count: Int = 30) async throws -> GifPage {
        var q = ["count": "\(count)", "page": "\(page)"]
        if let order { q["order"] = order }
        return try await get("niches/\(enc(id))/gifs", q)
    }

    func user(_ username: String, page: Int, count: Int = 30) async throws -> GifPage {
        try await get("users/\(enc(username))/search", ["order": "new", "count": "\(count)", "page": "\(page)"])
    }

    func niches(page: Int, count: Int = 40) async throws -> NichePage {
        try await get("niches", ["count": "\(count)", "page": "\(page)"])
    }

    func trendingTags() async throws -> TagsResponse {
        try await get("tags/trending")
    }

    func suggest(_ query: String) async throws -> [Suggestion] {
        try await get("search/suggest", ["query": query])
    }
}

