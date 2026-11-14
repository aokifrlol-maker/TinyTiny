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
                "cipher": sealed.base64EncodedString()
            ])
            if let (data, resp) = try? await session.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let shareId = json["id"] as? String {
                let code = "TTDROP:\(shareId).\(encodedKey)"
                let link = "\(base)/s/\(shareId)#k=\(encodedKey)"
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

        guard !shareId.isEmpty,
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

        if let blobStr = payload.encryptedBlobUrl, let blobURL = URL(string: blobStr),
           let (cipher, resp) = try? await session.data(from: blobURL),
           (resp as? HTTPURLResponse)?.statusCode ?? 200 < 400,
           let plainBytes = try? CryptoBox.open(cipher, using: key) {
            let ext = (payload.fileExtension?.isEmpty == false) ? payload.fileExtension! : "mp4"
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

    @State private var generatedCode: String?
    @State private var generatedLink: String?
    @State private var statusNote: String?
    @State private var isCreatingDrop = false
    @State private var showActivitySheet = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.modalGradient.ignoresSafeArea()
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

                        if OfflineManager.localMediaURL(forId: gif.id) == nil,
                           let remote = gif.videoURL(hd: false) ?? gif.imageURL,
                           !remote.absoluteString.lowercased().contains(".m3u8") {
                            Button {
                                Task {
                                    isCreatingDrop = true
                                    statusNote = "Encrypting & uploading media copy..."
                                    if let res = await ShareService.shared.createEncryptedRemoteMediaShareLink(for: gif) {
                                        generatedLink = res.link
                                        generatedCode = res.code
                                        statusNote = "Encrypted video copy uploaded & linked!"
                                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                                    } else {
                                        statusNote = "Could not encrypt & upload this clip."
                                    }
                                    isCreatingDrop = false
                                }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "lock.doc.fill")
                                    Text("Encrypt & Host Video Copy (Up to 90 MB)")
                                }
                                .font(.system(size: 12.5, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .liquidGlassCapsule()
                            }
                            .disabled(isCreatingDrop)
                        }
                    }
                    .padding(14)
                    .liquidGlassCard(cornerRadius: 18)

                    // 2. Direct File / Post Link via System Share Sheet
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
                Theme.modalGradient.ignoresSafeArea()
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
                Theme.modalGradient.ignoresSafeArea()
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
