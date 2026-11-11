import Foundation

enum Config {
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    static let apiBase = "https://api.redgifs.com/v2/"
}

/// Decodes an element, or nil if it fails, so one bad item doesn't break a whole page.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

struct Gif: Codable, Identifiable, Hashable {
    let id: String
    var createDate: Int? = nil
    var duration: Double? = nil
    var hasAudio: Bool? = nil
    var width: Int? = nil
    var height: Int? = nil
    var likes: Int? = nil
    var views: Int? = nil
    var niches: [String]? = nil
    var tags: [String]? = nil
    var type: Int? = nil
    var urls: Urls
    var userName: String? = nil
    var verified: Bool? = nil
    var description: String? = nil

    struct Urls: Codable, Hashable {
        var sd: String? = nil
        var hd: String? = nil
        var poster: String? = nil
        var thumbnail: String? = nil
        var silent: String? = nil
        var html: String? = nil
    }

    static func == (a: Gif, b: Gif) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    var isImage: Bool { type == 2 }
    var aspect: Double {
        guard let w = width, let h = height, w > 0, h > 0 else { return 9.0 / 16.0 }
        return Double(w) / Double(h)
    }
    var clampedFeedAspect: CGFloat {
        CGFloat(min(max(aspect, 0.72), 1.35))
    }
    func videoURL(hd: Bool) -> URL? {
        let s = hd ? (urls.hd ?? urls.sd) : (urls.sd ?? urls.hd)
        return URL(string: s ?? "")
    }
    var imageURL: URL? { URL(string: urls.hd ?? urls.poster ?? urls.thumbnail ?? "") }
    var posterURL: URL? { URL(string: urls.poster ?? urls.thumbnail ?? "") }
    var thumbURL: URL? { URL(string: urls.thumbnail ?? urls.poster ?? "") }
    var webURL: URL { URL(string: "https://www.redgifs.com/watch/\(id)")! }
    var allTags: [String] { tags ?? [] }
    var allNiches: [String] { niches ?? [] }

    /// Assigned deterministic predefined category (never dynamic or AI-created).
    var category: GoonedCategory {
        GoonedCategory.categorize(self)
    }

    var relativeTime: String {
        guard let ts = createDate, ts > 0 else { return "Recently" }
        let delta = max(0, Int(Date().timeIntervalSince1970) - ts)
        if delta < 3600 { return "\(max(1, delta / 60))m ago" }
        if delta < 86_400 { return "\(delta / 3600)h ago" }
        if delta < 2_592_000 { return "\(delta / 86_400)d ago" }
        return "\(delta / 2_592_000)mo ago"
    }
}

struct RGUser: Codable, Identifiable, Hashable {
    var username: String
    var name: String? = nil
    var description: String? = nil
    var followers: Int? = nil
    var gifs: Int? = nil
    var views: Int? = nil
    var profileImageUrl: String? = nil
    var verified: Bool? = nil
    var id: String { username }
}

struct GifPage: Decodable {
    var gifs: [Gif]
    var users: [RGUser]
    var page: Int
    var pages: Int

    enum CodingKeys: String, CodingKey { case gifs, users, page, pages }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gifs = ((try? c.decode([Lossy<Gif>].self, forKey: .gifs)) ?? []).compactMap { $0.value }
        users = ((try? c.decode([Lossy<RGUser>].self, forKey: .users)) ?? []).compactMap { $0.value }
        page = (try? c.decode(Int.self, forKey: .page)) ?? 1
        pages = (try? c.decode(Int.self, forKey: .pages)) ?? 1
    }
}

struct TagCount: Decodable, Hashable {
    var name: String
    var count: Int?
}

struct TagsResponse: Decodable {
    var tags: [TagCount]
}

struct Suggestion: Decodable, Hashable {
    var type: String?
    var text: String
    var gifs: Int?
}

func shortCount(_ n: Int?) -> String {
    guard let n else { return "0" }
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
    return "\(n)"
}
