import SwiftUI
import AVFoundation
import WebKit
import Photos

/// Manages offline video/image downloading into the app's private, passcode-protected Documents/OfflineVault directory.
/// Stores only relative filenames so offline media survives iOS container UUID changes across app updates/re-signs.
@MainActor
final class OfflineManager: ObservableObject {
    static let shared = OfflineManager()

    @Published var activeDownloads: [String: Double] = [:] // gif.id -> progress (0.0 ... 1.0)
    @Published var lastDownloadError: String? = nil

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 300
        cfg.httpShouldSetCookies = true
        return URLSession(configuration: cfg)
    }()

    @Published private(set) var cachedDiskUsageString: String = "0 MB"

    private static let indexLock = NSLock()
    private static let vaultQueue = DispatchQueue(label: "tinytiny.offline.vault", qos: .utility)
    private nonisolated(unsafe) static var cachedVaultDir: URL? = nil
    private nonisolated(unsafe) static var mediaIndex: [String: URL] = [:]
    private nonisolated(unsafe) static var thumbIndex: [String: URL] = [:]
    private nonisolated(unsafe) static var indexReady: Bool = false

    private init() {
        Self.vaultQueue.async {
            Self.ensureIndexReady()
            let usage = Self.computeDiskUsageString()
            Task { @MainActor in
                self.cachedDiskUsageString = usage
            }
        }
    }

    func refreshDiskUsage() {
        Self.vaultQueue.async {
            let usage = Self.computeDiskUsageString()
            Task { @MainActor in
                self.cachedDiskUsageString = usage
            }
        }
    }

    nonisolated static var vaultDirectory: URL {
        indexLock.lock()
        if let cached = cachedVaultDir {
            indexLock.unlock()
            return cached
        }
        indexLock.unlock()
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
        indexLock.lock()
        cachedVaultDir = dir
        indexLock.unlock()
        return dir
    }

    nonisolated private static func ensureIndexReady() {
        indexLock.lock()
        if indexReady {
            indexLock.unlock()
            return
        }
        indexLock.unlock()

        let dir = vaultDirectory
        var mMap: [String: URL] = [:]
        var tMap: [String: URL] = [:]
        let validExts: Set<String> = ["mp4", "mov", "m4v", "gif", "jpg", "png", "webp"]
        if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            for f in files {
                let name = f.lastPathComponent
                if name.hasSuffix("_thumb.jpg") {
                    let stem = String(name.dropLast("_thumb.jpg".count))
                    tMap[stem] = f
                } else {
                    let ext = f.pathExtension.lowercased()
                    if validExts.contains(ext) {
                        let stem = f.deletingPathExtension().lastPathComponent
                        mMap[stem] = f
                    }
                }
            }
        }
        indexLock.lock()
        if !indexReady {
            mediaIndex = mMap
            thumbIndex = tMap
            indexReady = true
        }
        indexLock.unlock()
    }

    nonisolated static func registerIndexedFile(stem: String, mediaURL: URL? = nil, thumbURL: URL? = nil) {
        indexLock.lock()
        if let m = mediaURL { mediaIndex[stem] = m }
        if let t = thumbURL { thumbIndex[stem] = t }
        indexLock.unlock()
    }

    nonisolated static func removeIndexedFile(stem: String) {
        indexLock.lock()
        mediaIndex.removeValue(forKey: stem)
        thumbIndex.removeValue(forKey: stem)
        indexLock.unlock()
    }

    nonisolated static func clearIndexedFiles() {
        indexLock.lock()
        mediaIndex.removeAll()
        thumbIndex.removeAll()
        indexReady = true
        indexLock.unlock()
    }

    nonisolated static func safeFileStem(for id: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let cleaned = id.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let str = String(cleaned)
        return str.isEmpty ? "media" : String(str.prefix(64))
    }

    nonisolated static func localMediaURL(forId id: String) -> URL? {
        ensureIndexReady()
        let stem = safeFileStem(for: id)
        indexLock.lock()
        let found = mediaIndex[stem]
        indexLock.unlock()
        return found
    }

    nonisolated static func localThumbURL(forId id: String) -> URL? {
        ensureIndexReady()
        let stem = safeFileStem(for: id)
        indexLock.lock()
        let thumb = thumbIndex[stem]
        let media = mediaIndex[stem]
        indexLock.unlock()
        if let thumb { return thumb }
        if let media, ["jpg", "jpeg", "png", "webp", "gif"].contains(media.pathExtension.lowercased()) {
            return media
        }
        return nil
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
        lastDownloadError = nil

        let hd = UserStore.shared.data.settings.hd
        var rawCandidates: [URL] = gif.isImage
            ? gif.imageFallbackURLs.filter { !$0.isFileURL }
            : gif.allVideoURLs(hd: hd).filter { !$0.isFileURL }

        if rawCandidates.isEmpty && gif.isLongVideoPost {
            let resolved = await LongVideoAPI.shared.resolvePlayableURLs(for: gif)
            if !resolved.isEmpty {
                rawCandidates = resolved
            } else {
                rawCandidates = MediaMetaRegistry.albumItems(for: gif.id).map(\.url)
            }
        }

        // Always prefer direct downloadable MP4/MOV/M4V/image URLs before any .m3u8 playlist
        let directCandidates = rawCandidates.filter { !$0.absoluteString.lowercased().contains(".m3u8") }
        let candidates = directCandidates.isEmpty ? rawCandidates : directCandidates
        guard !candidates.isEmpty else {
            lastDownloadError = "No downloadable media URL available."
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }

        activeDownloads[gif.id] = 0.08
        defer { activeDownloads.removeValue(forKey: gif.id) }

        let stem = Self.safeFileStem(for: gif.id)
        let webCookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()

        for (idx, remoteURL) in candidates.enumerated() {
            if remoteURL.absoluteString.lowercased().contains(".m3u8") {
                continue
            }

            for includeReferer in [true, false] {
                var req = URLRequest(url: remoteURL)
                req.timeoutInterval = 30
                for (k, v) in MediaHeaders.headers(for: remoteURL, includeReferer: includeReferer) {
                    req.setValue(v, forHTTPHeaderField: k)
                }
                req.setValue("*/*", forHTTPHeaderField: "Accept")

                if let host = remoteURL.host?.lowercased() {
                    let matching = webCookies.filter { c in
                        let cd = c.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
                        return !cd.isEmpty && (host == cd || host.hasSuffix("." + cd))
                    }
                    if !matching.isEmpty {
                        let cookieHeader = HTTPCookie.requestHeaderFields(with: matching)
                        for (k, v) in cookieHeader {
                            req.setValue(v, forHTTPHeaderField: k)
                        }
                    }
                }

                do {
                    activeDownloads[gif.id] = min(0.65, 0.18 + Double(idx) * 0.12)
                    let (tempURL, resp) = try await session.download(for: req)
                    if let http = resp as? HTTPURLResponse {
                        guard (200..<300).contains(http.statusCode) else {
                            try? FileManager.default.removeItem(at: tempURL)
                            continue
                        }
                        let mime = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
                        if mime.contains("text/html") || mime.contains("application/json") || mime.contains("mpegurl") {
                            try? FileManager.default.removeItem(at: tempURL)
                            continue
                        }
                    }

                    let fileSize = (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? NSNumber)?.int64Value ?? 0
                    guard fileSize > 2048 else {
                        try? FileManager.default.removeItem(at: tempURL)
                        continue
                    }

                    activeDownloads[gif.id] = 0.82
                    let pathExt = remoteURL.pathExtension.lowercased()
                    let ext: String
                    if gif.isImage {
                        ext = (pathExt == "png" || pathExt == "gif" || pathExt == "webp") ? pathExt : "jpg"
                    } else {
                        ext = (pathExt == "mov" || pathExt == "gif" || pathExt == "m4v") ? pathExt : "mp4"
                    }

                    let destURL = Self.vaultDirectory.appendingPathComponent("\(stem).\(ext)")
                    try? FileManager.default.removeItem(at: destURL)
                    try FileManager.default.moveItem(at: tempURL, to: destURL)

                    // Download or generate offline thumbnail so Offline grid works in Airplane Mode
                    let thumbDest = Self.vaultDirectory.appendingPathComponent("\(stem)_thumb.jpg")
                    if let thumbRemote = gif.thumbURL, !thumbRemote.isFileURL {
                        var thumbReq = URLRequest(url: thumbRemote)
                        for (k, v) in MediaHeaders.headers(for: thumbRemote, includeReferer: true) {
                            thumbReq.setValue(v, forHTTPHeaderField: k)
                        }
                        if let (thumbData, tResp) = try? await session.data(for: thumbReq),
                           (tResp as? HTTPURLResponse)?.statusCode ?? 200 < 400,
                           !thumbData.isEmpty {
                            try? thumbData.write(to: thumbDest, options: [.atomic])
                        }
                    }
                    if !FileManager.default.fileExists(atPath: thumbDest.path), !gif.isImage {
                        await generateVideoThumbnail(from: destURL, to: thumbDest)
                    }

                    Self.registerIndexedFile(
                        stem: stem,
                        mediaURL: destURL,
                        thumbURL: FileManager.default.fileExists(atPath: thumbDest.path) ? thumbDest : nil
                    )

                    activeDownloads[gif.id] = 1.0
                    UserStore.shared.recordDownload(gif)
                    UserStore.shared.saveNow()
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    return
                } catch {
                    continue
                }
            }
        }

        lastDownloadError = "Download failed for this media."
        UINotificationFeedbackGenerator().notificationOccurred(.error)
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

    private static let photoIDsKey = "tt_saved_photo_asset_ids_v1"

    func recordSavedPhotoAssetId(_ localIdentifier: String, for gifId: String) {
        guard !localIdentifier.isEmpty else { return }
        var map = UserDefaults.standard.dictionary(forKey: Self.photoIDsKey) as? [String: String] ?? [:]
        map[gifId] = localIdentifier
        UserDefaults.standard.set(map, forKey: Self.photoIDsKey)
    }

    func savedPhotoAssetId(for gifId: String) -> String? {
        let map = UserDefaults.standard.dictionary(forKey: Self.photoIDsKey) as? [String: String] ?? [:]
        return map[gifId]
    }

    func deleteSavedPhotos(forIds gifIds: [String]) {
        var map = UserDefaults.standard.dictionary(forKey: Self.photoIDsKey) as? [String: String] ?? [:]
        var assetIds: [String] = []
        for gid in gifIds {
            if let localId = map.removeValue(forKey: gid), !localId.isEmpty {
                assetIds.append(localId)
            }
        }
        UserDefaults.standard.set(map, forKey: Self.photoIDsKey)
        guard !assetIds.isEmpty else { return }
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: assetIds, options: nil)
        guard fetched.count > 0 else { return }
        PHPhotoLibrary.shared().performChanges({
            PHAssetChangeRequest.deleteAssets(fetched)
        }, completionHandler: nil)
    }

    func removeDownload(_ gif: Gif, deleteFromPhotos: Bool = true) {
        let stem = Self.safeFileStem(for: gif.id)
        Self.removeIndexedFile(stem: stem)
        let dir = Self.vaultDirectory
        Self.vaultQueue.async {
            for ext in ["mp4", "mov", "m4v", "gif", "jpg", "png", "webp"] {
                try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(stem).\(ext)"))
            }
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(stem)_thumb.jpg"))
            let usage = Self.computeDiskUsageString()
            Task { @MainActor in
                self.cachedDiskUsageString = usage
            }
        }
        if deleteFromPhotos {
            deleteSavedPhotos(forIds: [gif.id])
        }
        UserStore.shared.removeDownloadedRecord(gif)
        objectWillChange.send()
    }

    func clearAllDownloads() {
        let allIds = UserStore.shared.data.downloaded.map(\.id)
        Self.clearIndexedFiles()
        deleteSavedPhotos(forIds: allIds)
        let dir = Self.vaultDirectory
        Self.vaultQueue.async {
            if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for f in files {
                    try? FileManager.default.removeItem(at: f)
                }
            }
            Task { @MainActor in
                self.cachedDiskUsageString = "0 MB"
            }
        }
        UserStore.shared.clearAllDownloadedRecords()
        objectWillChange.send()
    }

    func totalDiskUsageString() -> String {
        cachedDiskUsageString
    }

    nonisolated private static func computeDiskUsageString() -> String {
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
