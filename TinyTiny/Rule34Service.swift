import SwiftUI
import WebKit

// MARK: - Rule34.xxx Credentials & Models

struct Rule34Credentials: Codable, Equatable {
    var userId: String = ""
    var apiKey: String = ""

    var isConnected: Bool {
        !userId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct Rule34TagSuggestion: Codable, Identifiable, Hashable {
    var label: String
    var value: String
    var id: String { value }
}

// MARK: - Multi-Engine Rule34 Service (Direct api.rule34.xxx + Zero-Auth Booru & Gooned R34 Network)

actor Rule34API {
    static let shared = Rule34API()

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 16
        cfg.httpAdditionalHeaders = [
            "User-Agent": "GoonedR34Client/2.0 (iOS; Mobile)"
        ]
        return URLSession(configuration: cfg)
    }()

    /// Parses user search into Rule34 tags: spaces start a NEW tag, underscores keep a multi-word tag together.
    /// e.g. "Hentai Femboy" -> ["hentai", "femboy"], "Hentai_Femboy" -> ["hentai_femboy"]
    nonisolated static func parseTags(_ raw: String) -> [String] {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .map {
                String($0)
                    .replacingOccurrences(of: "#", with: "")
                    .replacingOccurrences(of: "r34:", with: "", options: .caseInsensitive)
                    .lowercased()
            }
            .filter { !$0.isEmpty }
    }

    /// Live tag autocomplete from `https://api.rule34.xxx/autocomplete.php?q=...` (works without authentication).
    /// Only autocompletes the active (last) tag being typed so multi-tag queries ("hentai fem...") work naturally!
    func autocomplete(_ rawQuery: String) async -> [Rule34TagSuggestion] {
        let tags = Self.parseTags(rawQuery)
        let activeWord = tags.last ?? ""
        guard !activeWord.isEmpty,
              let encoded = activeWord.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.rule34.xxx/autocomplete.php?q=\(encoded)") else {
            return []
        }
        do {
            let (data, _) = try await session.data(from: url)
            return (try? JSONDecoder().decode([Rule34TagSuggestion].self, from: data)) ?? []
        } catch {
            return []
        }
    }

    /// Fetches Rule34 videos & high-res posts for a tag query (space-separated tags = AND; underscores = single tag).
    func fetchFeed(
        tag: String?,
        sort: String,
        after: String?,
        credentials: Rule34Credentials
    ) async -> GoonedFeedResponse {
        let page = Int(after ?? "0") ?? 0
        let tags = Self.parseTags(tag ?? "")
        let cleanTagString = tags.joined(separator: " ")

        var combined: [Gif] = []
        var seen = Set<String>()

        // 1. Direct api.rule34.xxx JSON API (if user connected their rule34.xxx user_id + api_key)
        if credentials.isConnected {
            let directPosts = await fetchDirectRule34XXX(
                tag: cleanTagString,
                sort: sort,
                page: page,
                credentials: credentials
            )
            for p in directPosts where seen.insert(p.id).inserted {
                combined.append(p)
            }
        }

        // 2. Always-on Zero-Auth Engine (Gooned R34/Hentai network + Booru JSON APIs) so Rule34 works 100% out of the box
        if combined.count < 12 {
            let primaryTag = tags.first ?? ""
            async let goonedR34Task = fetchGoonedRule34(tags: tags, sort: sort, page: page)
            async let booruTask = fetchZeroAuthBooru(tag: cleanTagString.isEmpty ? primaryTag : cleanTagString, sort: sort, page: page)

            let (goonedPosts, booruPosts) = await (goonedR34Task, booruTask)
            for p in goonedPosts where seen.insert(p.id).inserted {
                combined.append(p)
            }
            for p in booruPosts where seen.insert(p.id).inserted {
                combined.append(p)
            }
        }

        return GoonedFeedResponse(posts: combined, after: "\(page + 1)")
    }

    // MARK: - Tier 1: Direct `api.rule34.xxx`

