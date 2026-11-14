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
    private var routeBuffers: [String: [Gif]] = [:]
    private var seenIds = Set<String>()
    private var waiters: [(routeKey: String, cont: CheckedContinuation<[Gif], Never>)] = []
    private var pageCounter: Int = 0
    private var nextMaxIdByRoute: [String: String] = [:]
    private var dryPayloadCountByRoute: [String: Int] = [:]
    private var pumpTask: Task<Void, Never>?
    private var isEngineBusy: Bool = false
    private var lockWaiters: [CheckedContinuation<Void, Never>] = []
    private var isWarmedUp: Bool = false

    private let scrollAdvanceJS = """
    (function() {
        try {
            const evtInit = { key: 'ArrowDown', code: 'ArrowDown', keyCode: 40, which: 40, bubbles: true, cancelable: true };
            document.dispatchEvent(new KeyboardEvent('keydown', evtInit));
            if (document.activeElement) {
                document.activeElement.dispatchEvent(new KeyboardEvent('keydown', evtInit));
            }
            window.dispatchEvent(new WheelEvent('wheel', { deltaY: 960, bubbles: true, cancelable: true }));
            const main = document.querySelector('main') || document.body;
            if (main) {
                main.dispatchEvent(new WheelEvent('wheel', { deltaY: 960, bubbles: true, cancelable: true }));
            }
            const els = document.querySelectorAll('div, section, main');
            for (const el of els) {
                if (el.scrollHeight > el.clientHeight + 80) {
                    const style = window.getComputedStyle(el);
                    if (style.overflowY === 'auto' || style.overflowY === 'scroll' || style.scrollSnapType) {
                        el.scrollTop += Math.max(900, el.clientHeight);
                        el.dispatchEvent(new Event('scroll', { bubbles: true }));
                    }
                }
            }
            if (document.scrollingElement) {
                document.scrollingElement.scrollTop += 2600;
            }
            window.scrollBy(0, 2600);
            window.dispatchEvent(new Event('scroll'));
        } catch (e) {}
    })();
    """

    private func attachToKeyWindowIfNeeded(_ wv: WKWebView) {
        if wv.superview != nil { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap { $0.windows }.first(where: { $0.isKeyWindow }) ?? scenes.flatMap { $0.windows }.first
        guard let window else { return }
        wv.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        wv.alpha = 0.011 // Visible to WebKit IntersectionObserver/React without affecting UI
        wv.isUserInteractionEnabled = false
        wv.isHidden = false
        window.insertSubview(wv, at: 0)
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

    func currentMaxId(for routeKey: String) -> String? {
        nextMaxIdByRoute[routeKey]
    }

    private func extractMaxId(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: []) else { return nil }
        return findNextCursor(in: root, depth: 0)
    }

    private func findNextCursor(in obj: Any, depth: Int) -> String? {
        if depth > 14 { return nil }
        if let dict = obj as? [String: Any] {
            if let paging = dict["paging_info"] as? [String: Any],
               let maxId = paging["max_id"] as? String, !maxId.isEmpty {
                let moreAvailable = (paging["more_available"] as? Bool) ?? true
                if moreAvailable { return maxId }
            }
            if let nextMax = dict["next_max_id"] as? String, !nextMax.isEmpty {
                return nextMax
            }
            if let pageInfo = dict["page_info"] as? [String: Any],
               let endCursor = pageInfo["end_cursor"] as? String, !endCursor.isEmpty {
                let hasNext = (pageInfo["has_next_page"] as? Bool) ?? true
                if hasNext { return endCursor }
            }
            for (_, v) in dict {
                if let found = findNextCursor(in: v, depth: depth + 1) { return found }
            }
        } else if let arr = obj as? [Any] {
            for item in arr.prefix(25) {
                if let found = findNextCursor(in: item, depth: depth + 1) { return found }
            }
        }
        return nil
    }

    override private init() {
        super.init()
    }

    func warmUp() async {
        guard UserStore.shared.data.igSession.isConnected else { return }
        if isWarmedUp, let wv = webView {
            attachToKeyWindowIfNeeded(wv)
            return
        }
        let wv = await ensureWebView()
        if wv.url == nil || wv.url?.absoluteString == "about:blank" {
            activeRouteKey = "ig_reels"
            wv.load(URLRequest(url: URL(string: "https://www.instagram.com/reels/")!))
        }
        isWarmedUp = true
    }

    func ensureWebView() async -> WKWebView {
        if let existing = webView {
            attachToKeyWindowIfNeeded(existing)
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

            try {
                // Keep hidden IG videos silent and non-decoding so the engine stays fast and audio-free
                const origPlay = HTMLMediaElement.prototype.play;
                HTMLMediaElement.prototype.play = function() {
                    try { this.muted = true; this.pause(); } catch (e) {}
                    return Promise.resolve();
                };
            } catch (e) {}

            function postPayload(url, body) {
                if (!body || body.length < 20) return;
                if (body.indexOf('video_versions') === -1 && body.indexOf('video_url') === -1) return;
                if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.igBridge) {
                    window.webkit.messageHandlers.igBridge.postMessage({ type: 'payload', url: url || '', pageUrl: location.href, body: body });
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
                    document.querySelectorAll('video, audio').forEach(function(m) {
                        m.muted = true;
                        if (!m.paused) m.pause();
                    });
                } catch (e) {}
            }

            document.addEventListener('DOMContentLoaded', scanSSRScripts);
            setInterval(scanSSRScripts, 1400);
        })();
        """

        let script = WKUserScript(source: hookJS, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        config.userContentController.addUserScript(script)
        config.userContentController.add(self, name: "igBridge")

        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: config)
        wv.customUserAgent = Config.userAgent
        wv.navigationDelegate = self
        attachToKeyWindowIfNeeded(wv)
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

        let reqUrl = (body["url"] as? String ?? "").lowercased()
        let pageUrl = (body["pageUrl"] as? String ?? "").lowercased()

        // Strict route isolation: never let discovery Reels (/clips/home/) leak into Following or Saved
        if activeRouteKey == "ig_following" {
            if reqUrl.contains("clips/home") || (reqUrl == "ssr_script" && pageUrl.contains("/reels")) {
                return
            }
        } else if activeRouteKey == "ig_saved" {
            if reqUrl.contains("clips/home") || reqUrl.contains("feed/timeline") {
                return
            }
        }

        if !activeRouteKey.isEmpty, let maxId = extractMaxId(from: data) {
            nextMaxIdByRoute[activeRouteKey] = maxId
        }

        let reels = InstagramParser.parseReels(from: data)
            .filter {
                AdultContentClassifier.isEligibleIGReel(
                    caption: $0.title ?? "",
                    author: $0.author ?? "",
                    routeKey: activeRouteKey
                )
            }
        guard !reels.isEmpty else { return }

        let store = UserStore.shared
        let fresh = reels.filter {
            !store.isSeen($0)
            && !store.isBlockedByAlgorithm($0)
            && seenIds.insert($0.canonicalDedupeKey).inserted
        }
        guard !fresh.isEmpty else { return }

        dryPayloadCountByRoute[activeRouteKey] = 0
        var buf = routeBuffers[activeRouteKey] ?? []
        buf.append(contentsOf: fresh)
        routeBuffers[activeRouteKey] = buf
        flushWaitersIfNeeded(for: activeRouteKey)
        if buf.count < 18, let wv = webView {
            scheduleBackgroundPump(for: activeRouteKey, wv: wv, apiTriggerJS: nil)
        }
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

    private func scheduleBackgroundPump(for routeKey: String, wv: WKWebView, apiTriggerJS: String?) {
        guard pumpTask == nil || pumpTask?.isCancelled == true else { return }
        pumpTask = Task { @MainActor [weak self] in
            defer { self?.pumpTask = nil }
            for _ in 0..<2 {
                try? await Task.sleep(nanoseconds: 550_000_000)
                guard let self,
                      !Task.isCancelled,
                      self.activeRouteKey == routeKey,
                      (self.routeBuffers[routeKey]?.count ?? 0) < 18 else { return }
                _ = try? await wv.evaluateJavaScript(self.scrollAdvanceJS)
                if let apiTriggerJS {
                    _ = try? await wv.evaluateJavaScript(apiTriggerJS)
                }
            }
        }
    }

    func fetchFeed(
        routeKey: String,
        targetURL: URL,
        apiTriggerJS: String? = nil,
        isRefresh: Bool
    ) async -> GoonedFeedResponse {
        attachToKeyWindowIfNeededIfReady()
        // Fast-path: return buffered posts for this route immediately in 0ms without waiting on lock
        if !isRefresh, let existing = routeBuffers[routeKey], !existing.isEmpty {
            routeBuffers[routeKey] = []
            activeRouteKey = routeKey
            pageCounter += 1
            if let wv = webView {
                scheduleBackgroundPump(for: routeKey, wv: wv, apiTriggerJS: apiTriggerJS)
            }
            return GoonedFeedResponse(posts: existing, after: "igpage_\(pageCounter)")
        }

        await acquireLock()
        defer { releaseLock() }

        if !isRefresh, let existing = routeBuffers[routeKey], !existing.isEmpty {
            routeBuffers[routeKey] = []
            activeRouteKey = routeKey
            pageCounter += 1
            if let wv = webView {
                scheduleBackgroundPump(for: routeKey, wv: wv, apiTriggerJS: apiTriggerJS)
            }
            return GoonedFeedResponse(posts: existing, after: "igpage_\(pageCounter)")
        }

        let wv = await ensureWebView()
        var didLoadNewURL = false
        let dryStreak = dryPayloadCountByRoute[routeKey] ?? 0
        let forceNavigate = (isRefresh || activeRouteKey != routeKey || dryStreak >= 2)

        if forceNavigate {
            pumpTask?.cancel()
            pumpTask = nil
            activeRouteKey = routeKey
            if isRefresh {
                pageCounter = 0
                nextMaxIdByRoute[routeKey] = nil
            }
            dryPayloadCountByRoute[routeKey] = 0

            // If already on the target path and just doing an API-triggered refresh (not a dry-streak recovery), fire JS immediately
            let onTargetHost = wv.url?.host?.contains("instagram.com") == true
            let onTargetPath = wv.url?.path == targetURL.path
            if let apiTriggerJS, onTargetHost && (onTargetPath || routeKey != "ig_reels") && dryStreak < 2 {
                _ = try? await wv.evaluateJavaScript(apiTriggerJS)
                _ = try? await wv.evaluateJavaScript(scrollAdvanceJS)
            } else {
                let alreadyLoadingSame = (wv.url?.absoluteString == targetURL.absoluteString && wv.isLoading)
                if !alreadyLoadingSame || dryStreak >= 2 {
                    wv.load(URLRequest(url: targetURL))
                }
                didLoadNewURL = true
                if let apiTriggerJS {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 900_000_000)
                        _ = try? await wv.evaluateJavaScript(apiTriggerJS)
                    }
                }
            }
        } else {
            _ = try? await wv.evaluateJavaScript(scrollAdvanceJS)
            if let apiTriggerJS {
                _ = try? await wv.evaluateJavaScript(apiTriggerJS)
            }
        }

        let firstNudgeNs: UInt64 = didLoadNewURL ? 1_200_000_000 : 450_000_000
        let remainingWaitNs: UInt64 = didLoadNewURL ? 2_600_000_000 : 1_100_000_000
        let posts = await withCheckedContinuation { (cont: CheckedContinuation<[Gif], Never>) in
            self.waiters.append((routeKey: routeKey, cont: cont))
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: firstNudgeNs)
                if self.waiters.contains(where: { $0.routeKey == routeKey }) {
                    _ = try? await wv.evaluateJavaScript(self.scrollAdvanceJS)
                }
                try? await Task.sleep(nanoseconds: remainingWaitNs)
                let pending = self.waiters.filter { $0.routeKey == routeKey }
                if !pending.isEmpty {
                    self.waiters.removeAll { $0.routeKey == routeKey }
                    let fallback = self.routeBuffers[routeKey] ?? []
                    self.routeBuffers[routeKey] = []
                    if fallback.isEmpty {
                        self.dryPayloadCountByRoute[routeKey, default: 0] += 1
                    }
                    for p in pending {
                        p.cont.resume(returning: fallback)
                    }
                }
            }
        }

        scheduleBackgroundPump(for: routeKey, wv: wv, apiTriggerJS: apiTriggerJS)
        pageCounter += 1
        return GoonedFeedResponse(
            posts: posts,
            after: "igpage_\(pageCounter)"
        )
    }

    private func attachToKeyWindowIfNeededIfReady() {
        if let wv = webView {
            attachToKeyWindowIfNeeded(wv)
        }
    }

    /// Follows or unfollows an Instagram creator directly on the user's real IG account.
    @discardableResult
    func followUser(_ username: String, unfollow: Bool) async -> Bool {
        let session = UserStore.shared.data.igSession
        guard session.isConnected else { return false }
        let clean = username
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "@", with: "")
        guard !clean.isEmpty,
              let encoded = clean.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let lookupURL = URL(string: "https://www.instagram.com/api/v1/users/web_profile_info/?username=\(encoded)") else {
            return false
        }

        var cookieParts = ["sessionid=\(session.sessionId)"]
        if !session.csrfToken.isEmpty { cookieParts.append("csrftoken=\(session.csrfToken)") }
        if !session.userId.isEmpty { cookieParts.append("ds_user_id=\(session.userId)") }
        let cookieHeader = cookieParts.joined(separator: "; ")

        var lookupReq = URLRequest(url: lookupURL)
        lookupReq.timeoutInterval = 10
        lookupReq.setValue(Config.userAgent, forHTTPHeaderField: "User-Agent")
        lookupReq.setValue("936619743392459", forHTTPHeaderField: "X-IG-App-ID")
        lookupReq.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        lookupReq.setValue(cookieHeader, forHTTPHeaderField: "Cookie")

        guard let (data, _) = try? await URLSession.shared.data(for: lookupReq),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let user = ((json["data"] as? [String: Any])?["user"] as? [String: Any]),
              let targetId = user["id"] as? String, !targetId.isEmpty,
              let followURL = URL(string: "https://www.instagram.com/api/v1/web/friendships/\(targetId)/\(unfollow ? "unfollow" : "follow")/") else {
            return false
        }

        var followReq = URLRequest(url: followURL)
        followReq.httpMethod = "POST"
        followReq.timeoutInterval = 10
        followReq.setValue(Config.userAgent, forHTTPHeaderField: "User-Agent")
        followReq.setValue("936619743392459", forHTTPHeaderField: "X-IG-App-ID")
        followReq.setValue(session.csrfToken, forHTTPHeaderField: "X-CSRFToken")
        followReq.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        followReq.setValue("https://www.instagram.com/\(clean)/", forHTTPHeaderField: "Referer")
        followReq.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        followReq.httpBody = Data()

        if let (_, resp) = try? await URLSession.shared.data(for: followReq),
           let code = (resp as? HTTPURLResponse)?.statusCode,
           (200..<300).contains(code) {
            return true
        }
        return false
    }

    func resetSession() async {
        pumpTask?.cancel()
        pumpTask = nil
        isWarmedUp = false
        activeRouteKey = ""
        routeBuffers.removeAll()
        seenIds.removeAll()
        nextMaxIdByRoute.removeAll()
        dryPayloadCountByRoute.removeAll()
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
        // Only call /api/v1/clips/home/ on initial load or when we actually have a max_id cursor.
        // Calling it without max_id during pagination re-fetches page 1 duplicates and stalls scroll.
        let triggerClipsJS: String?
        if after == nil || !escapedMax.isEmpty {
            let bodyExpr = escapedMax.isEmpty
                ? "'container_module=clips_viewer_clips_tab'"
                : "'container_module=clips_viewer_clips_tab&max_id=\(escapedMax)'"
            triggerClipsJS = """
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
        } else {
            triggerClipsJS = nil
        }
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
        if after != nil && maxId.isEmpty {
            return GoonedFeedResponse(posts: [], after: nil)
        }
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
                                Task { await InstagramWebEngine.shared.warmUp() }
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
        Task { await InstagramWebEngine.shared.warmUp() }
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

