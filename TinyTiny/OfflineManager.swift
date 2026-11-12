import SwiftUI
import AVFoundation

/// Manages offline video/image downloading into the app's private, passcode-protected Documents/OfflineVault directory.
/// Stores only relative filenames so offline media survives iOS container UUID changes across app updates/re-signs.
@MainActor
final class OfflineManager: ObservableObject {
    static let shared = OfflineManager()

    @Published var activeDownloads: [String: Double] = [:] // gif.id -> progress (0.0 ... 1.0)

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 300
        return URLSession(configuration: cfg)
    }()

    nonisolated static var vaultDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("OfflineVault", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
            var rv = URLResourceValues()
            rv.isExcludedFromBackup = true
            var mutableDir = dir
            try? mutableDir.setResourceValues(rv)
        }
        return dir
    }

    nonisolated static func safeFileStem(for id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let cleaned = id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let str = String(cleaned)
        return str.isEmpty ? "media" : String(str.prefix(64))
    }

    nonisolated static func localMediaURL(forId id: String) -> URL? {
        let stem = safeFileStem(for: id)
        let dir = vaultDirectory
        for ext in ["mp4", "mov", "gif", "jpg", "png"] {
            let candidate = dir.appendingPathComponent("\(stem).\(ext)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    nonisolated static func localThumbURL(forId id: String) -> URL? {
        let stem = safeFileStem(for: id)
        let thumb = vaultDirectory.appendingPathComponent("\(stem)_thumb.jpg")
        if FileManager.default.fileExists(atPath: thumb.path) {
            return thumb
        }
        return localMediaURL(forId: id)
    }

    func localMediaURL(for gif: Gif) -> URL? {
        Self.localMediaURL(forId: gif.id)
    }

    func localThumbURL(for gif: Gif) -> URL? {
        Self.localThumbURL(forId: gif.id)
    }

    func isDownloaded(_ gif: Gif) -> Bool {
        localMediaURL(for: gif) != nil
    }

    func isDownloading(_ gif: Gif) -> Bool {
        activeDownloads[gif.id] != nil
    }

    func toggleDownload(_ gif: Gif) {
        if isDownloaded(gif) {
            removeDownload(gif)
        } else if !isDownloading(gif) {
            Task { await download(gif) }
        }
    }

    func download(_ gif: Gif) async {
        guard activeDownloads[gif.id] == nil else { return }
        let remoteURL: URL? = gif.isImage ? gif.imageURL : gif.videoURL(hd: UserStore.shared.data.settings.hd)
        guard let remoteURL else { return }

        activeDownloads[gif.id] = 0.05
        defer { activeDownloads.removeValue(forKey: gif.id) }

        var req = URLRequest(url: remoteURL)
        req.setValue(Config.userAgent, forHTTPHeaderField: "User-Agent")
        if let host = remoteURL.host?.lowercased() {
            if host.contains("twimg.com") || host.contains("x.com") {
                req.setValue("https://x.com/", forHTTPHeaderField: "Referer")
            } else if host.contains("cdninstagram.com") || host.contains("instagram.com") {
                req.setValue("https://www.instagram.com/", forHTTPHeaderField: "Referer")
            } else if host.contains("rule34.xxx") {
                req.setValue("https://rule34.xxx/", forHTTPHeaderField: "Referer")
            } else {
                req.setValue(Config.referer, forHTTPHeaderField: "Referer")
            }
        }

        do {
            activeDownloads[gif.id] = 0.25
            let (tempURL, resp) = try await session.download(for: req)
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return
            }
            activeDownloads[gif.id] = 0.80

            let stem = Self.safeFileStem(for: gif.id)
            let pathExt = remoteURL.pathExtension.lowercased()
            let ext: String
            if gif.isImage {
                ext = (pathExt == "png" || pathExt == "gif") ? pathExt : "jpg"
            } else {
                ext = (pathExt == "mov" || pathExt == "gif") ? pathExt : "mp4"
            }

            let destURL = Self.vaultDirectory.appendingPathComponent("\(stem).\(ext)")
            try? FileManager.default.removeItem(at: destURL)
            try FileManager.default.moveItem(at: tempURL, to: destURL)

            // Download or generate offline thumbnail so Offline grid works in Airplane Mode
            let thumbDest = Self.vaultDirectory.appendingPathComponent("\(stem)_thumb.jpg")
            if let thumbRemote = gif.thumbURL {
                var thumbReq = URLRequest(url: thumbRemote)
                thumbReq.setValue(Config.userAgent, forHTTPHeaderField: "User-Agent")
                if let (thumbData, _) = try? await session.data(for: thumbReq), !thumbData.isEmpty {
                    try? thumbData.write(to: thumbDest, options: [.atomic])
                }
            }
            if !FileManager.default.fileExists(atPath: thumbDest.path), !gif.isImage {
                await generateVideoThumbnail(from: destURL, to: thumbDest)
            }

            activeDownloads[gif.id] = 1.0
            UserStore.shared.recordDownload(gif)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            // Download failed cleanly; state is cleared by defer
        }
    }

    private func generateVideoThumbnail(from videoURL: URL, to destURL: URL) async {
        let asset = AVURLAsset(url: videoURL)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 540, height: 960)
        let time = CMTime(seconds: 0.5, preferredTimescale: 600)
        if let cgImage = try? await gen.image(at: time).image {
            let uiImage = UIImage(cgImage: cgImage)
            if let jpeg = uiImage.jpegData(compressionQuality: 0.78) {
                try? jpeg.write(to: destURL, options: [.atomic])
            }
        }
    }

    func removeDownload(_ gif: Gif) {
        let stem = Self.safeFileStem(for: gif.id)
        let dir = Self.vaultDirectory
        for ext in ["mp4", "mov", "gif", "jpg", "png"] {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(stem).\(ext)"))
        }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(stem)_thumb.jpg"))
        UserStore.shared.removeDownloadedRecord(gif)
        objectWillChange.send()
    }

    func clearAllDownloads() {
        let dir = Self.vaultDirectory
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in files {
                try? FileManager.default.removeItem(at: f)
            }
        }
        UserStore.shared.data.downloaded.removeAll()
        objectWillChange.send()
    }

    func totalDiskUsageString() -> String {
        let dir = Self.vaultDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey]
        ) else { return "0 MB" }

        var totalBytes: Int64 = 0
        for f in files {
            if let sz = try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                totalBytes += Int64(sz)
            }
        }
        let mb = Double(totalBytes) / (1024.0 * 1024.0)
        if mb < 0.1 { return "0 MB" }
        if mb >= 1024 {
            return String(format: "%.2f GB", mb / 1024.0)
        }
        return String(format: "%.1f MB", mb)
    }
}