    private func fetchDirectRule34XXX(
        tag: String,
        sort: String,
        page: Int,
        credentials: Rule34Credentials
    ) async -> [Gif] {
        var tagParts: [String] = []
        if !tag.isEmpty { tagParts.append(tag) }
        if sort == "top" || sort == "hot" {
            tagParts.append("sort:score:desc")
        }
        let tagString = tagParts.joined(separator: " ")

        var comps = URLComponents(string: "https://api.rule34.xxx/index.php")
        comps?.queryItems = [
            URLQueryItem(name: "page", value: "dapi"),
            URLQueryItem(name: "s", value: "post"),
            URLQueryItem(name: "q", value: "index"),
            URLQueryItem(name: "json", value: "1"),
            URLQueryItem(name: "limit", value: "40"),
            URLQueryItem(name: "pid", value: "\(page)"),
            URLQueryItem(name: "tags", value: tagString),
            URLQueryItem(name: "user_id", value: credentials.userId.trimmingCharacters(in: .whitespacesAndNewlines)),
            URLQueryItem(name: "api_key", value: credentials.apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
        ]
        guard let url = comps?.url else { return [] }

        do {
            let (data, _) = try await session.data(from: url)
            return parseGelbooruStyleJSON(data: data, sourcePrefix: "r34", basePermalink: "https://rule34.xxx/index.php?page=post&s=view&id=")
        } catch {
            return []
        }
    }

    // MARK: - Tier 2A: Gooned Rule34 / Hentai Subreddit Network

    private func fetchGoonedRule34(tags: [String], sort: String, page: Int) async -> [Gif] {
        let api = GoonedAPI.shared
        let offsetCursor = page == 0 ? nil : GoonedAPI.randomForYouCursor(offset: page * 25)

        if tags.isEmpty {
            let catName = (page % 2 == 0) ? "Rule34" : "Hentai"
            if let resp = try? await api.category(catName, sort: sort, after: offsetCursor, limit: 25) {
                return resp.posts.map { markAsRule34($0, tag: "rule34") }
            }
            return []
        }

        // Search matching subreddits on gooned.app for each tag (e.g. "hentai femboy" -> searches both!)
        var targetSubs: [String] = []
        for tag in tags.prefix(3) {
            let cleanSub = tag.replacingOccurrences(of: "_", with: "")
            if let searchResp = try? await api.search(cleanSub) {
                for s in searchResp.subreddits.prefix(2) where !targetSubs.contains(s.name) {
                    targetSubs.append(s.name)
                }
            }
        }
        if targetSubs.isEmpty {
            targetSubs = ["rule34", "HENTAI_GIF", "FutanariGifs", "Hentai__videos"]
        }

        let chosenSub = targetSubs[page % max(1, targetSubs.count)]
        if let resp = try? await api.subreddit(chosenSub, sort: sort, after: offsetCursor, limit: 25) {
            return resp.posts.map { markAsRule34($0, tag: tags.joined(separator: " ")) }
        }
        return []
    }

    private func markAsRule34(_ gif: Gif, tag: String) -> Gif {
        var copy = gif
        if copy.subreddit == nil || copy.subreddit?.isEmpty == true {
            copy.subreddit = "rule34"
        }
        return copy
    }

    // MARK: - Tier 2B: Zero-Auth Booru JSON APIs (MP4 & High-Res Art)

    private func fetchZeroAuthBooru(tag: String, sort: String, page: Int) async -> [Gif] {
        var results: [Gif] = []
        let pageNum = page + 1

        // 1. yande.re explicit high-res art/animations
        var yandeComps = URLComponents(string: "https://yande.re/post.json")
        let yandeTags = tag.isEmpty ? "order:score rating:e" : "\(tag) rating:e"
        yandeComps?.queryItems = [
            URLQueryItem(name: "limit", value: "20"),
            URLQueryItem(name: "page", value: "\(pageNum)"),
            URLQueryItem(name: "tags", value: yandeTags)
        ]
        if let url = yandeComps?.url,
           let (data, _) = try? await session.data(from: url) {
            results.append(contentsOf: parseMoebooruJSON(data: data, sourcePrefix: "r34y"))
        }

        // 2. hypnohub.net Gelbooru-compatible DAPI
        var hypComps = URLComponents(string: "https://hypnohub.net/index.php")
        hypComps?.queryItems = [
            URLQueryItem(name: "page", value: "dapi"),
            URLQueryItem(name: "s", value: "post"),
            URLQueryItem(name: "q", value: "index"),
            URLQueryItem(name: "json", value: "1"),
            URLQueryItem(name: "limit", value: "20"),
            URLQueryItem(name: "pid", value: "\(page)"),
            URLQueryItem(name: "tags", value: tag)
        ]
        if let url = hypComps?.url,
           let (data, _) = try? await session.data(from: url) {
            results.append(contentsOf: parseGelbooruStyleJSON(data: data, sourcePrefix: "r34h", basePermalink: "https://hypnohub.net/index.php?page=post&s=view&id="))
        }

        return results
    }

    // MARK: - JSON Parsers (Filtering Out Unplayable .webm so iOS AVPlayer Never Fails)

    private func parseGelbooruStyleJSON(data: Data, sourcePrefix: String, basePermalink: String) -> [Gif] {
        let rawArray: [[String: Any]]
        if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            rawArray = arr
        } else if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let arr = dict["post"] as? [[String: Any]] {
            rawArray = arr
        } else {
            return []
        }

        var posts: [Gif] = []
        for item in rawArray {
            guard let fileUrl = item["file_url"] as? String, !fileUrl.isEmpty else { continue }
            let sampleUrl = (item["sample_url"] as? String) ?? fileUrl
            let previewUrl = (item["preview_url"] as? String) ?? sampleUrl

            let lower = fileUrl.lowercased()
            // Skip raw .webm files unless sample_url is an .mp4 (iOS AVPlayer plays .mp4/.mov natively, not VP8/VP9 .webm)
            let isMp4 = lower.hasSuffix(".mp4") || lower.hasSuffix(".mov") || sampleUrl.lowercased().hasSuffix(".mp4")
            let isGif = lower.hasSuffix(".gif")
            let isImage = lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") || lower.hasSuffix(".png")

            guard isMp4 || isGif || isImage else { continue }

            let playableVideoUrl: String? = isMp4 ? (lower.hasSuffix(".mp4") ? fileUrl : sampleUrl) : nil
            let idVal: String
            if let i = item["id"] as? Int {
                idVal = "\(i)"
            } else if let s = item["id"] as? String {
                idVal = s
            } else {
                idVal = UUID().uuidString
            }

            let score = (item["score"] as? Int) ?? Int((item["score"] as? String) ?? "0") ?? 0
            let width = (item["width"] as? Int) ?? Int((item["width"] as? String) ?? "0")
            let height = (item["height"] as? Int) ?? Int((item["height"] as? String) ?? "0")
            let owner = (item["owner"] as? String) ?? "rule34"
            let rawTags = (item["tags"] as? String) ?? ""
            let topTags = rawTags
                .split(separator: " ")
                .prefix(8)
                .map { "#\($0)" }
                .joined(separator: " ")

            let mediaType: String
            if isMp4 {
                mediaType = "video"
            } else {
                mediaType = "image"
            }

            posts.append(
                Gif(
                    id: "\(sourcePrefix)_\(idVal)",
                    title: topTags,
                    author: owner,
                    subreddit: "rule34.xxx",
                    upvotes: score,
                    duration: nil,
                    width: width,
                    height: height,
                    mediaType: mediaType,
                    mediaUrl: playableVideoUrl ?? fileUrl,
                    muxedUrl: playableVideoUrl,
                    muxedUrlHd: playableVideoUrl,
                    hlsUrl: nil,
                    posterUrl: previewUrl,
                    thumbnailUrl: previewUrl,
                    sourceUrl: "\(basePermalink)\(idVal)",
                    permalink: "\(basePermalink)\(idVal)",
                    createdUtc: nil
                )
            )
        }
        return posts
    }

