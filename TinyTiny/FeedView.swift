import SwiftUI
import AVFoundation

// MARK: - Native AVPlayer Layer (Properly Bounded & Clipped)

final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        clipsToBounds = true
        backgroundColor = .clear
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
    }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    let fill: Bool
    var onReadyForDisplay: ((Bool) -> Void)? = nil

    final class Coordinator {
        var readyObservation: NSKeyValueObservation?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PlayerUIView {
        let v = PlayerUIView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        context.coordinator.readyObservation = v.playerLayer.observe(\.isReadyForDisplay, options: [.new, .initial]) { layer, _ in
            let ready = layer.isReadyForDisplay
            DispatchQueue.main.async {
                onReadyForDisplay?(ready)
            }
        }
        return v
    }

    func updateUIView(_ v: PlayerUIView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
        let targetGravity: AVLayerVideoGravity = fill ? .resizeAspectFill : .resizeAspect
        if v.playerLayer.videoGravity != targetGravity {
            v.playerLayer.videoGravity = targetGravity
        }
    }
}

// MARK: - Source-Aware HTTP Headers & Fast Cached Image/Video Preloaders

enum MediaHeaders {
    static func headers(for url: URL, includeReferer: Bool = true) -> [String: String] {
        let host = url.host?.lowercased() ?? ""
        var h: [String: String] = ["User-Agent": Config.userAgent]
        guard includeReferer else { return h }
        if host.contains("redgifs.com") {
            h["Referer"] = "https://www.redgifs.com/"
        } else if host.contains("yande.re") {
            h["Referer"] = "https://yande.re/"
        } else if host.contains("hypnohub") {
            h["Referer"] = "https://hypnohub.net/"
        } else if host.contains("realbooru") {
            h["Referer"] = "https://realbooru.com/"
        } else if host.contains("gelbooru") {
            h["Referer"] = "https://gelbooru.com/"
        } else if host.contains("rule34") {
            h["Referer"] = "https://rule34.xxx/"
        } else if host.contains("twimg.com") || host.contains("x.com") || host.contains("twitter.com") {
            h["Referer"] = "https://x.com/"
        } else if host.contains("cdninstagram.com") || host.contains("fbcdn.net") || host.contains("instagram.com") {
            h["Referer"] = "https://www.instagram.com/"
        } else if host.contains("eporner") {
            h["Referer"] = "https://www.eporner.com/"
        } else if host.contains("pornhub") || host.contains("phncdn") {
            h["Referer"] = "https://www.pornhub.com/"
        } else if host.contains("xhamster") || host.contains("xhcdn") {
            h["Referer"] = "https://xhamster.com/"
        } else if host.contains("spankbang") || host.contains("sb-cd") {
            h["Referer"] = "https://spankbang.com/"
        } else if host.contains("cum.st") {
            h["Referer"] = "https://cum.st/"
        } else {
            h["Referer"] = Config.referer
        }
        return h
    }
}

@MainActor
final class MediaImageLoader {
    static let shared = MediaImageLoader()
    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.urlCache = URLCache.shared
        return URLSession(configuration: cfg)
    }()

    init() {
        cache.countLimit = 180
        cache.totalCostLimit = 96 * 1024 * 1024
    }

    func cached(_ url: URL) -> UIImage? {
        cache.object(forKey: url.absoluteString as NSString)
    }

    func load(_ url: URL) async -> UIImage? {
        if url.isFileURL {
            if let img = cached(url) { return img }
            if let data = try? Data(contentsOf: url), let img = UIImage(data: data) {
                cache.setObject(img, forKey: url.absoluteString as NSString)
                return img
            }
            return nil
        }
        let key = url.absoluteString
        if let existing = cache.object(forKey: key as NSString) { return existing }
        if let task = inFlight[key] { return await task.value }

        let task = Task<UIImage?, Never> {
            for useReferer in [true, false] {
                var req = URLRequest(url: url)
                for (k, v) in MediaHeaders.headers(for: url, includeReferer: useReferer) {
                    req.setValue(v, forHTTPHeaderField: k)
                }
                if let (data, resp) = try? await session.data(for: req),
                   (resp as? HTTPURLResponse)?.statusCode ?? 200 < 400,
                   let img = UIImage(data: data) {
                    cache.setObject(img, forKey: key as NSString, cost: data.count)
                    return img
                }
            }
            return nil
        }
        inFlight[key] = task
        let img = await task.value
        inFlight.removeValue(forKey: key)
        return img
    }

    func prefetch(urls: [URL?]) {
        for u in urls.compactMap({ $0 }) where cached(u) == nil {
            Task.detached(priority: .utility) { _ = await MediaImageLoader.shared.load(u) }
        }
    }
}

struct RemoteImageView: View {
    let url: URL?
    var fallbackURLs: [URL] = []
    var fill: Bool = false
    var showSpinnerOnLoad: Bool = true
    var onFailed: (() -> Void)? = nil

    @State private var image: UIImage?
    @State private var didFail = false
    @State private var reloadToken = 0

    private var candidateURLs: [URL] {
        var result: [URL] = []
        var seen = Set<String>()
        if let url, seen.insert(url.absoluteString).inserted {
            result.append(url)
        }
        for fb in fallbackURLs where seen.insert(fb.absoluteString).inserted {
            result.append(fb)
        }
        return result
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: fill ? .fill : .fit)
            } else if didFail {
                VStack(spacing: 10) {
                    Image(systemName: "photo.badge.exclamationmark")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.white.opacity(0.45))
                    Button {
                        didFail = false
                        reloadToken += 1
                    } label: {
                        Text("Tap to retry")
                            .font(.caption.bold())
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .liquidGlassCapsule(tinted: true)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.black)
            } else {
                ZStack {
                    Color.black
                    if showSpinnerOnLoad {
                        ProgressView()
                            .tint(Theme.accent.opacity(0.8))
                    }
                }
            }
        }
        .task(id: "\(url?.absoluteString ?? "nil")_\(reloadToken)") {
            let candidates = candidateURLs
            guard !candidates.isEmpty else {
                didFail = true
                onFailed?()
                return
            }
            for candidate in candidates {
                if let cached = MediaImageLoader.shared.cached(candidate) {
                    image = cached
                    didFail = false
                    return
                }
            }
            for candidate in candidates {
                if let loaded = await MediaImageLoader.shared.load(candidate) {
                    image = loaded
                    didFail = false
                    return
                }
            }
            didFail = true
            onFailed?()
        }
    }
}

@MainActor
final class VideoPreloader {
    static let shared = VideoPreloader()
    private var cachedAssets: [String: AVURLAsset] = [:]
    private var order: [String] = []

    func preload(gifs: [Gif], hd: Bool) {
        MediaImageLoader.shared.prefetch(urls: gifs.prefix(5).map(\.posterURL))
        for gif in gifs.prefix(5) {
            guard !gif.isImage, let url = gif.videoURL(hd: hd) else { continue }
            let key = url.absoluteString
            guard cachedAssets[key] == nil else { continue }
            let asset: AVURLAsset
            if url.isFileURL {
                asset = AVURLAsset(url: url)
            } else {
                asset = AVURLAsset(
                    url: url,
                    options: ["AVURLAssetHTTPHeaderFieldsKey": MediaHeaders.headers(for: url)]
                )
            }
            cachedAssets[key] = asset
            order.append(key)
            if order.count > 14, let oldest = order.first {
                order.removeFirst()
                cachedAssets.removeValue(forKey: oldest)
            }
            Task.detached(priority: .utility) {
                _ = try? await asset.load(.isPlayable)
            }
        }
    }

