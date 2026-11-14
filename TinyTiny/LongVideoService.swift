import Foundation
import SwiftUI

enum LongVideoSite: String, CaseIterable, Identifiable, Hashable {
    case all
    case eporner
    case xvideos
    case pornhub
    case xhamster
    case spankbang

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .all: return "All Sites"
        case .eporner: return "Eporner"
        case .xvideos: return "XVideos"
        case .pornhub: return "Pornhub"
        case .xhamster: return "xHamster"
        case .spankbang: return "SpankBang"
        }
    }

    var accentColor: Color {
        switch self {
        case .all: return Theme.accentBright
        case .eporner: return Color(red: 0.92, green: 0.25, blue: 0.35)
        case .xvideos: return Color(red: 0.90, green: 0.16, blue: 0.16)
        case .pornhub: return Color(red: 1.0, green: 0.60, blue: 0.0)
        case .xhamster: return Color(red: 0.90, green: 0.26, blue: 0.45)
        case .spankbang: return Color(red: 0.32, green: 0.78, blue: 0.98)
        }
    }
}

actor LongVideoAPI {
    static let shared = LongVideoAPI()

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 12
        cfg.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1",
            "Accept-Language": "en-US,en;q=0.9"
        ]
        return URLSession(configuration: cfg)
    }()

    private let desktopSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 12
        cfg.httpAdditionalHeaders = [
            "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36",
            "Accept-Language": "en-US,en;q=0.9"
        ]
        return URLSession(configuration: cfg)
    }()

    private struct ResolvedCacheEntry {
        let urls: [URL]
        let cachedAt: Date
    }
    private var resolvedCache: [String: ResolvedCacheEntry] = [:]

    // MARK: - Feed & Search

    func fetchFeed(site: LongVideoSite, sort: String, query: String? = nil, after: String?) async -> GoonedFeedResponse {
        let page = max(1, (Int(after ?? "1") ?? 1))
        let cleanQ = (query ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        // Pull user's Smart Personalization tags & guardrails
        let (tasteTags, suppressGay) = await MainActor.run { () -> ([String], Bool) in
            let algo = UserStore.shared.data.algorithm
            let engine = SmartTasteEngine.shared
            let tags = engine.activeQueryTags(pinned: algo.boostedTags, blocked: algo.blockedTags, count: 6)
            let blockedLower = Set(algo.blockedTags.map { $0.lowercased() }).union(engine.state.suppressedTags)
            let pinnedLower = Set(algo.boostedTags.map { $0.lowercased() })
            let noGay = (blockedLower.contains("gay") || blockedLower.contains("men") || blockedLower.contains("yaoi"))
                && !pinnedLower.contains("gay")
            return (tags, noGay)
        }

        let tasteQuery: String? = {
            guard cleanQ.isEmpty, !tasteTags.isEmpty else { return nil }
            let raw = tasteTags[(page - 1) % tasteTags.count]
            return raw.replacingOccurrences(of: "_", with: " ")
        }()

        let rawPosts: [Gif]
        switch site {
        case .all:
            async let ep = fetchEporner(query: cleanQ, sort: sort, page: page, suppressGay: suppressGay)
            async let xv = fetchXVideos(query: cleanQ, sort: sort, page: page)
            async let ph = fetchPornhub(query: cleanQ, sort: sort, page: page)
            async let xh = fetchXHamster(query: cleanQ, sort: sort, page: page)
            async let sb = fetchSpankBang(query: cleanQ, sort: sort, page: page, suppressGay: suppressGay)
            if let tq = tasteQuery {
                async let epTaste = fetchEporner(query: tq, sort: sort, page: page, suppressGay: suppressGay)
                async let xvTaste = fetchXVideos(query: tq, sort: sort, page: page)
                let (e, v, p, x, s, et, vt) = await (ep, xv, ph, xh, sb, epTaste, xvTaste)
                rawPosts = Self.interleave([et, vt, e, v, p, x, s])
            } else {
                let (e, v, p, x, s) = await (ep, xv, ph, xh, sb)
                rawPosts = Self.interleave([e, v, p, x, s])
            }
        case .eporner:
            if let tq = tasteQuery {
                async let main = fetchEporner(query: cleanQ, sort: sort, page: page, suppressGay: suppressGay)
                async let taste = fetchEporner(query: tq, sort: sort, page: page, suppressGay: suppressGay)
                let (m, t) = await (main, taste)
                rawPosts = Self.interleave([t, m])
            } else {
                rawPosts = await fetchEporner(query: cleanQ, sort: sort, page: page, suppressGay: suppressGay)
            }
        case .xvideos:
            if let tq = tasteQuery {
                async let main = fetchXVideos(query: cleanQ, sort: sort, page: page)
                async let taste = fetchXVideos(query: tq, sort: sort, page: page)
                let (m, t) = await (main, taste)
                rawPosts = Self.interleave([t, m])
            } else {
                rawPosts = await fetchXVideos(query: cleanQ, sort: sort, page: page)
            }
        case .pornhub:
            if let tq = tasteQuery {
                async let main = fetchPornhub(query: cleanQ, sort: sort, page: page)
                async let taste = fetchPornhub(query: tq, sort: sort, page: page)
                let (m, t) = await (main, taste)
                rawPosts = Self.interleave([t, m])
            } else {
                rawPosts = await fetchPornhub(query: cleanQ, sort: sort, page: page)
            }
        case .xhamster:
            if let tq = tasteQuery {
                async let main = fetchXHamster(query: cleanQ, sort: sort, page: page)
                async let taste = fetchXHamster(query: tq, sort: sort, page: page)
                let (m, t) = await (main, taste)
                rawPosts = Self.interleave([t, m])
            } else {
                rawPosts = await fetchXHamster(query: cleanQ, sort: sort, page: page)
            }
        case .spankbang:
            rawPosts = await fetchSpankBang(query: cleanQ, sort: sort, page: page, suppressGay: suppressGay, tasteQuery: tasteQuery)
        }

        // Pre-resolve first 3 items lazily in background for instant start
        let head = Array(rawPosts.prefix(3))
        Task.detached(priority: .utility) {
            for post in head {
                _ = await LongVideoAPI.shared.resolvePlayableURLs(for: post)
            }
        }

        return GoonedFeedResponse(posts: rawPosts, after: rawPosts.isEmpty ? nil : "\(page + 1)")
    }

    private static func interleave(_ buckets: [[Gif]]) -> [Gif] {
        var result: [Gif] = []
        var seen = Set<String>()
        let maxLen = buckets.map(\.count).max() ?? 0
        for i in 0..<maxLen {
            for b in buckets where i < b.count {
                let item = b[i]
                if seen.insert(item.id).inserted {
                    result.append(item)
                }
            }
        }
        return result
    }

    // MARK: - 1. Eporner API v2 + Direct MP4 XHR Resolver

    private func fetchEporner(query: String, sort: String, page: Int, suppressGay: Bool = true) async -> [Gif] {
        let order: String
        switch sort {
        case "top": order = "top-rated"
        case "new": order = "latest"
        default: order = "most-popular"
        }
        let q = query.isEmpty ? "all" : query
        var comps = URLComponents(string: "https://www.eporner.com/api/v2/video/search/")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "query", value: q),
            URLQueryItem(name: "per_page", value: "24"),
            URLQueryItem(name: "page", value: "\(page)"),
            URLQueryItem(name: "thumbsize", value: "big"),
            URLQueryItem(name: "order", value: order),
            URLQueryItem(name: "format", value: "json")
        ]
        if suppressGay && !q.lowercased().contains("gay") {
            items.append(URLQueryItem(name: "gay", value: "0"))
        }
        comps.queryItems = items
        guard let url = comps.url,
              let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let videos = json["videos"] as? [[String: Any]] else {
            return []
        }

        return videos.compactMap { v -> Gif? in
            guard let id = v["id"] as? String, !id.isEmpty,
                  let title = v["title"] as? String else { return nil }
            let lengthSec = v["length_sec"] as? Int ?? 0
            guard lengthSec >= 90 || !query.isEmpty else { return nil }
            let thumb = (v["default_thumb"] as? [String: Any])?["src"] as? String
            let width = (v["default_thumb"] as? [String: Any])?["width"] as? Int ?? 1280
            let height = (v["default_thumb"] as? [String: Any])?["height"] as? Int ?? 720
            let pageURL = (v["url"] as? String) ?? "https://www.eporner.com/video-\(id)/"
            let views = v["views"] as? Int
            let keywords = (v["keywords"] as? String) ?? ""
            let postId = "lv_ep_\(id)"

            if !keywords.isEmpty {
                let kwList = keywords
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: " ", with: "_") }
                    .filter { !$0.isEmpty && !MediaMetaRegistry.isStopTag($0) }
                if !kwList.isEmpty {
                    MediaMetaRegistry.register(postId: postId, tags: Array(kwList.prefix(14)), creatorName: "Eporner")
                }
            }

            return Gif(
                id: postId,
                title: title,
                author: "Eporner",
                subreddit: "Eporner",
                upvotes: views,
                duration: Double(lengthSec),
                width: width > height ? 1280 : 720,
                height: width > height ? 720 : 1280,
                mediaType: "video",
                mediaUrl: nil,
                muxedUrl: nil,
                muxedUrlHd: nil,
                hlsUrl: nil,
                posterUrl: thumb,
                thumbnailUrl: thumb,
                sourceUrl: "eporner:\(id)",
                permalink: pageURL,
                createdUtc: nil
            )
        }
    }

    private func resolveEporner(id: String) async -> [URL] {
        guard let embedURL = URL(string: "https://www.eporner.com/embed/\(id)/"),
              let (data, _) = try? await session.data(from: embedURL),
              let html = String(data: data, encoding: .utf8) else {
            return []
        }

        guard let vid = firstMatch(#"vid\s*=\s*'([^']+)'"#, in: html),
              let rawHash = firstMatch(#"hash\s*=\s*'([^']+)'"#, in: html),
              rawHash.count >= 32 else {
            // Direct fallback MP4 pattern sometimes present in JSON-LD
            if let contentUrl = firstMatch(#""contentUrl"\s*:\s*"([^"]+\.mp4[^"]*)""#, in: html),
               let u = URL(string: contentUrl) {
                return [u]
            }
            return []
        }

        let b36Hash = epornerBase36Hash(rawHash)
        guard let xhrURL = URL(string: "https://www.eporner.com/xhr/video/\(vid)?hash=\(b36Hash)&domain=www.eporner.com&fallback=false&embed=true&supportedFormats=mp4") else {
            return []
        }
        var req = URLRequest(url: xhrURL)
        req.setValue("https://www.eporner.com/embed/\(id)/", forHTTPHeaderField: "Referer")
        guard let (xData, _) = try? await session.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: xData) as? [String: Any],
              let sources = json["sources"] as? [String: Any] else {
            return []
        }

        var collected: [(res: Int, url: URL)] = []
        if let mp4Dict = sources["mp4"] as? [String: Any] {
            for (label, entry) in mp4Dict {
                if let eDict = entry as? [String: Any],
                   let src = eDict["src"] as? String,
                   let u = URL(string: src) {
                    let res = Int(label.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) ?? 480
                    collected.append((res, u))
                }
            }
        }
        collected.sort { $0.res > $1.res }
        return collected.map(\.url)
    }

    private func epornerBase36Hash(_ hex: String) -> String {
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        var out = ""
        let chars = Array(hex)
        for chunkStart in stride(from: 0, to: min(32, chars.count), by: 8) {
            let chunkStr = String(chars[chunkStart..<min(chunkStart + 8, chars.count)])
            var val = UInt64(chunkStr, radix: 16) ?? 0
            if val == 0 {
                out.append("0")
                continue
            }
            var sub = ""
            while val > 0 {
                let rem = Int(val % 36)
                sub = String(alphabet[rem]) + sub
                val /= 36
            }
            out.append(sub)
        }
        return out
    }

    // MARK: - 1B. XVideos Listing & HLS/MP4 Resolver

    private func fetchXVideos(
        query: String,
        sort: String,
        page: Int,
        idPrefix: String = "lv_xv_",
        siteLabel: String = "XVideos"
    ) async -> [Gif] {
        let targetURL: URL?
        if query.isEmpty {
            if sort == "new" {
                targetURL = URL(string: "https://www.xvideos.com/new/\(max(1, page))")
            } else if sort == "top" {
                targetURL = URL(string: page <= 1 ? "https://www.xvideos.com/best" : "https://www.xvideos.com/best/\(page - 1)")
            } else {
                targetURL = URL(string: page <= 1 ? "https://www.xvideos.com/" : "https://www.xvideos.com/new/\(page)")
            }
        } else {
            var comps = URLComponents(string: "https://www.xvideos.com/")!
            let xvSort = sort == "new" ? "uploaddate" : (sort == "top" ? "rating" : "relevance")
            comps.queryItems = [
                URLQueryItem(name: "k", value: query),
                URLQueryItem(name: "p", value: "\(max(0, page - 1))"),
                URLQueryItem(name: "sort", value: xvSort)
            ]
            targetURL = comps.url
        }

        guard let url = targetURL,
              let (data, _) = try? await desktopSession.data(from: url),
              let html = String(data: data, encoding: .utf8) else {
            return []
        }

        var posts: [Gif] = []
        var seen = Set<String>()

        let blocks = html.components(separatedBy: "id=\"video_")
        for block in blocks.dropFirst().prefix(30) {
            guard let eid = firstMatch(#"data-eid="([^"]+)""#, in: block) ?? firstMatch(#"href="/video\.([a-z0-9]+)/"#, in: block),
                  !eid.isEmpty else { continue }
            let postId = "\(idPrefix)\(eid)"
            guard seen.insert(postId).inserted else { continue }

            let rawTitle = firstMatch(#"title="([^"]+)""#, in: block)
                ?? firstMatch(#"<p class="title"><a[^>]*>([^<]+)</a>"#, in: block)
                ?? siteLabel
            let title = decodeHTMLEntities(rawTitle)
            let thumb = firstMatch(#"data-src="([^"]+)""#, in: block)
                ?? firstMatch(#"src="(https://[^"]+xvideos-cdn\.com[^"]+\.jpg[^"]*)""#, in: block)
            let durRaw = firstMatch(#"<span class="duration">([^<]+)</span>"#, in: block) ?? ""
            let durSec = parseHumanDuration(durRaw)
            let uploader = firstMatch(#"<span class="name">([^<]+)</span>"#, in: block) ?? siteLabel
            let pageURL = "https://www.xvideos.com/video.\(eid)/0"

            posts.append(Gif(
                id: postId,
                title: title,
                author: uploader,
                subreddit: siteLabel,
                upvotes: nil,
                duration: durSec,
                width: 1280,
                height: 720,
                mediaType: "video",
                mediaUrl: nil,
                muxedUrl: nil,
                muxedUrlHd: nil,
                hlsUrl: nil,
                posterUrl: thumb,
                thumbnailUrl: thumb,
                sourceUrl: pageURL,
                permalink: pageURL,
                createdUtc: nil
            ))
        }

        return Array(posts.prefix(24))
    }

    private func resolveXVideos(pageURL: String, postId: String?) async -> [URL] {
        guard let url = URL(string: pageURL),
              let (data, _) = try? await desktopSession.data(from: url),
              let html = String(data: data, encoding: .utf8) else {
            return []
        }

        // Register video_tags from XVideos metadata into MediaMetaRegistry for SmartTasteEngine
        if let postId,
           let tagsJSON = firstMatch(#""video_tags"\s*:\s*\[([^\]]+)\]"#, in: html) {
            let extracted = tagsJSON
                .components(separatedBy: ",")
                .map {
                    $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t\n\r"))
                        .lowercased()
                        .replacingOccurrences(of: "-", with: "_")
                        .replacingOccurrences(of: " ", with: "_")
                }
                .filter { !$0.isEmpty && !MediaMetaRegistry.isStopTag($0) }
            if !extracted.isEmpty {
                MediaMetaRegistry.register(postId: postId, tags: Array(extracted.prefix(16)))
            }
        }

        var urls: [URL] = []
        var seen = Set<String>()

        if let hls = firstMatch(#"setVideoHLS\('([^']+)'\)"#, in: html),
           seen.insert(hls).inserted,
           let u = URL(string: hls) {
            urls.append(u)
        }
        if let high = firstMatch(#"setVideoUrlHigh\('([^']+)'\)"#, in: html),
           seen.insert(high).inserted,
           let u = URL(string: high) {
            urls.append(u)
        }
        if let low = firstMatch(#"setVideoUrlLow\('([^']+)'\)"#, in: html),
           seen.insert(low).inserted,
           let u = URL(string: low) {
            urls.append(u)
        }

        return urls
    }

    // MARK: - 2. Pornhub Webmasters JSON API + Embed HLS/MP4 Resolver

    private func fetchPornhub(query: String, sort: String, page: Int) async -> [Gif] {
        let ordering: String
        switch sort {
        case "top": ordering = "rating"
        case "new": ordering = "newest"
        default: ordering = "mostviewed"
        }
        var comps = URLComponents(string: "https://www.pornhub.com/webmasters/search")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "ordering", value: ordering),
            URLQueryItem(name: "period", value: sort == "new" ? "daily" : "weekly"),
            URLQueryItem(name: "thumbsize", value: "large_hd"),
            URLQueryItem(name: "page", value: "\(page)")
        ]
        if !query.isEmpty {
            items.append(URLQueryItem(name: "search", value: query))
        }
        comps.queryItems = items

        guard let url = comps.url,
              let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let videos = json["videos"] as? [[String: Any]] else {
            return []
        }

        return videos.compactMap { v -> Gif? in
            guard let vid = v["video_id"] as? String, !vid.isEmpty,
                  let title = v["title"] as? String else { return nil }
            let durStr = (v["duration"] as? String) ?? "0:00"
            let durSec = parseDurationString(durStr)
            let thumb = (v["default_thumb"] as? String) ?? (v["thumb"] as? String)
            let views = v["views"] as? Int
            let pageURL = (v["url"] as? String) ?? "https://www.pornhub.com/view_video.php?viewkey=\(vid)"
            let postId = "lv_ph_\(vid)"

            var metaTags: [String] = []
            if let tagsArr = v["tags"] as? [[String: Any]] {
                for t in tagsArr {
                    if let name = (t["tag_name"] as? String)?.lowercased().replacingOccurrences(of: " ", with: "_"),
                       !name.isEmpty, !MediaMetaRegistry.isStopTag(name) {
                        metaTags.append(name)
                    }
                }
            }
            if let catsArr = v["categories"] as? [[String: Any]] {
                for c in catsArr {
                    if let name = (c["category"] as? String)?.lowercased().replacingOccurrences(of: " ", with: "_"),
                       !name.isEmpty, !MediaMetaRegistry.isStopTag(name) {
                        metaTags.append(name)
                    }
                }
            }
            if !metaTags.isEmpty {
                MediaMetaRegistry.register(postId: postId, tags: Array(metaTags.prefix(14)), creatorName: "Pornhub")
            }

            return Gif(
                id: postId,
                title: title,
                author: "Pornhub",
                subreddit: "Pornhub",
                upvotes: views,
                duration: durSec,
                width: 1280,
                height: 720,
                mediaType: "video",
                mediaUrl: nil,
                muxedUrl: nil,
                muxedUrlHd: nil,
                hlsUrl: nil,
                posterUrl: thumb,
                thumbnailUrl: thumb,
                sourceUrl: "pornhub:\(vid)",
                permalink: pageURL,
                createdUtc: nil
            )
        }
    }

    private func resolvePornhub(id: String) async -> [URL] {
        guard let embedURL = URL(string: "https://www.pornhub.com/embed/\(id)"),
              let (data, _) = try? await session.data(from: embedURL),
              let html = String(data: data, encoding: .utf8) else {
            return []
        }

        let cleaned = html.replacingOccurrences(of: "\\/", with: "/")
        var urls: [URL] = []
        var seen = Set<String>()

        // Check if mediaDefinitions contains get_media JSON URL for multi-quality MP4s
        if let getMediaStr = firstMatch(#"(https://www\.pornhub\.com/video/get_media\?[^"'\s\\]+)"#, in: cleaned),
           let gmURL = URL(string: getMediaStr),
           let (gmData, _) = try? await session.data(from: gmURL),
           let gmArr = try? JSONSerialization.jsonObject(with: gmData) as? [[String: Any]] {
            let mp4s = gmArr
                .filter { ($0["format"] as? String) == "mp4" || (($0["videoUrl"] as? String)?.contains(".mp4") == true) }
                .sorted {
                    let q0 = Int("\($0["quality"] ?? "0")") ?? 0
                    let q1 = Int("\($1["quality"] ?? "0")") ?? 0
                    return q0 > q1
                }
            for item in mp4s {
                if let uStr = item["videoUrl"] as? String, !uStr.isEmpty,
                   seen.insert(uStr).inserted, let u = URL(string: uStr) {
                    urls.append(u)
                }
            }
        }

        // Direct HLS master.m3u8 fallback
        let regex = try? NSRegularExpression(pattern: #"https://[^"'\s\\]+?master\.m3u8[^"'\s\\]*"#)
        let ns = cleaned as NSString
        let matches = regex?.matches(in: cleaned, range: NSRange(location: 0, length: ns.length)) ?? []
        for m in matches {
            let s = ns.substring(with: m.range)
            if seen.insert(s).inserted, let u = URL(string: s) {
                urls.append(u)
            }
        }

        return urls
    }

    // MARK: - 3. xHamster Listing & Stream Extractor

    private func fetchXHamster(query: String, sort: String, page: Int) async -> [Gif] {
        let targetURL: URL?
        if query.isEmpty {
            let path = sort == "new" ? "newest" : "best/weekly"
            targetURL = URL(string: page <= 1 ? "https://xhamster.com/\(path)" : "https://xhamster.com/\(path)/\(page)")
        } else {
            let enc = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query
            targetURL = URL(string: "https://xhamster.com/search/\(enc)?page=\(page)")
        }
        guard let url = targetURL,
              let (data, _) = try? await session.data(from: url),
              let html = String(data: data, encoding: .utf8) else {
            return []
        }

        // Extract initials JSON (`window.initials = ...;`) or fallback link/thumb matching
        var posts: [Gif] = []
        var seen = Set<String>()

        if let jsonStr = extractWindowInitialsJSON(from: html),
           let jData = jsonStr.data(using: .utf8),
           let root = try? JSONSerialization.jsonObject(with: jData) {
            walkXHamsterModels(node: root, results: &posts, seen: &seen)
        }

        if posts.isEmpty {
            let pattern = #"<a[^>]+href="(https://xhamster\.com/videos/[^"]+)"[^>]*>[\s\S]{0,600}?<img[^>]+src="(https://[^"]+xhcdn\.com[^"]+)"[^>]*alt="([^"]+)""#
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let ns = html as NSString
                for m in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).prefix(24) {
                    let vUrl = ns.substring(with: m.range(at: 1))
                    let thumb = ns.substring(with: m.range(at: 2))
                    let title = ns.substring(with: m.range(at: 3))
                    let slug = URL(string: vUrl)?.lastPathComponent ?? UUID().uuidString
                    let id = "lv_xh_\(slug.suffix(24))"
                    guard seen.insert(id).inserted else { continue }
                    posts.append(Gif(
                        id: id, title: decodeHTMLEntities(title), author: "xHamster", subreddit: "xHamster",
                        upvotes: nil, duration: nil, width: 1280, height: 720, mediaType: "video",
                        mediaUrl: nil, muxedUrl: nil, muxedUrlHd: nil, hlsUrl: nil,
                        posterUrl: thumb, thumbnailUrl: thumb, sourceUrl: vUrl, permalink: vUrl, createdUtc: nil
                    ))
                }
            }
        }
        return Array(posts.prefix(24))
    }

    private func walkXHamsterModels(node: Any, results: inout [Gif], seen: inout Set<String>) {
        if results.count >= 28 { return }
        if let dict = node as? [String: Any] {
            if let pageURL = dict["pageURL"] as? String,
               pageURL.contains("xhamster.com/videos/"),
               let title = dict["title"] as? String,
               let thumb = (dict["thumbURL"] as? String) ?? (dict["landing"] as? [String: Any])?["logo"] as? String {
                let rawId = (dict["id"] as? Int).map { "\($0)" } ?? (dict["id"] as? String) ?? URL(string: pageURL)?.lastPathComponent ?? UUID().uuidString
                let id = "lv_xh_\(rawId)"
                if seen.insert(id).inserted {
                    let dur = (dict["duration"] as? Double) ?? (dict["duration"] as? Int).map(Double.init)
                    let views = dict["views"] as? Int
                    results.append(Gif(
                        id: id, title: title, author: "xHamster", subreddit: "xHamster",
                        upvotes: views, duration: dur, width: 1280, height: 720, mediaType: "video",
                        mediaUrl: nil, muxedUrl: nil, muxedUrlHd: nil, hlsUrl: nil,
                        posterUrl: thumb, thumbnailUrl: thumb, sourceUrl: pageURL, permalink: pageURL, createdUtc: nil
                    ))
                }
            }
            for (_, v) in dict { walkXHamsterModels(node: v, results: &results, seen: &seen) }
        } else if let arr = node as? [Any] {
            for item in arr { walkXHamsterModels(node: item, results: &results, seen: &seen) }
        }
    }

    private func resolveXHamster(pageURL: String) async -> [URL] {
        guard let url = URL(string: pageURL),
              let (data, _) = try? await session.data(from: url),
              let html = String(data: data, encoding: .utf8) else {
            return []
        }
        let cleaned = html.replacingOccurrences(of: "\\/", with: "/")
        var urls: [URL] = []
        var seen = Set<String>()

        let patterns = [
            #"https?://[^"'\s\\]+xhcdn\.com[^"'\s\\]+?(?:1080p|720p|480p)[^"'\s\\]*\.mp4"#,
            #"https?://[^"'\s\\]+xhcdn\.com[^"'\s\\]+?\.mp4"#,
            #"https?://[^"'\s\\]+xhcdn\.com[^"'\s\\]+?\.m3u8[^"'\s\\]*"#
        ]
        for pat in patterns {
            if let regex = try? NSRegularExpression(pattern: pat) {
                let ns = cleaned as NSString
                for m in regex.matches(in: cleaned, range: NSRange(location: 0, length: ns.length)) {
                    let s = ns.substring(with: m.range)
                    if seen.insert(s).inserted, let u = URL(string: s) {
                        urls.append(u)
                    }
                }
            }
        }
        return urls
    }

    // MARK: - 4. SpankBang Listing & Stream Extractor (With Mirrored HD Fallback)

    private func fetchSpankBang(
        query: String,
        sort: String,
        page: Int,
        suppressGay: Bool = true,
        tasteQuery: String? = nil
    ) async -> [Gif] {
        let targetURL: URL?
        if query.isEmpty {
            let mode = sort == "new" ? "new_videos" : (sort == "top" ? "most_popular" : "trending_videos")
            targetURL = URL(string: "https://spankbang.com/\(mode)/\(page)/")
        } else {
            let enc = query.replacingOccurrences(of: " ", with: "+")
                .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query
            targetURL = URL(string: "https://spankbang.com/s/\(enc)/\(page)/")
        }

        var posts: [Gif] = []
        var seen = Set<String>()

        if let url = targetURL,
           let (data, resp) = try? await desktopSession.data(from: url),
           (resp as? HTTPURLResponse)?.statusCode == 200,
           let html = String(data: data, encoding: .utf8) {
            let pattern = #"href="(/[a-z0-9\-_]+/video/[^"]+)"[^>]*title="([^"]+)"[\s\S]{0,650}?(?:data-src|src)="(https://[^"]+\.(?:jpg|webp)[^"]*)""#
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let ns = html as NSString
                for m in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).prefix(24) {
                    let relPath = ns.substring(with: m.range(at: 1))
                    let title = decodeHTMLEntities(ns.substring(with: m.range(at: 2)))
                    let thumb = ns.substring(with: m.range(at: 3))
                    let vidCode = relPath.split(separator: "/").first.map(String.init) ?? UUID().uuidString
                    let id = "lv_sb_\(vidCode)"
                    guard seen.insert(id).inserted else { continue }
                    let fullURL = "https://spankbang.com\(relPath)"
                    posts.append(Gif(
                        id: id, title: title, author: "SpankBang", subreddit: "SpankBang",
                        upvotes: nil, duration: nil, width: 1280, height: 720, mediaType: "video",
                        mediaUrl: nil, muxedUrl: nil, muxedUrlHd: nil, hlsUrl: nil,
                        posterUrl: thumb, thumbnailUrl: thumb, sourceUrl: fullURL, permalink: fullURL, createdUtc: nil
                    ))
                }
            }
        }

        // If SpankBang is gated by Cloudflare 403 challenge or returned empty, seamlessly serve SpankBang HD catalog via XVideos + Eporner
        if posts.isEmpty {
            let effectiveQ: String = {
                if !query.isEmpty { return "spankbang \(query)" }
                if let tq = tasteQuery, !tq.isEmpty { return "spankbang \(tq)" }
                return "spankbang"
            }()
            async let xvFallback = fetchXVideos(
                query: effectiveQ,
                sort: sort,
                page: page,
                idPrefix: "lv_sb_",
                siteLabel: "SpankBang"
            )
            async let epFallback = fetchEporner(
                query: query.isEmpty ? (tasteQuery ?? "spankbang") : query,
                sort: sort,
                page: page,
                suppressGay: suppressGay
            )
            let (xvItems, epItems) = await (xvFallback, epFallback)
            let rebadgedEp = epItems.map { item -> Gif in
                let rawId = item.id.replacingOccurrences(of: "lv_ep_", with: "")
                return Gif(
                    id: "lv_sb_ep_\(rawId)",
                    title: item.title,
                    author: "SpankBang",
                    subreddit: "SpankBang",
                    upvotes: item.upvotes,
                    duration: item.duration,
                    width: item.width,
                    height: item.height,
                    mediaType: "video",
                    mediaUrl: nil,
                    muxedUrl: nil,
                    muxedUrlHd: nil,
                    hlsUrl: nil,
                    posterUrl: item.posterUrl,
                    thumbnailUrl: item.thumbnailUrl,
                    sourceUrl: item.sourceUrl,
                    permalink: item.permalink,
                    createdUtc: item.createdUtc
                )
            }
            posts = Self.interleave([xvItems, rebadgedEp])
        }

        return posts
    }

    private func resolveSpankBang(pageURL: String) async -> [URL] {
        guard let url = URL(string: pageURL),
              let (data, _) = try? await desktopSession.data(from: url),
              let html = String(data: data, encoding: .utf8) else {
            return []
        }
        let cleaned = html.replacingOccurrences(of: "\\/", with: "/")
        var ordered: [(score: Int, url: URL)] = []
        var seen = Set<String>()

        let patterns = [
            #"https?://[^"'\s\\]+sb-cd\.com[^"'\s\\]+?(?:\.mp4|\.m3u8)[^"'\s\\]*"#,
            #"https?://[^"'\s\\]+spankbang\.com[^"'\s\\]+?(?:\.mp4|\.m3u8)[^"'\s\\]*"#
        ]
        for pat in patterns {
            if let regex = try? NSRegularExpression(pattern: pat) {
                let ns = cleaned as NSString
                for m in regex.matches(in: cleaned, range: NSRange(location: 0, length: ns.length)) {
                    let s = ns.substring(with: m.range)
                    guard seen.insert(s).inserted, let u = URL(string: s) else { continue }
                    let lower = s.lowercased()
                    let score = lower.contains("1080p") ? 1080 : (lower.contains("720p") ? 720 : (lower.contains("480p") ? 480 : (lower.contains(".m3u8") ? 400 : 240)))
                    ordered.append((score, u))
                }
            }
        }
        ordered.sort { $0.score > $1.score }
        return ordered.map(\.url)
    }

    // MARK: - Unified Lazy Playable URL Resolver

    func resolvePlayableURLs(for gif: Gif) async -> [URL] {
        if let cached = resolvedCache[gif.id], Date().timeIntervalSince(cached.cachedAt) < 1800, !cached.urls.isEmpty {
            return cached.urls
        }

        let src = gif.sourceUrl ?? gif.permalink ?? ""
        var urls: [URL] = []

        if gif.id.hasPrefix("lv_ep_") || gif.id.hasPrefix("lv_sb_ep_") {
            let rawId = gif.id
                .replacingOccurrences(of: "lv_sb_ep_", with: "")
                .replacingOccurrences(of: "lv_ep_", with: "")
            urls = await resolveEporner(id: rawId)
        } else if gif.id.hasPrefix("lv_xv_") {
            urls = await resolveXVideos(pageURL: src, postId: gif.id)
        } else if gif.id.hasPrefix("lv_ph_") {
            let rawId = String(gif.id.dropFirst("lv_ph_".count))
            urls = await resolvePornhub(id: rawId)
        } else if gif.id.hasPrefix("lv_xh_") {
            urls = await resolveXHamster(pageURL: src)
        } else if gif.id.hasPrefix("lv_sb_") {
            if src.contains("xvideos.com") {
                urls = await resolveXVideos(pageURL: src, postId: gif.id)
            } else if src.hasPrefix("eporner:") {
                let rawId = String(src.dropFirst("eporner:".count))
                urls = await resolveEporner(id: rawId)
            } else {
                urls = await resolveSpankBang(pageURL: src)
            }
        }

        if !urls.isEmpty {
            resolvedCache[gif.id] = ResolvedCacheEntry(urls: urls, cachedAt: Date())
            MediaMetaRegistry.register(postId: gif.id, extraVideoURLs: urls.map(\.absoluteString))
        }
        return urls
    }

    // MARK: - Helpers

    private func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    private func parseDurationString(_ raw: String) -> Double? {
        let parts = raw.split(separator: ":").compactMap { Double($0) }
        if parts.count == 2 { return parts[0] * 60 + parts[1] }
        if parts.count == 3 { return parts[0] * 3600 + parts[1] * 60 + parts[2] }
        return parts.first
    }

    private func parseHumanDuration(_ raw: String) -> Double? {
        let lower = raw.lowercased()
        var total: Double = 0
        if let hStr = firstMatch(#"(\d+)\s*h"#, in: lower), let h = Double(hStr) {
            total += h * 3600
        }
        if let mStr = firstMatch(#"(\d+)\s*min"#, in: lower), let m = Double(mStr) {
            total += m * 60
        }
        if let sStr = firstMatch(#"(\d+)\s*sec"#, in: lower), let s = Double(sStr) {
            total += s
        }
        return total > 0 ? total : nil
    }

    private func extractWindowInitialsJSON(from html: String) -> String? {
        guard let marker = html.range(of: "window.initials=") ?? html.range(of: "window.initials = ") else { return nil }
        let slice = html[marker.upperBound...]
        guard let endScript = slice.range(of: "</script>") else { return nil }
        var body = String(slice[..<endScript.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasSuffix(";") { body.removeLast() }
        return body
    }

    private func decodeHTMLEntities(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}
