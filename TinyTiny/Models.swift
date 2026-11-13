import Foundation

enum Config {
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
    static let goonedBase = "https://api.gooned.app"
    static let onlyHavenBase = "https://cum.st/api/v1"
    static let origin = "https://gooned.app"
    static let referer = "https://gooned.app/"
}

struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

/// Unified post model supporting `api.gooned.app`, Personal X.com, Personal Instagram, Rule34.xxx, and Offline Vault.
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

    /// Stable, query-stripped identifier so repeating posts across rotating CDN tokens,
    /// Instagram `_userId` suffixes, or cross-posted URLs are always deduplicated.
    var canonicalDedupeKey: String {
        if isIGPost {
            if let permalink,
               let url = URL(string: permalink),
               let code = url.pathComponents.last(where: { !$0.isEmpty && $0 != "reel" && $0 != "p" }),
               code.count >= 5 {
                return "ig_code_\(code)"
            }
            let raw = id.hasPrefix("ig_") ? String(id.dropFirst(3)) : id
            let base = raw.split(separator: "_").first.map(String.init) ?? raw
            return "ig_pk_\(base)"
        }
        let media = muxedUrlHd ?? muxedUrl ?? mediaUrl ?? posterUrl
        if let media, let u = URL(string: media), let host = u.host {
            let path = u.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !path.isEmpty {
                return "media_\(host.lowercased())/\(path)"
            }
        }
        return id.lowercased()
    }

    var isXPost: Bool {
        id.hasPrefix("x_") || (sourceUrl?.contains("x.com") == true) || (permalink?.contains("x.com") == true)
    }

    var isIGPost: Bool {
        id.hasPrefix("ig_") || (sourceUrl?.contains("instagram.com") == true) || (permalink?.contains("instagram.com") == true)
    }

    var isRule34Post: Bool {
        id.hasPrefix("r34") || (subreddit?.lowercased().contains("rule34") == true) || (sourceUrl?.contains("rule34.xxx") == true)
    }

    var isOnlyFansPost: Bool {
        id.hasPrefix("of_") || (sourceUrl?.contains("cum.st") == true) || (permalink?.contains("cum.st") == true)
    }

    /// Extracts OnlyFans creator external ID from `https://cum.st/creators/onlyfans/{creatorId}/...`
    var onlyFansCreatorId: String? {
        guard isOnlyFansPost else { return nil }
        let candidate = permalink ?? sourceUrl ?? ""
        guard let url = URL(string: candidate) else { return nil }
        let parts = url.pathComponents
        if let idx = parts.firstIndex(of: "onlyfans"), idx + 1 < parts.count {
            let cid = parts[idx + 1]
            if !cid.isEmpty && cid != "post" { return cid }
        }
        return nil
    }

    var isImage: Bool {
        if mediaType == "image" { return true }
        return remoteOrLocalVideoURLs(hd: true).isEmpty
    }

    var hasPlayableMedia: Bool {
        !remoteOrLocalVideoURLs(hd: true).isEmpty || imageURL != nil
    }

    private static func isPlayableVideoURLString(_ s: String) -> Bool {
        let lower = s.lowercased()
        if lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") || lower.hasSuffix(".png") || lower.hasSuffix(".webp") || lower.hasSuffix(".gif") {
            return false
        }
        if lower.contains("redgifs.com/watch/") || lower.contains("redgifs.com/ifr/") {
            return false
        }
        if lower.contains(".mp4") || lower.contains(".mov") || lower.contains(".m4v") || lower.contains(".m3u8") {
            return true
        }
        // Some CDN video URLs don't end in .mp4 (e.g. X/IG/Reddit v.redd.it without ext)
        return lower.contains("video.twimg.com") || lower.contains("v.redd.it") || lower.contains("cdninstagram.com") || lower.contains("fbcdn.net")
    }

    private static func isRenderableImageURLString(_ s: String) -> Bool {
        let lower = s.lowercased()
        if lower.contains(".mp4") || lower.contains(".mov") || lower.contains(".m4v") || lower.contains(".m3u8") {
            return false
        }
        if lower.contains("redgifs.com/watch/") || lower.contains("redgifs.com/ifr/") {
            return false
        }
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("file://")
    }

    /// Returns the actual width/height ratio only when real dimensions are known.
    var knownAspect: Double? {
        guard let w = width, let h = height, w > 0, h > 0 else { return nil }
        return Double(w) / Double(h)
    }

    var aspect: Double {
        knownAspect ?? 1.0
    }

    private func remoteOrLocalVideoURLs(hd: Bool) -> [URL] {
        guard mediaType != "image" else { return [] }
        var urls: [URL] = []
        // 1. Prefer offline local file if downloaded!
        if let local = OfflineManager.localMediaURL(forId: id),
           !["jpg", "jpeg", "png", "webp", "gif"].contains(local.pathExtension.lowercased()) {
            urls.append(local)
        }
        // 2. Remote stream candidates (validated so .gif/.jpg/HTML never enter AVPlayer)
        let candidates: [String?] = hd
            ? [muxedUrlHd, muxedUrl, mediaUrl, hlsUrl]
            : [muxedUrl, muxedUrlHd, mediaUrl, hlsUrl]
        var seen = Set<String>()
        for c in candidates {
            if let s = c, !s.isEmpty, Self.isPlayableVideoURLString(s), seen.insert(s).inserted, let u = URL(string: s) {
                urls.append(u)
            }
        }
        return urls
    }

    func allVideoURLs(hd: Bool) -> [URL] {
        remoteOrLocalVideoURLs(hd: hd)
    }

    func videoURL(hd: Bool) -> URL? {
        remoteOrLocalVideoURLs(hd: hd).first
    }

    var imageURL: URL? {
        imageFallbackURLs.first
    }

    var imageFallbackURLs: [URL] {
        var urls: [URL] = []
        var seen = Set<String>()
        if let local = OfflineManager.localMediaURL(forId: id), seen.insert(local.absoluteString).inserted {
            urls.append(local)
        }
        for c in [mediaUrl, posterUrl, thumbnailUrl] {
            if let s = c, !s.isEmpty, Self.isRenderableImageURLString(s),
               seen.insert(s).inserted, let u = URL(string: s) {
                urls.append(u)
            }
        }
        return urls
    }

    var posterURL: URL? {
        posterFallbackURLs.first
    }

    var posterFallbackURLs: [URL] {
        var urls: [URL] = []
        var seen = Set<String>()
        if let localThumb = OfflineManager.localThumbURL(forId: id), seen.insert(localThumb.absoluteString).inserted {
            urls.append(localThumb)
        }
        for c in [posterUrl, thumbnailUrl, mediaUrl] {
            if let s = c, !s.isEmpty, Self.isRenderableImageURLString(s),
               seen.insert(s).inserted, let u = URL(string: s) {
                urls.append(u)
            }
        }
        return urls
    }

    var thumbURL: URL? {
        if let localThumb = OfflineManager.localThumbURL(forId: id) {
            return localThumb
        }
        for c in [posterUrl, thumbnailUrl, mediaUrl] {
            if let s = c, !s.isEmpty, Self.isRenderableImageURLString(s), let u = URL(string: s) { return u }
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

    init(posts: [Gif], after: String?) {
        self.posts = posts
        self.after = after
    }

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
