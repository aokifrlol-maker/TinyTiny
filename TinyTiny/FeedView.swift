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

    func makeUIView(context: Context) -> PlayerUIView {
        let v = PlayerUIView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
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
    static func headers(for url: URL) -> [String: String] {
        let host = url.host?.lowercased() ?? ""
        var h: [String: String] = ["User-Agent": Config.userAgent]
        if host.contains("redgifs.com") {
            h["Referer"] = "https://www.redgifs.com/"
        } else if host.contains("rule34") || host.contains("yande.re") || host.contains("hypnohub") || host.contains("gelbooru") {
            h["Referer"] = "https://rule34.xxx/"
        } else if host.contains("twimg.com") || host.contains("x.com") || host.contains("twitter.com") {
            h["Referer"] = "https://x.com/"
        } else if host.contains("cdninstagram.com") || host.contains("fbcdn.net") || host.contains("instagram.com") {
            h["Referer"] = "https://www.instagram.com/"
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
        cfg.timeoutIntervalForRequest = 14
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
            var req = URLRequest(url: url)
            for (k, v) in MediaHeaders.headers(for: url) {
                req.setValue(v, forHTTPHeaderField: k)
            }
            guard let (data, resp) = try? await session.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode ?? 200 < 400,
                  let img = UIImage(data: data) else {
                return nil
            }
            cache.setObject(img, forKey: key as NSString, cost: data.count)
            return img
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
    var fill: Bool = false
    var showSpinnerOnLoad: Bool = true
    var onFailed: (() -> Void)? = nil

    @State private var image: UIImage?
    @State private var didFail = false
    @State private var reloadToken = 0

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
            guard let url else {
                didFail = true
                onFailed?()
                return
            }
            if let cached = MediaImageLoader.shared.cached(url) {
                image = cached
                didFail = false
                return
            }
            if let loaded = await MediaImageLoader.shared.load(url) {
                image = loaded
                didFail = false
            } else {
                didFail = true
                onFailed?()
            }
        }
    }
}

@MainActor
final class VideoPreloader {
    static let shared = VideoPreloader()
    private var cachedAssets: [String: AVURLAsset] = [:]
    private var order: [String] = []

    func preload(gifs: [Gif], hd: Bool) {
        MediaImageLoader.shared.prefetch(urls: gifs.prefix(3).map(\.posterURL))
        for gif in gifs.prefix(3) {
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
            if order.count > 10, let oldest = order.first {
                order.removeFirst()
                cachedAssets.removeValue(forKey: oldest)
            }
            Task.detached(priority: .utility) {
                _ = try? await asset.load(.isPlayable)
            }
        }
    }

    func asset(for url: URL) -> AVURLAsset {
        if let existing = cachedAssets[url.absoluteString] {
            return existing
        }
        if url.isFileURL {
            return AVURLAsset(url: url)
        }
        return AVURLAsset(
            url: url,
            options: ["AVURLAssetHTTPHeaderFieldsKey": MediaHeaders.headers(for: url)]
        )
    }
}

