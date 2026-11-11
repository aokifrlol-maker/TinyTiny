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
    /// Recursively walks any X GraphQL or REST JSON payload and extracts all video/GIF posts as `Gif` items.
    static func parseTweets(from data: Data) -> [Gif] {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return []
        }
        var results: [Gif] = []
        var seen = Set<String>()
        walk(node: root, inheritedAuthor: nil, results: &results, seen: &seen)
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

            let currentAuthor = extractAuthor(from: dict) ?? inheritedAuthor

            // Check if this dictionary is a Tweet object with `legacy` or direct `extended_entities`
            if let gif = extractGif(fromTweetDict: dict, fallbackAuthor: currentAuthor),
               seen.insert(gif.id).inserted {
                results.append(gif)
            }

            // Continue walking children
            for (key, value) in dict {
                if key == "promotedMetadata" { continue }
                walk(node: value, inheritedAuthor: currentAuthor, results: &results, seen: &seen)
            }
        } else if let array = node as? [Any] {
            for item in array {
                walk(node: item, inheritedAuthor: inheritedAuthor, results: &results, seen: &seen)
            }
        }
    }

    private static func extractAuthor(from dict: [String: Any]) -> String? {
        // GraphQL tweet -> core -> user_results -> result -> (core | legacy) -> screen_name
        if let core = dict["core"] as? [String: Any],
           let userResults = core["user_results"] as? [String: Any],
           let result = userResults["result"] as? [String: Any] {
            if let innerCore = result["core"] as? [String: Any],
               let sn = innerCore["screen_name"] as? String, !sn.isEmpty {
                return sn
            }
            if let innerLegacy = result["legacy"] as? [String: Any],
               let sn = innerLegacy["screen_name"] as? String, !sn.isEmpty {
                return sn
            }
        }
        // REST / v1.1 tweet -> user -> screen_name
        if let user = dict["user"] as? [String: Any],
           let sn = user["screen_name"] as? String, !sn.isEmpty {
            return sn
        }
        return nil
    }

    private static func extractGif(fromTweetDict dict: [String: Any], fallbackAuthor: String?) -> Gif? {
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

            let author = extractAuthor(from: dict) ?? fallbackAuthor ?? "x_user"
            let rawText = (legacy["full_text"] as? String) ?? (legacy["text"] as? String) ?? ""
            let cleanTitle = cleanTweetText(rawText)

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
}

// MARK: - Hidden Authenticated WKWebView Engine + Interceptor (`XWebEngine`)

