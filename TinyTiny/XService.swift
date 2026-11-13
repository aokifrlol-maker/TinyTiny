import SwiftUI
import WebKit

// MARK: - X.com Session & Credentials

struct XAccountSession: Codable, Equatable {
    var authToken: String = ""
    var ct0: String = ""
    var userId: String = ""
    var screenName: String = ""
    var mixIntoForYou: Bool = true

    var isConnected: Bool {
        !authToken.isEmpty && !ct0.isEmpty
    }
}

// MARK: - Recursive X GraphQL / REST Video Tweet Parser

enum XTweetParser {
    /// Recursively walks any X GraphQL or REST JSON payload and extracts eligible adult video/GIF posts as `Gif` items.
    static func parseTweets(from data: Data, routeKey: String = "") -> [Gif] {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return []
        }
        var results: [Gif] = []
        var seen = Set<String>()
        walk(
            node: root,
            inheritedAuthor: nil,
            inheritedBio: nil,
            routeKey: routeKey,
            results: &results,
            seen: &seen
        )
        return results
    }

    /// Attempts to extract the logged-in user's `@screen_name` from a settings or viewer payload.
    static func parseScreenName(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] else {
            return nil
        }
        if let sn = obj["screen_name"] as? String, !sn.isEmpty {
            return sn
        }
        if let dataDict = obj["data"] as? [String: Any],
           let viewer = dataDict["viewer"] as? [String: Any],
           let userResult = (viewer["user_results"] as? [String: Any])?["result"] as? [String: Any] {
            if let core = userResult["core"] as? [String: Any], let sn = core["screen_name"] as? String, !sn.isEmpty {
                return sn
            }
            if let leg = userResult["legacy"] as? [String: Any], let sn = leg["screen_name"] as? String, !sn.isEmpty {
                return sn
            }
        }
        return nil
    }

    private static func walk(
        node: Any,
        inheritedAuthor: String?,
        inheritedBio: String?,
        routeKey: String,
        results: inout [Gif],
        seen: inout Set<String>
    ) {
        if let dict = node as? [String: Any] {
            // Skip promoted/ad timeline items
            if dict["promotedMetadata"] != nil || dict["promoted_metadata"] != nil {
                return
            }
            if let entryId = dict["entryId"] as? String,
               entryId.lowercased().contains("promoted") {
                return
            }

            let authorMeta = extractAuthorAndBio(from: dict)
            let currentAuthor = authorMeta.screenName ?? inheritedAuthor
            let currentBio = authorMeta.bio ?? inheritedBio

            // Check if this dictionary is a Tweet object with `legacy` or direct `extended_entities`
            if let gif = extractGif(
                fromTweetDict: dict,
                fallbackAuthor: currentAuthor,
                fallbackBio: currentBio,
                routeKey: routeKey
            ), seen.insert(gif.id).inserted {
                results.append(gif)
            }

            // Continue walking children
            for (key, value) in dict {
                if key == "promotedMetadata" { continue }
                walk(
                    node: value,
                    inheritedAuthor: currentAuthor,
                    inheritedBio: currentBio,
                    routeKey: routeKey,
                    results: &results,
                    seen: &seen
                )
            }
        } else if let array = node as? [Any] {
            for item in array {
                walk(
                    node: item,
                    inheritedAuthor: inheritedAuthor,
                    inheritedBio: inheritedBio,
                    routeKey: routeKey,
                    results: &results,
                    seen: &seen
                )
            }
        }
    }

    private static func extractAuthorAndBio(from dict: [String: Any]) -> (screenName: String?, bio: String?) {
        // GraphQL tweet -> core -> user_results -> result -> (core | legacy) -> (screen_name, description)
        if let core = dict["core"] as? [String: Any],
           let userResults = core["user_results"] as? [String: Any],
           let result = userResults["result"] as? [String: Any] {
            let innerCore = result["core"] as? [String: Any]
            let innerLegacy = result["legacy"] as? [String: Any]
            let sn = (innerCore?["screen_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (innerLegacy?["screen_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let bio = (innerLegacy?["description"] as? String)
                ?? (innerCore?["description"] as? String)
                ?? (result["description"] as? String)
            if sn != nil || bio != nil {
                return (sn, bio)
            }
        }
        // REST / v1.1 tweet -> user -> (screen_name, description)
        if let user = dict["user"] as? [String: Any] {
            let sn = (user["screen_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let bio = user["description"] as? String
            if sn != nil || bio != nil {
                return (sn, bio)
            }
        }
        return (nil, nil)
    }

    private static func extractGif(
        fromTweetDict dict: [String: Any],
        fallbackAuthor: String?,
        fallbackBio: String?,
        routeKey: String
    ) -> Gif? {
        // Avoid extracting twice from outer `retweeted_status_result` wrapper if inner `result` will be visited
        let legacy = (dict["legacy"] as? [String: Any]) ?? dict

        let extEntities = (legacy["extended_entities"] as? [String: Any])
            ?? (dict["extended_entities"] as? [String: Any])
            ?? (legacy["entities"] as? [String: Any])

        guard let mediaList = extEntities?["media"] as? [[String: Any]], !mediaList.isEmpty else {
            return nil
        }

        // Find the first video or animated_gif media attachment
        for media in mediaList {
            let type = (media["type"] as? String) ?? ""
            guard type == "video" || type == "animated_gif" || media["video_info"] != nil else {
                continue
            }
            guard let videoInfo = media["video_info"] as? [String: Any],
                  let variants = videoInfo["variants"] as? [[String: Any]] else {
                continue
            }

            // Collect MP4 variants sorted by bitrate descending
            var mp4Variants: [(bitrate: Int, url: String)] = []
            var hlsVariant: String?

            for v in variants {
                guard let url = v["url"] as? String, !url.isEmpty else { continue }
                let contentType = (v["content_type"] as? String) ?? ""
                if contentType.contains("mp4") || url.contains(".mp4") {
                    let br = (v["bitrate"] as? Int) ?? 0
                    mp4Variants.append((br, url))
                } else if contentType.contains("mpegURL") || url.contains(".m3u8") {
                    hlsVariant = url
                }
            }

            mp4Variants.sort { $0.bitrate > $1.bitrate }
            guard let bestMp4 = mp4Variants.first?.url ?? hlsVariant else {
                continue
            }
            let sdMp4 = mp4Variants.dropFirst().first?.url ?? bestMp4

            let rawTweetId = (dict["rest_id"] as? String)
                ?? (legacy["id_str"] as? String)
                ?? (media["id_str"] as? String)
                ?? UUID().uuidString

            let authorMeta = extractAuthorAndBio(from: dict)
            let author = authorMeta.screenName ?? fallbackAuthor ?? "x_user"
            let authorBio = authorMeta.bio ?? fallbackBio ?? ""
            let rawText = (legacy["full_text"] as? String) ?? (legacy["text"] as? String) ?? ""
            let cleanTitle = cleanTweetText(rawText)

            let possiblySensitive = (legacy["possibly_sensitive"] as? Bool)
                ?? (dict["possibly_sensitive"] as? Bool)
                ?? false
            let warningDict = (media["sensitive_media_warning"] as? [String: Any])
                ?? (media["ext_sensitive_media_warning"] as? [String: Any])
            let hasAdultWarning = (warningDict?["adult_content"] as? Bool == true)
                || (warningDict?["nudity"] as? Bool == true)
            let hasGraphicViolenceOnly = (warningDict?["graphic_violence"] as? Bool == true) && !hasAdultWarning

            guard AdultContentClassifier.isEligibleXTweet(
                text: cleanTitle,
                author: author,
                authorBio: authorBio,
                possiblySensitive: possiblySensitive,
                hasAdultWarning: hasAdultWarning,
                hasGraphicViolenceOnly: hasGraphicViolenceOnly,
                routeKey: routeKey
            ) else {
                continue
            }

            let favCount = (legacy["favorite_count"] as? Int) ?? 0
            let durationMs = (videoInfo["duration_millis"] as? Int)
            let durationSec = durationMs.map { Double($0) / 1000.0 }

            var width: Int?
            var height: Int?
            if let origInfo = media["original_info"] as? [String: Any] {
                width = origInfo["width"] as? Int
                height = origInfo["height"] as? Int
            } else if let sizes = media["sizes"] as? [String: Any],
                      let large = sizes["large"] as? [String: Any] {
                width = large["w"] as? Int
                height = large["h"] as? Int
            }

            let poster = (media["media_url_https"] as? String) ?? (media["media_url"] as? String)
            let createdAt = (legacy["created_at"] as? String)
            let isoCreated = parseTwitterDate(createdAt)
            let permalink = "https://x.com/\(author)/status/\(rawTweetId)"

            return Gif(
                id: "x_\(rawTweetId)",
                title: cleanTitle,
                author: author,
                subreddit: nil,
                upvotes: favCount,
                duration: durationSec,
                width: width,
                height: height,
                mediaType: type == "animated_gif" ? "gif" : "video",
                mediaUrl: bestMp4,
                muxedUrl: sdMp4,
                muxedUrlHd: bestMp4,
                hlsUrl: hlsVariant,
                posterUrl: poster,
                thumbnailUrl: poster,
                sourceUrl: permalink,
                permalink: permalink,
                createdUtc: isoCreated
            )
        }

        return nil
    }

    private static func cleanTweetText(_ text: String) -> String {
        // Strip trailing https://t.co/... links
        let pattern = #"https?://t\.co/[A-Za-z0-9]+"#
        let stripped = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseTwitterDate(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEE MMM dd HH:mm:ss Z yyyy"
        guard let date = df.date(from: raw) else { return nil }
        return ISO8601DateFormatter().string(from: date)
    }

    static func extractBottomCursor(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return nil
        }
        return findBottomCursor(in: root)
    }

    private static func findBottomCursor(in node: Any) -> String? {
        if let dict = node as? [String: Any] {
            if let cursorType = dict["cursorType"] as? String,
               cursorType == "Bottom",
               let val = dict["value"] as? String, !val.isEmpty {
                return val
            }
            for (_, v) in dict {
                if let found = findBottomCursor(in: v) {
                    return found
                }
            }
        } else if let arr = node as? [Any] {
            for item in arr {
                if let found = findBottomCursor(in: item) {
                    return found
                }
            }
        }
        return nil
    }
}

// MARK: - Direct Native URLSession GraphQL Engine (`XWebEngine`)

actor XWebEngine {
    static let shared = XWebEngine()

    private let bearerToken = "AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA"
    private let userAgent = Config.userAgent

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.timeoutIntervalForRequest = 15
        cfg.timeoutIntervalForResource = 25
        return URLSession(configuration: cfg)
    }()

    // Live x-web Relay persisted query IDs (auto-refreshed from x.com/home bundles on 400/404/422)
    private var queryIds: [String: String] = [
        "HomeTimeline": "QyTWLuWc5B83huorkB6mqw",
        "HomeLatestTimelineQuery": "HbJxZtMbjueV7WzK0knHKQ",
        "SearchByRawQuery": "US58CpbxEKe7RJzrZ-TMHQ",
        "UserVideoTimeline": "MPA1X8jpBRqI9rmEeWKZkw",
        "likesQuery": "GA-Msc0mQg-YAWXTgMuaVQ",
        "viewerQuery": "VNDJhBbDKWIzHmR7xvScxA",
        "Bookmarks": "qLDK3tP5B7c3k2Q4p8-t2w"
    ]
    private var queryIdsLoadedFromBundle = false
    private var lastQueryIdFetch: Date?
    private var cachedViewerId: String = ""
    private var supplementCursorIndex = 0

    func resetSession() {
        cachedViewerId = ""
        queryIdsLoadedFromBundle = false
        lastQueryIdFetch = nil
        supplementCursorIndex = 0
    }

    func resolveCt0IfNeeded(authToken: String) async -> String {
        let token = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return "" }
        guard let url = URL(string: "https://x.com/home") else { return "" }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("auth_token=\(token)", forHTTPHeaderField: "Cookie")

        do {
            let (_, resp) = try await session.data(for: req)
            if let http = resp as? HTTPURLResponse {
                var headers: [String: String] = [:]
                for (k, v) in http.allHeaderFields {
                    if let ks = k as? String, let vs = v as? String {
                        headers[ks] = vs
                    }
                }
                let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url)
                if let ct0Cookie = cookies.first(where: { $0.name == "ct0" }), !ct0Cookie.value.isEmpty {
                    return ct0Cookie.value
                }
                for (k, v) in headers where k.lowercased() == "set-cookie" {
                    if let range = v.range(of: #"ct0=([^;]+)"#, options: .regularExpression) {
                        let pair = String(v[range])
                        return String(pair.dropFirst(4))
                    }
                }
            }
        } catch {}
        return ""
    }

    private func scanJSForQueryIds(_ js: String, wantedOps: Set<String>) -> [String: String] {
        var found: [String: String] = [:]
        // 1. x-web Relay format: params:{id:`<id>`,...,name:`<op>`}
        let relayPattern = #"params:\{id:[`"']([A-Za-z0-9_-]+)[`"'],[\s\S]{0,160}?name:[`"']([A-Za-z0-9_]+)[`"']"#
        if let regex = try? NSRegularExpression(pattern: relayPattern) {
            let nsJs = js as NSString
            for m in regex.matches(in: js, range: NSRange(location: 0, length: nsJs.length)) where m.numberOfRanges >= 3 {
                let qid = nsJs.substring(with: m.range(at: 1))
                let op = nsJs.substring(with: m.range(at: 2))
                if wantedOps.contains(op) {
                    found[op] = qid
                }
            }
        }
        // 2. Legacy responsive-web format: queryId:"<id>",operationName:"<op>"
        let legacyPattern = #"queryId\s*:\s*["']([A-Za-z0-9_-]+)["']\s*,\s*operationName\s*:\s*["']([A-Za-z0-9_]+)["']"#
        if let regex = try? NSRegularExpression(pattern: legacyPattern) {
            let nsJs = js as NSString
            for m in regex.matches(in: js, range: NSRange(location: 0, length: nsJs.length)) where m.numberOfRanges >= 3 {
                let qid = nsJs.substring(with: m.range(at: 1))
                let op = nsJs.substring(with: m.range(at: 2))
                if wantedOps.contains(op) {
                    found[op] = qid
                }
            }
        }
        return found
    }

    private func ensureQueryIds(authToken: String, ct0: String, forceRefresh: Bool = false) async {
        if !forceRefresh {
            if queryIdsLoadedFromBundle, let last = lastQueryIdFetch, Date().timeIntervalSince(last) < 1800 {
                return
            }
        }

        guard let homeURL = URL(string: "https://x.com/home") else { return }
        var req = URLRequest(url: homeURL)
        req.httpMethod = "GET"
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if !authToken.isEmpty {
            let cookie = ct0.isEmpty ? "auth_token=\(authToken)" : "auth_token=\(authToken); ct0=\(ct0)"
            req.setValue(cookie, forHTTPHeaderField: "Cookie")
        }

        do {
            let (data, _) = try await session.data(for: req)
            guard let html = String(data: data, encoding: .utf8) else { return }

            let scriptPattern = #"https://abs\.twimg\.com/(?:x-web/x-web|responsive-web/client-web)[^"'\s<>]+\.js"#
            guard let scriptRegex = try? NSRegularExpression(pattern: scriptPattern) else { return }
            let nsHtml = html as NSString
            let matches = scriptRegex.matches(in: html, range: NSRange(location: 0, length: nsHtml.length))

            var entryURLs: [String] = []
            var seen = Set<String>()
            for m in matches {
                let u = nsHtml.substring(with: m.range)
                if seen.insert(u).inserted {
                    entryURLs.append(u)
                }
            }

            var targetURLs = entryURLs
            // For x-web entry-client-*.js, discover imported assets/*.js chunks
            for entry in entryURLs where entry.contains("/x-web/x-web/") {
                guard let u = URL(string: entry) else { continue }
                var r = URLRequest(url: u)
                r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                if let (jsData, _) = try? await session.data(for: r),
                   let js = String(data: jsData, encoding: .utf8),
                   let assetRegex = try? NSRegularExpression(pattern: #"assets/[A-Za-z0-9_-]+\.js"#) {
                    let nsJs = js as NSString
                    for m in assetRegex.matches(in: js, range: NSRange(location: 0, length: nsJs.length)) {
                        let rel = nsJs.substring(with: m.range)
                        let full = "https://abs.twimg.com/x-web/x-web/" + rel
                        if seen.insert(full).inserted {
                            targetURLs.append(full)
                        }
                    }
                }
            }

            let wantedOps = Set(queryIds.keys)
            let targets = Array(targetURLs.prefix(16))

            let discovered = await withTaskGroup(of: [String: String].self) { group in
                for urlStr in targets {
                    group.addTask { [session, userAgent, wantedOps] in
                        guard let u = URL(string: urlStr) else { return [:] }
                        var r = URLRequest(url: u)
                        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                        guard let (jsData, _) = try? await session.data(for: r),
                              let js = String(data: jsData, encoding: .utf8) else { return [:] }
                        return await self.scanJSForQueryIds(js, wantedOps: wantedOps)
                    }
                }

                var merged: [String: String] = [:]
                for await chunk in group {
                    for (k, v) in chunk {
                        merged[k] = v
                    }
                }
                return merged
            }

            if !discovered.isEmpty {
                for (k, v) in discovered {
                    queryIds[k] = v
                }
                queryIdsLoadedFromBundle = true
            }
            lastQueryIdFetch = Date()
        } catch {
            lastQueryIdFetch = Date()
        }
    }

    private func jsonString(_ dict: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else { return nil }
        return str
    }

    private func graphQLRequest(
        operation: String,
        variables: [String: Any],
        authToken: String,
        ct0: String,
        routeKey: String
    ) async -> (data: Data?, posts: [Gif], cursor: String?, statusCode: Int) {
        let token = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return (nil, [], nil, 401) }

        var effectiveCt0 = ct0.trimmingCharacters(in: .whitespacesAndNewlines)
        if effectiveCt0.isEmpty {
            effectiveCt0 = await resolveCt0IfNeeded(authToken: token)
        }
        guard !effectiveCt0.isEmpty else { return (nil, [], nil, 401) }

        for attempt in 0..<2 {
            guard let qid = queryIds[operation] else { return (nil, [], nil, 404) }
            var comps = URLComponents()
            comps.scheme = "https"
            comps.host = "x.com"
            comps.path = "/i/api/graphql/\(qid)/\(operation)"

            if let varsStr = jsonString(variables) {
                comps.queryItems = [URLQueryItem(name: "variables", value: varsStr)]
            }

            guard let url = comps.url else { return (nil, [], nil, 400) }
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
            req.setValue(effectiveCt0, forHTTPHeaderField: "x-csrf-token")
            req.setValue("yes", forHTTPHeaderField: "x-twitter-active-user")
            req.setValue("OAuth2Session", forHTTPHeaderField: "x-twitter-auth-type")
            req.setValue("en", forHTTPHeaderField: "x-twitter-client-language")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("https://x.com/home", forHTTPHeaderField: "Referer")
            req.setValue("https://x.com", forHTTPHeaderField: "Origin")
            req.setValue("auth_token=\(token); ct0=\(effectiveCt0)", forHTTPHeaderField: "Cookie")

            do {
                let (data, resp) = try await session.data(for: req)
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if (status == 400 || status == 404 || status == 422), attempt == 0 {
                    await ensureQueryIds(authToken: token, ct0: effectiveCt0, forceRefresh: true)
                    continue
                }
                let posts = XTweetParser.parseTweets(from: data, routeKey: routeKey)
                let cursor = XTweetParser.extractBottomCursor(from: data)
                return (data, posts, cursor, status)
            } catch {
                return (nil, [], nil, 0)
            }
        }
        return (nil, [], nil, 0)
    }

    private func resolveViewerUserId(authToken: String, ct0: String) async -> String {
        if !cachedViewerId.isEmpty { return cachedViewerId }
        let res = await graphQLRequest(
            operation: "viewerQuery",
            variables: [:],
            authToken: authToken,
            ct0: ct0,
            routeKey: "viewer"
        )
        if let data = res.data,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let dataObj = json["data"] as? [String: Any],
           let viewer = dataObj["viewer"] as? [String: Any],
           let userResults = viewer["user_results"] as? [String: Any],
           let result = userResults["result"] as? [String: Any],
           let restId = result["rest_id"] as? String, !restId.isEmpty {
            cachedViewerId = restId
            return restId
        }
        return ""
    }

    func fetchHomeTimeline(latest: Bool, after cursor: String?, authToken: String, ct0: String, topTags: [String]) async -> GoonedFeedResponse {
        let op = latest ? "HomeLatestTimelineQuery" : "HomeTimeline"
        let routeKey = latest ? "following" : "foryou"
        var vars: [String: Any] = ["count": 40]
        if latest {
            vars["enableRanking"] = false
        }
        if let c = cursor, !c.isEmpty {
            vars["cursor"] = c
        }

        let primary = await graphQLRequest(
            operation: op,
            variables: vars,
            authToken: authToken,
            ct0: ct0,
            routeKey: routeKey
        )

        var merged = primary.posts
        var outCursor = primary.cursor

        if merged.count < 3 {
            let sup = await fetchAdultSupplement(topTags: topTags, after: cursor, authToken: authToken, ct0: ct0)
            var seenIds = Set(merged.map(\.id))
            for p in sup.posts where seenIds.insert(p.id).inserted {
                merged.append(p)
            }
            if outCursor == nil {
                outCursor = sup.after
            }
        }
        return GoonedFeedResponse(posts: merged, after: outCursor)
    }

    func fetchBookmarks(after cursor: String?, authToken: String, ct0: String, topTags: [String]) async -> GoonedFeedResponse {
        var vars: [String: Any] = ["count": 40]
        if let c = cursor, !c.isEmpty {
            vars["cursor"] = c
        }
        let res = await graphQLRequest(
            operation: "Bookmarks",
            variables: vars,
            authToken: authToken,
            ct0: ct0,
            routeKey: "bookmarks"
        )
        if res.posts.isEmpty {
            return await fetchAdultSupplement(topTags: topTags, after: cursor, authToken: authToken, ct0: ct0)
        }
        return GoonedFeedResponse(posts: res.posts, after: res.cursor)
    }

    func fetchLikes(userId: String, screenName: String, after cursor: String?, authToken: String, ct0: String, topTags: [String]) async -> GoonedFeedResponse {
        var uid = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        if uid.isEmpty {
            uid = await resolveViewerUserId(authToken: authToken, ct0: ct0)
        }
        guard !uid.isEmpty else {
            return await fetchAdultSupplement(topTags: topTags, after: cursor, authToken: authToken, ct0: ct0)
        }

        var vars: [String: Any] = [
            "userId": uid,
            "count": 40
        ]
        if let c = cursor, !c.isEmpty {
            vars["cursor"] = c
        }

        let res = await graphQLRequest(
            operation: "likesQuery",
            variables: vars,
            authToken: authToken,
            ct0: ct0,
            routeKey: "likes"
        )
        if res.posts.isEmpty {
            return await fetchAdultSupplement(topTags: topTags, after: cursor, authToken: authToken, ct0: ct0)
        }
        return GoonedFeedResponse(posts: res.posts, after: res.cursor)
    }

    func fetchSearch(query: String, sort: String, after cursor: String?, authToken: String, ct0: String) async -> GoonedFeedResponse {
        let product = (sort == "Latest") ? "Latest" : "Top"
        var vars: [String: Any] = [
            "rawQuery": query,
            "count": 40,
            "querySource": "typed_query",
            "product": product
        ]
        if let c = cursor, !c.isEmpty {
            vars["cursor"] = c
        }
        let res = await graphQLRequest(
            operation: "SearchByRawQuery",
            variables: vars,
            authToken: authToken,
            ct0: ct0,
            routeKey: "search_\(query)"
        )
        return GoonedFeedResponse(posts: res.posts, after: res.cursor)
    }

    func fetchUserMedia(username: String, after cursor: String?, authToken: String, ct0: String) async -> GoonedFeedResponse {
        let clean = username.trimmingCharacters(in: CharacterSet(charactersIn: "@ "))
        guard !clean.isEmpty else { return GoonedFeedResponse(posts: [], after: nil) }
        var vars: [String: Any] = [
            "screenName": clean,
            "count": 40
        ]
        if let c = cursor, !c.isEmpty {
            vars["cursor"] = c
        }
        let res = await graphQLRequest(
            operation: "UserVideoTimeline",
            variables: vars,
            authToken: authToken,
            ct0: ct0,
            routeKey: "user_\(clean)"
        )
        return GoonedFeedResponse(posts: res.posts, after: res.cursor)
    }

    func fetchAdultSupplement(topTags: [String], after cursor: String?, authToken: String, ct0: String) async -> GoonedFeedResponse {
        var queries: [String] = []
        if let top = topTags.first, !top.isEmpty {
            queries.append("nsfw \(top) filter:videos")
        }
        queries.append(contentsOf: [
            "nsfw filter:videos",
            "porn filter:videos",
            "hentai filter:videos",
            "nsfw gif filter:native_video"
        ])
        let idx = supplementCursorIndex % queries.count
        supplementCursorIndex += 1
        let q = queries[idx]
        return await fetchSearch(query: q, sort: "Latest", after: cursor, authToken: authToken, ct0: ct0)
    }
}

