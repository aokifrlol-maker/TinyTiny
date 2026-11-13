import SwiftUI
import WebKit

// MARK: - Instagram Personal Account Session

struct InstagramAccountSession: Codable, Equatable {
    var sessionId: String = ""
    var csrfToken: String = ""
    var userId: String = ""
    var username: String = ""
    var mixIntoForYou: Bool = false

    var isConnected: Bool {
        !sessionId.isEmpty
    }
}

// MARK: - Recursive Instagram GraphQL / REST v1 Video & Reel Parser

enum InstagramParser {
    static func parseReels(from data: Data) -> [Gif] {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return []
        }
        var results: [Gif] = []
        var seen = Set<String>()
        walk(node: root, inheritedAuthor: nil, results: &results, seen: &seen)
        return results
    }

    private static func walk(
        node: Any,
        inheritedAuthor: String?,
        results: inout [Gif],
        seen: inout Set<String>
    ) {
        if let dict = node as? [String: Any] {
            // Skip Instagram ads / sponsored items
            if dict["ad_id"] != nil || dict["ad_action"] != nil || dict["injected"] != nil {
                return
            }
            if let paid = dict["is_paid_partnership"] as? Bool, paid {
                return
            }

            let author = extractUsername(from: dict) ?? inheritedAuthor

            var didExtractMediaWrapper = false
            if let gif = extractGif(fromMediaDict: dict, fallbackAuthor: author) {
                didExtractMediaWrapper = (dict["media"] != nil)
                if seen.insert(gif.canonicalDedupeKey).inserted {
                    results.append(gif)
                }
            }

            for (key, value) in dict {
                if didExtractMediaWrapper && key == "media" { continue }
                walk(node: value, inheritedAuthor: author, results: &results, seen: &seen)
            }
        } else if let arr = node as? [Any] {
            for item in arr {
                walk(node: item, inheritedAuthor: inheritedAuthor, results: &results, seen: &seen)
            }
        }
    }

    private static func extractUsername(from dict: [String: Any]) -> String? {
        if let user = dict["user"] as? [String: Any],
           let un = user["username"] as? String, !un.isEmpty {
            return un
        }
        if let owner = dict["owner"] as? [String: Any],
           let un = owner["username"] as? String, !un.isEmpty {
            return un
        }
        return nil
    }

    private static func extractGif(fromMediaDict dict: [String: Any], fallbackAuthor: String?) -> Gif? {
        let media = (dict["media"] as? [String: Any]) ?? dict

        var bestMp4: String?
        var sdMp4: String?
        var width: Int? = (media["original_width"] as? Int)
        var height: Int? = (media["original_height"] as? Int)

        if let versions = media["video_versions"] as? [[String: Any]], !versions.isEmpty {
            let sorted = versions.sorted { a, b in
                let wa = (a["width"] as? Int) ?? 0
                let wb = (b["width"] as? Int) ?? 0
                return wa > wb
            }
            bestMp4 = sorted.first?["url"] as? String
            sdMp4 = sorted.last?["url"] as? String ?? bestMp4
            if width == nil { width = sorted.first?["width"] as? Int }
            if height == nil { height = sorted.first?["height"] as? Int }
        } else if let directVideoUrl = media["video_url"] as? String, !directVideoUrl.isEmpty {
            bestMp4 = directVideoUrl
            sdMp4 = directVideoUrl
            if let dims = media["dimensions"] as? [String: Any] {
                width = dims["width"] as? Int
                height = dims["height"] as? Int
            }
        }

        guard let videoUrl = bestMp4, !videoUrl.isEmpty else {
            return nil
        }

        var poster: String?
        if let imgVersions = media["image_versions2"] as? [String: Any],
           let candidates = imgVersions["candidates"] as? [[String: Any]],
           let firstUrl = candidates.first?["url"] as? String {
            poster = firstUrl
        } else if let displayUrl = media["display_url"] as? String {
            poster = displayUrl
        } else if let thumbSrc = media["thumbnail_src"] as? String {
            poster = thumbSrc
        }

        let code = (media["code"] as? String) ?? (media["shortcode"] as? String) ?? ""

        let rawCandidate: String
        if let pk = media["pk"] as? String, !pk.isEmpty {
            rawCandidate = pk
        } else if let pkInt = media["pk"] as? Int {
            rawCandidate = "\(pkInt)"
        } else if let idStr = media["id"] as? String, !idStr.isEmpty {
            rawCandidate = idStr
        } else if !code.isEmpty {
            rawCandidate = code
        } else if let urlSlug = URL(string: videoUrl)?.lastPathComponent, !urlSlug.isEmpty {
            rawCandidate = urlSlug
        } else {
            rawCandidate = UUID().uuidString
        }
        // Normalize "34567890123_987654" -> "34567890123" so REST v1 and GraphQL yield the exact same ID
        let rawId = rawCandidate.split(separator: "_").first.map(String.init) ?? rawCandidate

        let author = extractUsername(from: media) ?? fallbackAuthor ?? "instagram"

        var captionText = ""
        if let capDict = media["caption"] as? [String: Any],
           let text = capDict["text"] as? String {
            captionText = text
        } else if let edgeCap = media["edge_media_to_caption"] as? [String: Any],
                  let edges = edgeCap["edges"] as? [[String: Any]],
                  let node = edges.first?["node"] as? [String: Any],
                  let text = node["text"] as? String {
            captionText = text
        }

        let likes = (media["like_count"] as? Int)
            ?? ((media["edge_media_preview_like"] as? [String: Any])?["count"] as? Int)
            ?? 0
        let duration = media["video_duration"] as? Double
        let permalink = code.isEmpty
            ? "https://www.instagram.com/\(author)/"
            : "https://www.instagram.com/reel/\(code)/"

        return Gif(
            id: "ig_\(rawId)",
            title: captionText,
            author: author,
            subreddit: nil,
            upvotes: likes,
            duration: duration,
            width: width,
            height: height,
            mediaType: "video",
            mediaUrl: videoUrl,
            muxedUrl: sdMp4 ?? videoUrl,
            muxedUrlHd: videoUrl,
            hlsUrl: nil,
            posterUrl: poster,
            thumbnailUrl: poster,
            sourceUrl: permalink,
            permalink: permalink,
            createdUtc: nil
        )
    }
}

