import SwiftUI
import WebKit

// MARK: - Personal Reddit Account Session (Isolated from Regular For You Unless Opted In)

struct RedditAccountSession: Codable, Equatable {
    var redditSessionCookie: String = ""
    var tokenV2: String = ""
    var username: String = ""
    var mixIntoForYou: Bool = false

    var isConnected: Bool {
        !username.isEmpty && (!redditSessionCookie.isEmpty || !tokenV2.isEmpty)
    }

    var cookieHeader: String {
        var parts: [String] = ["over18=1"]
        if !redditSessionCookie.isEmpty {
            parts.append("reddit_session=\(redditSessionCookie)")
        }
        if !tokenV2.isEmpty {
            parts.append("token_v2=\(tokenV2)")
        }
        return parts.joined(separator: "; ")
    }
}

// MARK: - Personal Reddit API (Direct Authenticated JSON Listings)

final class RedditPersonalAPI {
    static let shared = RedditPersonalAPI()

    fileprivate let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 18
        cfg.timeoutIntervalForResource = 30
        cfg.httpShouldSetCookies = false
        return URLSession(configuration: cfg)
    }()

    private static let mobileUA = Config.userAgent
    private static let isoLock = NSLock()
    private nonisolated(unsafe) static let isoFormatter = ISO8601DateFormatter()

    func homeFeed(after: String?) async throws -> GoonedFeedResponse {
        try await fetchListing(path: "/.json", after: after)
    }

    func popularFeed(after: String?) async throws -> GoonedFeedResponse {
        try await fetchListing(path: "/r/popular.json", after: after)
    }

    func savedFeed(after: String?) async throws -> GoonedFeedResponse {
        let uname = await MainActor.run { UserStore.shared.data.redditSession.username }
        guard !uname.isEmpty else { return GoonedFeedResponse(posts: [], after: nil) }
        return try await fetchListing(path: "/user/\(uname)/saved.json", after: after)
    }

    func upvotedFeed(after: String?) async throws -> GoonedFeedResponse {
        let uname = await MainActor.run { UserStore.shared.data.redditSession.username }
        guard !uname.isEmpty else { return GoonedFeedResponse(posts: [], after: nil) }
        return try await fetchListing(path: "/user/\(uname)/upvoted.json", after: after)
    }

    private func fetchListing(path: String, after: String?) async throws -> GoonedFeedResponse {
        let rd = await MainActor.run { UserStore.shared.data.redditSession }
        guard rd.isConnected else { return GoonedFeedResponse(posts: [], after: nil) }

        var comps = URLComponents(string: "https://www.reddit.com\(path)")!
        var items = [
            URLQueryItem(name: "raw_json", value: "1"),
            URLQueryItem(name: "limit", value: "35")
        ]
        if let after, !after.isEmpty {
            items.append(URLQueryItem(name: "after", value: after))
        }
        comps.queryItems = items
        guard let url = comps.url else { return GoonedFeedResponse(posts: [], after: nil) }

        var req = URLRequest(url: url)
        req.setValue(Self.mobileUA, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(rd.cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue("https://www.reddit.com/", forHTTPHeaderField: "Referer")

        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            return GoonedFeedResponse(posts: [], after: nil)
        }
        return Self.parseListing(data)
    }

    static func parseListing(_ data: Data) -> GoonedFeedResponse {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let listing = root["data"] as? [String: Any],
              let children = listing["children"] as? [[String: Any]] else {
            return GoonedFeedResponse(posts: [], after: nil)
        }
        let nextAfter = listing["after"] as? String
        var posts: [Gif] = []
        var seen = Set<String>()

        for child in children {
            guard let raw = child["data"] as? [String: Any] else { continue }
            guard let postId = raw["id"] as? String, !postId.isEmpty else { continue }
            let gid = "rd_\(postId)"
            guard seen.insert(gid).inserted else { continue }

            let mediaNode: [String: Any]
            if let cross = (raw["crosspost_parent_list"] as? [[String: Any]])?.first {
                mediaNode = cross
            } else {
                mediaNode = raw
            }

            let title = (raw["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let author = raw["author"] as? String
            let subreddit = raw["subreddit"] as? String
            let ups = raw["ups"] as? Int ?? raw["score"] as? Int ?? 0
            let permalinkPath = raw["permalink"] as? String ?? ""
            let permalink = permalinkPath.isEmpty ? "https://www.reddit.com/comments/\(postId)" : "https://www.reddit.com\(permalinkPath)"
            let createdEpoch = raw["created_utc"] as? Double
            let createdISO: String? = createdEpoch.map { epoch in
                Self.isoLock.lock()
                let s = Self.isoFormatter.string(from: Date(timeIntervalSince1970: epoch))
                Self.isoLock.unlock()
                return s
            }

            let thumb = extractThumb(from: mediaNode) ?? extractThumb(from: raw)
            let media = extractMedia(from: mediaNode) ?? extractMedia(from: raw)
            guard let media else { continue }

            MediaMetaRegistry.register(
                postId: gid,
                extraVideoURLs: media.extraVideos,
                tags: subreddit.map { [$0.lowercased()] } ?? [],
                creatorName: author
            )
            if media.galleryItems.count > 1 {
                MediaMetaRegistry.registerAlbumItems(postId: gid, items: media.galleryItems)
            }

            posts.append(
                Gif(
                    id: gid,
                    title: title.isEmpty ? (subreddit.map { "r/\($0)" } ?? "Reddit") : title,
                    author: author,
                    subreddit: subreddit,
                    upvotes: ups,
                    duration: media.duration,
                    width: media.width,
                    height: media.height,
                    mediaType: media.isImage ? "image" : "video",
                    mediaUrl: media.primaryURL,
                    muxedUrl: media.isImage ? nil : (media.sdURL ?? media.primaryURL),
                    muxedUrlHd: media.isImage ? nil : (media.hdURL ?? media.primaryURL),
                    hlsUrl: media.isImage ? nil : media.hlsURL,
                    posterUrl: thumb ?? (media.isImage ? media.primaryURL : nil),
                    thumbnailUrl: thumb ?? (media.isImage ? media.primaryURL : nil),
                    sourceUrl: permalink,
                    permalink: permalink,
                    createdUtc: createdISO
                )
            )
        }
        return GoonedFeedResponse(posts: posts, after: nextAfter)
    }

    private struct ExtractedMedia {
        let isImage: Bool
        let primaryURL: String
        let sdURL: String?
        let hdURL: String?
        let hlsURL: String?
        let extraVideos: [String]
        let galleryItems: [AlbumMediaItem]
        let width: Int?
        let height: Int?
        let duration: Double?
    }

    private static func extractThumb(from node: [String: Any]) -> String? {
        if let preview = node["preview"] as? [String: Any],
           let images = preview["images"] as? [[String: Any]],
           let first = images.first,
           let src = first["source"] as? [String: Any],
           let url = src["url"] as? String,
           url.hasPrefix("http") {
            return url.replacingOccurrences(of: "&amp;", with: "&")
        }
        if let t = node["thumbnail"] as? String, t.hasPrefix("http") {
            return t.replacingOccurrences(of: "&amp;", with: "&")
        }
        return nil
    }

    private static func extractMedia(from node: [String: Any]) -> ExtractedMedia? {
        // 1. Native Reddit Video — ALWAYS prefer HLS (.m3u8) so audio is muxed (fallback_url is video-only!)
        let rv = (node["secure_media"] as? [String: Any])?["reddit_video"] as? [String: Any]
            ?? (node["media"] as? [String: Any])?["reddit_video"] as? [String: Any]
            ?? (node["preview"] as? [String: Any])?["reddit_video_preview"] as? [String: Any]

        if let rv {
            let hls = (rv["hls_url"] as? String)?.replacingOccurrences(of: "&amp;", with: "&").trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = (rv["fallback_url"] as? String)?.replacingOccurrences(of: "&amp;", with: "&").trimmingCharacters(in: .whitespacesAndNewlines)
            let scrubber = (rv["scrubber_media_url"] as? String)?.replacingOccurrences(of: "&amp;", with: "&").trimmingCharacters(in: .whitespacesAndNewlines)
            let candidates = [hls, fallback, scrubber].compactMap { $0 }.filter { !$0.isEmpty }
            if let primary = candidates.first {
                return ExtractedMedia(
                    isImage: false,
                    primaryURL: primary,
                    sdURL: hls ?? fallback ?? primary,
                    hdURL: hls ?? fallback ?? primary,
                    hlsURL: hls,
                    extraVideos: candidates,
                    galleryItems: [],
                    width: rv["width"] as? Int,
                    height: rv["height"] as? Int,
                    duration: rv["duration"] as? Double ?? (rv["duration"] as? Int).map(Double.init)
                )
            }
        }

        // 2. Preview MP4 variant (animated GIFs / imgur / redgifs embeds)
        if let preview = node["preview"] as? [String: Any],
           let images = preview["images"] as? [[String: Any]],
           let first = images.first,
           let variants = first["variants"] as? [String: Any],
           let mp4 = variants["mp4"] as? [String: Any],
           let src = mp4["source"] as? [String: Any],
           let mp4URL = (src["url"] as? String)?.replacingOccurrences(of: "&amp;", with: "&"),
           mp4URL.hasPrefix("http") {
            return ExtractedMedia(
                isImage: false,
                primaryURL: mp4URL,
                sdURL: mp4URL,
                hdURL: mp4URL,
                hlsURL: nil,
                extraVideos: [mp4URL],
                galleryItems: [],
                width: src["width"] as? Int,
                height: src["height"] as? Int,
                duration: nil
            )
        }

        // 3. Reddit Gallery (preserve gallery_data.items order + register all slides)
        if let gallery = node["media_metadata"] as? [String: Any] {
            var orderedIds: [String] = []
            if let gData = node["gallery_data"] as? [String: Any],
               let gItems = gData["items"] as? [[String: Any]] {
                orderedIds = gItems.compactMap { $0["media_id"] as? String }
            }
            if orderedIds.isEmpty {
                orderedIds = Array(gallery.keys)
            }
            var slides: [AlbumMediaItem] = []
            var firstW: Int? = nil
            var firstH: Int? = nil
            for (idx, mid) in orderedIds.enumerated() {
                guard let item = gallery[mid] as? [String: Any],
                      let s = item["s"] as? [String: Any],
                      let u = (s["u"] as? String ?? s["gif"] as? String)?.replacingOccurrences(of: "&amp;", with: "&"),
                      u.hasPrefix("http"),
                      let urlObj = URL(string: u) else { continue }
                if firstW == nil { firstW = s["x"] as? Int }
                if firstH == nil { firstH = s["y"] as? Int }
                slides.append(AlbumMediaItem(id: "rdg_\(mid)_\(idx)", url: urlObj, posterURL: urlObj, isVideo: false))
            }
            if let first = slides.first {
                return ExtractedMedia(
                    isImage: true,
                    primaryURL: first.url.absoluteString,
                    sdURL: nil,
                    hdURL: nil,
                    hlsURL: nil,
                    extraVideos: [],
                    galleryItems: slides,
                    width: firstW,
                    height: firstH,
                    duration: nil
                )
            }
        }

        // 4. Direct URL (mp4 / gifv / image — strip ?query before extension check!)
        let rawURL = ((node["url_overridden_by_dest"] as? String) ?? (node["url"] as? String) ?? "")
            .replacingOccurrences(of: "&amp;", with: "&")
        let lower = rawURL.lowercased()
        let pathOnly = lower.split(separator: "?", maxSplits: 1).first.map(String.init) ?? lower
        if lower.hasPrefix("http") {
            if pathOnly.hasSuffix(".mp4") || pathOnly.hasSuffix(".mov") || lower.contains(".mp4?") {
                return ExtractedMedia(isImage: false, primaryURL: rawURL, sdURL: rawURL, hdURL: rawURL, hlsURL: nil, extraVideos: [rawURL], galleryItems: [], width: nil, height: nil, duration: nil)
            }
            if pathOnly.hasSuffix(".gifv") {
                let mp4 = String(rawURL.dropLast(5)) + ".mp4"
                return ExtractedMedia(isImage: false, primaryURL: mp4, sdURL: mp4, hdURL: mp4, hlsURL: nil, extraVideos: [mp4], galleryItems: [], width: nil, height: nil, duration: nil)
            }
            if lower.contains("i.redd.it/") || lower.contains("preview.redd.it/") ||
                pathOnly.hasSuffix(".jpg") || pathOnly.hasSuffix(".jpeg") ||
                pathOnly.hasSuffix(".png") || pathOnly.hasSuffix(".webp") || pathOnly.hasSuffix(".gif") {
                return ExtractedMedia(isImage: true, primaryURL: rawURL, sdURL: nil, hdURL: nil, hlsURL: nil, extraVideos: [], galleryItems: [], width: nil, height: nil, duration: nil)
            }
        }

        return nil
    }

    static func clearCookies() async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        let all = await store.allCookies()
        for c in all where c.domain.lowercased().contains("reddit.com") {
            await store.deleteCookie(c)
        }
    }

    static func verifyUsername(cookieHeader: String) async -> String? {
        guard let url = URL(string: "https://www.reddit.com/api/me.json") else { return nil }
        var req = URLRequest(url: url)
        req.setValue(mobileUA, forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue("https://www.reddit.com/", forHTTPHeaderField: "Referer")
        guard let (data, resp) = try? await RedditPersonalAPI.shared.session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let me = root["data"] as? [String: Any],
              let name = me["name"] as? String,
              !name.isEmpty else {
            return nil
        }
        return name
    }
}

// MARK: - Personal Reddit Login Sheet (WKWebView + Google / Apple OAuth Popup Support)

struct RedditLoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: UserStore
    var onSuccess: () -> Void

    @State private var statusText = "Sign in · Google account? Or tap 'Email me a one-time link'"

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                RedditLoginWebView { sessionCookie, tokenV2, username in
                    Task { @MainActor in
                        let keepMix = store.data.redditSession.mixIntoForYou
                        store.data.redditSession = RedditAccountSession(
                            redditSessionCookie: sessionCookie,
                            tokenV2: tokenV2,
                            username: username,
                            mixIntoForYou: keepMix
                        )
                        store.saveNow()
                        onSuccess()
                        dismiss()
                    }
                } onStatus: { msg in
                    statusText = msg
                }

                HStack(spacing: 8) {
                    Image(systemName: "lock.shield.fill")
                        .foregroundStyle(Color(red: 1.0, green: 0.27, blue: 0.0))
                    Text(statusText)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 16)
            }
            .navigationTitle("Connect Reddit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}

private struct RedditLoginWebView: UIViewRepresentable {
    var onCaptured: (String, String, String) -> Void
    var onStatus: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCaptured: onCaptured, onStatus: onStatus)
    }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        cfg.allowsInlineMediaPlayback = true
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = true
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true

        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.customUserAgent = Config.userAgent
        wv.isOpaque = false
        wv.backgroundColor = .black
        wv.uiDelegate = context.coordinator
        wv.navigationDelegate = context.coordinator
        context.coordinator.parentWebView = wv

        wv.load(URLRequest(url: URL(string: "https://www.reddit.com/login")!))
        context.coordinator.startPolling(webView: wv)
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.stopPolling()
        coordinator.dismissPopup()
        uiView.uiDelegate = nil
        uiView.navigationDelegate = nil
    }

    final class Coordinator: NSObject, WKUIDelegate, WKNavigationDelegate {
        let onCaptured: (String, String, String) -> Void
        let onStatus: (String) -> Void
        weak var parentWebView: WKWebView?
        private var popupWebView: WKWebView?
        private var closeButton: UIButton?
        private var pollTask: Task<Void, Never>?
        private var didCapture = false
        private var isCheckingCookies = false

        init(onCaptured: @escaping (String, String, String) -> Void, onStatus: @escaping (String) -> Void) {
            self.onCaptured = onCaptured
            self.onStatus = onStatus
        }

        /// Supports Google & Apple OAuth popups (`window.open` / `target="_blank"`) while preserving `window.opener`.
        /// IMPORTANT: Never reassign `configuration.websiteDataStore` here — WebKit binds it to the opener process pool!
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if navigationAction.targetFrame == nil {
                let popup = WKWebView(frame: webView.bounds, configuration: configuration)
                popup.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                // Desktop Safari UA avoids Google's mobile WKWebView 403 disallowed_useragent block
                popup.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15"
                popup.uiDelegate = self
                popup.navigationDelegate = self
                popup.backgroundColor = .systemBackground
                webView.addSubview(popup)

                let closeBtn = UIButton(type: .system)
                closeBtn.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
                closeBtn.tintColor = .white
                closeBtn.backgroundColor = UIColor.black.withAlphaComponent(0.65)
                closeBtn.layer.cornerRadius = 16
                closeBtn.frame = CGRect(x: max(12, webView.bounds.width - 46), y: 12, width: 32, height: 32)
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
                if let parent = parentWebView {
                    Task { @MainActor [weak self, weak parent] in
                        guard let self, let parent else { return }
                        await self.checkCookies(in: parent)
                    }
                }
            }
        }

        @objc func dismissPopup() {
            popupWebView?.stopLoading()
            popupWebView?.removeFromSuperview()
            popupWebView = nil
            closeButton?.removeFromSuperview()
            closeButton = nil
        }

        func startPolling(webView: WKWebView) {
            stopPolling()
            pollTask = Task { @MainActor [weak self, weak webView] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_400_000_000)
                    guard let self, let webView, !self.didCapture else { break }
                    await self.checkCookies(in: webView)
                }
            }
        }

        func stopPolling() {
            pollTask?.cancel()
            pollTask = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor [weak self, weak webView] in
                guard let self, let webView, !self.didCapture else { return }
                await self.checkCookies(in: webView)
            }
        }

        @MainActor
        private func checkCookies(in webView: WKWebView) async {
            guard !didCapture, !isCheckingCookies else { return }
            isCheckingCookies = true
            defer { isCheckingCookies = false }

            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            let rdCookies = cookies.filter { $0.domain.lowercased().contains("reddit.com") && !$0.value.isEmpty }
            let sessionVal = rdCookies.first(where: { $0.name == "reddit_session" })?.value ?? ""
            let tokenVal = rdCookies.first(where: { $0.name == "token_v2" })?.value ?? ""
            guard !sessionVal.isEmpty || !tokenVal.isEmpty else { return }

            let tempSession = RedditAccountSession(redditSessionCookie: sessionVal, tokenV2: tokenVal, username: "")
            if let uname = await RedditPersonalAPI.verifyUsername(cookieHeader: tempSession.cookieHeader) {
                guard !didCapture else { return }
                didCapture = true
                stopPolling()
                dismissPopup()
                onStatus("Connected as u/\(uname)!")
                onCaptured(sessionVal, tokenVal, uname)
            }
        }
    }
}
