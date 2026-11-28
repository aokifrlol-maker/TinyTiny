import Foundation
import SwiftUI
import CryptoKit
import UniformTypeIdentifiers

// MARK: - Encrypted User-to-User Video & File Drop Sharing

struct ShareDropPayload: Codable {
    var version: Int = 1
    var kind: String // "post" | "collection" | "file" | "encrypted_blob"
    var title: String
    var post: Gif?
    var posts: [Gif]?
    var fileName: String?
    var fileExtension: String?
    var encryptedBlobUrl: String?
    var inlineBase64: String? // Small file (<1.5MB) inline or post metadata
}

@MainActor
final class ShareService: ObservableObject {
    static let shared = ShareService()

    @Published var pendingReceivedPost: Gif?
    @Published var pendingReceivedPosts: [Gif]?
    @Published var pendingReceivedMediaURL: URL?
    @Published var pendingReceivedTitle: String?
    @Published var showReceiveSheet: Bool = false
    @Published var statusMessage: String?

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 90
        cfg.timeoutIntervalForResource = 180
        return URLSession(configuration: cfg)
    }()

    private let watchitSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 1200
        return URLSession(configuration: cfg)
    }()

    private init() {}

    /// Creates an AES-256-GCM encrypted drop (`https://.../s/<id>#k=<key>` + `TTDROP:` code).
    /// Zero plaintext leaves the device: the Worker / KV only stores encrypted ciphertext.
    func createEncryptedShareLink(for post: Gif) async -> (link: String, code: String)? {
        let payload = ShareDropPayload(
            kind: "post",
            title: post.title ?? post.author ?? "Shared Video",
            post: post,
            posts: nil,
            fileName: "\(post.id).mp4",
            fileExtension: post.isImage ? "jpg" : "mp4"
        )
        return await sealAndPublishPayload(payload)
    }

    /// Creates an AES-256-GCM encrypted multi-video collection share URL (`https://.../s/<id>#k=<key>`).
    /// Recipients can watch all shared videos in any browser or open the full collection inside TinyTiny.
    func createEncryptedCollectionShareLink(for posts: [Gif], title: String? = nil) async -> (link: String, code: String)? {
        guard !posts.isEmpty else { return nil }
        if posts.count == 1, let single = posts.first {
            return await createEncryptedShareLink(for: single)
        }
        let cleanTitle = (title?.isEmpty == false) ? title! : "Shared Collection (\(posts.count) Videos)"
        let payload = ShareDropPayload(
            kind: "collection",
            title: cleanTitle,
            post: nil,
            posts: posts,
            fileName: nil,
            fileExtension: nil
        )
        return await sealAndPublishPayload(payload)
    }

    /// Encrypts an arbitrary local file (e.g., Offline Vault video, iPhone Files picker video/zip/image)
    /// and returns an E2EE Drop Link where the decryption key lives strictly inside the URL fragment `#k=`.
    func createEncryptedFileShareLink(fileURL: URL, title: String? = nil) async -> (link: String, code: String)? {
        guard let bytes = try? Data(contentsOf: fileURL), !bytes.isEmpty else { return nil }
        let key = CryptoBox.generateKey()
        let keyB64 = CryptoBox.exportKeyBase64URL(key)

        // Encrypt raw file bytes first
        guard let sealedBytes = try? CryptoBox.seal(bytes, using: key) else { return nil }
        let ext = fileURL.pathExtension.isEmpty ? "mp4" : fileURL.pathExtension

        // Try uploading ciphertext blob (hidden encrypted relay)
        if let blobURL = await LicenseManager.shared.uploadTemporaryEncryptedBlob(sealedBytes, filename: "\(UUID().uuidString).ttenc") {
            let payload = ShareDropPayload(
                kind: "encrypted_blob",
                title: title ?? fileURL.lastPathComponent,
                post: nil,
                fileName: fileURL.lastPathComponent,
                fileExtension: ext,
                encryptedBlobUrl: blobURL.absoluteString
            )
            if let published = await sealAndPublishPayload(payload, explicitKey: key, keyB64: keyB64) {
                return published
            }
        }
        return nil
    }

    /// Downloads a remote clip (up to 90 MB), encrypts the raw bytes locally with AES-256-GCM,
    /// and uploads only ciphertext to the encrypted cloud relay. Falls back to metadata post drop if unavailable.
    func createEncryptedRemoteMediaShareLink(for post: Gif) async -> (link: String, code: String)? {
        if let remote = post.videoURL(hd: false) ?? post.imageURL ?? URL(string: post.mediaUrl ?? ""),
           !remote.absoluteString.lowercased().contains(".m3u8") {
            var req = URLRequest(url: remote)
            req.timeoutInterval = 30
            if remote.absoluteString.contains("twimg.com") || remote.absoluteString.contains("x.com") {
                req.setValue("https://x.com/", forHTTPHeaderField: "Referer")
            }
            if let (data, resp) = try? await session.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode ?? 200 < 400,
               !data.isEmpty, data.count <= 90 * 1024 * 1024 {
                let ext = remote.pathExtension.isEmpty ? (post.isImage ? "jpg" : "mp4") : remote.pathExtension
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent("tt_share_\(post.id).\(ext)")
                try? data.write(to: tmp, options: [.atomic])
                defer { try? FileManager.default.removeItem(at: tmp) }
                if let uploaded = await createEncryptedFileShareLink(fileURL: tmp, title: post.title ?? post.author) {
                    return uploaded
                }
            }
        }
        return await createEncryptedShareLink(for: post)
    }

    /// Admin-only: creates a public Watchit Watch & Direct Download URL (`/w/<id>`) by uploading the MP4
    /// from the device in 8MB chunks to the Worker (bypasses IP-locked & geo-blocked adult CDNs 100%).
    func createAdminWatchitLink(for post: Gif, onProgress: ((String) -> Void)? = nil) async -> (watchUrl: String, downloadUrl: String)? {
        guard LicenseManager.shared.isAdmin else { return nil }
        let base = LicenseManager.shared.normalizedBaseURL
        let licKey = LicenseManager.shared.status.licenseKey
        let devId = LicenseManager.shared.deviceId
        let title = post.title ?? post.author ?? "TinyTiny Video"
        let maxBytes: Int64 = 500 * 1024 * 1024

        // 1. Obtain a local MP4 file (reuse Offline Vault copy if downloaded, otherwise stream-download on device IP)
        var localFileURL: URL? = nil
        var shouldDeleteTemp = false
        var fallbackPickedURL: URL? = nil

        if let offline = OfflineManager.localMediaURL(forId: post.id),
           FileManager.default.fileExists(atPath: offline.path) {
            localFileURL = offline
        } else {
            onProgress?("Resolving video stream...")
            var candidates: [URL] = []
            if post.isLongVideoPost {
                let resolved = await LongVideoAPI.shared.resolvePlayableURLs(for: post)
                candidates.append(contentsOf: resolved)
            }
            candidates.append(contentsOf: post.allVideoURLs(hd: false))
            candidates.append(contentsOf: post.allVideoURLs(hd: true))
            var seenURLs = Set<String>()
            let remoteCandidates = candidates.filter { ($0.scheme?.lowercased() ?? "") == "https" && seenURLs.insert($0.absoluteString).inserted }
            // Prefer smaller/faster MP4s (480p/720p) over massive 1080p so device download + upload finishes quickly
            let rawMp4s = remoteCandidates.filter { !$0.absoluteString.lowercased().contains(".m3u8") }
            let mp4Candidates = rawMp4s.count > 1 ? rawMp4s.reversed() : rawMp4s
            fallbackPickedURL = mp4Candidates.first ?? remoteCandidates.first

            onProgress?("Downloading video on device...")
            outer: for cand in mp4Candidates.prefix(3) {
                for useRef in [true, false] {
                    var dlReq = URLRequest(url: cand)
                    dlReq.timeoutInterval = 1200
                    for (k, v) in MediaHeaders.headers(for: cand) {
                        if !useRef && k.lowercased() == "referer" { continue }
                        dlReq.setValue(v, forHTTPHeaderField: k)
                    }
                    if let (tmpURL, resp) = try? await watchitSession.download(for: dlReq),
                       let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                       let attrs = try? FileManager.default.attributesOfItem(atPath: tmpURL.path),
                       let fSize = (attrs[.size] as? NSNumber)?.int64Value,
                       fSize > 4096, fSize <= maxBytes {
                        let dest = FileManager.default.temporaryDirectory.appendingPathComponent("tt_watchit_\(UUID().uuidString).mp4")
                        try? FileManager.default.removeItem(at: dest)
                        if (try? FileManager.default.moveItem(at: tmpURL, to: dest)) != nil {
                            localFileURL = dest
                            shouldDeleteTemp = true
                            break outer
                        }
                    }
                }
            }
        }

        defer {
            if shouldDeleteTemp, let f = localFileURL {
                try? FileManager.default.removeItem(at: f)
            }
        }

        // 2. Upload MP4 in 8 MiB chunks to Worker KV so `/w/<id>` streams & downloads from ANY IP forever!
        if let fileURL = localFileURL,
           let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
           let totalSize = (attrs[.size] as? NSNumber)?.int64Value,
           totalSize > 0, totalSize <= maxBytes,
           let initURL = URL(string: "\(base)/v1/admin/watchit/init") {
            var initReq = URLRequest(url: initURL)
            initReq.httpMethod = "POST"
            initReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
            initReq.httpBody = try? JSONSerialization.data(withJSONObject: [
                "key": licKey,
                "deviceId": devId,
                "title": title
            ])
            if let (initData, initResp) = try? await watchitSession.data(for: initReq),
               (initResp as? HTTPURLResponse)?.statusCode == 200,
               let initJson = try? JSONSerialization.jsonObject(with: initData) as? [String: Any],
               let wid = initJson["id"] as? String, !wid.isEmpty {
                let chunkSize = (initJson["chunkSize"] as? Int) ?? (8 * 1024 * 1024)
                let estTotalChunks = max(1, Int((totalSize + Int64(chunkSize) - 1) / Int64(chunkSize)))
                if let handle = try? FileHandle(forReadingFrom: fileURL) {
                    defer { try? handle.close() }
                    var chunkIdx = 0
                    var allOk = true
                    while true {
                        let slice = handle.readData(ofLength: chunkSize)
                        if slice.isEmpty { break }
                        onProgress?("Uploading part \(chunkIdx + 1)/\(estTotalChunks)...")
                        guard let chunkURL = URL(string: "\(base)/v1/admin/watchit/chunk/\(wid)/\(chunkIdx)") else {
                            allOk = false; break
                        }
                        var cReq = URLRequest(url: chunkURL)
                        cReq.httpMethod = "PUT"
                        cReq.timeoutInterval = 180
                        cReq.setValue(licKey, forHTTPHeaderField: "X-License-Key")
                        cReq.setValue(devId, forHTTPHeaderField: "X-Device-Id")
                        cReq.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                        cReq.httpBody = slice
                        if let (_, cResp) = try? await watchitSession.data(for: cReq),
                           (cResp as? HTTPURLResponse)?.statusCode == 200 {
                            chunkIdx += 1
                        } else {
                            allOk = false; break
                        }
                    }
                    if allOk && chunkIdx > 0,
                       let compURL = URL(string: "\(base)/v1/admin/watchit/complete/\(wid)") {
                        onProgress?("Finalizing link...")
                        var compReq = URLRequest(url: compURL)
                        compReq.httpMethod = "POST"
                        compReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        compReq.httpBody = try? JSONSerialization.data(withJSONObject: [
                            "key": licKey,
                            "deviceId": devId,
                            "title": title,
                            "size": totalSize,
                            "chunkSize": chunkSize,
                            "chunkCount": chunkIdx
                        ])
                        if let (cData, cResp) = try? await watchitSession.data(for: compReq),
                           (cResp as? HTTPURLResponse)?.statusCode == 200,
                           let cJson = try? JSONSerialization.jsonObject(with: cData) as? [String: Any],
                           let watchUrl = cJson["watchUrl"] as? String,
                           let downloadUrl = cJson["downloadUrl"] as? String {
                            return (watchUrl, downloadUrl)
                        }
                    }
                }
            }
        }

        // 3. Fallback ONLY for non-IP-locked direct URLs (never return a broken IP-locked phncdn/eporner link!)
        guard let picked = fallbackPickedURL else { return nil }
        let lowerPicked = picked.absoluteString.lowercased()
        let isIpLockedCdn = lowerPicked.contains("ip=") || lowerPicked.contains("phncdn.com") ||
            lowerPicked.contains("eporner.com") || lowerPicked.contains("xhcdn.com") ||
            lowerPicked.contains("sb-cd.com") || lowerPicked.contains("xvideos-cdn.com")
        if isIpLockedCdn { return nil }
        guard let apiURL = URL(string: "\(base)/v1/admin/watchit") else { return nil }
        var req = URLRequest(url: apiURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let referer = MediaHeaders.headers(for: picked)["Referer"] ?? post.sourceUrl ?? ""
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "key": licKey,
            "deviceId": devId,
            "videoUrl": picked.absoluteString,
            "pageUrl": post.permalink ?? "",
            "sourceUrl": post.sourceUrl ?? "",
            "title": title,
            "referer": referer
        ])
        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let watchUrl = json["watchUrl"] as? String,
              let downloadUrl = json["downloadUrl"] as? String else {
            return nil
        }
        return (watchUrl, downloadUrl)
    }

    private func sealAndPublishPayload(
        _ payload: ShareDropPayload,
        explicitKey: SymmetricKey? = nil,
        keyB64: String? = nil
    ) async -> (link: String, code: String)? {
        let key = explicitKey ?? CryptoBox.generateKey()
        let encodedKey = keyB64 ?? CryptoBox.exportKeyBase64URL(key)

        guard let jsonData = try? JSONEncoder().encode(payload),
              let sealed = try? CryptoBox.seal(jsonData, using: key) else {
            return nil
        }

        let base = LicenseManager.shared.normalizedBaseURL
        if let apiURL = URL(string: "\(base)/v1/share") {
            var req = URLRequest(url: apiURL)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "key": LicenseManager.shared.status.licenseKey,
                "deviceId": LicenseManager.shared.deviceId,
                "cipher": sealed.base64EncodedString()
            ])
            if let (data, resp) = try? await session.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let shareId = json["id"] as? String {
                let code = "TTDROP:\(shareId).\(encodedKey)"
                let link = "tinytiny://drop/\(shareId)#k=\(encodedKey)"
                return (link, code)
            }
        }

        // Offline / Serverless compact fallback for post links (self-contained encrypted capsule!)
        let b64Url = sealed.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let code = "TTPOST:\(b64Url).\(encodedKey)"
        let link = "tinytiny://drop/inline?p=\(b64Url)#k=\(encodedKey)"
        return (link, code)
    }

    /// Parses and decrypts an incoming `tinytiny://drop/...`, `https://.../s/...`, `TTDROP:...`, or `TTPOST:...` string.
    func handleIncomingShare(_ raw: String) async -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Empty share link or code." }

        // 1. Inline encrypted post capsule `TTPOST:<cipher>.<key>`
        if trimmed.hasPrefix("TTPOST:") {
            let body = String(trimmed.dropFirst("TTPOST:".count))
            let parts = body.split(separator: ".", maxSplits: 1).map(String.init)
            guard parts.count == 2, let key = CryptoBox.importKeyBase64URL(parts[1]),
                  let cipher = decodeBase64URL(parts[0]),
                  let plain = try? CryptoBox.open(cipher, using: key),
                  let payload = try? JSONDecoder().decode(ShareDropPayload.self, from: plain) else {
                return "Could not decrypt share capsule."
            }
            return await openDecryptedPayload(payload, key: key)
        }

        // 2. Worker share code `TTDROP:<id>.<key>` or URL `tinytiny://drop/<id>#k=<key>` or `https://.../s/<id>#k=<key>`
        var shareId = ""
        var keyStr = ""
        var inlineCipher = ""

        if trimmed.hasPrefix("TTDROP:") {
            let parts = String(trimmed.dropFirst("TTDROP:".count)).split(separator: ".", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                shareId = parts[0]
                keyStr = parts[1]
            }
        } else if let url = URL(string: trimmed) {
            let frag = url.fragment ?? ""
            if frag.hasPrefix("k=") { keyStr = String(frag.dropFirst(2)) }
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            if keyStr.isEmpty {
                keyStr = comps?.queryItems?.first(where: { $0.name == "k" })?.value ?? ""
            }
            inlineCipher = comps?.queryItems?.first(where: { $0.name == "p" })?.value ?? ""
            if url.lastPathComponent != "inline" && !url.lastPathComponent.isEmpty {
                shareId = url.lastPathComponent
            }
        }

        guard let key = CryptoBox.importKeyBase64URL(keyStr) else {
            return "Missing or invalid decryption key."
        }

        if !inlineCipher.isEmpty,
           let cipher = decodeBase64URL(inlineCipher),
           let plain = try? CryptoBox.open(cipher, using: key),
           let payload = try? JSONDecoder().decode(ShareDropPayload.self, from: plain) {
            return await openDecryptedPayload(payload, key: key)
        }

        let validId = shareId.range(of: "^[A-Za-z0-9_-]{4,64}$", options: .regularExpression) != nil
        guard validId,
              let url = URL(string: "\(LicenseManager.shared.normalizedBaseURL)/v1/share/\(shareId)"),
              let (data, resp) = try? await session.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let b64 = json["cipher"] as? String,
              let cipher = Data(base64Encoded: b64),
              let plain = try? CryptoBox.open(cipher, using: key),
              let payload = try? JSONDecoder().decode(ShareDropPayload.self, from: plain) else {
            return "Share drop not found or expired."
        }

        return await openDecryptedPayload(payload, key: key)
    }

    private func openDecryptedPayload(_ payload: ShareDropPayload, key: SymmetricKey) async -> String? {
        if let posts = payload.posts, !posts.isEmpty {
            pendingReceivedPosts = posts
            pendingReceivedPost = nil
            pendingReceivedTitle = payload.title
            pendingReceivedMediaURL = nil
            return nil
        }

        if let post = payload.post {
            pendingReceivedPost = post
            pendingReceivedPosts = nil
            pendingReceivedTitle = payload.title
            pendingReceivedMediaURL = nil
            return nil
        }

        if let blobStr = payload.encryptedBlobUrl,
           let blobURL = URL(string: blobStr),
           blobURL.scheme == "https",
           let expectedHost = URL(string: LicenseManager.shared.normalizedBaseURL)?.host,
           blobURL.host == expectedHost,
           blobURL.path.hasPrefix("/v1/blob/"),
           let (cipher, resp) = try? await session.data(from: blobURL),
           (resp as? HTTPURLResponse)?.statusCode == 200,
           let plainBytes = try? CryptoBox.open(cipher, using: key) {
            let rawExt = (payload.fileExtension ?? "mp4").lowercased()
            let safeExt = rawExt.filter { $0.isLetter || $0.isNumber }
            let ext = safeExt.isEmpty ? "mp4" : String(safeExt.prefix(8))
            let local = FileManager.default.temporaryDirectory
                .appendingPathComponent("tt_drop_\(UUID().uuidString.prefix(8)).\(ext)")
            try? plainBytes.write(to: local, options: [.atomic])
            let synth = Gif(
                id: "drop_\(UUID().uuidString.prefix(8))",
                title: payload.title,
                author: "Shared Drop",
                subreddit: "Drop",
                upvotes: nil,
                duration: nil,
                width: nil,
                height: nil,
                mediaType: ["jpg", "jpeg", "png", "webp"].contains(ext.lowercased()) ? "image" : "video",
                mediaUrl: local.absoluteString,
                muxedUrl: local.absoluteString,
                muxedUrlHd: local.absoluteString,
                hlsUrl: nil,
                posterUrl: nil,
                thumbnailUrl: nil,
                sourceUrl: local.absoluteString,
                permalink: local.absoluteString,
                createdUtc: nil
            )
            pendingReceivedPost = synth
            pendingReceivedMediaURL = local
            pendingReceivedTitle = payload.title
            return nil
        }
        return "Shared drop has no playable content."
    }

    private func decodeBase64URL(_ token: String) -> Data? {
        var b64 = token
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64.append("=") }
        return Data(base64Encoded: b64)
    }
}

