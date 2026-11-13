import SwiftUI
import WebKit
import Security

// MARK: - Rule34.xxx Credentials & Keychain Store

private enum Rule34KeychainStore {
    private static let service = "tinytiny.r34.credentials"

    static func save(_ value: String, account: String) {
        delete(account: account)
        guard let data = value.data(using: .utf8), !value.isEmpty else { return }
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func read(account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(account: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(q as CFDictionary)
    }
}

struct Rule34Credentials: Codable, Equatable {
    private static let uidAccount = "r34.custom.uid"
    private static let keyAccount = "r34.custom.key"
    private static let mask: [UInt8] = [0x5A, 0x3D, 0x71, 0xA4, 0x2F, 0x91, 0xC6, 0x18]

    private static let defaultUidBytes: [UInt8] = [
        0x6D, 0x0D, 0x45, 0x93, 0x17, 0xA4, 0xFF
    ]
    private static let defaultKeyBytes: [UInt8] = [
        0x3F, 0x5E, 0x12, 0xC7, 0x4D, 0xA7, 0xF4, 0x7A, 0x38, 0x5B, 0x17, 0x91, 0x19, 0xF0, 0xA5, 0x2D,
        0x38, 0x5F, 0x12, 0x90, 0x16, 0xF4, 0xFF, 0x2D, 0x6D, 0x5B, 0x17, 0x97, 0x16, 0xA1, 0xF3, 0x28,
        0x3F, 0x0A, 0x40, 0xC0, 0x4D, 0xF0, 0xA0, 0x7B, 0x6A, 0x59, 0x13, 0xC2, 0x17, 0xA0, 0xF3, 0x28,
        0x69, 0x08, 0x17, 0x97, 0x1E, 0xF5, 0xF6, 0x7B, 0x68, 0x0A, 0x49, 0x90, 0x1C, 0xF7, 0xA0, 0x2C,
        0x68, 0x59, 0x13, 0x95, 0x18, 0xF4, 0xF0, 0x29, 0x68, 0x58, 0x43, 0xC5, 0x4B, 0xF3, 0xF1, 0x20,
        0x6E, 0x0B, 0x46, 0xC1, 0x16, 0xA3, 0xA0, 0x7E, 0x38, 0x08, 0x14, 0x95, 0x1E, 0xA9, 0xA7, 0x29,
        0x6D, 0x0E, 0x15, 0xC1, 0x1E, 0xA7, 0xF3, 0x2D, 0x3C, 0x0D, 0x43, 0x96, 0x4D, 0xA3, 0xF0, 0x7E,
        0x62, 0x5F, 0x46, 0x90, 0x4B, 0xA8, 0xF4, 0x2D, 0x63, 0x04, 0x14, 0x96, 0x4C, 0xA9, 0xF5, 0x2B
    ]

    private static func decode(_ bytes: [UInt8]) -> String {
        let plain = bytes.enumerated().map { idx, b in
            b ^ mask[idx % mask.count]
        }
        return String(bytes: plain, encoding: .utf8) ?? ""
    }

    static var defaultUserId: String { decode(defaultUidBytes) }
    private static var defaultApiKey: String { decode(defaultKeyBytes) }

    // Only store non-secret override metadata in Codable UserData; secrets live in Keychain.
    var customUserId: String = ""
    var useCustomCredentials: Bool = false

    enum CodingKeys: String, CodingKey {
        case customUserId, useCustomCredentials, userId, apiKey
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let savedCustomUid = (try? c.decode(String.self, forKey: .customUserId)) ?? ""
        let savedUseCustom = (try? c.decode(Bool.self, forKey: .useCustomCredentials)) ?? false
        let legacyUid = ((try? c.decode(String.self, forKey: .userId)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let legacyKey = ((try? c.decode(String.self, forKey: .apiKey)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        if !legacyUid.isEmpty && !legacyKey.isEmpty {
            Rule34KeychainStore.save(legacyUid, account: Self.uidAccount)
            Rule34KeychainStore.save(legacyKey, account: Self.keyAccount)
            self.customUserId = legacyUid
            self.useCustomCredentials = true
        } else {
            self.customUserId = savedCustomUid
            self.useCustomCredentials = savedUseCustom
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(customUserId, forKey: .customUserId)
        try c.encode(useCustomCredentials, forKey: .useCustomCredentials)
    }

    var userId: String {
        let kc = (Rule34KeychainStore.read(account: Self.uidAccount) ?? customUserId).trimmingCharacters(in: .whitespacesAndNewlines)
        return kc
    }

    var apiKey: String {
        (Rule34KeychainStore.read(account: Self.keyAccount) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasCustomCredentials: Bool {
        useCustomCredentials && !userId.isEmpty && !apiKey.isEmpty
    }

    var effectiveUserId: String {
        hasCustomCredentials ? userId : Self.defaultUserId
    }

    var effectiveApiKey: String {
        hasCustomCredentials ? apiKey : Self.defaultApiKey
    }

    var isConnected: Bool {
        !effectiveUserId.isEmpty && !effectiveApiKey.isEmpty
    }

    mutating func setCustom(userId: String, apiKey: String) {
        let uid = userId.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uid.isEmpty, !key.isEmpty else {
            resetToDefault()
            return
        }
        Rule34KeychainStore.save(uid, account: Self.uidAccount)
        Rule34KeychainStore.save(key, account: Self.keyAccount)
        customUserId = uid
        useCustomCredentials = true
    }

    mutating func resetToDefault() {
        Rule34KeychainStore.delete(account: Self.uidAccount)
        Rule34KeychainStore.delete(account: Self.keyAccount)
        customUserId = ""
        useCustomCredentials = false
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
        // Strictly explicit adult content only (-rating:safe -rating:questionable)
        tagParts.append("-rating:safe")
        tagParts.append("-rating:questionable")
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
            URLQueryItem(name: "user_id", value: credentials.effectiveUserId),
            URLQueryItem(name: "api_key", value: credentials.effectiveApiKey)
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

        // 2. hypnohub.net Gelbooru-compatible DAPI (explicit rating only)
        var hypComps = URLComponents(string: "https://hypnohub.net/index.php")
        let hypTags = tag.isEmpty ? "-rating:safe -rating:questionable" : "\(tag) -rating:safe -rating:questionable"
        hypComps?.queryItems = [
            URLQueryItem(name: "page", value: "dapi"),
            URLQueryItem(name: "s", value: "post"),
            URLQueryItem(name: "q", value: "index"),
            URLQueryItem(name: "json", value: "1"),
            URLQueryItem(name: "limit", value: "20"),
            URLQueryItem(name: "pid", value: "\(page)"),
            URLQueryItem(name: "tags", value: hypTags)
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
            if let rating = (item["rating"] as? String)?.lowercased(),
               rating == "s" || rating == "safe" || rating == "general" {
                continue
            }
            guard let rawFile = item["file_url"] as? String, !rawFile.isEmpty else { continue }
            let fileUrl = normalizeHTTPS(rawFile)
            let sampleUrl = normalizeHTTPS((item["sample_url"] as? String) ?? fileUrl)
            let previewUrl = normalizeHTTPS((item["preview_url"] as? String) ?? sampleUrl)

            let lower = fileUrl.lowercased().split(separator: "?").first.map(String.init) ?? fileUrl.lowercased()
            let sampleLower = sampleUrl.lowercased().split(separator: "?").first.map(String.init) ?? sampleUrl.lowercased()
            // Skip raw .webm files unless sample_url is an .mp4 (iOS AVPlayer plays .mp4/.mov natively, not VP8/VP9 .webm)
            let isMp4 = lower.hasSuffix(".mp4") || lower.hasSuffix(".mov") || sampleLower.hasSuffix(".mp4")
            let isGif = lower.hasSuffix(".gif")
            let isImage = lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") || lower.hasSuffix(".png") || lower.hasSuffix(".webp")
                || sampleLower.hasSuffix(".jpg") || sampleLower.hasSuffix(".jpeg") || sampleLower.hasSuffix(".png")

            guard isMp4 || isGif || isImage else { continue }

            let playableVideoUrl: String? = isMp4 ? ((lower.hasSuffix(".mp4") || lower.hasSuffix(".mov")) ? fileUrl : sampleUrl) : nil
            let sampleIsFastImg = !isGif && (sampleLower.hasSuffix(".jpg") || sampleLower.hasSuffix(".jpeg") || sampleLower.hasSuffix(".png") || sampleLower.hasSuffix(".webp"))
            let preferredImageUrl = isGif ? fileUrl : (sampleIsFastImg ? sampleUrl : fileUrl)
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
                    mediaUrl: playableVideoUrl ?? preferredImageUrl,
                    muxedUrl: playableVideoUrl,
                    muxedUrlHd: playableVideoUrl,
                    hlsUrl: nil,
                    posterUrl: sampleIsFastImg ? fileUrl : previewUrl,
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
            if let rating = (item["rating"] as? String)?.lowercased(),
               rating == "s" || rating == "safe" || rating == "general" {
                continue
            }
            guard let rawFile = (item["file_url"] as? String) ?? (item["jpeg_url"] as? String) ?? (item["sample_url"] as? String),
                  !rawFile.isEmpty else { continue }
            let fileUrl = normalizeHTTPS(rawFile)
            let sampleUrl = normalizeHTTPS((item["sample_url"] as? String) ?? (item["jpeg_url"] as? String) ?? fileUrl)
            let previewUrl = normalizeHTTPS((item["preview_url"] as? String) ?? sampleUrl)

            let lower = fileUrl.lowercased().split(separator: "?").first.map(String.init) ?? fileUrl.lowercased()
            let sampleLower = sampleUrl.lowercased().split(separator: "?").first.map(String.init) ?? sampleUrl.lowercased()
            let isMp4 = lower.hasSuffix(".mp4") || lower.hasSuffix(".mov") || sampleLower.hasSuffix(".mp4")
            let isGif = lower.hasSuffix(".gif")
            let isImage = isGif || lower.hasSuffix(".jpg") || lower.hasSuffix(".jpeg") || lower.hasSuffix(".png") || lower.hasSuffix(".webp")
                || sampleLower.hasSuffix(".jpg") || sampleLower.hasSuffix(".jpeg")
            guard isMp4 || isImage else { continue }

            let idVal = (item["id"] as? Int).map { "\($0)" } ?? UUID().uuidString
            let score = (item["score"] as? Int) ?? 0
            let width = item["width"] as? Int
            let height = item["height"] as? Int
            let author = (item["author"] as? String) ?? "rule34"
            let rawTags = (item["tags"] as? String) ?? ""
            let topTags = rawTags.split(separator: " ").prefix(8).map { "#\($0)" }.joined(separator: " ")

            let preferredImage = isGif ? fileUrl : sampleUrl
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
                    mediaUrl: isMp4 ? fileUrl : preferredImage,
                    muxedUrl: isMp4 ? fileUrl : nil,
                    muxedUrlHd: isMp4 ? fileUrl : nil,
                    hlsUrl: nil,
                    posterUrl: fileUrl == preferredImage ? previewUrl : fileUrl,
                    thumbnailUrl: previewUrl,
                    sourceUrl: "https://rule34.xxx",
                    permalink: "https://rule34.xxx",
                    createdUtc: nil
                )
            )
        }
        return posts
    }

    private func normalizeHTTPS(_ raw: String) -> String {
        if raw.hasPrefix("//") { return "https:\(raw)" }
        if raw.hasPrefix("http://") { return "https://" + raw.dropFirst(7) }
        return raw
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

                    Text("Direct authenticated rule34.xxx DAPI is enabled by default. Enter custom credentials below only if you want to override the built-in API key.")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.75))

                    HStack(spacing: 10) {
                        Circle()
                            .fill(store.data.r34Credentials.hasCustomCredentials ? Color.cyan : Color(red: 0.45, green: 0.92, blue: 0.55))
                            .frame(width: 8, height: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(store.data.r34Credentials.hasCustomCredentials ? "Custom Credentials Active" : "Built-In Default Credentials Active")
                                .font(.system(size: 13.5, weight: .bold))
                            Text("User ID: \(store.data.r34Credentials.effectiveUserId) · Stored in iOS Keychain")
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.66))
                        }
                        Spacer()
                        if store.data.r34Credentials.hasCustomCredentials {
                            Button {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                store.data.r34Credentials.resetToDefault()
                                userId = ""
                                apiKey = ""
                            } label: {
                                Text("Use Default")
                                    .font(.caption.bold())
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .liquidGlassCapsule()
                            }
                        }
                    }
                    .padding(12)
                    .liquidGlassCard(cornerRadius: 16)

                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Custom User ID (leave blank for default)", text: $userId)
                            .keyboardType(.asciiCapable)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.system(size: 14, design: .monospaced))
                            .padding(12)
                            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))

                        SecureField("Custom API Key (stored securely in Keychain)", text: $apiKey)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.system(size: 14, design: .monospaced))
                            .padding(12)
                            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))

                        HStack(spacing: 10) {
                            Button {
                                let cleanUid = userId.trimmingCharacters(in: .whitespacesAndNewlines)
                                let cleanKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
                                if cleanUid.isEmpty && cleanKey.isEmpty {
                                    store.data.r34Credentials.resetToDefault()
                                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                                    dismiss()
                                } else if !cleanUid.isEmpty && !cleanKey.isEmpty {
                                    store.data.r34Credentials.setCustom(userId: cleanUid, apiKey: cleanKey)
                                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                                    dismiss()
                                } else {
                                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                                }
                            } label: {
                                Text(userId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Use Default API" : "Save Custom API")
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