    func asset(for url: URL, includeReferer: Bool = true) -> AVURLAsset {
        if url.isFileURL {
            return AVURLAsset(url: url)
        }
        if includeReferer, let existing = cachedAssets[url.absoluteString] {
            return existing
        }
        return AVURLAsset(
            url: url,
            options: ["AVURLAssetHTTPHeaderFieldsKey": MediaHeaders.headers(for: url, includeReferer: includeReferer)]
        )
    }
}

// MARK: - Resilient PlayerModel (Auto-Fallback URLs + Black-Screen/Stall Recovery + HLS Looper Fix)

@MainActor
final class PlayerModel: ObservableObject {
    let player = AVQueuePlayer()
    @Published var progress: Double = 0
    @Published var currentSeconds: Double = 0
    @Published var durationSeconds: Double = 0
    @Published var is2xSpeed: Bool = false
    @Published var detectedAspect: Double? = nil
    @Published var isReady: Bool = false
    @Published var allFailed: Bool = false

    private var looper: AVPlayerLooper?
    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var sizeObservation: NSKeyValueObservation?
    private var stallWatchdogTask: Task<Void, Never>?
    private var candidateEntries: [(url: URL, includeReferer: Bool)] = []
    private var currentURLIndex: Int = 0
    private var prepared = false
    private var wantsPlaying = false
    private var hasValidVideoSize = false
    private var layerReadyForDisplay = false
    var onClipEnded: (() -> Void)?