// MARK: - Unified Share Sheet (Encrypted Drop, AirDrop/iOS Share)

struct ShareItemSheet: View {
    let gif: Gif
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var license = LicenseManager.shared

    @State private var generatedCode: String?
    @State private var generatedLink: String?
    @State private var statusNote: String?
    @State private var isCreatingDrop = false
    @State private var showActivitySheet = false
    @State private var showIGDirectSheet = false
    @State private var watchitWatchURL: String? = nil
    @State private var watchitDownloadURL: String? = nil
    @State private var isCreatingWatchit = false
    @State private var watchitCopied = false
    @State private var watchitError: String? = nil
    @State private var watchitStatus: String? = nil

    var body: some View {
        NavigationStack {
            ZStack {
                Color.clear.liquidGlassBackground(tinted: UserStore.shared.data.settings.tintedGlass)
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Share Video or File")
                                .font(.system(size: 20, weight: .bold))
                            Text("End-to-end AES-256-GCM encrypted")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.65))
                        }
                        Spacer()
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .bold))
                                .frame(width: 34, height: 34)
                                .liquidGlassCircle()
                        }
                    }

                    // 1. Copy / Send Encrypted TinyTiny Drop Link (for another TinyTiny user)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: "paperplane.fill").foregroundStyle(Theme.accentBright)
                            Text("Send to Another User (Encrypted Drop)")
                                .font(.system(size: 15, weight: .bold))
                        }
                        Text("Encrypts this clip end-to-end and generates a secret TinyTiny drop link & code.")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.68))

                        if let statusNote {
                            Text(statusNote)
                                .font(.caption.bold())
                                .foregroundStyle(Theme.accentBright)
                        }

                        if let code = generatedCode {
                            HStack {
                                Text(code)
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .lineLimit(1)
                                Spacer()
                                Button("Copy") {
                                    UIPasteboard.general.string = generatedLink ?? code
                                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                                }
                                .font(.caption.bold())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .liquidGlassCapsule(active: true)
                            }
                            .padding(10)
                            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                        }

                        HStack(spacing: 8) {
                            Button {
                                Task {
                                    isCreatingDrop = true
                                    statusNote = nil
                                    if let local = OfflineManager.localMediaURL(forId: gif.id),
                                       let res = await ShareService.shared.createEncryptedFileShareLink(fileURL: local, title: gif.title) {
                                        generatedLink = res.link
                                        generatedCode = res.code
                                    } else if let res = await ShareService.shared.createEncryptedShareLink(for: gif) {
                                        generatedLink = res.link
                                        generatedCode = res.code
                                    } else {
                                        statusNote = "Could not create encrypted drop."
                                    }
                                    isCreatingDrop = false
                                    if generatedCode != nil {
                                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                                    }
                                }
                            } label: {
                                Group {
                                    if isCreatingDrop { ProgressView().tint(.white) }
                                    else { Text(generatedCode == nil ? "Generate Secret Link" : "Regenerate") }
                                }
                                .font(.system(size: 13.5, weight: .bold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .liquidGlassCapsule(active: true)
                            }

                            if generatedLink != nil {
                                Button {
                                    showActivitySheet = true
                                } label: {
                                    Image(systemName: "square.and.arrow.up")
                                        .font(.system(size: 15, weight: .bold))
                                        .frame(width: 42, height: 38)
                                        .liquidGlassCircle()
                                }
                            }
                        }
                    }
                    .padding(14)
                    .liquidGlassCard(cornerRadius: 18)

                    // 2. Admin Watch & Download URL (Watchit) + IG Direct
                    if license.isAdmin, !gif.isImage {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Image(systemName: "play.rectangle.on.rectangle.fill")
                                    .foregroundStyle(Theme.accentBright)
                                Text("Watchit Watch & Download (Admin)")
                                    .font(.system(size: 14.5, weight: .bold))
                                Spacer()
                            }
                            Text("Creates a clean browser Watch + Direct Download URL you can copy & paste anywhere.")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.68))

                            if let watchitError {
                                Text(watchitError)
                                    .font(.caption.bold())
                                    .foregroundStyle(Color.red.opacity(0.9))
                            }

                            if let wUrl = watchitWatchURL {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(wUrl)
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                    HStack(spacing: 8) {
                                        Button(watchitCopied ? "Copied!" : "Copy Watch URL") {
                                            UIPasteboard.general.string = wUrl
                                            watchitCopied = true
                                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                                        }
                                        .font(.caption.bold())
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .liquidGlassCapsule(active: true)

                                        if let dUrl = watchitDownloadURL {
                                            Button("Copy Download") {
                                                UIPasteboard.general.string = dUrl
                                                UINotificationFeedbackGenerator().notificationOccurred(.success)
                                            }
                                            .font(.caption.bold())
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 7)
                                            .liquidGlassCapsule()
                                        }
                                    }
                                }
                                .padding(10)
                                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                            }

                            Button {
                                Task {
                                    isCreatingWatchit = true
                                    watchitError = nil
                                    watchitCopied = false
                                    watchitStatus = "Preparing video..."
                                    if let res = await ShareService.shared.createAdminWatchitLink(for: gif, onProgress: { msg in
                                        watchitStatus = msg
                                    }) {
                                        watchitWatchURL = res.watchUrl
                                        watchitDownloadURL = res.downloadUrl
                                        UIPasteboard.general.string = res.watchUrl
                                        watchitCopied = true
                                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                                    } else {
                                        watchitError = "Could not download/upload this video (check connection or size <= 500MB)."
                                    }
                                    watchitStatus = nil
                                    isCreatingWatchit = false
                                }
                            } label: {
                                Group {
                                    if isCreatingWatchit {
                                        HStack(spacing: 8) {
                                            ProgressView().tint(.white)
                                            Text(watchitStatus ?? "Uploading...")
                                        }
                                    } else {
                                        Text(watchitWatchURL == nil ? "Create Watch & Download URL" : "Regenerate Watchit URL")
                                    }
                                }
                                .font(.system(size: 13.5, weight: .bold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                                .liquidGlassCapsule(active: true)
                            }
                            .disabled(isCreatingWatchit)
                        }
                        .padding(14)
                        .liquidGlassCard(cornerRadius: 18)
                    }

                    if license.isAdmin, !gif.isImage, let mp4URL = gif.allVideoURLs(hd: true).first {
                        Button {
                            showIGDirectSheet = true
                        } label: {
                            shareRow(icon: "paperplane.circle.fill", text: "Send MP4 to IG DM / Group (Admin)")
                        }
                    }

                    if let local = OfflineManager.localMediaURL(forId: gif.id) {
                        ShareLink(item: local) {
                            shareRow(icon: "doc.fill", text: "Share Downloaded Video File (AirDrop / Messages)")
                        }
                    }
                    ShareLink(item: gif.webURL) {
                        shareRow(icon: "link", text: "Share Source URL")
                    }

                    Spacer()
                }
                .padding(18)
                .foregroundStyle(.white)
            }
            .sheet(isPresented: $showIGDirectSheet) {
                if let mp4URL = gif.allVideoURLs(hd: true).first {
                    IGDirectSendSheet(
                        videoURL: mp4URL,
                        title: gif.title ?? "",
                        referer: MediaHeaders.headers(for: mp4URL)["Referer"]
                    )
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                }
            }
            .sheet(isPresented: $showActivitySheet) {
                if let urlStr = generatedLink, let u = URL(string: urlStr) {
                    ActivityShareSheet(items: [u])
                } else if let code = generatedCode {
                    ActivityShareSheet(items: [code])
                }
            }
        }
    }

    private func shareRow(icon: String, text: String) -> some View {
        HStack {
            Image(systemName: icon)
            Text(text).font(.subheadline.bold())
            Spacer()
            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.white.opacity(0.5))
        }
        .padding(14)
        .liquidGlassCard(cornerRadius: 16)
    }
}

