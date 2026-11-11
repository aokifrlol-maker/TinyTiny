import SwiftUI
import AVFoundation

// MARK: - Native AVPlayer Layer

final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    let fill: Bool

    func makeUIView(context: Context) -> PlayerUIView {
        let v = PlayerUIView()
        v.backgroundColor = .clear
        v.playerLayer.player = player
        v.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        return v
    }

    func updateUIView(_ v: PlayerUIView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
        v.playerLayer.videoGravity = fill ? .resizeAspectFill : .resizeAspect
    }
}

@MainActor
final class PlayerModel: ObservableObject {
    let player = AVQueuePlayer()
    @Published var progress: Double = 0
    @Published var is2xSpeed: Bool = false
    private var looper: AVPlayerLooper?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var prepared = false
    var onClipEnded: (() -> Void)?

    func prepare(url: URL) {
        guard !prepared else { return }
        prepared = true
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": Config.userAgent]])
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 4
        looper = AVPlayerLooper(player: player, templateItem: item)

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.12, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 else { return }
                let ratio = min(max(time.seconds / d, 0), 1)
                if ratio >= 0.97 && self.progress < 0.97 {
                    self.onClipEnded?()
                }
                self.progress = ratio
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

    func teardown() {
        player.pause()
        is2xSpeed = false
        onClipEnded = nil
        if let o = timeObserver { player.removeTimeObserver(o); timeObserver = nil }
        if let e = endObserver { NotificationCenter.default.removeObserver(e); endObserver = nil }
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        prepared = false
        progress = 0
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
    var onConnectX: () -> Void

    @EnvironmentObject var store: UserStore
    @State private var onScreen = false
    @State private var autoScrollTask: Task<Void, Never>?

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
                        onConnectX: onConnectX
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
        .onChange(of: model.items.count) { _, _ in fixCurrent() }
        .onChange(of: store.data.settings.autoScroll) { _, _ in scheduleAutoScrollTimer() }
        .onChange(of: store.data.settings.autoScrollDelay) { _, _ in scheduleAutoScrollTimer() }
        .onChange(of: store.data.settings.playVideosToEnd) { _, _ in scheduleAutoScrollTimer() }
        .onChange(of: currentID) { old, new in
            if old != nil, new != nil {
                let key = model.source.swipeKey
                store.recordSwipe(kind: key.kind, name: key.name, displayTitle: model.source.displayTitle)
            }
            scheduleAutoScrollTimer()
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
            currentID = model.items.first?.id
        }
    }
}

struct FeedStateView: View {
    @ObservedObject var model: FeedModel
    var onOpenCategories: () -> Void
    var onConnectX: () -> Void
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
                    Task { await model.refresh() }
                } label: {
                    Text("Retry")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 24)
                        .padding(.vertical, 11)
                        .liquidGlassCapsule(tinted: true, active: true)
                }
            } else if model.canLoadMore || model.isLoading {
                ProgressView()
                    .tint(Theme.accent)
                    .controlSize(.large)
                if model.source.isXFeed {
                    Text("Loading \(model.source.displayTitle)...")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                }
            } else {
                Image(systemName: "safari")
                    .font(.system(size: 38))
                    .foregroundStyle(Theme.accent)
                Text("No posts found")
                    .font(.headline)
                HStack(spacing: 10) {
                    Button {
                        Task { await model.refresh() }
                    } label: {
                        Text("Reload")
                            .font(.subheadline.bold())
                            .padding(.horizontal, 20)
                            .padding(.vertical, 11)
                            .liquidGlassCapsule(tinted: true)
                    }
                    Button {
                        onOpenCategories()
                    } label: {
                        Text("Browse")
                            .font(.subheadline.bold())
                            .padding(.horizontal, 22)
                            .padding(.vertical, 11)
                            .liquidGlassCapsule(tinted: true, active: true)
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

// MARK: - Exact gooned.app Reel Cell (Liquid Glass Controls, No Text Over Video Until Hold)

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
    var onClipFinished: () -> Void

    @EnvironmentObject var store: UserStore
    @EnvironmentObject var app: AppState
    @StateObject private var player = PlayerModel()
    @State private var userPaused = false
    @State private var showHeart = false
    @State private var skipIndicator: Int? = nil // -5 or +5
    @State private var isHolding = false
    @State private var showMoreSheet = false

    private var shouldPlay: Bool { isActive && !app.isLocked && !userPaused }
    private var fill: Bool { gif.aspect < 0.78 }
    private var liked: Bool { store.isLiked(gif) }
    private var tinted: Bool { store.data.settings.tintedGlass }

    private var isFollowed: Bool {
        if gif.isXPost, let u = gif.author {
            return store.isFollowingXUser(u)
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

                // Gesture Zones: Left Double-Tap = -5s, Center Double-Tap = Like, Right Double-Tap = +5s, Single Tap = Pause, Hold = 2x Speed + Details
                gestureZones(size: geo.size)

                // Center Play Icon when paused
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

                // Double-Tap Heart Animation
                if showHeart {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 104))
                        .foregroundStyle(Theme.accent)
                        .shadow(color: Theme.accent.opacity(0.6), radius: 18)
                        .transition(.scale.combined(with: .opacity))
                        .allowsHitTesting(false)
                }

                // Double-Tap Left/Right -5s / +5s Indicator
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
                    // Hold Overlay: 2x Speed Pill + Full Post Details (`author · /r/Subreddit · time` + Title)
                    holdDetailsHUD
                        .allowsHitTesting(false)
                        .transition(.opacity)
                } else {
                    // Exact gooned.app Liquid Glass Controls (NO text over the video!)
                    VStack(spacing: 10) {
                        Spacer()

                        HStack(alignment: .bottom) {
                            leftControlCluster
                            Spacer()
                            rightActionStack
                        }
                        .padding(.horizontal, 14)

                        // Pink Scrubber Progress Line right above the bottom dock
                        scrubberBar(width: geo.size.width)
                    }
                    .padding(.bottom, 84)
                    .foregroundStyle(.white)
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
                }
            )
            .presentationDetents([.medium])
            .presentationDragIndicator(.visible)
        }
        .onAppear {
            player.onClipEnded = onClipFinished
            if !gif.isImage, let url = gif.videoURL(hd: store.data.settings.hd) {
                player.prepare(url: url)
            }
            player.setMuted(store.data.settings.muted)
            syncPlayback()
        }
        .onDisappear {
            player.teardown()
            userPaused = false
            isHolding = false
        }
        .onChange(of: shouldPlay) { _, _ in syncPlayback() }
        .onChange(of: store.data.settings.muted) { _, m in player.setMuted(m) }
    }

    // MARK: - Exact gooned.app Left Control Cluster (`🔥 Hot` pill + `⊞` `🔀` `︾` `+` circles)

    private var leftControlCluster: some View {
        VStack(alignment: .leading, spacing: 10) {
            // `🔥 Hot` Sort Pill
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
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .liquidGlassCapsule(tinted: tinted)
            }

            // 4 Liquid Glass Circle Buttons: Categories (`⊞`), Shuffle (`🔀`), Auto-Scroll (`︾`), Follow (`+`)
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

    // MARK: - Exact gooned.app Right Action Stack (Source Badge `r/` or `𝕏`, Heart + Count, Mute + Label, `•••`)

    private var rightActionStack: some View {
        VStack(spacing: 14) {
            // Source Badge Circle (`𝕏` for X posts, Pink `r/` for Reddit posts)
            Button {
                if gif.isXPost, let u = gif.author {
                    onSelectXUser(u)
                } else if let sub = gif.subreddit {
                    onSelectSubreddit(sub)
                } else if let u = gif.author {
                    onSelectUser(u)
                }
            } label: {
                if gif.isXPost {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color(white: 0.18), Color.black],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(width: 44, height: 44)
                            .overlay(Circle().stroke(Color.white.opacity(0.42), lineWidth: 1))
                        Text("𝕏")
                            .font(.system(size: 18, weight: .black))
                            .foregroundStyle(.white)
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
            VStack(spacing: 4) {
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
                    .font(.system(size: 12, weight: .semibold))
            }

            // Mute Circle + Label
            VStack(spacing: 4) {
                Button {
                    store.data.settings.muted.toggle()
                } label: {
                    Image(systemName: store.data.settings.muted ? "speaker.slash" : "speaker.wave.2")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .liquidGlassCircle(tinted: tinted)
                }
                .buttonStyle(ScalePressButtonStyle())

                Text(store.data.settings.muted ? "Muted" : "Sound")
                    .font(.system(size: 12, weight: .semibold))
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

            // Exact gooned.app caption layout (`wisconsinWife · /r/BustyPetite · 6d` or `@handle · 𝕏 · 2h`) shown ONLY while holding
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    if let author = gif.author {
                        Text(gif.isXPost ? "@\(author)" : author)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    if gif.isXPost {
                        Text("·")
                            .foregroundStyle(.white.opacity(0.65))
                        Text("𝕏")
                            .font(.system(size: 14, weight: .black))
                            .foregroundStyle(.white.opacity(0.9))
                    } else if let sub = gif.subreddit {
                        Text("·")
                            .foregroundStyle(.white.opacity(0.65))
                        Text("/r/\(sub)")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    if !gif.relativeTime.isEmpty {
                        Text("·")
                            .foregroundStyle(.white.opacity(0.65))
                        Text(gif.relativeTime)
                            .font(.system(size: 14))
                            .foregroundStyle(.white.opacity(0.75))
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
                    if let d = gif.duration {
                        Label("\(Int(d))s", systemImage: "clock")
                    }
                    if let w = gif.width, let h = gif.height {
                        Text("\(w)×\(h)")
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
            AsyncImage(url: gif.imageURL) { phase in
                if let img = phase.image {
                    img.resizable().aspectRatio(contentMode: fill ? .fill : .fit)
                } else {
                    ShimmerPlaceholder()
                }
            }
            .frame(width: size.width, height: size.height)
            .clipped()
        } else {
            ZStack {
                AsyncImage(url: gif.posterURL) { phase in
                    if let img = phase.image {
                        img.resizable().aspectRatio(contentMode: fill ? .fill : .fit)
                    } else {
                        ShimmerPlaceholder()
                    }
                }
                .frame(width: size.width, height: size.height)
                .clipped()

                PlayerLayerView(player: player.player, fill: fill)
                    .frame(width: size.width, height: size.height)
            }
        }
    }

    private func scrubberBar(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(Color.white.opacity(0.24))
            Rectangle().fill(Theme.accent)
                .frame(width: max(0, width * player.progress))
        }
        .frame(height: 2.5)
        .opacity(gif.isImage ? 0 : 1)
    }
}

// MARK: - More (`•••`) Sheet

struct PostMoreSheet: View {
    let gif: Gif
    var onSelectSubreddit: (String) -> Void
    var onSelectUser: (String) -> Void
    var onSelectXUser: (String) -> Void
    @EnvironmentObject var store: UserStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Theme.modalGradient.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Post Info")
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

                if let sub = gif.subreddit {
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
                            } else {
                                onSelectUser(u)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Text(gif.isXPost ? "𝕏  @\(u)" : "u/\(u)")
                                    .font(.headline)
                                Image(systemName: "chevron.right")
                                    .font(.caption.bold())
                            }
                        }
                        Spacer()
                        Button {
                            if gif.isXPost {
                                store.toggleFollowXUser(u)
                            } else {
                                store.toggleFollowUser(u)
                            }
                        } label: {
                            let following = gif.isXPost ? store.isFollowingXUser(u) : store.isFollowingUser(u)
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
                        Text(gif.isXPost ? "Share X Post Link" : "Share Post Link")
                            .font(.subheadline.bold())
                        Spacer()
                    }
                    .padding(14)
                    .liquidGlassCard(cornerRadius: 16)
                }

                Spacer()
            }
            .padding(20)
            .foregroundStyle(.white)
        }
    }
}