// MARK: - High-Level X API Facade (`XAPI`)

@MainActor
enum XAPI {
    private static func currentCreds() -> (authToken: String, ct0: String, userId: String, screenName: String, topTags: [String]) {
        let s = UserStore.shared.data.xSession
        let topTags = UserStore.shared.data.algorithm.tagWeights
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map(\.key)
        return (s.authToken, s.ct0, s.userId, s.screenName, topTags)
    }

    private static func filterUnseen(_ posts: [Gif]) -> [Gif] {
        var seen = Set<String>()
        return posts.filter { post in
            guard !UserStore.shared.isSeen(post) else { return false }
            return seen.insert(post.id).inserted
        }
    }

    static func forYou(after: String? = nil) async -> GoonedFeedResponse {
        let c = currentCreds()
        let res = await XWebEngine.shared.fetchHomeTimeline(
            latest: false,
            after: after,
            authToken: c.authToken,
            ct0: c.ct0,
            topTags: c.topTags
        )
        var filtered = filterUnseen(res.posts)
        var nextCursor = res.after
        if filtered.count < 3 {
            let sup = await XWebEngine.shared.fetchAdultSupplement(
                topTags: c.topTags,
                after: nil,
                authToken: c.authToken,
                ct0: c.ct0
            )
            filtered = filterUnseen(filtered + sup.posts)
            if nextCursor == nil { nextCursor = sup.after }
        }
        return GoonedFeedResponse(posts: filtered, after: nextCursor)
    }