struct ReceiveDropSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onOpenPost: (Gif) -> Void

    @State private var input = ""
    @State private var errorText: String?
    @State private var isOpening = false
    @State private var showFileImporter = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.clear.liquidGlassBackground(tinted: UserStore.shared.data.settings.tintedGlass)
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Receive Shared Drop or File")
                            .font(.system(size: 20, weight: .bold))
                        Spacer()
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .bold))
                                .frame(width: 34, height: 34)
                                .liquidGlassCircle()
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Paste a `TTDROP:` / `TTPOST:` code or `tinytiny://` link from another user:")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.72))

                        TextField("TTDROP:... or tinytiny://drop/...", text: $input)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .font(.system(size: 13, design: .monospaced))
                            .padding(12)
                            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))

                        if let errorText {
                            Text(errorText).font(.caption.bold()).foregroundStyle(.red.opacity(0.9))
                        }

                        Button {
                            Task {
                                isOpening = true
                                errorText = nil
                                let err = await ShareService.shared.handleIncomingShare(input)
                                isOpening = false
                                if let err {
                                    errorText = err
                                } else if let post = ShareService.shared.pendingReceivedPost {
                                    onOpenPost(post)
                                    dismiss()
                                } else if ShareService.shared.pendingReceivedPosts != nil {
                                    dismiss()
                                }
                            }
                        } label: {
                            Group {
                                if isOpening { ProgressView().tint(.white) }
                                else { Text("Decrypt & Open").font(.system(size: 15, weight: .bold)) }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .liquidGlassCapsule(active: true)
                        }
                        .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || isOpening)
                    }
                    .padding(16)
                    .liquidGlassCard(cornerRadius: 18)

                    Button {
                        showFileImporter = true
                    } label: {
                        HStack {
                            Image(systemName: "folder.badge.plus")
                            Text("Share a Video or File From iPhone Files (AES-256 Encrypted)")
                                .font(.subheadline.bold())
                            Spacer()
                        }
                        .padding(14)
                        .liquidGlassCard(cornerRadius: 16)
                    }

                    Spacer()
                }
                .padding(18)
                .foregroundStyle(.white)
            }
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.movie, .video, .image, .data]) { result in
                if case .success(let url) = result {
                    let accessed = url.startAccessingSecurityScopedResource()
                    Task {
                        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                        if let res = await ShareService.shared.createEncryptedFileShareLink(fileURL: url) {
                            UIPasteboard.general.string = res.code
                            errorText = "Encrypted Drop Code copied to clipboard!"
                        } else {
                            errorText = "File share upload failed (check worker limit / connection)."
                        }
                    }
                }
            }
        }
    }
}