    func prepare(urls: [URL]) {
        guard !prepared, !urls.isEmpty else { return }
        prepared = true
        allFailed = false
        isReady = false
        hasValidVideoSize = false
        layerReadyForDisplay = false
        candidateEntries = Self.buildCandidateEntries(from: urls)
        currentURLIndex = 0
        loadCandidate(at: 0)

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, let item = self.player.currentItem else { return }
                let d = item.duration.seconds
                guard d.isFinite, d > 0 else { return }
                let cur = max(0, time.seconds)
                if cur > 0.08 && self.hasValidVideoSize {
                    self.promoteReadyIfRenderable()
                }
                let ratio = min(max(cur / d, 0), 1)
                if ratio >= 0.97 && self.progress < 0.97 {
                    self.onClipEnded?()
                }
                self.currentSeconds = cur
                self.durationSeconds = d
                self.progress = ratio
            }
        }
    }

    func updateCandidateURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let entries = Self.buildCandidateEntries(from: urls)
        let wasPlaying = wantsPlaying
        if !prepared {
            prepare(urls: urls)
            if wasPlaying { play() }
            return
        }
        // Only hot-swap if the primary resolved stream is actually newer/better than our placeholder
        let existingFirst = candidateEntries.first?.url
        if existingFirst != entries.first?.url {
            candidateEntries = entries
            currentURLIndex = 0
            allFailed = false
            isReady = false
            hasValidVideoSize = false
            loadCandidate(at: 0)
            if wasPlaying { play() }
        }
    }

    func updateLayerReadyForDisplay(_ ready: Bool) {
        layerReadyForDisplay = ready
        if ready { promoteReadyIfRenderable() }
    }

    private func promoteReadyIfRenderable() {
        guard !isReady else { return }
        if hasValidVideoSize && (layerReadyForDisplay || currentSeconds > 0.08) {
            isReady = true
            allFailed = false
            stallWatchdogTask?.cancel()
            stallWatchdogTask = nil
        }
    }

    private static func buildCandidateEntries(from urls: [URL]) -> [(url: URL, includeReferer: Bool)] {
        var entries: [(URL, Bool)] = []
        var seen = Set<String>()
        for u in urls {
            let k1 = "\(u.absoluteString)|ref1"
            if seen.insert(k1).inserted {
                entries.append((u, true))
            }
        }
        // Append no-Referer fallback for CDNs/hosts that intermittently reject hotlink Referer headers
        if let primary = urls.first, !primary.isFileURL {
            let k0 = "\(primary.absoluteString)|ref0"
            if seen.insert(k0).inserted {
                entries.append((primary, false))
            }
        }
        return entries
    }

    func retry() {
        let urls = candidateEntries.filter { $0.includeReferer }.map(\.url)
        let fallbackUrls = urls.isEmpty ? candidateEntries.map(\.url) : urls
        let wasPlaying = wantsPlaying
        teardown()
        prepare(urls: fallbackUrls)
        if wasPlaying { play() }
    }

    private func advanceToNextCandidate() {
        stallWatchdogTask?.cancel()
        stallWatchdogTask = nil
        if currentURLIndex + 1 < candidateEntries.count {
            currentURLIndex += 1
            isReady = false
            hasValidVideoSize = false
            loadCandidate(at: currentURLIndex)
            if wantsPlaying { player.play() }
        } else {
            allFailed = true
        }
    }

    private func scheduleStallWatchdog(forGeneration index: Int) {
        stallWatchdogTask?.cancel()
        stallWatchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_800_000_000)
            guard !Task.isCancelled, let self else { return }
            guard self.wantsPlaying, !self.isReady, self.currentURLIndex == index else { return }
            self.advanceToNextCandidate()
        }
    }

    private func loadCandidate(at index: Int) {
        guard index < candidateEntries.count else {
            allFailed = true
            return
        }
        let entry = candidateEntries[index]
        let url = entry.url
        let isHLS = url.absoluteString.lowercased().contains(".m3u8")
        let asset = VideoPreloader.shared.asset(for: url, includeReferer: entry.includeReferer)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = isHLS ? 2.5 : 1.5
        player.automaticallyWaitsToMinimizeStalling = isHLS

        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()

        if isHLS || url.isFileURL {
            // AVPlayerLooper frequently freezes or black-frames on HLS (.m3u8); loop via end notification instead
            player.insert(item, after: nil)
            endObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.onClipEnded?()
                    self.player.seek(to: .zero) { _ in
                        Task { @MainActor [weak self] in
                            guard let self, self.wantsPlaying else { return }
                            self.player.play()
                        }
                    }
                }
            }
        } else {
            looper = AVPlayerLooper(player: player, templateItem: item)
        }

        sizeObservation = player.observe(\.currentItem?.presentationSize, options: [.new, .initial]) { [weak self] p, _ in
            MainActor.assumeIsolated {
                guard let self, let sz = p.currentItem?.presentationSize, sz.width > 0, sz.height > 0 else { return }
                self.detectedAspect = Double(sz.width / sz.height)
                self.hasValidVideoSize = true
                self.promoteReadyIfRenderable()
            }
        }

        statusObservation = player.observe(\.currentItem?.status, options: [.new]) { [weak self] p, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch p.currentItem?.status {
                case .readyToPlay:
                    self.allFailed = false
                    if let sz = p.currentItem?.presentationSize, sz.width > 0, sz.height > 0 {
                        self.detectedAspect = Double(sz.width / sz.height)
                        self.hasValidVideoSize = true
                    }
                    self.promoteReadyIfRenderable()
                case .failed:
                    self.advanceToNextCandidate()
                default:
                    break
                }
            }
        }

        if wantsPlaying {
            scheduleStallWatchdog(forGeneration: index)
        }
    }

    func play() {
        wantsPlaying = true
        player.play()
        if is2xSpeed { player.rate = 2.0 }
        if !isReady && !allFailed {
            scheduleStallWatchdog(forGeneration: currentURLIndex)
        }
    }

    func pause() {
        wantsPlaying = false
        stallWatchdogTask?.cancel()
        stallWatchdogTask = nil
        player.pause()
    }

    func setMuted(_ m: Bool) {
        player.isMuted = m
    }

    func setFastForward(_ active: Bool) {
        is2xSpeed = active
        guard player.timeControlStatus == .playing || active else { return }
        player.rate = active ? 2.0 : 1.0
    }

    func skip(by seconds: Double) {
        guard let item = player.currentItem else { return }
        let dur = item.duration.seconds
        let cur = player.currentTime().seconds
        guard dur.isFinite, dur > 0, cur.isFinite else { return }
        let targetSec = min(max(cur + seconds, 0), max(dur - 0.1, 0))
        let target = CMTime(seconds: targetSec, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func seek(toProgress ratio: Double) {
        guard let item = player.currentItem else { return }
        let dur = item.duration.seconds
        guard dur.isFinite, dur > 0 else { return }
        let clamped = min(max(ratio, 0), 0.995)
        let target = CMTime(seconds: dur * clamped, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        progress = clamped
        currentSeconds = dur * clamped
    }

    func teardown() {
        wantsPlaying = false
        stallWatchdogTask?.cancel()
        stallWatchdogTask = nil
        player.pause()
        is2xSpeed = false
        isReady = false
        hasValidVideoSize = false
        layerReadyForDisplay = false
        allFailed = false
        onClipEnded = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        statusObservation?.invalidate()
        statusObservation = nil
        sizeObservation?.invalidate()
        sizeObservation = nil
        if let o = timeObserver { player.removeTimeObserver(o); timeObserver = nil }
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        prepared = false
        progress = 0
        currentSeconds = 0
        durationSeconds = 0
    }
}

// MARK: - gooned.app Vertical Scroller FeedView

struct FeedView: View {
    @ObservedObject var model: FeedModel
    var isVisible: Bool = true
    @Binding var currentID: String?
    var onOpenCategories: () -> Void
    var onSelectSubreddit: (String) -> Void
    var onSelectUser: (String) -> Void
    var onSelectXUser: (String) -> Void
    var onSelectIGUser: (String) -> Void
    var onSelectRule34Tag: (String) -> Void
    var onSelectOFCreator: (String, String) -> Void
    var onConnectX: () -> Void
    var onConnectIG: () -> Void

    @EnvironmentObject var store: UserStore
    @State private var onScreen = false
    @State private var autoScrollTask: Task<Void, Never>?
    @State private var currentItemShownAt: Date = Date()
    @State private var shareTarget: Gif?
    @State private var dislikeToast: (tag: String?, autoBlocked: Bool)?
    @State private var dislikeToastTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(model.items) { gif in
                        GoonedReelCell(
                            gif: gif,
                            isActive: onScreen && isVisible && currentID == gif.id,
                            sort: model.sort,
                            onSelectSort: { model.setSort($0) },
                            onOpenCategories: onOpenCategories,
                            onShuffle: {
                                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                model.shuffleItems()
                                currentID = model.items.first?.id
                            },
                            onSelectSubreddit: onSelectSubreddit,
                            onSelectUser: onSelectUser,
                            onSelectXUser: onSelectXUser,
                            onSelectIGUser: onSelectIGUser,
                            onSelectRule34Tag: onSelectRule34Tag,
                            onSelectOFCreator: onSelectOFCreator,
                            onClipFinished: {
                                store.recordLoopSignal(for: gif)
                                if store.data.settings.autoScroll && store.data.settings.playVideosToEnd {
                                    advanceToNext(from: gif.id)
                                }
                            },
                            onDislike: {
                                handleDislike(gif)
                            },
                            onShare: {
                                shareTarget = gif
                            }
                        )
                        .containerRelativeFrame([.horizontal, .vertical])
                        .id(gif.id)
                        .onAppear { model.onItemAppear(gif) }
                    }

                    if model.items.isEmpty || (!model.canLoadMore && !model.isLoading) {
                        FeedStateView(
                            model: model,
                            onOpenCategories: onOpenCategories,
                            onConnectX: onConnectX,
                            onConnectIG: onConnectIG
                        )
                        .containerRelativeFrame([.horizontal, .vertical])
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $currentID)
            .background(Color.black)
            .ignoresSafeArea()

            if let toast = dislikeToast {
                HStack(spacing: 10) {
                    Image(systemName: "hand.thumbsdown.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.accentBright)
                    if let tag = toast.tag, toast.autoBlocked {
                        Text("Auto-blocked #\(tag)")
                            .font(.system(size: 13, weight: .semibold))
                    } else {
                        Text("Not interested · Showing less like this")
                            .font(.system(size: 13, weight: .semibold))
                        if let tag = toast.tag {
                            Button {
                                SmartTasteEngine.shared.blockDislikedTag(tag)
                                dislikeToast = (tag: tag, autoBlocked: true)
                            } label: {
                                Text("Block #\(tag)")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(Theme.accentBright)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 4)
                                    .liquidGlassCapsule(tinted: true, active: true)
                            }
                        }
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .liquidGlassCapsule(tinted: true)
                .padding(.top, 114)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .sheet(item: $shareTarget) { post in
            ShareItemSheet(gif: post)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onAppear {
            onScreen = true
            scheduleAutoScrollTimer()
        }
        .onDisappear {
            onScreen = false
            autoScrollTask?.cancel()
        }
        .task {
            if model.items.isEmpty { await model.loadMore() }
            fixCurrent()
        }
        .onChange(of: model.items.count) { _, _ in
            fixCurrent()
            preloadUpcoming()
        }
        .onChange(of: store.data.settings.autoScroll) { _, _ in scheduleAutoScrollTimer() }
        .onChange(of: store.data.settings.autoScrollDelay) { _, _ in scheduleAutoScrollTimer() }
        .onChange(of: store.data.settings.playVideosToEnd) { _, _ in scheduleAutoScrollTimer() }
        .onChange(of: currentID) { old, new in
            if let old {
                if let oldPost = model.items.first(where: { $0.id == old }) {
                    store.markSeen(oldPost)
                    let dwell = Date().timeIntervalSince(currentItemShownAt)
                    store.recordDwellSignal(for: oldPost, secondsWatched: dwell)
                } else {
                    store.markSeen(old)
                }
            }
            if let new {
                currentItemShownAt = Date()
                if let newPost = model.items.first(where: { $0.id == new }) {
                    store.markSeen(newPost)
                } else {
                    store.markSeen(new)
                }
                if old != nil {
                    let key = model.source.swipeKey
                    store.recordSwipe(kind: key.kind, name: key.name, displayTitle: model.source.displayTitle, postID: new)
                }
            }
            preloadUpcoming()
            scheduleAutoScrollTimer()
            model.prefetchIfNeeded(currentID: new)
        }
    }

    private func preloadUpcoming() {
        guard let curID = currentID,
              let idx = model.items.firstIndex(where: { $0.id == curID }),
              idx + 1 < model.items.count else { return }
        let upcoming = Array(model.items[(idx + 1)...].prefix(5))
        VideoPreloader.shared.preload(gifs: upcoming, hd: store.data.settings.hd)
        for item in upcoming.prefix(3) where item.isLongVideoPost {
            Task.detached(priority: .utility) {
                _ = await LongVideoAPI.shared.resolvePlayableURLs(for: item)
            }
        }
    }

    private func handleDislike(_ gif: Gif) {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        let outcome = store.dislike(gif)
        let currentIdx = model.items.firstIndex(where: { $0.id == gif.id })
        withAnimation(.easeInOut(duration: 0.22)) {
            model.removeDisliked(gif)
            if let currentIdx, currentIdx < model.items.count {
                currentID = model.items[currentIdx].id
            } else {
                currentID = model.items.first?.id
            }
        }
        if model.items.count < 10 && model.canLoadMore {
            Task { await model.loadMore() }
        }
        dislikeToastTask?.cancel()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
            if let autoTag = outcome.autoSuppressedTag {
                dislikeToast = (tag: autoTag, autoBlocked: true)
            } else {
                dislikeToast = (tag: outcome.primaryTag, autoBlocked: false)
            }
        }
        dislikeToastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                dislikeToast = nil
            }
        }
    }

    private func scheduleAutoScrollTimer() {
        autoScrollTask?.cancel()
        guard onScreen, isVisible, store.data.settings.autoScroll else { return }
        guard let curID = currentID, let curGif = model.items.first(where: { $0.id == curID }) else { return }
        if store.data.settings.playVideosToEnd && !curGif.isImage { return }

        let delay = max(3, store.data.settings.autoScrollDelay)
        autoScrollTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            advanceToNext(from: curID)
        }
    }

    private func advanceToNext(from id: String) {
        guard let idx = model.items.firstIndex(where: { $0.id == id }),
              idx + 1 < model.items.count else { return }
        withAnimation(.easeInOut(duration: 0.28)) {
            currentID = model.items[idx + 1].id
        }
    }

    private func fixCurrent() {
        if currentID == nil || !model.items.contains(where: { $0.id == currentID }) {
            if let firstID = model.items.first?.id {
                currentID = firstID
                store.markSeen(firstID)
            }
        }
    }
}

struct FeedStateView: View {
    @ObservedObject var model: FeedModel
    var onOpenCategories: () -> Void
    var onConnectX: () -> Void
    var onConnectIG: () -> Void
    @EnvironmentObject var store: UserStore

    var body: some View {
        VStack(spacing: 16) {
            if model.source.isXFeed && !store.data.xSession.isConnected {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.14))
                        .frame(width: 68, height: 68)
                        .overlay(Circle().stroke(Color.white.opacity(0.28), lineWidth: 1))
                    Text("𝕏")
                        .font(.system(size: 32, weight: .black))
                }
                Text("Connect Personal X")
                    .font(.title3.bold())
                Text("Sign in once to stream your X For You, Following, Bookmarks, and 18+ creator videos.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
                Button(action: onConnectX) {
                    Text("Sign in with X")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 26)
                        .padding(.vertical, 12)
                        .liquidGlassCapsule(tinted: true, active: true)
                }
            } else if model.source.isIGFeed && !store.data.igSession.isConnected {
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
                        .frame(width: 68, height: 68)
                    Image(systemName: "camera.fill")
                        .font(.system(size: 28, weight: .bold))
                }
                Text("Connect Instagram")
                    .font(.title3.bold())
                Text("Sign in once to stream your personal Instagram Reels, Following, Saved Reels, and creator feeds.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
                Button(action: onConnectIG) {
                    Text("Sign in with Instagram")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 26)
                        .padding(.vertical, 12)
                        .liquidGlassCapsule(tinted: true, active: true)
                }
            } else if let err = model.errorText {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(Theme.accent)
                Text(err)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button {
                    Task { await model.refresh(rotateCursor: true) }
                } label: {
                    Text("Retry")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 24)
                        .padding(.vertical, 11)
                        .liquidGlassCapsule(tinted: true, active: true)
                }
            } else if model.isSwitching || model.isLoading {
                ProgressView()
                    .tint(Theme.accent)
                    .controlSize(.large)
                if model.source.isXFeed || model.source.isIGFeed || model.source.isRule34Feed {
                    Text("Loading \(model.source.displayTitle)...")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
            } else {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 38))
                    .foregroundStyle(Theme.accent)
                Text("Rotate More Videos")
                    .font(.headline)
                HStack(spacing: 10) {
                    Button {
                        Task { await model.refresh(rotateCursor: true) }
                    } label: {
                        Text("Load Fresh Batch")
                            .font(.subheadline.bold())
                            .padding(.horizontal, 20)
                            .padding(.vertical, 11)
                            .liquidGlassCapsule(tinted: true, active: true)
                    }
                    Button {
                        onOpenCategories()
                    } label: {
                        Text("Browse")
                            .font(.subheadline.bold())
                            .padding(.horizontal, 22)
                            .padding(.vertical, 11)
                            .liquidGlassCapsule(tinted: true)
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .onAppear { Task { await model.loadMore() } }
    }
}