    private func parseMoebooruJSON(data: Data, sourcePrefix: String) -> [Gif] {
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        var posts: [Gif] = []
        for item in arr {
            guard let fileUrl = (item["file_url"] as? String) ?? (item["sample_url"] as? String),
                  !fileUrl.isEmpty else { continue }
            let lower = fileUrl.lowercased()
            let isMp4 = lower.hasSuffix(".mp4")
            let isImage = lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") || lower.hasSuffix(".png") || lower.hasSuffix(".gif")
            guard isMp4 || isImage else { continue }

            let idVal = (item["id"] as? Int).map { "\($0)" } ?? UUID().uuidString
            let previewUrl = (item["preview_url"] as? String) ?? (item["sample_url"] as? String) ?? fileUrl
            let sampleUrl = (item["sample_url"] as? String) ?? fileUrl
            let score = (item["score"] as? Int) ?? 0
            let width = item["width"] as? Int
            let height = item["height"] as? Int
            let author = (item["author"] as? String) ?? "rule34"
            let rawTags = (item["tags"] as? String) ?? ""
            let topTags = rawTags.split(separator: " ").prefix(8).map { "#\($0)" }.joined(separator: " ")

            posts.append(
                Gif(
                    id: "\(sourcePrefix)_\(idVal)",
                    title: topTags,
                    author: author,
                    subreddit: "rule34.xxx",
                    upvotes: score,
                    duration: nil,
                    width: width,
                    height: height,
                    mediaType: isMp4 ? "video" : "image",
                    mediaUrl: isMp4 ? fileUrl : sampleUrl,
                    muxedUrl: isMp4 ? fileUrl : nil,
                    muxedUrlHd: isMp4 ? fileUrl : nil,
                    hlsUrl: nil,
                    posterUrl: previewUrl,
                    thumbnailUrl: previewUrl,
                    sourceUrl: "https://rule34.xxx",
                    permalink: "https://rule34.xxx",
                    createdUtc: nil
                )
            )
        }
        return posts
    }
}

