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
            ), seen.insert(gif.canonicalDedupeKey).inserted, seen.insert(gif.id).inserted {
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
        // Avoid extracting twice from outer retweet wrapper; walk() visits inner retweeted_status_result
        let legacy = (dict["legacy"] as? [String: Any]) ?? dict
        if dict["retweeted_status_results"] != nil || legacy["retweeted_status_result"] != nil || legacy["retweeted_status_results"] != nil {
            if dict["media_entities2"] == nil && legacy["extended_entities"] == nil {
                return nil
            }
        }

        // Support BOTH x-web Relay `media_entities2` and legacy `extended_entities.media` / `entities.media`
        let mediaList: [[String: Any]] =
            (dict["media_entities2"] as? [[String: Any]]).flatMap { $0.isEmpty ? nil : $0 }
            ?? (legacy["media_entities2"] as? [[String: Any]]).flatMap { $0.isEmpty ? nil : $0 }
            ?? (legacy["extended_entities"] as? [String: Any])?["media"] as? [[String: Any]]
            ?? (dict["extended_entities"] as? [String: Any])?["media"] as? [[String: Any]]
            ?? (legacy["entities"] as? [String: Any])?["media"] as? [[String: Any]]
            ?? []

        guard !mediaList.isEmpty else {
            return nil
        }

        let details = dict["details"] as? [String: Any]
        let noteText = (((dict["note_tweet"] as? [String: Any])?["note_tweet_results"] as? [String: Any])?["result"] as? [String: Any])?["text"] as? String

        // Find the first video or animated_gif media attachment
        for media in mediaList {
            let type = ((media["type"] as? String) ?? "").lowercased()
            guard type == "video" || type == "animated_gif" || media["video_info"] != nil else {
                continue
            }
            guard let videoInfo = media["video_info"] as? [String: Any],
                  let variants = videoInfo["variants"] as? [[String: Any]] else {
                continue
            }

            // Collect MP4 variants & sort by reliability + bitrate
            var mp4Variants: [(bitrate: Int, url: String)] = []
            var hlsVariant: String?

            for v in variants {
                guard let url = v["url"] as? String, !url.isEmpty else { continue }
                let contentType = ((v["content_type"] as? String) ?? "").lowercased()
                if contentType.contains("mp4") || url.contains(".mp4") {
                    let br = (v["bitrate"] as? Int) ?? 0
                    mp4Variants.append((br, url))
                } else if contentType.contains("mpegurl") || contentType.contains("m3u8") || url.contains(".m3u8") {
                    hlsVariant = url
                }
            }

            // Sort high-to-low, while preferring fast-starting <=2.5Mbps AVC stream for SD/default and fallback chain
            mp4Variants.sort { $0.bitrate > $1.bitrate }
            let fastStartMp4 = mp4Variants.first(where: { $0.bitrate > 0 && $0.bitrate <= 2_500_000 })?.url
                ?? mp4Variants.last?.url
            guard let bestMp4 = mp4Variants.first?.url ?? hlsVariant else {
                continue
            }
            let sdMp4 = fastStartMp4 ?? mp4Variants.dropFirst().first?.url ?? bestMp4

            let rawTweetId = (dict["rest_id"] as? String)
                ?? (legacy["id_str"] as? String)
                ?? (media["source_status_id_str"] as? String)
                ?? (media["id_str"] as? String)
                ?? UUID().uuidString

            let mediaFingerprint: String? = (media["media_key"] as? String)
                ?? (media["source_status_id_str"] as? String).map { "xsrc_\($0)" }
                ?? (media["id_str"] as? String).map { "xmed_\($0)" }

            let allVariantURLs = mp4Variants.map(\.url) + (hlsVariant.map { [$0] } ?? [])
            MediaMetaRegistry.register(
                postId: "x_\(rawTweetId)",
                fingerprint: mediaFingerprint,
                extraVideoURLs: allVariantURLs
            )

            let authorMeta = extractAuthorAndBio(from: dict)
            let author = authorMeta.screenName ?? fallbackAuthor ?? "x_user"
            let authorBio = authorMeta.bio ?? fallbackBio ?? ""
            let rawText = (legacy["full_text"] as? String)
                ?? (details?["full_text"] as? String)
                ?? (dict["full_text"] as? String)
                ?? noteText
                ?? (legacy["text"] as? String)
                ?? (dict["text"] as? String)
                ?? ""
            let cleanTitle = cleanTweetText(rawText)

            let possiblySensitive = (legacy["possibly_sensitive"] as? Bool)
                ?? (dict["possibly_sensitive"] as? Bool)
                ?? (dict["is_nsfw"] as? Bool)
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

            let favCount = (legacy["favorite_count"] as? Int)
                ?? (dict["favorite_count"] as? Int)
                ?? 0
            let durationMs = (videoInfo["duration_millis"] as? Int)
            let durationSec = durationMs.map { Double($0) / 1000.0 }

            var width: Int? = (media["original_img_width"] as? Int)
            var height: Int? = (media["original_img_height"] as? Int)
            if let origInfo = media["original_info"] as? [String: Any] {
                if width == nil { width = origInfo["width"] as? Int }
                if height == nil { height = origInfo["height"] as? Int }
            } else if let sizes = media["sizes"] as? [String: Any],
                      let large = sizes["large"] as? [String: Any] {
                if width == nil { width = large["w"] as? Int }
                if height == nil { height = large["h"] as? Int }
            }

            let poster = (media["media_url_https"] as? String) ?? (media["media_url"] as? String)
            let isoCreated = parseTwitterDate((legacy["created_at"] as? String) ?? (dict["created_at"] as? String))
                ?? parseCreatedAtMs(details?["created_at_ms"] ?? dict["created_at_ms"])
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

    private static func parseCreatedAtMs(_ val: Any?) -> String? {
        let ms: Double?
        if let d = val as? Double { ms = d }
        else if let i = val as? Int { ms = Double(i) }
        else if let s = val as? String { ms = Double(s) }
        else { ms = nil }
        guard let ms, ms > 1_000_000_000_000 else { return nil }
        return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: ms / 1000.0))
    }

    static func extractBottomCursor(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return nil
        }
        return findBottomCursor(in: root)
    }

    private static func findBottomCursor(in node: Any) -> String? {
        if let dict = node as? [String: Any] {
            let cursorType = (dict["cursorType"] as? String) ?? (dict["cursor_type"] as? String)
            if cursorType == "Bottom",
               let val = dict["value"] as? String, !val.isEmpty {
                return val
            }
            if let bottom = dict["bottom_cursor"] as? String, !bottom.isEmpty {
                return bottom
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

// MARK: - Window-Attached Authenticated X WebView Engine (`XWebEngine`)

@MainActor
final class XWebEngine: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    static let shared = XWebEngine()

    private var webView: WKWebView?
    private var activeRouteKey: String = ""
    private var routeBuffers: [String: [Gif]] = [:]
    private var seenIds = Set<String>()
    private var waiters: [(routeKey: String, cont: CheckedContinuation<[Gif], Never>)] = []
    private var pageCounter: Int = 0
    private var dryPayloadCount: Int = 0
    private var adultSupplementIndex: Int = 0
    private var isEngineBusy: Bool = false
    private var lockWaiters: [CheckedContinuation<Void, Never>] = []
    private var pumpTask: Task<Void, Never>?
    private var lastLoadedTab: String = ""

    private override init() {
        super.init()
    }

    private func acquireLock() async {
        if !isEngineBusy {
            isEngineBusy = true
            return
        }
        await withCheckedContinuation { cont in
            lockWaiters.append(cont)
        }
    }

    private func releaseLock() {
        if !lockWaiters.isEmpty {
            let next = lockWaiters.removeFirst()
            next.resume()
        } else {
            isEngineBusy = false
        }
    }

    func resolveCt0IfNeeded(authToken: String) async -> String {
        let token = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return "" }
        guard let url = URL(string: "https://x.com/home") else { return "" }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue(Config.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("auth_token=\(token)", forHTTPHeaderField: "Cookie")

        do {
            let (_, resp) = try await URLSession.shared.data(for: req)
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

    /// Attaches the WKWebView behind the root window at alpha 0.011 so iOS WebKit never throttles JS/timers/IntersectionObserver.
    private func attachToKeyWindowIfNeeded(_ wv: WKWebView) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let keyWindow = scenes.flatMap(\.windows).first(where: { $0.isKeyWindow }) ?? scenes.flatMap(\.windows).first
        guard let window = keyWindow else { return }
        if wv.superview !== window {
            wv.removeFromSuperview()
            wv.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            wv.alpha = 0.011
            wv.isUserInteractionEnabled = false
            window.insertSubview(wv, at: 0)
        }
    }

    func ensureWebView() async -> WKWebView {
        if let existing = webView {
            attachToKeyWindowIfNeeded(existing)
            await injectStoredCookies(into: existing.configuration.websiteDataStore.httpCookieStore)
            return existing
        }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = false
        config.mediaTypesRequiringUserActionForPlayback = [.all]

        let hookJS = """
        (function() {
            if (window.__goonedXHooked) return;
            window.__goonedXHooked = true;

            try {
                HTMLMediaElement.prototype.play = function() {
                    try { this.muted = true; this.pause(); } catch (e) {}
                    return Promise.resolve();
                };
            } catch (e) {}

            function shouldCapture(url) {
                if (!url) return false;
                return url.indexOf('/graphql') !== -1 ||
                       url.indexOf('/i/api/') !== -1 ||
                       url.indexOf('/1.1/') !== -1 ||
                       url.indexOf('settings.json') !== -1;
            }

            const origFetch = window.fetch;
            window.fetch = async function(...args) {
                const req = args[0];
                const url = (typeof req === 'string') ? req : (req && req.url ? req.url : '');
                const resp = await origFetch.apply(this, args);
                try {
                    if (shouldCapture(url)) {
                        const clone = resp.clone();
                        clone.text().then(function(body) {
                            if (body && body.length > 10 && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.xBridge) {
                                window.webkit.messageHandlers.xBridge.postMessage({ type: 'payload', url: url, pageUrl: location.href, body: body });
                            }
                        }).catch(function(){});
                    }
                } catch (e) {}
                return resp;
            };

            const origOpen = XMLHttpRequest.prototype.open;
            const origSend = XMLHttpRequest.prototype.send;
            XMLHttpRequest.prototype.open = function(method, url) {
                this.__goonedUrl = url;
                return origOpen.apply(this, arguments);
            };
            XMLHttpRequest.prototype.send = function() {
                const xhr = this;
                xhr.addEventListener('load', function() {
                    try {
                        const url = xhr.__goonedUrl || '';
                        if (shouldCapture(url) && xhr.responseText && xhr.responseText.length > 10) {
                            if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.xBridge) {
                                window.webkit.messageHandlers.xBridge.postMessage({ type: 'payload', url: url, pageUrl: location.href, body: xhr.responseText });
                            }
                        }
                    } catch (e) {}
                });
                return origSend.apply(this, arguments);
            };

            function scanPageMeta() {
                try {
                    const html = document.documentElement ? document.documentElement.innerHTML : '';
                    const m = html.match(/"screen_name":"([A-Za-z0-9_]{1,20})"/);
                    if (m && m[1] && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.xBridge) {
                        window.webkit.messageHandlers.xBridge.postMessage({ type: 'screenName', screenName: m[1] });
                    }
                    const scripts = document.querySelectorAll('script[type="application/json"]');
                    for (const s of scripts) {
                        if (s.__goonedXScanned) continue;
                        s.__goonedXScanned = true;
                        const text = s.textContent || '';
                        if (text.length > 100 && (text.indexOf('video_info') !== -1 || text.indexOf('media_entities2') !== -1)) {
                            window.webkit.messageHandlers.xBridge.postMessage({ type: 'payload', url: 'ssr_x', body: text });
                        }
                    }
                } catch (e) {}
            }
            document.addEventListener('DOMContentLoaded', scanPageMeta);
            setInterval(scanPageMeta, 1800);
        })();
        """

        let userScript = WKUserScript(source: hookJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        config.userContentController.addUserScript(userScript)
        config.userContentController.add(self, name: "xBridge")

        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        wv.customUserAgent = Config.userAgent
        wv.navigationDelegate = self
        attachToKeyWindowIfNeeded(wv)
        await injectStoredCookies(into: config.websiteDataStore.httpCookieStore)
        self.webView = wv
        return wv
    }

    private func injectStoredCookies(into cookieStore: WKHTTPCookieStore) async {
        let session = UserStore.shared.data.xSession
        guard session.isConnected else { return }

        let existing = await cookieStore.allCookies()
        let hasLiveAuth = existing.contains { ($0.domain.contains("x.com") || $0.domain.contains("twitter.com")) && $0.name == "auth_token" && $0.value == session.authToken }
        if hasLiveAuth { return }

        let domains = [".x.com", ".twitter.com"]
        for domain in domains {
            if let authCookie = HTTPCookie(properties: [
                .domain: domain,
                .path: "/",
                .name: "auth_token",
                .value: session.authToken,
                .secure: "TRUE",
                .expires: Date(timeIntervalSinceNow: 31_536_000)
            ]) {
                await cookieStore.setCookie(authCookie)
            }
            if let ct0Cookie = HTTPCookie(properties: [
                .domain: domain,
                .path: "/",
                .name: "ct0",
                .value: session.ct0,
                .secure: "TRUE",
                .expires: Date(timeIntervalSinceNow: 31_536_000)
            ]) {
                await cookieStore.setCookie(ct0Cookie)
            }
        }
    }

    func warmUp() async {
        guard UserStore.shared.data.xSession.isConnected else { return }
        let wv = await ensureWebView()
        if wv.url == nil || wv.url?.absoluteString == "about:blank" {
            if activeRouteKey.isEmpty {
                activeRouteKey = "x_foryou"
                lastLoadedTab = "For you"
            }
            if let url = URL(string: "https://x.com/home") {
                wv.load(URLRequest(url: url))
            }
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }

        if type == "screenName", let sn = body["screenName"] as? String, !sn.isEmpty {
            if UserStore.shared.data.xSession.screenName.isEmpty {
                UserStore.shared.data.xSession.screenName = sn
            }
            return
        }

        guard type == "payload",
              let url = body["url"] as? String,
              let jsonText = body["body"] as? String,
              let data = jsonText.data(using: .utf8) else { return }

        if UserStore.shared.data.xSession.screenName.isEmpty,
           let sn = XTweetParser.parseScreenName(from: data) {
            UserStore.shared.data.xSession.screenName = sn
        }

        // Strict route isolation: never let X's "For you" HomeTimeline or Search payloads leak into Following/Bookmarks/User feeds
        let pageUrl = (body["pageUrl"] as? String ?? "").lowercased()
        if activeRouteKey == "x_following" {
            let isForYouTimeline = url.contains("HomeTimeline") && !url.contains("HomeLatestTimeline")
            let isSearchResult = url.contains("SearchTimeline") || pageUrl.contains("/search")
            if isForYouTimeline || isSearchResult {
                return
            }
        } else if activeRouteKey == "x_bookmarks" && !url.contains("Bookmarks") && !pageUrl.contains("/bookmarks") && url != "ssr_x" {
            return
        } else if activeRouteKey.hasPrefix("x_search_") && (url.contains("HomeTimeline") || url.contains("HomeLatestTimeline")) {
            return
        }

        let tweets = XTweetParser.parseTweets(from: data, routeKey: activeRouteKey)
        if !tweets.isEmpty {
            let store = UserStore.shared
            let fresh = tweets.filter {
                !store.isSeen($0)
                    && !store.isBlockedByAlgorithm($0)
                    && seenIds.insert($0.canonicalDedupeKey).inserted
            }
            if !fresh.isEmpty {
                dryPayloadCount = 0
                var buf = routeBuffers[activeRouteKey] ?? []
                buf.append(contentsOf: fresh)
                routeBuffers[activeRouteKey] = buf
                flushWaitersIfNeeded(for: activeRouteKey)
                if buf.count < 24, let wv = webView {
                    scheduleBackgroundPump(for: activeRouteKey, wv: wv)
                }
                return
            }
        }

        let isTimelinePayload = url.contains("Timeline") || url.contains("Search") || url.contains("Bookmarks") || url.contains("likes") || url.contains("Likes") || url.contains("UserVideo") || url.contains("UserMedia") || jsonText.contains("media_entities2") || jsonText.contains("video_info")
        guard isTimelinePayload else { return }

        dryPayloadCount += 1
        let bufCount = routeBuffers[activeRouteKey]?.count ?? 0
        // Only "For You" may fall back to adult search discovery; Following/Bookmarks/Search/User never mix in random tweets
        let shouldSupplement = (activeRouteKey == "x_foryou")
        if shouldSupplement && bufCount == 0 && dryPayloadCount >= 1,
           let wv = webView,
           let supURL = nextAdultSupplementURL() {
            if dryPayloadCount >= 2 {
                wv.load(URLRequest(url: supURL))
            } else {
                Task { @MainActor [weak self] in
                    _ = try? await wv.evaluateJavaScript(Self.scrollAdvanceJS)
                    try? await Task.sleep(nanoseconds: 1_100_000_000)
                    guard let self,
                          self.activeRouteKey == "x_foryou",
                          !self.waiters.filter({ $0.routeKey == self.activeRouteKey }).isEmpty,
                          (self.routeBuffers[self.activeRouteKey]?.isEmpty ?? true),
                          let nextSup = self.nextAdultSupplementURL() else { return }
                    wv.load(URLRequest(url: nextSup))
                }
            }
        }
    }

    func nextAdultSupplementURL() -> URL? {
        let topTags = UserStore.shared.data.algorithm.tagWeights
            .filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
            .prefix(4)
            .map(\.key)
        let blocked = Set(
            UserStore.shared.data.algorithm.blockedTags.map { $0.lowercased() }
            + SmartTasteEngine.shared.state.suppressedTags.map { $0.lowercased() }
        )
        let exclusions = blocked.prefix(4).map { "-\($0)" }.joined(separator: " ")
        var queries = topTags.filter { !blocked.contains($0.lowercased()) }.map { "nsfw \($0) \(exclusions) filter:videos" }
        queries.append(contentsOf: [
            "nsfw \(exclusions) filter:videos",
            "porn \(exclusions) filter:videos",
            "hentai \(exclusions) filter:videos",
            "nsfw gif \(exclusions) filter:native_video",
            "onlyfans \(exclusions) filter:videos"
        ])
        let q = queries[adultSupplementIndex % queries.count]
        adultSupplementIndex += 1
        let tab = (adultSupplementIndex % 2 == 0) ? "top" : "live"
        guard let encoded = q.addingPercentEncoding(withAllowedCharacters: CharacterSet.urlQueryAllowed) else {
            return nil
        }
        return URL(string: "https://x.com/search?q=\(encoded)&src=typed_query&f=\(tab)")
    }

    private func flushWaitersIfNeeded(for routeKey: String) {
        let buf = routeBuffers[routeKey] ?? []
        guard !buf.isEmpty else { return }
        let matching = waiters.filter { $0.routeKey == routeKey }
        guard !matching.isEmpty else { return }
        waiters.removeAll { $0.routeKey == routeKey }
        routeBuffers[routeKey] = []
        for w in matching {
            w.cont.resume(returning: buf)
        }
    }

    private static let scrollAdvanceJS = """
    (function() {
        try {
            window.scrollBy(0, 2600);
            if (document.scrollingElement) {
                document.scrollingElement.scrollTop = Math.min(
                    document.scrollingElement.scrollHeight,
                    document.scrollingElement.scrollTop + 2600
                );
            }
            const els = document.querySelectorAll('div, main, section');
            for (let i = 0; i < els.length; i++) {
                const el = els[i];
                if (el.scrollHeight > el.clientHeight + 120) {
                    const st = getComputedStyle(el);
                    if (st.overflowY === 'auto' || st.overflowY === 'scroll') {
                        el.scrollTop += 2200;
                    }
                }
            }
            window.dispatchEvent(new Event('scroll'));
            window.dispatchEvent(new WheelEvent('wheel', { deltaY: 900, bubbles: true }));
        } catch (e) {}
    })();
    """

    private func scheduleBackgroundPump(for routeKey: String, wv: WKWebView) {
        guard pumpTask == nil || pumpTask?.isCancelled == true else { return }
        pumpTask = Task { @MainActor [weak self] in
            defer { self?.pumpTask = nil }
            for _ in 0..<3 {
                try? await Task.sleep(nanoseconds: 700_000_000)
                guard let self,
                      !Task.isCancelled,
                      self.activeRouteKey == routeKey,
                      (self.routeBuffers[routeKey]?.count ?? 0) < 24 else { return }
                _ = try? await wv.evaluateJavaScript(Self.scrollAdvanceJS)
            }
        }
    }

    private static func selectHomeTabJS(_ tabLabel: String) -> String {
        let escaped = tabLabel.replacingOccurrences(of: "'", with: "\\'")
        return """
        (function() {
            let tries = 0;
            const iv = setInterval(function() {
                tries++;
                const tabs = Array.from(document.querySelectorAll('[role="tab"]'));
                const target = tabs.find(el => (el.innerText || '').trim().toLowerCase() === '\(escaped)'.toLowerCase());
                if (target) {
                    if (target.getAttribute('aria-selected') !== 'true') {
                        target.click();
                    }
                    clearInterval(iv);
                } else if (tries > 24) {
                    clearInterval(iv);
                }
            }, 180);
        })();
        """
    }

    func fetchFeed(
        routeKey: String,
        targetURL: URL,
        homeTabLabel: String? = nil,
        isRefresh: Bool
    ) async -> GoonedFeedResponse {
        guard UserStore.shared.data.xSession.isConnected else {
            return GoonedFeedResponse(posts: [], after: nil)
        }

        if !isRefresh, let existing = routeBuffers[routeKey], !existing.isEmpty {
            routeBuffers[routeKey] = []
            activeRouteKey = routeKey
            pageCounter += 1
            if let wv = webView {
                scheduleBackgroundPump(for: routeKey, wv: wv)
            }
            return GoonedFeedResponse(posts: existing, after: "xpage_\(pageCounter)")
        }

        await acquireLock()
        defer { releaseLock() }

        if !isRefresh, let existing = routeBuffers[routeKey], !existing.isEmpty {
            routeBuffers[routeKey] = []
            activeRouteKey = routeKey
            pageCounter += 1
            if let wv = webView {
                scheduleBackgroundPump(for: routeKey, wv: wv)
            }
            return GoonedFeedResponse(posts: existing, after: "xpage_\(pageCounter)")
        }

        let wv = await ensureWebView()
        var didLoadNewURL = false

        if isRefresh || activeRouteKey != routeKey {
            pumpTask?.cancel()
            pumpTask = nil
            activeRouteKey = routeKey
            if isRefresh {
                routeBuffers[routeKey] = []
            }
            dryPayloadCount = 0
            pageCounter = 0

            let onHomeAlready = wv.url?.path == "/home"
            if let homeTabLabel, onHomeAlready, lastLoadedTab != homeTabLabel {
                lastLoadedTab = homeTabLabel
                _ = try? await wv.evaluateJavaScript(Self.selectHomeTabJS(homeTabLabel))
            } else {
                let alreadyLoadingSameHome = onHomeAlready && homeTabLabel != nil && !isRefresh
                if !alreadyLoadingSameHome {
                    lastLoadedTab = homeTabLabel ?? ""
                    wv.load(URLRequest(url: targetURL))
                    didLoadNewURL = true
                }
                if let homeTabLabel {
                    _ = try? await wv.evaluateJavaScript(Self.selectHomeTabJS(homeTabLabel))
                }
            }
        } else {
            _ = try? await wv.evaluateJavaScript(Self.scrollAdvanceJS)
        }

        let nudgeDelayNs: UInt64 = didLoadNewURL ? 1_400_000_000 : 650_000_000
        let maxRemainingNs: UInt64 = didLoadNewURL ? 3_400_000_000 : 1_800_000_000

        let posts = await withCheckedContinuation { (cont: CheckedContinuation<[Gif], Never>) in
            self.waiters.append((routeKey: routeKey, cont: cont))
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: nudgeDelayNs)
                guard let self else { return }
                if self.waiters.contains(where: { $0.routeKey == routeKey }) {
                    _ = try? await wv.evaluateJavaScript(Self.scrollAdvanceJS)
                    if let homeTabLabel {
                        _ = try? await wv.evaluateJavaScript(Self.selectHomeTabJS(homeTabLabel))
                    }
                }
                try? await Task.sleep(nanoseconds: maxRemainingNs)
                let pending = self.waiters.filter { $0.routeKey == routeKey }
                if !pending.isEmpty {
                    self.waiters.removeAll { $0.routeKey == routeKey }
                    let fallback = self.routeBuffers[routeKey] ?? []
                    self.routeBuffers[routeKey] = []
                    for p in pending {
                        p.cont.resume(returning: fallback)
                    }
                }
            }
        }

        scheduleBackgroundPump(for: routeKey, wv: wv)
        pageCounter += 1
        return GoonedFeedResponse(posts: posts, after: "xpage_\(pageCounter)")
    }

    /// Direct authenticated X Search via REST v2 (`adaptive.json`) — bypasses slow DOM navigation (~350ms).
    /// Falls back cleanly to live WebView search if adaptive.json is blocked or returns 0 videos.
    func searchFast(query: String, sort: String, after: String?) async -> GoonedFeedResponse {
        let session = UserStore.shared.data.xSession
        guard session.isConnected else { return GoonedFeedResponse(posts: [], after: nil) }

        let cleaned = query
            .replacingOccurrences(of: "x:", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let baseQuery = cleaned.isEmpty ? "nsfw" : cleaned

        // Try direct authenticated adaptive JSON API first (very fast, zero WebView lock contention)
        for qVariant in ["\(baseQuery) filter:videos", baseQuery] {
            var comps = URLComponents(string: "https://x.com/i/api/2/search/adaptive.json")!
            comps.queryItems = [
                URLQueryItem(name: "q", value: qVariant),
                URLQueryItem(name: "count", value: "40"),
                URLQueryItem(name: "tweet_mode", value: "extended"),
                URLQueryItem(name: "include_entities", value: "1"),
                URLQueryItem(name: "include_ext_media_color", value: "true"),
                URLQueryItem(name: "tweet_search_mode", value: sort == "Latest" ? "live" : "top")
            ]
            if let after, after.hasPrefix("cursor:"), !after.dropFirst(7).isEmpty {
                comps.queryItems?.append(URLQueryItem(name: "cursor", value: String(after.dropFirst(7))))
            }
            if let url = comps.url {
                var req = URLRequest(url: url)
                req.timeoutInterval = 7
                req.setValue(Config.userAgent, forHTTPHeaderField: "User-Agent")
                req.setValue("Bearer AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA", forHTTPHeaderField: "Authorization")
                req.setValue(session.ct0, forHTTPHeaderField: "x-csrf-token")
                req.setValue("auth_token=\(session.authToken); ct0=\(session.ct0)", forHTTPHeaderField: "Cookie")
                req.setValue("https://x.com/search", forHTTPHeaderField: "Referer")
                req.setValue("OAuth2Session", forHTTPHeaderField: "x-twitter-auth-type")
                req.setValue("true", forHTTPHeaderField: "x-twitter-active-user")

                if let (data, resp) = try? await URLSession.shared.data(for: req),
                   (resp as? HTTPURLResponse)?.statusCode == 200 {
                    let parsed = XTweetParser.parseTweets(from: data, routeKey: "x_search_fast")
                    let store = UserStore.shared
                    let filtered = parsed.filter {
                        !store.isSeen($0)
                        && !store.isBlockedByAlgorithm($0)
                        && seenIds.insert($0.canonicalDedupeKey).inserted
                    }
                    let nextCursor = XTweetParser.extractBottomCursor(from: data).map { "cursor:\($0)" }
                    if !filtered.isEmpty {
                        return GoonedFeedResponse(posts: filtered, after: nextCursor)
                    }
                }
            }
        }

        // WebView fallback: try unfiltered / filtered search on x.com/search
        let encoded = "\(baseQuery) filter:videos".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "nsfw"
        let tab = (sort == "Latest") ? "live" : "top"
        let searchURL = URL(string: "https://x.com/search?q=\(encoded)&src=typed_query&f=\(tab)")!
        let res = await fetchFeed(
            routeKey: "x_search_\(cleaned.lowercased())_\(tab)",
            targetURL: searchURL,
            isRefresh: after == nil
        )
        if !res.posts.isEmpty { return res }

        let broadEncoded = baseQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "nsfw"
        let broadURL = URL(string: "https://x.com/search?q=\(broadEncoded)&src=typed_query&f=\(tab)")!
        return await fetchFeed(
            routeKey: "x_search_broad_\(cleaned.lowercased())_\(tab)",
            targetURL: broadURL,
            isRefresh: true
        )
    }

    /// Follows or unfollows an account directly on the user's real X account using authenticated CSRF headers.
    @discardableResult
    func followUser(_ screenName: String, unfollow: Bool) async -> Bool {
        let session = UserStore.shared.data.xSession
        guard session.isConnected else { return false }
        let handle = screenName.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "@", with: "")
        guard !handle.isEmpty else { return false }

        let endpoint = unfollow
            ? "https://x.com/i/api/1.1/friendships/destroy.json"
            : "https://x.com/i/api/1.1/friendships/create.json"
        guard let url = URL(string: endpoint) else { return false }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue(Config.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("Bearer AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA", forHTTPHeaderField: "Authorization")
        req.setValue(session.ct0, forHTTPHeaderField: "x-csrf-token")
        req.setValue("auth_token=\(session.authToken); ct0=\(session.ct0)", forHTTPHeaderField: "Cookie")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.setValue("OAuth2Session", forHTTPHeaderField: "x-twitter-auth-type")
        req.setValue("https://x.com/\(handle)", forHTTPHeaderField: "Referer")
        let enc = handle.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? handle
        req.httpBody = "screen_name=\(enc)&follow=true".data(using: .utf8)

        if let (_, resp) = try? await URLSession.shared.data(for: req),
           let code = (resp as? HTTPURLResponse)?.statusCode,
           (200..<300).contains(code) {
            return true
        }
        return false
    }

    func resetSession() async {
        pumpTask?.cancel()
        pumpTask = nil
        activeRouteKey = ""
        lastLoadedTab = ""
        routeBuffers.removeAll()
        seenIds.removeAll()
        dryPayloadCount = 0
        let store = WKWebsiteDataStore.default()
        let cookies = await store.httpCookieStore.allCookies()
        for c in cookies where c.domain.contains("x.com") || c.domain.contains("twitter.com") {
            await store.httpCookieStore.deleteCookie(c)
        }
        webView?.load(URLRequest(url: URL(string: "about:blank")!))
    }
}

// MARK: - High-Level X API Facade (`XAPI`)

@MainActor
enum XAPI {
    static func forYou(after: String? = nil) async -> GoonedFeedResponse {
        let url = URL(string: "https://x.com/home")!
        return await XWebEngine.shared.fetchFeed(
            routeKey: "x_foryou",
            targetURL: url,
            homeTabLabel: "For you",
            isRefresh: after == nil
        )
    }

    static func following(after: String? = nil) async -> GoonedFeedResponse {
        let url = URL(string: "https://x.com/home")!
        return await XWebEngine.shared.fetchFeed(
            routeKey: "x_following",
            targetURL: url,
            homeTabLabel: "Following",
            isRefresh: after == nil
        )
    }

    static func bookmarks(after: String? = nil) async -> GoonedFeedResponse {
        let url = URL(string: "https://x.com/i/bookmarks")!
        return await XWebEngine.shared.fetchFeed(
            routeKey: "x_bookmarks",
            targetURL: url,
            isRefresh: after == nil
        )
    }

    static func likes(after: String? = nil) async -> GoonedFeedResponse {
        let sn = UserStore.shared.data.xSession.screenName.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlString = sn.isEmpty
            ? "https://x.com/i/history/likes"
            : "https://x.com/\(sn)/likes"
        let url = URL(string: urlString) ?? URL(string: "https://x.com/i/history/likes")!
        return await XWebEngine.shared.fetchFeed(
            routeKey: "x_likes_\(sn.isEmpty ? "me" : sn)",
            targetURL: url,
            isRefresh: after == nil
        )
    }

    static func search(_ query: String, sort: String = "Top", after: String? = nil) async -> GoonedFeedResponse {
        await XWebEngine.shared.searchFast(query: query, sort: sort, after: after)
    }

    static func userMedia(_ username: String, after: String? = nil) async -> GoonedFeedResponse {
        let clean = username
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "@", with: "")
            .replacingOccurrences(of: "x:", with: "")
        let url = URL(string: "https://x.com/\(clean)/media") ?? URL(string: "https://x.com/home")!
        return await XWebEngine.shared.fetchFeed(
            routeKey: "x_user_\(clean.lowercased())",
            targetURL: url,
            isRefresh: after == nil
        )
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
                                    Task { await XWebEngine.shared.warmUp() }
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

        Task { await XWebEngine.shared.warmUp() }
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