// MARK: - Exact gooned.app Reel Cell (Collapsible Controls, Proper Video Fit, Offline Download, Hold for Details)

struct GoonedReelCell: View {
    let gif: Gif
    let isActive: Bool
    let sort: FeedSort
    var onSelectSort: (FeedSort) -> Void
    var onOpenCategories: () -> Void
    var onShuffle: () -> Void
    var onSelectSubreddit: (String) -> Void
    var onSelectUser: (String) -> Void
    var onSelectXUser: (String) -> Void
    var onSelectIGUser: (String) -> Void
    var onSelectRule34Tag: (String) -> Void
    var onSelectOFCreator: (String, String) -> Void
    var onClipFinished: () -> Void
    var onDislike: () -> Void = {}
    var onShare: () -> Void = {}

    @EnvironmentObject var store: UserStore
    @EnvironmentObject var app: AppState
    @ObservedObject private var offline = OfflineManager.shared
    @StateObject private var player = PlayerModel()
    @State private var userPaused = false
    @State private var showHeart = false
    @State private var skipIndicator: Int? = nil // -5 or +5
    @State private var isHolding = false
    @State private var showMoreSheet = false
    @State private var isScrubbing = false
    @State private var localFitOverride: Bool? = nil

    private var shouldPlay: Bool { isActive && !app.isLocked && !userPaused }
    private var liked: Bool { store.isLiked(gif) }
    private var downloaded: Bool { offline.isDownloaded(gif) }
    private var downloadProgress: Double? { offline.activeDownloads[gif.id] }
    private var tinted: Bool { store.data.settings.tintedGlass }
    private var collapsed: Bool { store.data.settings.controlsCollapsed }

    private var fill: Bool {
        let fitMode = localFitOverride ?? store.data.settings.videoFitScreen
        if fitMode { return false }
        let ratio = player.detectedAspect ?? gif.knownAspect
        guard let ratio else { return false }
        return ratio < 0.68
    }