// MARK: - Optional Rule34.xxx API Key Sheet (`Rule34KeySheet`)

struct Rule34KeySheet: View {
    @EnvironmentObject var store: UserStore
    @Environment(\.dismiss) private var dismiss

    @State private var userId: String = ""
    @State private var apiKey: String = ""
    @State private var showWebAccount = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.modalGradient.ignoresSafeArea()

                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Rule34.xxx API Setup")
                            .font(.system(size: 20, weight: .bold))
                        Spacer()
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .bold))
                                .frame(width: 34, height: 34)
                                .liquidGlassCircle()
                        }
                    }

                    Text("Rule34 search & feeds work out of the box! To also pull directly from rule34.xxx's authenticated DAPI, enter your free User ID & API Key from your rule34.xxx Account Options page.")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.75))

                    VStack(alignment: .leading, spacing: 10) {
                        TextField("User ID (e.g. 1234567)", text: $userId)
                            .keyboardType(.asciiCapable)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.system(size: 14, design: .monospaced))
                            .padding(12)
                            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))

                        TextField("API Key", text: $apiKey)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.system(size: 14, design: .monospaced))
                            .padding(12)
                            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))

                        HStack(spacing: 10) {
                            Button {
                                store.data.r34Credentials.userId = userId.trimmingCharacters(in: .whitespacesAndNewlines)
                                store.data.r34Credentials.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                                UINotificationFeedbackGenerator().notificationOccurred(.success)
                                dismiss()
                            } label: {
                                Text("Save Credentials")
                                    .font(.system(size: 14, weight: .bold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 11)
                                    .liquidGlassCapsule(active: true)
                            }

                            Button {
                                withAnimation { showWebAccount.toggle() }
                            } label: {
                                Text(showWebAccount ? "Hide Web" : "Open rule34.xxx")
                                    .font(.system(size: 14, weight: .bold))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 11)
                                    .liquidGlassCapsule()
                            }
                        }
                    }
                    .padding(14)
                    .liquidGlassCard(cornerRadius: 18)

                    if showWebAccount {
                        Rule34AccountWebView(userId: $userId, apiKey: $apiKey)
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    } else {
                        Spacer()
                    }
                }
                .padding(16)
                .foregroundStyle(.white)
            }
            .onAppear {
                userId = store.data.r34Credentials.userId
                apiKey = store.data.r34Credentials.apiKey
            }
        }
    }
}

struct Rule34AccountWebView: UIViewRepresentable {
    @Binding var userId: String
    @Binding var apiKey: String

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.customUserAgent = Config.userAgent
        if let url = URL(string: "https://rule34.xxx/index.php?page=account&s=options") {
            wv.load(URLRequest(url: url))
        }
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