    static func following(after: String? = nil) async -> GoonedFeedResponse {
        let c = currentCreds()
        let res = await XWebEngine.shared.fetchHomeTimeline(
            latest: true,
            after: after,
            authToken: c.authToken,
            ct0: c.ct0,
            topTags: c.topTags
        )
        var filtered = filterUnseen(res.posts)
        var nextCursor = res.after
        if filtered.count < 3 {
            let sup = await XWebEngine.shared.fetchAdultSupplement(
                topTags: c.topTags,
                after: nil,
                authToken: c.authToken,
                ct0: c.ct0
            )
            filtered = filterUnseen(filtered + sup.posts)
            if nextCursor == nil { nextCursor = sup.after }
        }
        return GoonedFeedResponse(posts: filtered, after: nextCursor)
    }

    static func bookmarks(after: String? = nil) async -> GoonedFeedResponse {
        let c = currentCreds()
        let res = await XWebEngine.shared.fetchBookmarks(
            after: after,
            authToken: c.authToken,
            ct0: c.ct0,
            topTags: c.topTags
        )
        return GoonedFeedResponse(posts: filterUnseen(res.posts), after: res.after)
    }

    static func likes(after: String? = nil) async -> GoonedFeedResponse {
        let c = currentCreds()
        let res = await XWebEngine.shared.fetchLikes(
            userId: c.userId,
            screenName: c.screenName,
            after: after,
            authToken: c.authToken,
            ct0: c.ct0,
            topTags: c.topTags
        )
        return GoonedFeedResponse(posts: filterUnseen(res.posts), after: res.after)
    }