@MainActor
final class XWebEngine: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    static let shared = XWebEngine()

    private var webView: WKWebView?
    private var activeRouteKey: String = ""
    private var bufferedPosts: [Gif] = []
    private var seenIds = Set<String>()
    private var waiters: [CheckedContinuation<[Gif], Never>] = []
    private var pageCounter: Int = 0

    // Dynamically captured headers & GraphQL queryIds from X's own live web client
    private(set) var bearerToken: String = "AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA"
    private(set) var queryIds: [String: String] = [:]

    override private init() {
        super.init()
    }

    /// Synchronizes cookies from `UserStore` into `WKWebsiteDataStore.default()` and creates the background `WKWebView` if needed.
    func ensureWebView() async -> WKWebView {
        if let existing = webView {
            await injectStoredCookies(into: existing.configuration.websiteDataStore.httpCookieStore)
            return existing
        }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = [.all]

        let hookJS = """
        (function() {
            if (window.__goonedXHooked) return;
            window.__goonedXHooked = true;

            function shouldCapture(url) {
                if (!url) return false;
                return url.indexOf('/graphql/') !== -1 ||
                       url.indexOf('/i/api/') !== -1 ||
                       url.indexOf('/1.1/') !== -1 ||
                       url.indexOf('settings.json') !== -1;
            }

            // Capture window.fetch
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
                                window.webkit.messageHandlers.xBridge.postMessage({ type: 'payload', url: url, body: body });
                            }
                        }).catch(function(){});
                    }
                } catch (e) {}
                return resp;
            };

            // Capture XMLHttpRequest
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
                                window.webkit.messageHandlers.xBridge.postMessage({ type: 'payload', url: url, body: xhr.responseText });
                            }
                        }
                    } catch (e) {}
                });
                return origSend.apply(this, arguments);
            };

            // Periodically check for logged-in @screen_name in initial state
            setInterval(function() {
                try {
                    const html = document.documentElement ? document.documentElement.innerHTML : '';
                    const m = html.match(/"screen_name":"([A-Za-z0-9_]{1,20})"/);
                    if (m && m[1] && window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.xBridge) {
                        window.webkit.messageHandlers.xBridge.postMessage({ type: 'screenName', screenName: m[1] });
                    }
                } catch (e) {}
            }, 2500);
        })();
        """

        let userScript = WKUserScript(source: hookJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        config.userContentController.addUserScript(userScript)
        config.userContentController.add(self, name: "xBridge")

        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        wv.customUserAgent = Config.userAgent
        wv.navigationDelegate = self
        await injectStoredCookies(into: config.websiteDataStore.httpCookieStore)
        self.webView = wv
        return wv
    }

    private func injectStoredCookies(into cookieStore: WKHTTPCookieStore) async {
        let session = UserStore.shared.data.xSession
        guard session.isConnected else { return }

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

        // Learn live GraphQL queryId if present in URL (`/i/api/graphql/<queryId>/<operationName>`)
        if let range = url.range(of: "/graphql/") {
            let tail = String(url[range.upperBound...])
            let parts = tail.split(separator: "/")
            if parts.count >= 2 {
                let qid = String(parts[0])
                let op = String(parts[1].split(separator: "?").first ?? parts[1])
                queryIds[op] = qid
            }
        }

        // Check if this payload contains screen_name info
        if UserStore.shared.data.xSession.screenName.isEmpty,
           let sn = XTweetParser.parseScreenName(from: data) {
            UserStore.shared.data.xSession.screenName = sn
        }

        // Parse video tweets from intercepted GraphQL / REST payload
        let tweets = XTweetParser.parseTweets(from: data)
        guard !tweets.isEmpty else { return }

        let fresh = tweets.filter { seenIds.insert($0.id).inserted }
        guard !fresh.isEmpty else { return }

        bufferedPosts.append(contentsOf: fresh)
        flushWaitersIfNeeded()
    }

    private func flushWaitersIfNeeded() {
        guard !waiters.isEmpty, !bufferedPosts.isEmpty else { return }
        let batch = bufferedPosts
        bufferedPosts.removeAll()
        let currentWaiters = waiters
        waiters.removeAll()
        for w in currentWaiters {
            w.resume(returning: batch)
        }
    }

    // MARK: - High-Level Feed Fetcher

    func fetchFeed(
        routeKey: String,
        targetURL: URL,
        postLoadJS: String? = nil,
        isRefresh: Bool
    ) async -> GoonedFeedResponse {
        let wv = await ensureWebView()

        if isRefresh || activeRouteKey != routeKey {
            activeRouteKey = routeKey
            bufferedPosts.removeAll()
            seenIds.removeAll()
            pageCounter = 0
            wv.load(URLRequest(url: targetURL))

            if let postLoadJS {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 2_200_000_000)
                    _ = try? await wv.evaluateJavaScript(postLoadJS)
                }
            }
        } else {
            // Scroll down inside the live X page to trigger X's next GraphQL page load
            let scrollJS = """
            window.scrollBy(0, 3800);
            if (document.scrollingElement) { document.scrollingElement.scrollTop += 3800; }
            """
            _ = try? await wv.evaluateJavaScript(scrollJS)
        }

        // If we already have buffered posts waiting, return them immediately
        if !bufferedPosts.isEmpty {
            let posts = bufferedPosts
            bufferedPosts.removeAll()
            pageCounter += 1
            return GoonedFeedResponse(posts: posts, after: "xpage_\(pageCounter)")
        }

        // Otherwise wait up to 7.5 seconds for X's GraphQL response to arrive
        let posts = await withCheckedContinuation { (cont: CheckedContinuation<[Gif], Never>) in
            self.waiters.append(cont)
            Task { @MainActor in
                // Nudge scroll halfway through if still waiting
                try? await Task.sleep(nanoseconds: 3_200_000_000)
                if !self.waiters.isEmpty {
                    _ = try? await wv.evaluateJavaScript("window.scrollBy(0, 2400);")
                }
                try? await Task.sleep(nanoseconds: 4_300_000_000)
                if !self.waiters.isEmpty {
                    let pending = self.waiters
                    self.waiters.removeAll()
                    let fallback = self.bufferedPosts
                    self.bufferedPosts.removeAll()
                    for p in pending {
                        p.resume(returning: fallback)
                    }
                }
            }
        }

        pageCounter += 1
        return GoonedFeedResponse(
            posts: posts,
            after: posts.isEmpty ? nil : "xpage_\(pageCounter)"
        )
    }

    func resetSession() async {
        activeRouteKey = ""
        bufferedPosts.removeAll()
        seenIds.removeAll()
        let store = WKWebsiteDataStore.default()
        let cookies = await store.httpCookieStore.allCookies()
        for cookie in cookies where cookie.domain.contains("x.com") || cookie.domain.contains("twitter.com") {
            await store.httpCookieStore.deleteCookie(cookie)
        }
        webView?.load(URLRequest(url: URL(string: "about:blank")!))
    }
}