    private var isFollowed: Bool {
        if gif.isOnlyFansPost {
            return store.isFollowingOFCreator(id: gif.onlyFansCreatorId, handle: gif.author)
        }
        if gif.isXPost, let u = gif.author {
            return store.isFollowingXUser(u)
        }
        if gif.isIGPost, let u = gif.author {
            return store.isFollowingIGUser(u)
        }
        if let sub = gif.subreddit, store.isFollowingSubreddit(sub) { return true }
        if let u = gif.author, store.isFollowingUser(u) { return true }
        return false
    }

    var body: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height
            ZStack {
                Color.black
                mediaView(geo.size)

                gestureZones(size: geo.size)

                if userPaused && !isHolding {
                    Circle()
                        .fill(.black.opacity(0.42))
                        .frame(width: 68, height: 68)
                        .overlay(
                            Image(systemName: "play.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(.white)
                                .offset(x: 2)
                        )
                        .allowsHitTesting(false)
                }

                if showHeart {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 104))
                        .foregroundStyle(Theme.accent)
                        .shadow(color: Theme.accent.opacity(0.6), radius: 18)
                        .transition(.scale.combined(with: .opacity))
                        .allowsHitTesting(false)
                }

                if let skip = skipIndicator {
                    HStack {
                        if skip > 0 { Spacer() }
                        VStack(spacing: 4) {
                            let stepMag = abs(skip)
                            Image(systemName: skip < 0 ? (stepMag >= 10 ? "gobackward.10" : "gobackward.5") : (stepMag >= 10 ? "goforward.10" : "goforward.5"))
                                .font(.system(size: 28, weight: .bold))
                            Text(skip < 0 ? "-\(stepMag)s" : "+\(stepMag)s")
                                .font(.caption.bold())
                        }
                        .foregroundStyle(.white)
                        .padding(18)
                        .background(.black.opacity(0.50), in: Circle())
                        .padding(.horizontal, 42)
                        if skip < 0 { Spacer() }
                    }
                    .transition(.scale.combined(with: .opacity))
                    .allowsHitTesting(false)
                }