struct ShareCollectionSheet: View {
    let posts: [Gif]
    @Environment(\.dismiss) private var dismiss

    @State private var collectionTitle: String = ""
    @State private var generatedLink: String?
    @State private var generatedCode: String?
    @State private var isCreating = false
    @State private var statusNote: String?
    @State private var showActivitySheet = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.clear.liquidGlassBackground(tinted: UserStore.shared.data.settings.tintedGlass)
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Share \(posts.count) Video\(posts.count == 1 ? "" : "s")")
                                .font(.system(size: 20, weight: .bold))
                            Text("Anyone with this link can watch in browser or TinyTiny")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.65))
                        }
                        Spacer()
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .bold))
                                .frame(width: 34, height: 34)
                                .liquidGlassCircle()
                        }
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Collection Title (Optional)")
                            .font(.caption.bold())
                            .foregroundStyle(.white.opacity(0.75))
                        TextField("e.g. Weekend Stash (\(posts.count) clips)", text: $collectionTitle)
                            .font(.system(size: 14))
                            .padding(11)
                            .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))

                        if let statusNote {
                            Text(statusNote)
                                .font(.caption.bold())
                                .foregroundStyle(Theme.accentBright)
                        }

                        if let link = generatedLink {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Share URL (Web + TinyTiny)")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.white.opacity(0.65))
                                HStack {
                                    Text(link)
                                        .font(.system(size: 11.5, design: .monospaced))
                                        .lineLimit(1)
                                    Spacer()
                                    Button("Copy URL") {
                                        UIPasteboard.general.string = link
                                        statusNote = "Copied share URL!"
                                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                                    }
                                    .font(.caption.bold())
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .liquidGlassCapsule(active: true)
                                }
                                .padding(10)
                                .background(Color.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 12))
                            }
                        }

                        HStack(spacing: 8) {
                            Button {
                                Task { await generateLink() }
                            } label: {
                                Group {
                                    if isCreating { ProgressView().tint(.white) }
                                    else { Text(generatedLink == nil ? "Create Share URL" : "Regenerate Link") }
                                }
                                .font(.system(size: 14, weight: .bold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .liquidGlassCapsule(active: true)
                            }
                            .disabled(isCreating || posts.isEmpty)

                            if generatedLink != nil {
                                Button {
                                    showActivitySheet = true
                                } label: {
                                    Image(systemName: "square.and.arrow.up")
                                        .font(.system(size: 15, weight: .bold))
                                        .frame(width: 44, height: 42)
                                        .liquidGlassCircle()
                                }
                            }
                        }
                    }
                    .padding(14)
                    .liquidGlassCard(cornerRadius: 18)

                    Spacer()
                }
                .padding(18)
                .foregroundStyle(.white)
            }
            .task {
                if generatedLink == nil && !posts.isEmpty {
                    await generateLink()
                }
            }
            .sheet(isPresented: $showActivitySheet) {
                if let link = generatedLink, let u = URL(string: link) {
                    ActivityShareSheet(items: [u])
                } else if let link = generatedLink {
                    ActivityShareSheet(items: [link])
                }
            }
        }
    }

    private func generateLink() async {
        isCreating = true
        statusNote = nil
        let cleanTitle = collectionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if let res = await ShareService.shared.createEncryptedCollectionShareLink(
            for: posts,
            title: cleanTitle.isEmpty ? nil : cleanTitle
        ) {
            generatedLink = res.link
            generatedCode = res.code
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } else {
            statusNote = "Could not create share URL. Check connection."
        }
        isCreating = false
    }
}

struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - Admin Direct IG DM / Group Chat MP4 Sender Sheet

struct DirectIGDropPayload: Identifiable {
    let id = UUID()
    let videoURL: URL
    let title: String
    let referer: String?

    @MainActor
    static func fetchFromWorker(dropId: String) async -> DirectIGDropPayload? {
        let base = LicenseManager.shared.normalizedBaseURL
        let validDropId = dropId.range(of: "^[A-Za-z0-9_-]{4,64}$", options: .regularExpression) != nil
        guard validDropId,
              let url = URL(string: "\(base)/v1/igdrop/\(dropId)"),
              let (data, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mp4Str = json["mp4Url"] as? String,
              let mp4URL = URL(string: mp4Str),
              mp4URL.scheme?.lowercased() == "https" else {
            return nil
        }
        let title = (json["title"] as? String) ?? "Video"
        let ref = mp4Str.contains("xvideos") ? "https://www.xvideos.com/" : nil
        return DirectIGDropPayload(videoURL: mp4URL, title: title, referer: ref)
    }
}

struct IGDirectSendSheet: View {
    let videoURL: URL
    let title: String
    let referer: String?

    @Environment(\.dismiss) private var dismiss
    @State private var threads: [InstagramWebEngine.IGDirectThread] = []
    @State private var isLoading = true
    @State private var sendingThreadId: String?
    @State private var statusText: String?
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.clear.liquidGlassBackground(tinted: UserStore.shared.data.settings.tintedGlass)
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Send MP4 to Instagram")
                                .font(.system(size: 19, weight: .bold))
                            Text(title.isEmpty ? "In-memory upload (not saved to phone)" : title)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.62))
                                .lineLimit(1)
                        }
                        Spacer()
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 13, weight: .bold))
                                .frame(width: 32, height: 32)
                                .liquidGlassCircle()
                        }
                    }

                    if let statusText {
                        Text(statusText)
                            .font(.subheadline.bold())
                            .foregroundStyle(.green)
                    }
                    if let errorText {
                        Text(errorText)
                            .font(.caption.bold())
                            .foregroundStyle(.red)
                    }

                    if isLoading {
                        Spacer()
                        HStack {
                            Spacer()
                            ProgressView("Loading IG DMs & Group Chats...")
                                .tint(Theme.accentBright)
                            Spacer()
                        }
                        Spacer()
                    } else if threads.isEmpty {
                        Spacer()
                        VStack(spacing: 10) {
                            Text("No Instagram chats loaded.")
                                .font(.subheadline.bold())
                            Text("Make sure you are signed into Instagram in the IG tab.")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        .frame(maxWidth: .infinity)
                        Spacer()
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                ForEach(threads) { thread in
                                    Button {
                                        Task { await send(to: thread) }
                                    } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: thread.isGroup ? "person.3.fill" : "person.fill")
                                                .font(.system(size: 15, weight: .semibold))
                                                .foregroundStyle(Theme.accentBright)
                                                .frame(width: 36, height: 36)
                                                .liquidGlassCircle()

                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(thread.title)
                                                    .font(.subheadline.bold())
                                                    .lineLimit(1)
                                                Text(thread.isGroup ? "Group Chat · \(thread.memberCount) members" : "Direct Message")
                                                    .font(.caption2)
                                                    .foregroundStyle(.white.opacity(0.55))
                                            }
                                            Spacer()
                                            if sendingThreadId == thread.id {
                                                ProgressView().tint(.white)
                                            } else {
                                                Image(systemName: "paperplane.fill")
                                                    .foregroundStyle(Theme.accentBright)
                                            }
                                        }
                                        .padding(12)
                                        .liquidGlassCard(cornerRadius: 16)
                                    }
                                    .disabled(sendingThreadId != nil)
                                }
                            }
                        }
                    }
                }
                .padding(18)
                .foregroundStyle(.white)
            }
            .task { await loadInbox() }
        }
    }

    private func loadInbox() async {
        isLoading = true
        errorText = nil
        do {
            threads = try await InstagramWebEngine.shared.fetchDirectThreads()
        } catch {
            errorText = error.localizedDescription
        }
        isLoading = false
    }

    private func send(to thread: InstagramWebEngine.IGDirectThread) async {
        sendingThreadId = thread.id
        errorText = nil
        statusText = nil
        do {
            try await InstagramWebEngine.shared.sendMP4ToDirectThread(
                threadId: thread.id,
                videoURL: videoURL,
                referer: referer
            )
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            statusText = "Sent MP4 to \(thread.title)!"
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            errorText = error.localizedDescription
        }
        sendingThreadId = nil
    }
}
