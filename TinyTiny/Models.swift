import Foundation

enum Config {
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    static let apiBase = "https://api.redgifs.com/v2/"
    static let redditBase = "https://arctic-shift.photon-reddit.com/api/"
}

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
    var type: Int? = nil // 1 = video, 2 = image
    var urls: Urls
    var userName: String? = nil
    var verified: Bool? = nil
    var description: String? = nil
    var subreddit: String? = nil // non-nil when sourced from Reddit (e.g. "gonewild")
    var redditPermalink: String? = nil

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

    var isImage: Bool {
        if type == 2 { return true }
        return urls.hd == nil && urls.sd == nil
    }

    var isReddit: Bool { subreddit != nil }

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

    var webURL: URL {
        if let p = redditPermalink, let u = URL(string: "https://www.reddit.com\(p)") { return u }
        if let h = urls.html, let u = URL(string: h) { return u }
        return URL(string: "https://www.redgifs.com/watch/\(id)")!
    }

    var allTags: [String] { tags ?? [] }
    var allNiches: [String] { niches ?? [] }

    var category: GoonedCategory {
        GoonedCategory.categorize(self)
    }

    var relativeTime: String {
        guard let ts = createDate, ts > 0 else { return "" }
        let delta = max(0, Int(Date().timeIntervalSince1970) - ts)
        if delta < 3600 { return "\(max(1, delta / 60))m" }
        if delta < 86_400 { return "\(delta / 3600)h" }
        if delta < 2_592_000 { return "\(delta / 86_400)d" }
        return "\(delta / 2_592_000)mo"
    }
}

struct SingleGifResponse: Decodable {
    var gif: Gif
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

    init(gifs: [Gif], users: [RGUser] = [], page: Int = 1, pages: Int = 100) {
        self.gifs = gifs
        self.users = users
        self.page = page
        self.pages = pages
    }

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

// MARK: - 18+ Reddit Models

struct SubredditInfo: Codable, Identifiable, Hashable {
    var display_name: String
    var title: String?
    var subscribers: Int?
    var public_description: String?
    var over18: Bool?
    var community_icon: String?
    var icon_img: String?

    var id: String { display_name.lowercased() }

    var cleanIconURL: String? {
        let raw = (community_icon?.isEmpty == false ? community_icon : icon_img) ?? ""
        guard !raw.isEmpty else { return nil }
        return raw.replacingOccurrences(of: "&amp;", with: "&")
    }
}

struct SubredditSearchResponse: Decodable {
    var data: [Lossy<SubredditInfo>]
}

func shortCount(_ n: Int?) -> String {
    guard let n else { return "0" }
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
    return "\(n)"
}