// MARK: - Resilient PlayerModel (Auto-Fallback URLs + Buffering/Failure Recovery + Scrubbing)

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
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var sizeObservation: NSKeyValueObservation?
    private var candidateURLs: [URL] = []
    private var currentURLIndex: Int = 0
    private var prepared = false
    var onClipEnded: (() -> Void)?

    func prepare(urls: [URL]) {
        guard !prepared, !urls.isEmpty else { return }
        prepared = true
        allFailed = false
        isReady = false
        candidateURLs = urls
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

    func retry() {
        let urls = candidateURLs
        teardown()
        prepare(urls: urls)
        play()
    }

    private func loadCandidate(at index: Int) {
        guard index < candidateURLs.count else {
            allFailed = true
            return
        }
        let url = candidateURLs[index]
        let asset = VideoPreloader.shared.asset(for: url)
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 5

        looper?.disableLooping()
        player.removeAllItems()
        looper = AVPlayerLooper(player: player, templateItem: item)

        sizeObservation = player.observe(\.currentItem?.presentationSize, options: [.new, .initial]) { [weak self] p, _ in
            MainActor.assumeIsolated {
                guard let self, let sz = p.currentItem?.presentationSize, sz.width > 0, sz.height > 0 else { return }
                self.detectedAspect = Double(sz.width / sz.height)
                self.isReady = true
            }
        }

        statusObservation = player.observe(\.currentItem?.status, options: [.new]) { [weak self] p, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                switch p.currentItem?.status {
                case .readyToPlay:
                    self.isReady = true
                    self.allFailed = false
                case .failed:
                    if self.currentURLIndex + 1 < self.candidateURLs.count {
                        self.currentURLIndex += 1
                        self.loadCandidate(at: self.currentURLIndex)
                        self.player.play()
                    } else {
                        self.allFailed = true
                    }
                default:
                    break
                }
            }
        }
    }

    func play() {
        player.play()
        if is2xSpeed { player.rate = 2.0 }
    }

    func pause() {
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
        player.pause()
        is2xSpeed = false
        isReady = false
        allFailed = false
        onClipEnded = nil
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
    var onConnectX: () -> Void
    var onConnectIG: () -> Void

    @EnvironmentObject var store: UserStore
    @State private var onScreen = false
    @State private var autoScrollTask: Task<Void, Never>?
    @State private var currentItemShownAt: Date = Date()

    var body: some View {
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
                        onClipFinished: {
                            if store.data.settings.autoScroll && store.data.settings.playVideosToEnd {
                                advanceToNext(from: gif.id)
                            }
                        }
                    )
                    .containerRelativeFrame([.horizontal, .vertical])
                    .id(gif.id)
                    .onAppear { model.onItemAppear(gif) }
                }

                if model.canLoadMore || model.errorText != nil || model.items.isEmpty {
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
                store.markSeen(old)
                if let oldPost = model.items.first(where: { $0.id == old }) {
                    let dwell = Date().timeIntervalSince(currentItemShownAt)
                    store.recordDwellSignal(for: oldPost, secondsWatched: dwell)
                }
            }
            if let new {
                currentItemShownAt = Date()
                store.markSeen(new)
                if old != nil {
                    let key = model.source.swipeKey
                    store.recordSwipe(kind: key.kind, name: key.name, displayTitle: model.source.displayTitle, postID: new)
                }
            }
            preloadUpcoming()
            scheduleAutoScrollTimer()
        }
    }

    private func preloadUpcoming() {
        guard let curID = currentID,
              let idx = model.items.firstIndex(where: { $0.id == curID }),
              idx + 1 < model.items.count else { return }
        let upcoming = Array(model.items[(idx + 1)...].prefix(3))
        VideoPreloader.shared.preload(gifs: upcoming, hd: store.data.settings.hd)
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
            } else if model.isSwitching || model.isLoading || model.canLoadMore {
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
    var onClipFinished: () -> Void

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
                            Image(systemName: skip < 0 ? "gobackward.5" : "goforward.5")
                                .font(.system(size: 28, weight: .bold))
                            Text(skip < 0 ? "-5s" : "+5s")
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
                            leftControlCluster
                            Spacer()
                            rightActionStack
                        }
                        .padding(.horizontal, 14)

                        scrubberBar(width: geo.size.width)
                    }
                    .padding(.bottom, 84)
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
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .onAppear {
            player.onClipEnded = onClipFinished
            if !gif.isImage {
                let urls = gif.allVideoURLs(hd: store.data.settings.hd)
                player.prepare(urls: urls)
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
                    if gif.isXPost, let u = gif.author {
                        store.toggleFollowXUser(u)
                    } else if gif.isIGPost, let u = gif.author {
                        store.toggleFollowIGUser(u)
                    } else if let sub = gif.subreddit {
                        store.toggleFollowSubreddit(sub)
                    } else if let u = gif.author {
                        store.toggleFollowUser(u)
                    }
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

    // MARK: - Right Action Stack (Source Badge `r/` / `𝕏` / `IG` / `34`, Heart, Mute, Offline Download, `•••`)

    private var rightActionStack: some View {
        VStack(spacing: 12) {
            // Source Badge Circle
            Button {
                if gif.isXPost, let u = gif.author {
                    onSelectXUser(u)
                } else if gif.isIGPost, let u = gif.author {
                    onSelectIGUser(u)
                } else if gif.isRule34Post {
                    onSelectRule34Tag("")
                } else if let sub = gif.subreddit {
                    onSelectSubreddit(sub)
                } else if let u = gif.author {
                    onSelectUser(u)
                }
            } label: {
                if gif.isXPost {
                    ZStack {
                        Circle()
                            .fill(LinearGradient(colors: [Color(white: 0.18), Color.black], startPoint: .top, endPoint: .bottom))
                            .frame(width: 44, height: 44)
                            .overlay(Circle().stroke(Color.white.opacity(0.42), lineWidth: 1))
                        Text("𝕏")
                            .font(.system(size: 18, weight: .black))
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
                            .frame(width: 44, height: 44)
                            .overlay(Circle().stroke(Color.white.opacity(0.42), lineWidth: 1))
                        Image(systemName: "camera.fill")
                            .font(.system(size: 16, weight: .bold))
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
                            .frame(width: 44, height: 44)
                            .overlay(Circle().stroke(Color.white.opacity(0.42), lineWidth: 1))
                        Text("34")
                            .font(.system(size: 15, weight: .black, design: .rounded))
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
                            .frame(width: 44, height: 44)
                            .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 1))
                        Text("r/")
                            .font(.system(size: 15, weight: .black, design: .rounded))
                            .foregroundStyle(Color(red: 0.45, green: 0.12, blue: 0.22))
                    }
                }
            }
            .buttonStyle(ScalePressButtonStyle())

            // Heart Circle + Upvote Count
            VStack(spacing: 3) {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    store.toggleLike(gif)
                } label: {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(liked ? Theme.accent : .white)
                        .frame(width: 44, height: 44)
                        .liquidGlassCircle(tinted: tinted)
                }
                .buttonStyle(ScalePressButtonStyle())

                Text(shortCount((gif.upvotes ?? 0) + (liked ? 1 : 0)))
                    .font(.system(size: 11, weight: .semibold))
            }

            // Mute Circle + Label
            VStack(spacing: 3) {
                Button {
                    store.data.settings.muted.toggle()
                    UserStore.configureAudioSession(muted: store.data.settings.muted)
                } label: {
                    Image(systemName: store.data.settings.muted ? "speaker.slash" : "speaker.wave.2")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .liquidGlassCircle(tinted: tinted)
                }
                .buttonStyle(ScalePressButtonStyle())

                Text(store.data.settings.muted ? "Muted" : "Sound")
                    .font(.system(size: 11, weight: .semibold))
            }

            // Offline Download Circle + Label
            VStack(spacing: 3) {
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    offline.toggleDownload(gif)
                } label: {
                    ZStack {
                        if let prog = downloadProgress {
                            Circle()
                                .stroke(Color.white.opacity(0.25), lineWidth: 2.5)
                                .frame(width: 38, height: 38)
                            Circle()
                                .trim(from: 0, to: prog)
                                .stroke(Theme.accentBright, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .frame(width: 38, height: 38)
                            Image(systemName: "arrow.down")
                                .font(.system(size: 13, weight: .bold))
                        } else {
                            Image(systemName: downloaded ? "checkmark" : "arrow.down.to.line")
                                .font(.system(size: 16, weight: .bold))
                        }
                    }
                    .frame(width: 44, height: 44)
                    .liquidGlassCircle(tinted: tinted, active: downloaded)
                }
                .buttonStyle(ScalePressButtonStyle())

                Text(downloaded ? "Saved" : (downloadProgress != nil ? "Saving" : "Save"))
                    .font(.system(size: 11, weight: .semibold))
            }

            // More (`•••`) Circle
            Button {
                showMoreSheet = true
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .bold))
                    .frame(width: 44, height: 44)
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
                        Text((gif.isXPost || gif.isIGPost) ? "@\(author)" : author)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    if gif.isXPost {
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
        HStack(spacing: 0) {
            zone(width: size.width * 0.30) { triggerSkip(-5) }
            zone(width: size.width * 0.40) { triggerDoubleTapLike() }
            zone(width: size.width * 0.30) { triggerSkip(5) }
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
            RemoteImageView(url: gif.imageURL, fill: fill, showSpinnerOnLoad: true)
                .frame(width: size.width, height: size.height)
                .clipped()
        } else {
            ZStack {
                Color.black

                if let poster = gif.posterURL {
                    RemoteImageView(url: poster, fill: fill, showSpinnerOnLoad: false)
                        .frame(width: size.width, height: size.height)
                        .clipped()
                }

                PlayerLayerView(player: player.player, fill: fill)
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
                                if gif.isXPost {
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
                                    Text(gif.isXPost ? "𝕏  @\(u)" : (gif.isIGPost ? "IG  @\(u)" : "u/\(u)"))
                                        .font(.headline)
                                    Image(systemName: "chevron.right")
                                        .font(.caption.bold())
                                }
                            }
                            Spacer()
                            Button {
                                if gif.isXPost {
                                    store.toggleFollowXUser(u)
                                } else if gif.isIGPost {
                                    store.toggleFollowIGUser(u)
                                } else {
                                    store.toggleFollowUser(u)
                                }
                            } label: {
                                let following = gif.isXPost
                                    ? store.isFollowingXUser(u)
                                    : (gif.isIGPost ? store.isFollowingIGUser(u) : store.isFollowingUser(u))
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