    static func search(_ query: String, sort: String = "Top", after: String? = nil) async -> GoonedFeedResponse {
        let c = currentCreds()
        let res = await XWebEngine.shared.fetchSearch(
            query: query,
            sort: sort,
            after: after,
            authToken: c.authToken,
            ct0: c.ct0
        )
        return GoonedFeedResponse(posts: filterUnseen(res.posts), after: res.after)
    }

    static func userMedia(_ username: String, after: String? = nil) async -> GoonedFeedResponse {
        let c = currentCreds()
        let res = await XWebEngine.shared.fetchUserMedia(
            username: username,
            after: after,
            authToken: c.authToken,
            ct0: c.ct0
        )
        return GoonedFeedResponse(posts: filterUnseen(res.posts), after: res.after)
    }
}

// MARK: - In-App Personal X Login Sheet (`XLoginSheet`)

struct XLoginSheet: View {
    var onConnected: (() -> Void)? = nil
    @EnvironmentObject var store: UserStore
    @Environment(\.dismiss) private var dismiss

    @State private var statusText = "Sign in to your personal X account"
    @State private var showManualEntry = false
    @State private var manualAuthToken = ""
    @State private var manualCt0 = ""
    @State private var manualHandle = ""
    @State private var webViewRef: WKWebView?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.modalGradient.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Top Bar
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.black.opacity(0.65))
                                .frame(width: 36, height: 36)
                                .overlay(Circle().stroke(Color.white.opacity(0.25), lineWidth: 1))
                            Text("𝕏")
                                .font(.system(size: 18, weight: .black))
                                .foregroundStyle(.white)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Connect Personal X")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.white)
                            Text(statusText)
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.7))
                                .lineLimit(1)
                        }

                        Spacer()

                        Button {
                            withAnimation { showManualEntry.toggle() }
                        } label: {
                            Image(systemName: "key.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 34, height: 34)
                                .liquidGlassCircle()
                        }

                        Button {
                            Task {
                                if await checkAndCaptureCookies() {
                                    onConnected?()
                                    dismiss()
                                } else {
                                    dismiss()
                                }
                            }
                        } label: {
                            Text("Done")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .liquidGlassCapsule(active: store.data.xSession.isConnected)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                    if showManualEntry {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("MANUAL COOKIE LOGIN (OPTIONAL)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.6))

                            TextField("auth_token cookie", text: $manualAuthToken)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.system(size: 14, design: .monospaced))
                                .padding(10)
                                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))

                            TextField("ct0 cookie (auto-fetched if blank)", text: $manualCt0)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.system(size: 14, design: .monospaced))
                                .padding(10)
                                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))

                            TextField("@username (optional)", text: $manualHandle)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.system(size: 14))
                                .padding(10)
                                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))

                            Button {
                                let auth = manualAuthToken.trimmingCharacters(in: .whitespacesAndNewlines)
                                let rawCt0 = manualCt0.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !auth.isEmpty else { return }
                                Task {
                                    statusText = "Verifying session..."
                                    let resolvedCt0 = rawCt0.isEmpty
                                        ? await XWebEngine.shared.resolveCt0IfNeeded(authToken: auth)
                                        : rawCt0
                                    guard !resolvedCt0.isEmpty else {
                                        statusText = "Could not resolve ct0 — paste both cookies"
                                        return
                                    }
                                    store.data.xSession.authToken = auth
                                    store.data.xSession.ct0 = resolvedCt0
                                    store.data.xSession.screenName = manualHandle.replacingOccurrences(of: "@", with: "")
                                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                                    onConnected?()
                                    dismiss()
                                }
                            } label: {
                                Text("Save Session Cookies")
                                    .font(.system(size: 14, weight: .bold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 10)
                                    .liquidGlassCapsule(active: true)
                            }
                        }
                        .foregroundStyle(.white)
                        .padding(14)
                        .liquidGlassCard(cornerRadius: 18)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 8)
                    }

                    // Live X Login WebView
                    XLoginWebViewRepresentable(webViewRef: $webViewRef)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                }
            }
            .task {
                // Poll cookies every 1s so as soon as login finishes, we capture auth_token & ct0 automatically
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if await checkAndCaptureCookies() {
                        statusText = "Connected! Loading your X feed..."
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        try? await Task.sleep(nanoseconds: 700_000_000)
                        onConnected?()
                        dismiss()
                        break
                    }
                }
            }
        }
    }

    @MainActor
    private func checkAndCaptureCookies() async -> Bool {
        let cookieStore = WKWebsiteDataStore.default().httpCookieStore
        let cookies = await cookieStore.allCookies()

        var authToken = ""
        var ct0 = ""
        var twid = ""

        for c in cookies where c.domain.contains("x.com") || c.domain.contains("twitter.com") {
            if c.name == "auth_token" && !c.value.isEmpty {
                authToken = c.value
            } else if c.name == "ct0" && !c.value.isEmpty {
                ct0 = c.value
            } else if c.name == "twid" && !c.value.isEmpty {
                twid = c.value.removingPercentEncoding ?? c.value
            }
        }

        guard !authToken.isEmpty, !ct0.isEmpty else {
            return false
        }

        store.data.xSession.authToken = authToken
        store.data.xSession.ct0 = ct0
        if let range = twid.range(of: "u=") {
            store.data.xSession.userId = String(twid[range.upperBound...])
        }

        // Try to grab @screen_name from the active webView DOM if available
        if let wv = webViewRef, store.data.xSession.screenName.isEmpty {
            let js = """
            (function() {
                const html = document.documentElement ? document.documentElement.innerHTML : '';
                const m = html.match(/"screen_name":"([A-Za-z0-9_]{1,20})"/);
                return m ? m[1] : '';
            })();
            """
            if let sn = try? await wv.evaluateJavaScript(js) as? String, !sn.isEmpty {
                store.data.xSession.screenName = sn
            }
        }

        return true
    }
}

