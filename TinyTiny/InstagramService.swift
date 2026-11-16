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
    static func parseReels(from data: Data, routeKey: String = "") -> [Gif] {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return []
        }
        var results: [Gif] = []
        var seen = Set<String>()
        walk(node: root, inheritedAuthor: nil, inheritedFollowed: nil, routeKey: routeKey, results: &results, seen: &seen)
        return results
    }

    private static func walk(
        node: Any,
        inheritedAuthor: String?,
        inheritedFollowed: Bool?,
        routeKey: String,
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
            if routeKey == "ig_following" {
                if dict["explore_item_info"] != nil || dict["suggested_users"] != nil || dict["bloks_netego"] != nil {
                    return
                }
                if let inv = (dict["inventory_source"] as? String)?.lowercased(),
                   inv.contains("recommend") || inv.contains("explore") || inv.contains("suggest") || inv.contains("unconnected") || inv.contains("isf_") || inv.contains("chaining") {
                    return
                }
            }

            let authorMeta = extractUserMeta(from: dict)
            let author = authorMeta.username ?? inheritedAuthor
            let isFollowed = authorMeta.isFollowed ?? inheritedFollowed

            var didExtractMediaWrapper = false
            if let gif = extractGif(fromMediaDict: dict, fallbackAuthor: author, fallbackFollowed: isFollowed, routeKey: routeKey) {
                didExtractMediaWrapper = (dict["media"] != nil)
                if seen.insert(gif.canonicalDedupeKey).inserted {
                    results.append(gif)
                }
            }

            for (key, value) in dict {
                if didExtractMediaWrapper && key == "media" { continue }
                if routeKey == "ig_following" && (key == "suggested_users" || key == "clips_netego" || key == "EndOfFeedDemarcator") {
                    continue
                }
                walk(node: value, inheritedAuthor: author, inheritedFollowed: isFollowed, routeKey: routeKey, results: &results, seen: &seen)
            }
        } else if let arr = node as? [Any] {
            for item in arr {
                walk(node: item, inheritedAuthor: inheritedAuthor, inheritedFollowed: inheritedFollowed, routeKey: routeKey, results: &results, seen: &seen)
            }
        }
    }

    private static func extractUserMeta(from dict: [String: Any]) -> (username: String?, isFollowed: Bool?) {
        for key in ["user", "owner"] {
            if let u = dict[key] as? [String: Any] {
                let un = (u["username"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let fs = u["friendship_status"] as? [String: Any]
                let followed = (fs?["following"] as? Bool)
                    ?? (u["is_following"] as? Bool)
                    ?? (u["followed_by_viewer"] as? Bool)
                if un != nil || followed != nil {
                    return (un, followed)
                }
            }
        }
        return (nil, nil)
    }

    private static func extractGif(
        fromMediaDict dict: [String: Any],
        fallbackAuthor: String?,
        fallbackFollowed: Bool?,
        routeKey: String
    ) -> Gif? {
        let media = (dict["media"] as? [String: Any]) ?? dict
        if routeKey == "ig_following" {
            if let inv = (media["inventory_source"] as? String)?.lowercased(),
               inv.contains("recommend") || inv.contains("explore") || inv.contains("suggest") || inv.contains("unconnected") || inv.contains("isf_") || inv.contains("chaining") {
                return nil
            }
        }

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

        let mediaMeta = extractUserMeta(from: media)
        let author = mediaMeta.username ?? fallbackAuthor ?? "instagram"
        let isFollowed = mediaMeta.isFollowed ?? fallbackFollowed

        // Strict IG Following check: if Instagram reports `following == false` on the author, drop it
        if routeKey == "ig_following", isFollowed == false {
            return nil
        }

        let postId = "ig_\(rawId)"
        MediaMetaRegistry.register(
            postId: postId,
            creatorName: author,
            followedByViewer: isFollowed
        )

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
    private var directWebView: WKWebView?
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
    private var cachedDirectThreads: [IGDirectThread] = []

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
                if (body.indexOf('"thread_id"') !== -1 || body.indexOf('"thread_v2_id"') !== -1 || body.indexOf('"ig_thread_id"') !== -1) {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.igBridge) {
                        window.webkit.messageHandlers.igBridge.postMessage({ type: 'inbox', url: url || '', body: body });
                    }
                }
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
              let type = body["type"] as? String else { return }

        if type == "inbox",
           let jsonText = body["body"] as? String,
           let data = jsonText.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) {
            var found: [IGDirectThread] = []
            var seen = Set<String>()
            Self.extractThreadsRecursively(from: json, into: &found, seen: &seen)
            if !found.isEmpty { cachedDirectThreads = found }
            return
        }

        guard type == "payload",
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

        let reels = InstagramParser.parseReels(from: data, routeKey: activeRouteKey)
            .filter {
                AdultContentClassifier.isEligibleIGReel(
                    caption: $0.title ?? "",
                    author: $0.author ?? "",
                    routeKey: activeRouteKey
                )
            }
        guard !reels.isEmpty else { return }

        let store = UserStore.shared
        let fresh = reels.filter { post in
            guard !store.isSeen(post),
                  !store.isBlockedByAlgorithm(post) else { return false }
            if activeRouteKey == "ig_following" {
                let author = post.author ?? ""
                let viewerFollows = MediaMetaRegistry.isFollowedByViewer(postId: post.id, author: author)
                if viewerFollows == false && !store.isFollowingIGUser(author) {
                    return false
                }
            }
            return seenIds.insert(post.canonicalDedupeKey).inserted
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

    // MARK: - Admin Direct IG DM / Group Chat MP4 Sender (Strictly In-Memory)

    struct IGDirectThread: Identifiable, Hashable {
        let id: String
        let title: String
        let isGroup: Bool
        let memberCount: Int
    }

    private func fullIGCookieAndCSRF(from session: InstagramAccountSession) async -> (cookie: String, csrf: String) {
        let storeCookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
        var map: [String: String] = [:]
        for c in storeCookies where c.domain.contains("instagram.com") {
            map[c.name] = c.value
        }
        if map["sessionid"]?.isEmpty != false && !session.sessionId.isEmpty {
            map["sessionid"] = session.sessionId
        }
        if map["csrftoken"]?.isEmpty != false && !session.csrfToken.isEmpty {
            map["csrftoken"] = session.csrfToken
        }
        if map["ds_user_id"]?.isEmpty != false && !session.userId.isEmpty {
            map["ds_user_id"] = session.userId
        }
        let cookieStr = map.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        let csrf = map["csrftoken"] ?? session.csrfToken
        return (cookieStr, csrf)
    }

    private static func extractThreadsRecursively(from obj: Any, into out: inout [IGDirectThread], seen: inout Set<String>, depth: Int = 0) {
        guard depth < 14 else { return }
        if let dict = obj as? [String: Any] {
            let tid = (dict["thread_id"] as? String)
                ?? (dict["ig_thread_id"] as? String)
                ?? (dict["thread_v2_id"] as? String)
            if let tid, !tid.isEmpty, seen.insert(tid).inserted {
                let isGroup = (dict["is_group"] as? Bool) ?? false
                let users = (dict["users"] as? [[String: Any]]) ?? []
                let rawTitle = (dict["thread_title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let fallbackNames = users.compactMap { $0["username"] as? String }.prefix(3).joined(separator: ", ")
                let title = rawTitle.isEmpty ? (fallbackNames.isEmpty ? "Chat \(tid.suffix(4))" : fallbackNames) : rawTitle
                out.append(IGDirectThread(id: tid, title: title, isGroup: isGroup, memberCount: max(2, users.count + 1)))
            }
            for v in dict.values {
                extractThreadsRecursively(from: v, into: &out, seen: &seen, depth: depth + 1)
            }
        } else if let arr = obj as? [Any] {
            for item in arr {
                extractThreadsRecursively(from: item, into: &out, seen: &seen, depth: depth + 1)
            }
        }
    }

    private func ensureDirectWebView() async -> WKWebView {
        if let existing = directWebView {
            attachToKeyWindowIfNeeded(existing)
            await injectStoredCookies(into: existing.configuration.websiteDataStore.httpCookieStore)
            return existing
        }
        let mainWv = await ensureWebView()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.userContentController = mainWv.configuration.userContentController
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
        wv.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"
        wv.isHidden = true
        wv.alpha = 0.01
        wv.isUserInteractionEnabled = false
        attachToKeyWindowIfNeeded(wv)
        await injectStoredCookies(into: wv.configuration.websiteDataStore.httpCookieStore)
        self.directWebView = wv
        return wv
    }

    private func ensureOnInstagramInbox(_ wv: WKWebView) async {
        let onDirect = wv.url?.host?.contains("instagram.com") == true && wv.url?.path.contains("/direct/inbox") == true
        if !onDirect {
            wv.load(URLRequest(url: URL(string: "https://www.instagram.com/direct/inbox/")!))
            for _ in 0..<28 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                let ready = (try? await wv.evaluateJavaScript("location.origin === 'https://www.instagram.com' && document.readyState === 'complete'")) as? Bool ?? false
                if ready && !wv.isLoading { break }
            }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
        }
    }

    func fetchDirectThreads() async throws -> [IGDirectThread] {
        let session = UserStore.shared.data.igSession
        guard session.isConnected else {
            throw NSError(domain: "IGDirect", code: 401, userInfo: [NSLocalizedDescriptionKey: "Connect your Instagram account first."])
        }
        let wv = await ensureDirectWebView()
        await ensureOnInstagramInbox(wv)

        // 1. If Instagram Desktop Web's own inbox XHR/GraphQL was intercepted, return immediately
        if !cachedDirectThreads.isEmpty {
            return cachedDirectThreads
        }

        // 2. Check login redirect, SSR JSON, same-origin API, and live DOM
        let js = """
        try {
            if (location.pathname.indexOf('/accounts/login') !== -1) {
                return JSON.stringify({ ok: false, message: 'Instagram session expired — sign in again in the IG tab.' });
            }
            const csrfMatch = (document.cookie || '').match(/csrftoken=([^;]+)/);
            const csrf = (csrfMatch && csrfMatch[1]) ? csrfMatch[1] : (fallbackCsrf || '');

            // A. Scan SSR <script type="application/json"> embedded in /direct/inbox/
            let ssrThreads = [];
            const seenSSR = new Set();
            function walkSSR(obj, depth) {
                if (!obj || depth > 12) return;
                if (Array.isArray(obj)) {
                    for (const it of obj) walkSSR(it, depth + 1);
                    return;
                }
                if (typeof obj === 'object') {
                    const tid = obj.thread_id || obj.ig_thread_id || obj.thread_v2_id;
                    if (tid && typeof tid === 'string' && !seenSSR.has(tid)) {
                        seenSSR.add(tid);
                        const users = Array.isArray(obj.users) ? obj.users : [];
                        const tTitle = String(obj.thread_title || '').trim() || users.slice(0, 3).map(u => u && u.username).filter(Boolean).join(', ') || ('Chat ' + tid.slice(-4));
                        ssrThreads.push({ id: tid, isGroup: Boolean(obj.is_group), title: tTitle, memberCount: Math.max(2, users.length + 1) });
                    }
                    for (const k of Object.keys(obj)) walkSSR(obj[k], depth + 1);
                }
            }
            for (const s of document.querySelectorAll('script[type="application/json"]')) {
                try { walkSSR(JSON.parse(s.textContent || ''), 0); } catch {}
            }
            if (ssrThreads.length > 0) {
                return JSON.stringify({ ok: true, threads: ssrThreads });
            }

            // B. Try same-origin relative REST inbox
            let apiStatus = 0;
            let apiThreads = [];
            try {
                const r = await fetch('/api/v1/direct_v2/inbox/?persistentBadging=true&folder=&limit=25&thread_message_limit=5', {
                    credentials: 'include',
                    headers: {
                        'X-IG-App-ID': '936619743392459',
                        'X-CSRFToken': csrf,
                        'X-Requested-With': 'XMLHttpRequest'
                    }
                });
                apiStatus = r.status;
                if (r.ok) {
                    const data = await r.json();
                    const list = (data && data.inbox && Array.isArray(data.inbox.threads)) ? data.inbox.threads : [];
                    apiThreads = list.map(t => ({
                        id: String((t && t.thread_id) || ''),
                        isGroup: Boolean(t && t.is_group),
                        title: String((t && t.thread_title) || '').trim() || ((t && Array.isArray(t.users)) ? t.users : []).slice(0, 3).map(u => u && u.username).filter(Boolean).join(', ') || 'Direct Chat',
                        memberCount: ((t && Array.isArray(t.users)) ? t.users.length : 0) + 1
                    })).filter(t => t.id);
                }
            } catch (e1) {}
            if (apiThreads.length > 0) {
                return JSON.stringify({ ok: true, threads: apiThreads });
            }

            // C. Fallback: read rendered DM & Group Chat links from Desktop /direct/inbox/ DOM
            const tidRe = new RegExp('/direct/t/([^/?#]+)');
            for (let attempt = 0; attempt < 10; attempt++) {
                const links = Array.from(document.querySelectorAll('a[href*="/direct/t/"]'));
                if (links.length > 0) {
                    const seen = new Set();
                    const domThreads = [];
                    for (const a of links) {
                        const href = a.getAttribute('href') || '';
                        const m = href.match(tidRe);
                        if (!m) continue;
                        const id = m[1];
                        if (seen.has(id)) continue;
                        seen.add(id);
                        const lines = String(a.innerText || '').split('\\n').map(s => s.trim()).filter(Boolean);
                        const title = lines[0] || ('Chat ' + id.slice(-4));
                        domThreads.push({ id, isGroup: title.indexOf(',') !== -1, title, memberCount: 2 });
                    }
                    if (domThreads.length > 0) {
                        return JSON.stringify({ ok: true, threads: domThreads });
                    }
                }
                await new Promise(r => setTimeout(r, 350));
            }
            return JSON.stringify({ ok: false, message: 'Inbox empty on ' + location.pathname + ' (API ' + apiStatus + '). Try opening IG tab once.' });
        } catch (err) {
            return JSON.stringify({ ok: false, message: 'JS: ' + (err && err.message ? err.message : String(err)) });
        }
        """
        let rawObj = try await wv.callAsyncJavaScript(
            js,
            arguments: ["fallbackCsrf": session.csrfToken],
            in: nil,
            contentWorld: .page
        )
        if !cachedDirectThreads.isEmpty {
            return cachedDirectThreads
        }
        guard let rawStr = rawObj as? String,
              let jsonData = rawStr.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              (parsed["ok"] as? Bool) == true,
              let arr = parsed["threads"] as? [[String: Any]] else {
            let msg = ((rawObj as? String)?.data(using: .utf8)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["message"] as? String
            throw NSError(domain: "IGDirect", code: 400, userInfo: [NSLocalizedDescriptionKey: msg ?? "Could not load IG inbox."])
        }
        let result = arr.compactMap { t -> IGDirectThread? in
            guard let id = t["id"] as? String, !id.isEmpty else { return nil }
            let title = (t["title"] as? String) ?? "Direct Chat"
            let isGroup = (t["isGroup"] as? Bool) ?? false
            let count = (t["memberCount"] as? Int) ?? 2
            return IGDirectThread(id: id, title: title, isGroup: isGroup, memberCount: count)
        }
        cachedDirectThreads = result
        return result
    }

    func sendMP4ToDirectThread(threadId: String, videoURL: URL, referer: String? = nil) async throws {
        let session = UserStore.shared.data.igSession
        guard session.isConnected else {
            throw NSError(domain: "IGDirect", code: 401, userInfo: [NSLocalizedDescriptionKey: "Connect your Instagram account first."])
        }

        // 1. Buffer MP4 strictly in memory (never saved to Photos or phone storage)
        var dlReq = URLRequest(url: videoURL)
        dlReq.timeoutInterval = 45
        dlReq.setValue(Config.userAgent, forHTTPHeaderField: "User-Agent")
        if let referer, !referer.isEmpty {
            dlReq.setValue(referer, forHTTPHeaderField: "Referer")
        }
        let (mp4Data, dlResp) = try await URLSession.shared.data(for: dlReq)
        let dlCode = (dlResp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(dlCode), !mp4Data.isEmpty else {
            throw NSError(domain: "IGDirect", code: dlCode, userInfo: [NSLocalizedDescriptionKey: "Could not fetch MP4 stream (HTTP \(dlCode))."])
        }

        // 2. Upload MP4 to i.instagram.com/rupload_igvideo via native URLSession (zero CORS!)
        let auth = await fullIGCookieAndCSRF(from: session)
        let uploadId = String(Int64(Date().timeIntervalSince1970 * 1000))
        let entityName = "fb_uploader_\(uploadId)"
        guard let upURL = URL(string: "https://i.instagram.com/rupload_igvideo/\(entityName)") else {
            throw NSError(domain: "IGDirect", code: 400, userInfo: [NSLocalizedDescriptionKey: "Invalid upload URL"])
        }
        let ruploadParams: [String: Any] = [
            "media_type": 2,
            "upload_id": uploadId,
            "upload_media_height": 720,
            "upload_media_width": 720
        ]
        let paramsJSON = String(data: (try? JSONSerialization.data(withJSONObject: ruploadParams)) ?? Data(), encoding: .utf8) ?? "{}"

        var upReq = URLRequest(url: upURL)
        upReq.httpMethod = "POST"
        upReq.timeoutInterval = 60
        upReq.setValue(Config.userAgent, forHTTPHeaderField: "User-Agent")
        upReq.setValue("936619743392459", forHTTPHeaderField: "X-IG-App-ID")
        upReq.setValue("129477", forHTTPHeaderField: "X-ASBD-ID")
        upReq.setValue(auth.csrf, forHTTPHeaderField: "X-CSRFToken")
        upReq.setValue("https://www.instagram.com", forHTTPHeaderField: "Origin")
        upReq.setValue("https://www.instagram.com/", forHTTPHeaderField: "Referer")
        upReq.setValue(auth.cookie, forHTTPHeaderField: "Cookie")
        upReq.setValue(paramsJSON, forHTTPHeaderField: "X-Instagram-Rupload-Params")
        upReq.setValue(entityName, forHTTPHeaderField: "X-Entity-Name")
        upReq.setValue(String(mp4Data.count), forHTTPHeaderField: "X-Entity-Length")
        upReq.setValue("0", forHTTPHeaderField: "Offset")
        upReq.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        upReq.httpBody = mp4Data

        let (upData, upResp) = try await URLSession.shared.data(for: upReq)
        let upCode = (upResp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(upCode) else {
            let msg = (try? JSONSerialization.jsonObject(with: upData) as? [String: Any])?["message"] as? String
            throw NSError(domain: "IGDirect", code: upCode, userInfo: [NSLocalizedDescriptionKey: msg ?? "IG video upload rejected (HTTP \(upCode))."])
        }

        // 3A. Fast path: native URLSession POST to i.instagram.com/api/v1/direct_v2/threads/broadcast/configure_video/
        let clientCtx = UUID().uuidString.lowercased()
        if let sendURL = URL(string: "https://i.instagram.com/api/v1/direct_v2/threads/broadcast/configure_video/") {
            let threadArr = "[\"\(threadId)\"]"
            let bodyStr = "action=send_item&client_context=\(clientCtx)&thread_ids=\(threadArr.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? threadArr)&upload_id=\(uploadId)"
            var sendReq = URLRequest(url: sendURL)
            sendReq.httpMethod = "POST"
            sendReq.timeoutInterval = 20
            sendReq.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
            sendReq.setValue("936619743392459", forHTTPHeaderField: "X-IG-App-ID")
            sendReq.setValue("129477", forHTTPHeaderField: "X-ASBD-ID")
            sendReq.setValue(auth.csrf, forHTTPHeaderField: "X-CSRFToken")
            sendReq.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            sendReq.setValue("https://www.instagram.com", forHTTPHeaderField: "Origin")
            sendReq.setValue("https://www.instagram.com/", forHTTPHeaderField: "Referer")
            sendReq.setValue(auth.cookie, forHTTPHeaderField: "Cookie")
            sendReq.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            sendReq.httpBody = bodyStr.data(using: .utf8)

            if let (_, sendResp) = try? await URLSession.shared.data(for: sendReq),
               let code = (sendResp as? HTTPURLResponse)?.statusCode,
               (200..<300).contains(code) {
                return
            }
        }

        // 3B. Fallback: Desktop WKWebView on /direct/t/<threadId>/ using IG Web's own file input composer
        let wv = await ensureDirectWebView()
        let threadURLStr = "https://www.instagram.com/direct/t/\(threadId)/"
        if wv.url?.absoluteString.contains("/direct/t/\(threadId)") != true,
           let tURL = URL(string: threadURLStr) {
            wv.load(URLRequest(url: tURL))
            for _ in 0..<24 {
                try? await Task.sleep(nanoseconds: 250_000_000)
                let ready = (try? await wv.evaluateJavaScript("location.pathname.indexOf('/direct/t/') !== -1 && document.readyState === 'complete'")) as? Bool ?? false
                if ready && !wv.isLoading { break }
            }
            try? await Task.sleep(nanoseconds: 900_000_000)
        }

        let b64 = mp4Data.base64EncodedString()
        let domSendJS = """
        try {
            const bin = atob(mp4B64);
            const bytes = new Uint8Array(bin.length);
            for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
            const file = new File([bytes], 'video.mp4', { type: 'video/mp4' });

            let input = null;
            for (let i = 0; i < 10; i++) {
                const all = Array.from(document.querySelectorAll('input[type="file"]'));
                input = all.find(el => (el.getAttribute('accept') || '').indexOf('video') !== -1) || all[0] || null;
                if (input) break;
                await new Promise(r => setTimeout(r, 300));
            }
            if (!input) {
                return JSON.stringify({ ok: false, message: 'No file upload input found in this chat (thread may be restricted).' });
            }
            const dt = new DataTransfer();
            dt.items.add(file);
            input.files = dt.files;
            input.dispatchEvent(new Event('change', { bubbles: true }));
            input.dispatchEvent(new Event('input', { bubbles: true }));

            // Click Send button if IG shows a composer Send button after attaching
            await new Promise(r => setTimeout(r, 900));
            const btns = Array.from(document.querySelectorAll('div[role="button"], button'));
            const sendBtn = btns.find(b => /^send$/i.test((b.innerText || '').trim()));
            if (sendBtn) sendBtn.click();
            await new Promise(r => setTimeout(r, 1200));
            return JSON.stringify({ ok: true });
        } catch (err) {
            return JSON.stringify({ ok: false, message: 'JS: ' + (err && err.message ? err.message : String(err)) });
        }
        """
        let rawObj = try await wv.callAsyncJavaScript(
            domSendJS,
            arguments: ["mp4B64": b64],
            in: nil,
            contentWorld: .page
        )
        guard let rawStr = rawObj as? String,
              let jsonData = rawStr.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw NSError(domain: "IGDirect", code: 500, userInfo: [NSLocalizedDescriptionKey: "Failed to read IG send response."])
        }
        guard (parsed["ok"] as? Bool) == true else {
            let msg = (parsed["message"] as? String) ?? "IG rejected sending to this chat."
            throw NSError(domain: "IGDirect", code: 400, userInfo: [NSLocalizedDescriptionKey: msg])
        }
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
        let escapedMax = maxId.replacingOccurrences(of: "'", with: "")
        let bodyExpr = escapedMax.isEmpty
            ? "'variant=following&is_async_ads_in_headload_enabled=0'"
            : "'variant=following&max_id=\(escapedMax)&reason=pagination'"
        let triggerFeedJS = """
        (async function() {
            try {
                const csrfMatch = document.cookie.match(/csrftoken=([^;]+)/);
                const csrf = csrfMatch ? csrfMatch[1] : '';
                await fetch('https://www.instagram.com/api/v1/feed/timeline/', {
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

