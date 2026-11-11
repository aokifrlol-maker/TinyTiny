import Foundation

enum Config {
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    static let goonedBase = "https://api.gooned.app"
    static let origin = "https://gooned.app"
    static let referer = "https://gooned.app/"
}

struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

/// Exact post model returned by `api.gooned.app`.
struct Gif: Codable, Identifiable, Hashable {
    let id: String
    var title: String?
    var author: String?
    var subreddit: String?
    var upvotes: Int?
    var duration: Double?
    var width: Int?
    var height: Int?
    var mediaType: String? // "embed", "video", "gif", "image"
    var mediaUrl: String?
    var muxedUrl: String?
    var muxedUrlHd: String?
    var hlsUrl: String?
    var posterUrl: String?
    var thumbnailUrl: String?
    var sourceUrl: String?
    var permalink: String?
    var createdUtc: String?

    static func == (a: Gif, b: Gif) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    var isXPost: Bool {
        id.hasPrefix("x_") || (sourceUrl?.contains("x.com") == true) || (permalink?.contains("x.com") == true)
    }

    var isImage: Bool {
        if mediaType == "image" { return true }
        return videoURL(hd: true) == nil
    }

    var aspect: Double {
        guard let w = width, let h = height, w > 0, h > 0 else { return 9.0 / 16.0 }
        return Double(w) / Double(h)
    }

    func videoURL(hd: Bool) -> URL? {
        let candidates: [String?]
        if hd {
            candidates = [muxedUrlHd, muxedUrl, mediaUrl, hlsUrl]
        } else {
            candidates = [muxedUrl, muxedUrlHd, mediaUrl, hlsUrl]
        }
        for c in candidates {
            if let s = c, !s.isEmpty, mediaType != "image", let u = URL(string: s) {
                return u
            }
        }
        return nil
    }

    var imageURL: URL? {
        for c in [mediaUrl, posterUrl, thumbnailUrl, sourceUrl] {
            if let s = c, !s.isEmpty, let u = URL(string: s) { return u }
        }
        return nil
    }

    var posterURL: URL? {
        for c in [posterUrl, thumbnailUrl, mediaUrl] {
            if let s = c, !s.isEmpty, let u = URL(string: s) { return u }
        }
        return nil
    }

    var thumbURL: URL? {
        for c in [posterUrl, thumbnailUrl, mediaUrl] {
            if let s = c, !s.isEmpty, let u = URL(string: s) { return u }
        }
        return nil
    }

    var webURL: URL {
        if let p = permalink, let u = URL(string: p) { return u }
        if let s = sourceUrl, let u = URL(string: s) { return u }
        return URL(string: "https://gooned.app")!
    }

    var relativeTime: String {
        guard let createdUtc else { return "" }
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = fmt.date(from: createdUtc) ?? ISO8601DateFormatter().date(from: createdUtc)
        guard let date else { return "" }
        let delta = max(0, Int(Date().timeIntervalSince(date)))
        if delta < 3600 { return "\(max(1, delta / 60))m" }
        if delta < 86_400 { return "\(delta / 3600)h" }
        if delta < 2_592_000 { return "\(delta / 86_400)d" }
        if delta < 31_536_000 { return "\(delta / 2_592_000)mo" }
        return "\(delta / 31_536_000)y"
    }
}

struct GoonedFeedResponse: Decodable {
    var posts: [Gif]
    var after: String?

    enum CodingKeys: String, CodingKey { case posts, after }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        posts = ((try? c.decode([Lossy<Gif>].self, forKey: .posts)) ?? []).compactMap { $0.value }
        after = try? c.decode(String.self, forKey: .after)
    }
}

struct GoonedSearchItem: Codable, Identifiable, Hashable {
    var name: String
    var subscribers: Int?
    var iconUrl: String?
    var id: String { name.lowercased() }
}

struct GoonedSearchResponse: Decodable {
    var subreddits: [GoonedSearchItem]
    var users: [GoonedSearchItem]

    enum CodingKeys: String, CodingKey { case subreddits, users }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subreddits = ((try? c.decode([Lossy<GoonedSearchItem>].self, forKey: .subreddits)) ?? []).compactMap { $0.value }
        users = ((try? c.decode([Lossy<GoonedSearchItem>].self, forKey: .users)) ?? []).compactMap { $0.value }
    }
}

struct GoonedCategoriesResponse: Decodable {
    struct Entry: Decodable {
        var subreddits: [String]
        var subscribers: Int
    }
    var categories: [String: Entry]
}

func shortCount(_ n: Int?) -> String {
    guard let n else { return "0" }
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
    return "\(n)"
}