// MARK: - Hidden Authenticated Instagram WKWebView Engine (`InstagramWebEngine`)

@MainActor
final class InstagramWebEngine: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate {
    static let shared = InstagramWebEngine()

    private var webView: WKWebView?
    private var activeRouteKey: String = ""
    private var bufferedPosts: [Gif] = []
    private var seenIds = Set<String>()
    private var waiters: [CheckedContinuation<[Gif], Never>] = []
    private var pageCounter: Int = 0
    private var nextMaxIdByRoute: [String: String] = [:]

    func currentMaxId(for routeKey: String) -> String? {
        nextMaxIdByRoute[routeKey]
    }

    private func extractMaxId(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let paging = root["paging_info"] as? [String: Any],
           let maxId = paging["max_id"] as? String, !maxId.isEmpty {
            return maxId
        }
        if let nextMax = root["next_max_id"] as? String, !nextMax.isEmpty {
            return nextMax
        }
        return nil
    }

    override private init() {
        super.init()
    }

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
            if (window.__goonedIGHooked) return;
            window.__goonedIGHooked = true;

            function postPayload(url, body) {
                if (!body || body.length < 20) return;
                if (body.indexOf('video_versions') === -1 && body.indexOf('video_url') === -1) return;
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.igBridge) {
                    window.webkit.messageHandlers.igBridge.postMessage({ type: 'payload', url: url || '', body: body });
                }
            }

            // 1. Intercept window.fetch
            const origFetch = window.fetch;
            window.fetch = async function(...args) {
                const req = args[0];
                const url = (typeof req === 'string') ? req : (req && req.url ? req.url : '');
                const resp = await origFetch.apply(this, args);
                try {
                    const clone = resp.clone();
                    clone.text().then(function(text) {
                        postPayload(url, text);
                    }).catch(function(){});
                } catch (e) {}
                return resp;
            };

            // 2. Intercept XMLHttpRequest
            const origOpen = XMLHttpRequest.prototype.open;
            const origSend = XMLHttpRequest.prototype.send;
            XMLHttpRequest.prototype.open = function(method, url) {
                this.__goonedIGUrl = url;
                return origOpen.apply(this, arguments);
            };
            XMLHttpRequest.prototype.send = function() {
                const xhr = this;
                xhr.addEventListener('load', function() {
                    try {
                        postPayload(xhr.__goonedIGUrl || '', xhr.responseText || '');
                    } catch (e) {}
                });
                return origSend.apply(this, arguments);
            };

            // 3. Scan SSR <script type="application/json"> tags embedded in Instagram HTML
            function scanSSRScripts() {
                try {
                    const scripts = document.querySelectorAll('script[type="application/json"]');
                    for (const s of scripts) {
                        if (s.__goonedScanned) continue;
                        s.__goonedScanned = true;
                        const text = s.textContent || '';
                        postPayload('ssr_script', text);
                    }
                } catch (e) {}
            }

            document.addEventListener('DOMContentLoaded', scanSSRScripts);
            setInterval(scanSSRScripts, 1800);
        })();
        """

        let script = WKUserScript(source: hookJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        config.userContentController.addUserScript(script)
        config.userContentController.add(self, name: "igBridge")

        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        wv.customUserAgent = Config.userAgent
        wv.navigationDelegate = self
        await injectStoredCookies(into: config.websiteDataStore.httpCookieStore)
        self.webView = wv
        return wv
    }

    private func injectStoredCookies(into cookieStore: WKHTTPCookieStore) async {
        let session = UserStore.shared.data.igSession
        guard session.isConnected else { return }

        var cookiesToSet: [(String, String)] = [("sessionid", session.sessionId)]
        if !session.csrfToken.isEmpty { cookiesToSet.append(("csrftoken", session.csrfToken)) }
        if !session.userId.isEmpty { cookiesToSet.append(("ds_user_id", session.userId)) }

        for (name, val) in cookiesToSet {
            if let cookie = HTTPCookie(properties: [
                .domain: ".instagram.com",
                .path: "/",
                .name: name,
                .value: val,
                .secure: "TRUE",
                .expires: Date(timeIntervalSinceNow: 31_536_000)
            ]) {
                await cookieStore.setCookie(cookie)
            }
        }
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String,
              type == "payload",
              let jsonText = body["body"] as? String,
              let data = jsonText.data(using: .utf8) else { return }

        if !activeRouteKey.isEmpty, let maxId = extractMaxId(from: data) {
            nextMaxIdByRoute[activeRouteKey] = maxId
        }

        let reels = InstagramParser.parseReels(from: data)
        guard !reels.isEmpty else { return }

        let store = UserStore.shared
        let fresh = reels.filter { !store.isSeen($0) && seenIds.insert($0.canonicalDedupeKey).inserted }
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

    func fetchFeed(
        routeKey: String,
        targetURL: URL,
        apiTriggerJS: String? = nil,
        isRefresh: Bool
    ) async -> GoonedFeedResponse {
        let wv = await ensureWebView()

        if isRefresh || activeRouteKey != routeKey {
            activeRouteKey = routeKey
            bufferedPosts.removeAll()
            // Keep seenIds across refreshes so previously delivered reels never repeat
            pageCounter = 0
            wv.load(URLRequest(url: targetURL))

            if let apiTriggerJS {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    _ = try? await wv.evaluateJavaScript(apiTriggerJS)
                }
            }
        } else {
            let scrollJS = """
            window.scrollBy(0, 3200);
            if (document.scrollingElement) { document.scrollingElement.scrollTop += 3200; }
            window.dispatchEvent(new Event('scroll'));
            """
            _ = try? await wv.evaluateJavaScript(scrollJS)
            if let apiTriggerJS {
                _ = try? await wv.evaluateJavaScript(apiTriggerJS)
            }
        }

        if !bufferedPosts.isEmpty {
            let posts = bufferedPosts
            bufferedPosts.removeAll()
            pageCounter += 1
            return GoonedFeedResponse(posts: posts, after: "igpage_\(pageCounter)")
        }

        let posts = await withCheckedContinuation { (cont: CheckedContinuation<[Gif], Never>) in
            self.waiters.append(cont)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                if !self.waiters.isEmpty {
                    _ = try? await wv.evaluateJavaScript("window.scrollBy(0, 2400); window.dispatchEvent(new Event('scroll'));")
                }
                try? await Task.sleep(nanoseconds: 2_800_000_000)
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
            after: "igpage_\(pageCounter)"
        )
    }

    func resetSession() async {
        activeRouteKey = ""
        bufferedPosts.removeAll()
        seenIds.removeAll()
        nextMaxIdByRoute.removeAll()
        let store = WKWebsiteDataStore.default()
        let cookies = await store.httpCookieStore.allCookies()
        for c in cookies where c.domain.contains("instagram.com") {
            await store.httpCookieStore.deleteCookie(c)
        }
        webView?.load(URLRequest(url: URL(string: "about:blank")!))
    }
}

// MARK: - High-Level Instagram API Facade (`InstagramAPI`)

enum InstagramAPI {
    /// Personal Instagram Reels feed
    @MainActor
    static func reels(after: String?) async -> GoonedFeedResponse {
        let url = URL(string: "https://www.instagram.com/reels/")!
        let maxId = after != nil ? (InstagramWebEngine.shared.currentMaxId(for: "ig_reels") ?? "") : ""
        let escapedMax = maxId.replacingOccurrences(of: "'", with: "")
        let bodyExpr = escapedMax.isEmpty
            ? "'container_module=clips_viewer_clips_tab'"
            : "'container_module=clips_viewer_clips_tab&max_id=\(escapedMax)'"
        let triggerClipsJS = """
        (async function() {
            try {
                const csrfMatch = document.cookie.match(/csrftoken=([^;]+)/);
                const csrf = csrfMatch ? csrfMatch[1] : '';
                await fetch('https://www.instagram.com/api/v1/clips/home/', {
                    method: 'POST',
                    headers: {
                        'X-IG-App-ID': '936619743392459',
                        'X-CSRFToken': csrf,
                        'X-Requested-With': 'XMLHttpRequest',
                        'Content-Type': 'application/x-www-form-urlencoded'
                    },
                    body: \(bodyExpr)
                });
            } catch (e) {}
        })();
        """
        return await InstagramWebEngine.shared.fetchFeed(
            routeKey: "ig_reels",
            targetURL: url,
            apiTriggerJS: triggerClipsJS,
            isRefresh: after == nil
        )
    }

    /// Personal Instagram Following video feed
    @MainActor
    static func following(after: String?) async -> GoonedFeedResponse {
        let url = URL(string: "https://www.instagram.com/?variant=following")!
        let maxId = after != nil ? (InstagramWebEngine.shared.currentMaxId(for: "ig_following") ?? "") : ""
        let query = maxId.isEmpty ? "" : "?max_id=\(maxId)"
        let triggerFeedJS = """
        (async function() {
            try {
                await fetch('https://www.instagram.com/api/v1/feed/timeline/\(query)', {
                    headers: {
                        'X-IG-App-ID': '936619743392459',
                        'X-Requested-With': 'XMLHttpRequest'
                    }
                });
            } catch (e) {}
        })();
        """
        return await InstagramWebEngine.shared.fetchFeed(
            routeKey: "ig_following",
            targetURL: url,
            apiTriggerJS: triggerFeedJS,
            isRefresh: after == nil
        )
    }

    /// Personal Instagram Saved / Bookmarked Reels
    @MainActor
    static func saved(after: String?) async -> GoonedFeedResponse {
        let url = URL(string: "https://www.instagram.com/reels/")!
        let maxId = after != nil ? (InstagramWebEngine.shared.currentMaxId(for: "ig_saved") ?? "") : ""
        let query = maxId.isEmpty ? "" : "?max_id=\(maxId)"
        let triggerSavedJS = """
        (async function() {
            try {
                await fetch('https://www.instagram.com/api/v1/feed/saved/posts/\(query)', {
                    headers: {
                        'X-IG-App-ID': '936619743392459',
                        'X-Requested-With': 'XMLHttpRequest'
                    }
                });
            } catch (e) {}
        })();
        """
        return await InstagramWebEngine.shared.fetchFeed(
            routeKey: "ig_saved",
            targetURL: url,
            apiTriggerJS: triggerSavedJS,
            isRefresh: after == nil
        )
    }

    /// Any Instagram creator's (`@username`) Reels & video timeline
    @MainActor
    static func userReels(_ username: String, after: String?) async -> GoonedFeedResponse {
        let clean = username
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "@", with: "")
            .replacingOccurrences(of: "ig:", with: "")
        let url = URL(string: "https://www.instagram.com/\(clean)/reels/") ?? URL(string: "https://www.instagram.com/reels/")!
        let triggerProfileJS = """
        (async function() {
            try {
                await fetch('https://www.instagram.com/api/v1/users/web_profile_info/?username=\(clean)', {
                    headers: {
                        'X-IG-App-ID': '936619743392459',
                        'X-Requested-With': 'XMLHttpRequest'
                    }
                });
            } catch (e) {}
        })();
        """
        return await InstagramWebEngine.shared.fetchFeed(
            routeKey: "ig_user_\(clean.lowercased())",
            targetURL: url,
            apiTriggerJS: triggerProfileJS,
            isRefresh: after == nil
        )
    }
}

// MARK: - In-App Personal Instagram Login Sheet (`InstagramLoginSheet`)

struct InstagramLoginSheet: View {
    var onConnected: (() -> Void)? = nil
    @EnvironmentObject var store: UserStore
    @Environment(\.dismiss) private var dismiss

    @State private var statusText = "Sign in to your personal Instagram account"
    @State private var showManualEntry = false
    @State private var manualSessionId = ""
    @State private var manualCsrf = ""
    @State private var manualUsername = ""
    @State private var webViewRef: WKWebView?

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.modalGradient.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Header
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color(red: 0.98, green: 0.35, blue: 0.35),
                                            Color(red: 0.85, green: 0.18, blue: 0.56),
                                            Color(red: 0.55, green: 0.22, blue: 0.85)
                                        ],
                                        startPoint: .bottomLeading,
                                        endPoint: .topTrailing
                                    )
                                )
                                .frame(width: 36, height: 36)
                            Image(systemName: "camera.fill")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.white)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Connect Instagram")
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
                                }
                                dismiss()
                            }
                        } label: {
                            Text("Done")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 8)
                                .liquidGlassCapsule(active: store.data.igSession.isConnected)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)

                    if showManualEntry {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("MANUAL COOKIE LOGIN (OPTIONAL)")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.6))

                            TextField("sessionid cookie", text: $manualSessionId)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.system(size: 14, design: .monospaced))
                                .padding(10)
                                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))

                            TextField("csrftoken cookie (optional)", text: $manualCsrf)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.system(size: 14, design: .monospaced))
                                .padding(10)
                                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))

                            TextField("@username (optional)", text: $manualUsername)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(.system(size: 14))
                                .padding(10)
                                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))

                            Button {
                                let sid = manualSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !sid.isEmpty else { return }
                                store.data.igSession.sessionId = sid
                                store.data.igSession.csrfToken = manualCsrf.trimmingCharacters(in: .whitespacesAndNewlines)
                                store.data.igSession.username = manualUsername.replacingOccurrences(of: "@", with: "")
                                UINotificationFeedbackGenerator().notificationOccurred(.success)
                                onConnected?()
                                dismiss()
                            } label: {
                                Text("Save Session Cookie")
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

                    InstagramLoginWebViewRepresentable(webViewRef: $webViewRef)
                        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .padding(.horizontal, 8)
                        .padding(.bottom, 8)
                }
            }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if await checkAndCaptureCookies() {
                        statusText = "Connected! Loading your Instagram Reels..."
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

        var sessionId = ""
        var csrf = ""
        var dsUserId = ""

        for c in cookies where c.domain.contains("instagram.com") {
            if c.name == "sessionid" && !c.value.isEmpty {
                sessionId = c.value
            } else if c.name == "csrftoken" && !c.value.isEmpty {
                csrf = c.value
            } else if c.name == "ds_user_id" && !c.value.isEmpty {
                dsUserId = c.value
            }
        }

        guard !sessionId.isEmpty else { return false }

        store.data.igSession.sessionId = sessionId
        store.data.igSession.csrfToken = csrf
        store.data.igSession.userId = dsUserId
        return true
    }
}

struct InstagramLoginWebViewRepresentable: UIViewRepresentable {
    @Binding var webViewRef: WKWebView?

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.customUserAgent = Config.userAgent
        wv.isOpaque = false
        wv.backgroundColor = .black

        let url = URL(string: "https://www.instagram.com/accounts/login/")!
        wv.load(URLRequest(url: url))

        DispatchQueue.main.async {
            self.webViewRef = wv
        }
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