struct XLoginWebViewRepresentable: UIViewRepresentable {
    @Binding var webViewRef: WKWebView?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.customUserAgent = Config.userAgent
        wv.isOpaque = false
        wv.backgroundColor = .black
        wv.uiDelegate = context.coordinator
        wv.navigationDelegate = context.coordinator
        context.coordinator.parentWebView = wv

        let url = URL(string: "https://x.com/i/flow/login")!
        wv.load(URLRequest(url: url))

        DispatchQueue.main.async {
            self.webViewRef = wv
        }
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate {
        weak var parentWebView: WKWebView?
        private var popupWebView: WKWebView?
        private var closeButton: UIButton?

        /// Supports Google & Apple OAuth popups (`window.open` / `target="_blank"`) while preserving `window.opener`.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                configuration.websiteDataStore = .default()
                configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
                let popup = WKWebView(frame: webView.bounds, configuration: configuration)
                popup.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                popup.customUserAgent = Config.userAgent
                popup.uiDelegate = self
                popup.navigationDelegate = self
                popup.backgroundColor = .systemBackground
                webView.addSubview(popup)

                let closeBtn = UIButton(type: .system)
                closeBtn.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
                closeBtn.tintColor = .white
                closeBtn.backgroundColor = UIColor.black.withAlphaComponent(0.6)
                closeBtn.layer.cornerRadius = 16
                closeBtn.frame = CGRect(x: webView.bounds.width - 46, y: 12, width: 32, height: 32)
                closeBtn.autoresizingMask = [.flexibleLeftMargin, .flexibleBottomMargin]
                closeBtn.addTarget(self, action: #selector(dismissPopup), for: .touchUpInside)
                webView.addSubview(closeBtn)

                self.popupWebView?.removeFromSuperview()
                self.closeButton?.removeFromSuperview()
                self.popupWebView = popup
                self.closeButton = closeBtn
                return popup
            }
            return nil
        }

        func webViewDidClose(_ webView: WKWebView) {
            if webView === popupWebView {
                dismissPopup()
            }
        }

        @objc private func dismissPopup() {
            popupWebView?.removeFromSuperview()
            popupWebView = nil
            closeButton?.removeFromSuperview()
            closeButton = nil
        }
    }
}