                if isHolding {
                    holdDetailsHUD
                        .allowsHitTesting(false)
                        .transition(.opacity)
                } else if collapsed {
                    // Collapsed Clean View: Bottom UI pushed down out of the way
                    VStack(spacing: 6) {
                        Spacer()

                        HStack {
                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                    store.data.settings.controlsCollapsed = false
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "chevron.up")
                                        .font(.system(size: 11, weight: .bold))
                                    Text("Controls")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                .foregroundStyle(.white.opacity(0.85))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .liquidGlassCapsule(tinted: tinted)
                            }
                            .buttonStyle(ScalePressButtonStyle())

                            Spacer()

                            HStack(spacing: 8) {
                                Button {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    offline.toggleDownload(gif)
                                } label: {
                                    Image(systemName: downloaded ? "checkmark.circle.fill" : "arrow.down.to.line")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(downloaded ? Theme.accentBright : .white.opacity(0.85))
                                        .frame(width: 34, height: 34)
                                        .liquidGlassCircle(tinted: tinted)
                                }

                                Button {
                                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                    store.toggleLike(gif)
                                } label: {
                                    Image(systemName: "heart.fill")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(liked ? Theme.accent : .white.opacity(0.85))
                                        .frame(width: 34, height: 34)
                                        .liquidGlassCircle(tinted: tinted)
                                }

                                Button {
                                    store.data.settings.muted.toggle()
                                    UserStore.configureAudioSession(muted: store.data.settings.muted)
                                } label: {
                                    Image(systemName: store.data.settings.muted ? "speaker.slash" : "speaker.wave.2")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.85))
                                        .frame(width: 34, height: 34)
                                        .liquidGlassCircle(tinted: tinted)
                                }
                            }
                        }
                        .padding(.horizontal, 14)

                        scrubberBar(width: geo.size.width)
                    }
                    .padding(.bottom, 16)
                    .foregroundStyle(.white)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    VStack(spacing: 10) {
                        Spacer()

                        HStack(alignment: .bottom) {
                            VStack(alignment: .leading, spacing: 8) {
                                if gif.isLongVideoPost {
                                    HStack(spacing: 8) {
                                        HStack(spacing: 5) {
                                            Image(systemName: "play.rectangle.fill")
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundStyle(Theme.accentBright)
                                            Text(gif.longVideoSiteLabel ?? "LONG")
                                                .font(.system(size: 11, weight: .black, design: .rounded))
                                            let dur = gif.duration ?? (player.durationSeconds > 0 ? player.durationSeconds : nil)
                                            if let dur, dur > 0 {
                                                Text("· \(formatTime(dur))")
                                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                                    .foregroundStyle(.white.opacity(0.75))
                                            }
                                        }
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .liquidGlassCapsule(tinted: tinted)

                                        Button {
                                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                            toggleLongOrientation(currentlyLandscape: isLandscape)
                                        } label: {
                                            HStack(spacing: 4) {
                                                Image(systemName: isLandscape ? "iphone" : "iphone.landscape")
                                                    .font(.system(size: 11, weight: .bold))
                                                Text(isLandscape ? "Portrait" : "Full Wide")
                                                    .font(.system(size: 11, weight: .semibold))
                                            }
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .liquidGlassCapsule(tinted: tinted)
                                        }
                                        .buttonStyle(ScalePressButtonStyle())
                                    }
                                }
                                leftControlCluster
                            }
                            Spacer()
                            rightActionStack
                        }
                        .padding(.horizontal, isLandscape ? 28 : 14)

                        scrubberBar(width: geo.size.width)
                    }
                    .padding(.bottom, isLandscape ? 14 : 84)
                    .foregroundStyle(.white)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .sheet(isPresented: $showMoreSheet) {
            PostMoreSheet(
                gif: gif,
                onSelectSubreddit: { sub in
                    showMoreSheet = false
                    onSelectSubreddit(sub)
                },
                onSelectUser: { u in
                    showMoreSheet = false
                    onSelectUser(u)
                },
                onSelectXUser: { u in
                    showMoreSheet = false
                    onSelectXUser(u)
                },
                onSelectIGUser: { u in
                    showMoreSheet = false
                    onSelectIGUser(u)
                },
                onSelectRule34Tag: { tag in
                    showMoreSheet = false
                    onSelectRule34Tag(tag)
                },
                onSelectOFCreator: { cid, handle in
                    showMoreSheet = false
                    onSelectOFCreator(cid, handle)
                },
                onDislike: {
                    showMoreSheet = false
                    onDislike()
                },
                onShare: {
                    showMoreSheet = false
                    onShare()
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .onAppear {
            player.onClipEnded = onClipFinished
            if !gif.isImage {
                let urls = gif.allVideoURLs(hd: store.data.settings.hd)
                if !urls.isEmpty {
                    player.prepare(urls: urls)
                }
                if gif.isLongVideoPost {
                    Task {
                        let resolved = await LongVideoAPI.shared.resolvePlayableURLs(for: gif)
                        if !resolved.isEmpty {
                            player.updateCandidateURLs(resolved)
                            if shouldPlay { player.play() }
                        } else if urls.isEmpty {
                            player.allFailed = true
                        }
                    }
                } else if urls.isEmpty {
                    player.allFailed = true
                }
            }
            player.setMuted(store.data.settings.muted)
            syncPlayback()
        }
        .onDisappear {
            player.teardown()
            userPaused = false
            isHolding = false
            localFitOverride = nil
        }
        .onChange(of: shouldPlay) { _, _ in syncPlayback() }
        .onChange(of: store.data.settings.muted) { _, m in
            player.setMuted(m)
            UserStore.configureAudioSession(muted: m)
        }
    }

    // MARK: - Left Control Cluster (`🔥 Hot` pill + Fit/Fill + `⌄` Collapse Down + `⊞` `🔀` `︾` `+` circles)

    private var leftControlCluster: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Menu {
                    ForEach(FeedSort.allCases) { s in
                        Button {
                            onSelectSort(s)
                        } label: {
                            Label(s.label, systemImage: s.icon)
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: sort.icon)
                            .font(.system(size: 13, weight: .semibold))
                        Text(sort.label)
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 9)
                    .liquidGlassCapsule(tinted: tinted)
                }

                // Fit / Fill Aspect Ratio Quick Button
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    let currentFit = localFitOverride ?? store.data.settings.videoFitScreen
                    localFitOverride = !currentFit
                } label: {
                    Image(systemName: fill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .liquidGlassCircle(tinted: tinted)
                }
                .buttonStyle(ScalePressButtonStyle())

                // Collapse Down (`⌄`) Button
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        store.data.settings.controlsCollapsed = true
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .liquidGlassCircle(tinted: tinted)
                }
                .buttonStyle(ScalePressButtonStyle())
            }

            HStack(spacing: 10) {
                Button(action: onOpenCategories) {
                    Image(systemName: "square.grid.2x2")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 42, height: 42)
                        .liquidGlassCircle(tinted: tinted)
                }
                .buttonStyle(ScalePressButtonStyle())

                Button(action: onShuffle) {
                    Image(systemName: "shuffle")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 42, height: 42)
                        .liquidGlassCircle(tinted: tinted)
                }
                .buttonStyle(ScalePressButtonStyle())

                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    store.data.settings.autoScroll.toggle()
                } label: {
                    Image(systemName: "chevron.down.2")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 42, height: 42)
                        .liquidGlassCircle(tinted: tinted, active: store.data.settings.autoScroll)
                }
                .buttonStyle(ScalePressButtonStyle())

                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    store.toggleFollowAndSync(for: gif)
                } label: {
                    Image(systemName: isFollowed ? "checkmark" : "plus")
                        .font(.system(size: 16, weight: .bold))
                        .frame(width: 42, height: 42)
                        .liquidGlassCircle(tinted: tinted, active: isFollowed)
                }
                .buttonStyle(ScalePressButtonStyle())
            }
        }
    }

    // MARK: - Right Action Stack (Source Badge, Heart, Dislike, Mute, Offline Download, Share, `•••`)

    private var rightActionStack: some View {
        VStack(spacing: 9) {
            // Source Badge Circle
            Button {
                if gif.isOnlyFansPost, let cid = gif.onlyFansCreatorId {
                    onSelectOFCreator(cid, gif.author ?? cid)
                } else if gif.isXPost, let u = gif.author {
                    onSelectXUser(u)
                } else if gif.isIGPost, let u = gif.author {
                    onSelectIGUser(u)
                } else if gif.isRule34Post {
                    onSelectRule34Tag("")
                } else if gif.isLongVideoPost {
                    showMoreSheet = true
                } else if let sub = gif.subreddit {
                    onSelectSubreddit(sub)
                } else if let u = gif.author {
                    onSelectUser(u)
                }
            } label: {
                if gif.isLongVideoPost {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color(red: 1.0, green: 0.56, blue: 0.14), Color(red: 0.90, green: 0.24, blue: 0.44)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 40, height: 40)
                            .overlay(Circle().stroke(Color.white.opacity(0.45), lineWidth: 1))
                        Image(systemName: "play.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .offset(x: 1)
                    }
                } else if gif.isOnlyFansPost {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color(red: 0.0, green: 0.72, blue: 0.96), Color(red: 0.0, green: 0.54, blue: 0.84)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .frame(width: 40, height: 40)
                            .overlay(Circle().stroke(Color.white.opacity(0.45), lineWidth: 1))
                        Text("OF")
                            .font(.system(size: 13, weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                    }
                } else if gif.isXPost {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(colors: [Color(white: 0.18), Color.black], startPoint: .top, endPoint: .bottom))
                            .frame(width: 40, height: 40)
                            .overlay(Circle().stroke(Color.white.opacity(0.42), lineWidth: 1))
                        Text("𝕏")
                            .font(.system(size: 17, weight: .black))
                            .foregroundStyle(.white)
                    }
                } else if gif.isIGPost {
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
                            .frame(width: 40, height: 40)
                            .overlay(Circle().stroke(Color.white.opacity(0.42), lineWidth: 1))
                        Image(systemName: "camera.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                    }
                } else if gif.isRule34Post {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color(red: 0.67, green: 0.90, blue: 0.64), Color(red: 0.42, green: 0.72, blue: 0.40)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: 40, height: 40)
                            .overlay(Circle().stroke(Color.white.opacity(0.42), lineWidth: 1))
                        Text("34")
                            .font(.system(size: 14, weight: .black, design: .rounded))
                            .foregroundStyle(Color(red: 0.08, green: 0.24, blue: 0.08))
                    }
                } else {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [ Color(red: 0.96, green: 0.65, blue: 0.74), Color(red: 0.85, green: 0.42, blue: 0.56) ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: 40, height: 40)
                            .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 1))
                        Text("r/")
                            .font(.system(size: 14, weight: .black, design: .rounded))
                            .foregroundStyle(Color(red: 0.45, green: 0.12, blue: 0.22))
                    }
                }
            }
            .buttonStyle(ScalePressButtonStyle())

            // Heart Circle + Upvote Count
            VStack(spacing: 2) {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    store.toggleLike(gif)
                } label: {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(liked ? Theme.accent : .white)
                        .frame(width: 40, height: 40)
                        .liquidGlassCircle(tinted: tinted)
                }
                .buttonStyle(ScalePressButtonStyle())

                Text(shortCount((gif.upvotes ?? 0) + (liked ? 1 : 0)))
                    .font(.system(size: 10, weight: .semibold))
            }

            // Dislike / Not Interested Circle
            Button {
                onDislike()
            } label: {
                Image(systemName: "hand.thumbsdown.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(width: 40, height: 40)
                    .liquidGlassCircle(tinted: tinted)
            }
            .buttonStyle(ScalePressButtonStyle())

            // Mute Circle + Label
            VStack(spacing: 2) {
                Button {
                    store.data.settings.muted.toggle()
                    UserStore.configureAudioSession(muted: store.data.settings.muted)
                } label: {
                    Image(systemName: store.data.settings.muted ? "speaker.slash" : "speaker.wave.2")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .liquidGlassCircle(tinted: tinted)
                }
                .buttonStyle(ScalePressButtonStyle())

                Text(store.data.settings.muted ? "Muted" : "Sound")
                    .font(.system(size: 10, weight: .semibold))
            }

            // Offline Download Circle
            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                offline.toggleDownload(gif)
            } label: {
                ZStack {
                    if let prog = downloadProgress {
                        Circle()
                            .stroke(Color.white.opacity(0.25), lineWidth: 2.5)
                            .frame(width: 34, height: 34)
                        Circle()
                            .trim(from: 0, to: prog)
                            .stroke(Theme.accentBright, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 34, height: 34)
                        Image(systemName: "arrow.down")
                            .font(.system(size: 12, weight: .bold))
                    } else {
                        Image(systemName: downloaded ? "checkmark" : "arrow.down.to.line")
                            .font(.system(size: 15, weight: .bold))
                    }
                }
                .frame(width: 40, height: 40)
                .liquidGlassCircle(tinted: tinted, active: downloaded)
            }
            .buttonStyle(ScalePressButtonStyle())

            // Share / Encrypted Drop Circle
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                onShare()
            } label: {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 40, height: 40)
                    .liquidGlassCircle(tinted: tinted)
            }
            .buttonStyle(ScalePressButtonStyle())

            // More (`•••`) Circle
            Button {
                showMoreSheet = true
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 40, height: 40)
                    .liquidGlassCircle(tinted: tinted)
            }
            .buttonStyle(ScalePressButtonStyle())
        }
    }

    // MARK: - Hold Overlay (2x Speed + Video Details HUD)

    private var holdDetailsHUD: some View {
        VStack {
            HStack(spacing: 6) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 11, weight: .bold))
                Text(gif.isImage ? "Post Details" : "2x Speed")
                    .font(.system(size: 13, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .liquidGlassCapsule(tinted: true, active: true)
            .padding(.top, 58)

            Spacer()

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    if let author = gif.author {
                        Text((gif.isXPost || gif.isIGPost || gif.isOnlyFansPost) ? "@\(author)" : author)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    if gif.isOnlyFansPost {
                        Text("·").foregroundStyle(.white.opacity(0.65))
                        Text("OnlyFans").font(.system(size: 14, weight: .bold)).foregroundStyle(Color(red: 0.25, green: 0.80, blue: 1.0))
                    } else if gif.isXPost {
                        Text("·").foregroundStyle(.white.opacity(0.65))
                        Text("𝕏").font(.system(size: 14, weight: .black)).foregroundStyle(.white.opacity(0.9))
                    } else if gif.isIGPost {
                        Text("·").foregroundStyle(.white.opacity(0.65))
                        Text("Instagram").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white.opacity(0.9))
                    } else if gif.isRule34Post {
                        Text("·").foregroundStyle(.white.opacity(0.65))
                        Text("rule34.xxx").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color(red: 0.67, green: 0.90, blue: 0.64))
                    } else if let sub = gif.subreddit {
                        Text("·").foregroundStyle(.white.opacity(0.65))
                        Text("/r/\(sub)").font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                    }
                    if !gif.relativeTime.isEmpty {
                        Text("·").foregroundStyle(.white.opacity(0.65))
                        Text(gif.relativeTime).font(.system(size: 14)).foregroundStyle(.white.opacity(0.75))
                    }
                }

                if let title = gif.title, !title.isEmpty {
                    Text(title)
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.95))
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 14) {
                    Label("\(shortCount(gif.upvotes)) likes", systemImage: "heart.fill")
                    if let d = gif.duration ?? (player.durationSeconds > 0 ? player.durationSeconds : nil) {
                        Label("\(Int(d))s", systemImage: "clock")
                    }
                    if let w = gif.width, let h = gif.height {
                        Text("\(w)×\(h)")
                    }
                    if downloaded {
                        Label("Offline", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.accentBright)
                    }
                }
                .font(.caption.bold())
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 2)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlassCard(cornerRadius: 20, tinted: true)
            .padding(.horizontal, 14)
            .padding(.bottom, 92)
        }
    }

    // MARK: - Gesture Zones

    private func gestureZones(size: CGSize) -> some View {
        let step = gif.isLongVideoPost ? 10 : 5
        return HStack(spacing: 0) {
            zone(width: size.width * 0.30) { triggerSkip(-step) }
            zone(width: size.width * 0.40) { triggerDoubleTapLike() }
            zone(width: size.width * 0.30) { triggerSkip(step) }
        }
        .frame(width: size.width, height: size.height)
        .onLongPressGesture(minimumDuration: 0.22, maximumDistance: 45, pressing: { pressing in
            if !pressing && isHolding {
                withAnimation(.easeOut(duration: 0.14)) { isHolding = false }
                player.setFastForward(false)
            }
        }, perform: {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(.easeInOut(duration: 0.14)) { isHolding = true }
            if !gif.isImage {
                userPaused = false
                player.setFastForward(true)
            }
        })
    }

    private func toggleLongOrientation(currentlyLandscape: Bool) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        let mask: UIInterfaceOrientationMask = currentlyLandscape ? .portrait : .landscapeRight
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
    }

    private func zone(width: CGFloat, onDoubleTap: @escaping () -> Void) -> some View {
        Color.clear
            .frame(width: width)
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onDoubleTap)
            .onTapGesture(count: 1) {
                if !isHolding { userPaused.toggle() }
            }
    }

    private func triggerSkip(_ seconds: Int) {
        guard !gif.isImage else {
            triggerDoubleTapLike()
            return
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        player.skip(by: Double(seconds))
        withAnimation(.spring(response: 0.22, dampingFraction: 0.7)) { skipIndicator = seconds }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            withAnimation(.easeOut(duration: 0.18)) { skipIndicator = nil }
        }
    }

    private func triggerDoubleTapLike() {
        store.like(gif)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.spring(response: 0.26, dampingFraction: 0.55)) { showHeart = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.70) {
            withAnimation(.easeOut(duration: 0.2)) { showHeart = false }
        }
    }

    private func syncPlayback() {
        if shouldPlay { player.play() } else { player.pause() }
    }

    @ViewBuilder
    private func mediaView(_ size: CGSize) -> some View {
        if gif.isImage {
            RemoteImageView(
                url: gif.imageURL,
                fallbackURLs: gif.imageFallbackURLs,
                fill: fill,
                showSpinnerOnLoad: true
            )
            .frame(width: size.width, height: size.height)
            .clipped()
        } else {
            ZStack {
                Color.black

                if let poster = gif.posterURL {
                    RemoteImageView(
                        url: poster,
                        fallbackURLs: gif.posterFallbackURLs,
                        fill: fill,
                        showSpinnerOnLoad: false
                    )
                    .frame(width: size.width, height: size.height)
                    .clipped()
                }

                PlayerLayerView(
                    player: player.player,
                    fill: fill,
                    onReadyForDisplay: { ready in
                        player.updateLayerReadyForDisplay(ready)
                    }
                )
                .frame(width: size.width, height: size.height)
                .clipped()
                .opacity(player.isReady ? 1 : 0)

                if !player.isReady && !player.allFailed {
                    ProgressView()
                        .tint(Theme.accent.opacity(0.85))
                        .controlSize(.regular)
                } else if player.allFailed && gif.posterURL == nil {
                    VStack(spacing: 10) {
                        Image(systemName: "play.slash")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(.white.opacity(0.5))
                        Button {
                            player.retry()
                        } label: {
                            Text("Tap to retry")
                                .font(.caption.bold())
                                .foregroundStyle(.white.opacity(0.85))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .liquidGlassCapsule(tinted: true)
                        }
                    }
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        }
    }

    private func scrubberBar(width: CGFloat) -> some View {
        VStack(spacing: 4) {
            if isScrubbing && player.durationSeconds > 0 {
                Text("\(formatTime(player.currentSeconds)) / \(formatTime(player.durationSeconds))")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.65), in: Capsule())
            }

            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.24))
                Rectangle().fill(Theme.accent)
                    .frame(width: max(0, width * player.progress))
            }
            .frame(height: isScrubbing ? 6 : 2.5)
            .frame(height: 16)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { val in
                        isScrubbing = true
                        let ratio = Double(val.location.x / max(width, 1))
                        player.seek(toProgress: ratio)
                    }
                    .onEnded { _ in
                        isScrubbing = false
                    }
            )
        }
        .opacity(gif.isImage ? 0 : 1)
    }

    private func formatTime(_ sec: Double) -> String {
        guard sec.isFinite, sec >= 0 else { return "0:00" }
        let total = Int(sec)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - More (`•••`) Sheet (Offline Download, Creator Links, Rule34 Tags, File Share)

struct PostMoreSheet: View {
    let gif: Gif
    var onSelectSubreddit: (String) -> Void
    var onSelectUser: (String) -> Void
    var onSelectXUser: (String) -> Void
    var onSelectIGUser: (String) -> Void
    var onSelectRule34Tag: (String) -> Void
    var onSelectOFCreator: (String, String) -> Void
    var onDislike: () -> Void = {}
    var onShare: () -> Void = {}
    @EnvironmentObject var store: UserStore
    @ObservedObject private var offline = OfflineManager.shared
    @Environment(\.dismiss) private var dismiss

    private var r34Tags: [String] {
        guard gif.isRule34Post, let t = gif.title else { return [] }
        return t.split(separator: " ")
            .map { $0.replacingOccurrences(of: "#", with: "") }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        ZStack {
            Theme.modalGradient.ignoresSafeArea()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Text("Post Info & Offline")
                            .font(.title3.bold())
                        Spacer()
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .bold))
                                .frame(width: 34, height: 34)
                                .liquidGlassCircle()
                        }
                    }

                    if let title = gif.title, !title.isEmpty {
                        Text(title)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.92))
                    }

                    // Offline Download Action Card
                    let isSaved = offline.isDownloaded(gif)
                    let isSaving = offline.isDownloading(gif)
                    Button {
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        offline.toggleDownload(gif)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: isSaved ? "checkmark.circle.fill" : (isSaving ? "arrow.down.circle" : "arrow.down.to.line.circle.fill"))
                                .font(.system(size: 22))
                                .foregroundStyle(isSaved ? Theme.accentBright : .white)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(isSaved ? "Saved in Offline Vault" : (isSaving ? "Downloading for Offline View..." : "Download for Offline View"))
                                    .font(.system(size: 15, weight: .bold))
                                Text(isSaved ? "Tap to remove from offline storage" : "Watch anytime without internet connection")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.68))
                            }
                            Spacer()
                        }
                        .padding(14)
                        .liquidGlassCard(cornerRadius: 16)
                    }
                    .buttonStyle(ScalePressButtonStyle())

                    // Export local file if downloaded
                    if let localFile = offline.localMediaURL(for: gif) {
                        ShareLink(item: localFile) {
                            HStack(spacing: 12) {
                                Image(systemName: "folder.badge.plus")
                                    .font(.system(size: 18))
                                Text("Export Downloaded File to Files / Photos")
                                    .font(.subheadline.bold())
                                Spacer()
                            }
                            .padding(14)
                            .liquidGlassCard(cornerRadius: 16)
                        }
                    }

                    // Rule34 Tappable Tag Pills
                    if !r34Tags.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("RULE34 TAGS")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.6))
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 6)], spacing: 6) {
                                ForEach(r34Tags, id: \.self) { tag in
                                    Button {
                                        onSelectRule34Tag(tag)
                                    } label: {
                                        Text("#\(tag)")
                                            .font(.caption.bold())
                                            .lineLimit(1)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 7)
                                            .frame(maxWidth: .infinity)
                                            .liquidGlassCapsule()
                                    }
                                }
                            }
                        }
                    }

                    if let sub = gif.subreddit, !gif.isRule34Post {
                        HStack {
                            Button {
                                onSelectSubreddit(sub)
                            } label: {
                                HStack(spacing: 8) {
                                    Text("/r/\(sub)")
                                        .font(.headline)
                                    Image(systemName: "chevron.right")
                                        .font(.caption.bold())
                                }
                            }
                            Spacer()
                            Button {
                                store.toggleFollowSubreddit(sub)
                            } label: {
                                Text(store.isFollowingSubreddit(sub) ? "Joined" : "Join")
                                    .font(.subheadline.bold())
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .liquidGlassCapsule(active: store.isFollowingSubreddit(sub))
                            }
                        }
                        .padding(14)
                        .liquidGlassCard(cornerRadius: 16)
                    }

                    if let u = gif.author {
                        HStack {
                            Button {
                                if gif.isOnlyFansPost, let cid = gif.onlyFansCreatorId {
                                    onSelectOFCreator(cid, u)
                                } else if gif.isXPost {
                                    onSelectXUser(u)
                                } else if gif.isIGPost {
                                    onSelectIGUser(u)
                                } else if gif.isRule34Post {
                                    onSelectRule34Tag(u)
                                } else {
                                    onSelectUser(u)
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Text(gif.isOnlyFansPost ? "OF  @\(u)" : (gif.isXPost ? "𝕏  @\(u)" : (gif.isIGPost ? "IG  @\(u)" : "u/\(u)")))
                                        .font(.headline)
                                    Image(systemName: "chevron.right")
                                        .font(.caption.bold())
                                }
                            }
                            Spacer()
                            Button {
                                store.toggleFollowAndSync(for: gif)
                            } label: {
                                let following = gif.isOnlyFansPost
                                    ? store.isFollowingOFCreator(id: gif.onlyFansCreatorId, handle: u)
                                    : (gif.isXPost
                                        ? store.isFollowingXUser(u)
                                        : (gif.isIGPost ? store.isFollowingIGUser(u) : store.isFollowingUser(u)))
                                Text(following ? "Following" : "Follow")
                                    .font(.subheadline.bold())
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .liquidGlassCapsule(active: following)
                            }
                        }
                        .padding(14)
                        .liquidGlassCard(cornerRadius: 16)
                    }

                    Button {
                        onShare()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "paperplane.fill")
                                .foregroundStyle(Theme.accentBright)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Share Encrypted Drop")
                                    .font(.subheadline.bold())
                                Text("AES-256-GCM end-to-end encrypted link or code")
                                    .font(.caption)
                                    .foregroundStyle(.white.opacity(0.68))
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.bold())
                        }
                        .padding(14)
                        .liquidGlassCard(cornerRadius: 16)
                    }
                    .buttonStyle(ScalePressButtonStyle())

                    Button {
                        onDislike()
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "hand.thumbsdown.fill")
                                .foregroundStyle(.orange)
                            Text("Not Interested · Show Less Like This")
                                .font(.subheadline.bold())
                            Spacer()
                        }
                        .padding(14)
                        .liquidGlassCard(cornerRadius: 16)
                    }
                    .buttonStyle(ScalePressButtonStyle())

                    ShareLink(item: gif.webURL) {
                        HStack {
                            Image(systemName: "square.and.arrow.up")
                            Text("Share Original Post Link")
                                .font(.subheadline.bold())
                            Spacer()
                        }
                        .padding(14)
                        .liquidGlassCard(cornerRadius: 16)
                    }
                }
                .padding(20)
                .foregroundStyle(.white)
            }
        }
    }
}