// MARK: - High-Level X API Facade (`XAPI`)

enum XAPI {
    /// Personal X "For You" video timeline
    @MainActor
    static func forYou(after: String?) async -> GoonedFeedResponse {
        let url = URL(string: "https://x.com/home")!
        return await XWebEngine.shared.fetchFeed(
            routeKey: "x_foryou",
            targetURL: url,
            isRefresh: after == nil
        )
    }

    /// Personal X "Following" video timeline
    @MainActor
    static func following(after: String?) async -> GoonedFeedResponse {
        let url = URL(string: "https://x.com/home")!
        let clickFollowingJS = """
        (function() {
            const tabs = document.querySelectorAll('[role="tab"]');
            for (const t of tabs) {
                if (t.innerText && t.innerText.indexOf('Following') !== -1) {
                    t.click();
                    break;
                }
            }
        })();
        """
        return await XWebEngine.shared.fetchFeed(
            routeKey: "x_following",
            targetURL: url,
            postLoadJS: clickFollowingJS,
            isRefresh: after == nil
        )
    }

    /// Personal X Bookmarks video feed
    @MainActor
    static func bookmarks(after: String?) async -> GoonedFeedResponse {
        let url = URL(string: "https://x.com/i/bookmarks")!
        return await XWebEngine.shared.fetchFeed(
            routeKey: "x_bookmarks",
            targetURL: url,
            isRefresh: after == nil
        )
    }

    /// Personal X Likes video feed
    @MainActor
    static func likes(after: String?) async -> GoonedFeedResponse {
        let handle = UserStore.shared.data.xSession.screenName
        let urlString = handle.isEmpty ? "https://x.com/home" : "https://x.com/\(handle)/likes"
        let url = URL(string: urlString) ?? URL(string: "https://x.com/home")!
        return await XWebEngine.shared.fetchFeed(
            routeKey: "x_likes_\(handle)",
            targetURL: url,
            isRefresh: after == nil
        )
    }

    /// Search X videos by keyword/hashtag/topic (supports 18+ NSFW when logged in)
    @MainActor
    static func search(_ query: String, sort: String, after: String?) async -> GoonedFeedResponse {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let fullQuery = clean.lowercased().contains("filter:") ? clean : "\(clean) filter:videos"
        let encoded = fullQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? clean
        let tabMode = (sort == "new") ? "live" : "video"
        let url = URL(string: "https://x.com/search?q=\(encoded)&src=typed_query&f=\(tabMode)")!
        return await XWebEngine.shared.fetchFeed(
            routeKey: "x_search_\(clean.lowercased())_\(tabMode)",
            targetURL: url,
            isRefresh: after == nil
        )
    }

    /// Any X creator's (`@handle`) media timeline
    @MainActor
    static func userMedia(_ handle: String, after: String?) async -> GoonedFeedResponse {
        let clean = handle
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "@", with: "")
            .replacingOccurrences(of: "u/", with: "")
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

                            TextField("ct0 cookie", text: $manualCt0)
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
                                let ct0 = manualCt0.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !auth.isEmpty, !ct0.isEmpty else { return }
                                store.data.xSession.authToken = auth
                                store.data.xSession.ct0 = ct0
                                store.data.xSession.screenName = manualHandle.replacingOccurrences(of: "@", with: "")
                                UINotificationFeedbackGenerator().notificationOccurred(.success)
                                onConnected?()
                                dismiss()
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

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.customUserAgent = Config.userAgent
        wv.isOpaque = false
        wv.backgroundColor = .black

        let url = URL(string: "https://x.com/i/flow/login")!
        wv.load(URLRequest(url: url))

        DispatchQueue.main.async {
            self.webViewRef = wv
        }
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
