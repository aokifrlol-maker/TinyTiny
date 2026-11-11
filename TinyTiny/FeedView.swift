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
    private var prepared = false

    func prepare(url: URL) {
        guard !prepared else { return }
        prepared = true
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": Config.userAgent]])
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 4
        looper = AVPlayerLooper(player: player, templateItem: item)

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.15, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 else { return }
                self.progress = min(max(time.seconds / d, 0), 1)
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
        if let o = timeObserver { player.removeTimeObserver(o); timeObserver = nil }
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        prepared = false
        progress = 0
    }
}

// MARK: - Full-Screen Reels Scroller

struct FeedView: View {
    @ObservedObject var model: FeedModel
    var isVisible: Bool = true
    var bottomInset: CGFloat = 64

    @EnvironmentObject var store: UserStore
    @State private var currentID: String?
    @State private var onScreen = false
    @State private var enteredAt = Date()

    init(model: FeedModel, isVisible: Bool = true, initialID: String? = nil, bottomInset: CGFloat = 64) {
        self.model = model
        self.isVisible = isVisible
        self.bottomInset = bottomInset
        _currentID = State(initialValue: initialID)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(model.items) { gif in
                    ReelCellView(
                        gif: gif,
                        isActive: onScreen && isVisible && currentID == gif.id,
                        bottomInset: bottomInset
                    )
                    .containerRelativeFrame([.horizontal, .vertical])
                    .id(gif.id)
                    .onAppear { model.onItemAppear(gif) }
                }
                if model.canLoadMore || model.errorText != nil || model.items.isEmpty {
                    FeedStateView(model: model)
                        .containerRelativeFrame([.horizontal, .vertical])
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $currentID)
        .background(Color.black)
        .ignoresSafeArea(edges: .top)
        .onAppear { onScreen = true; enteredAt = Date() }
        .onDisappear { onScreen = false }
        .task {
            if model.items.isEmpty { await model.loadMore() }
            fixCurrent()
        }
        .onChange(of: model.items.count) { _, _ in fixCurrent() }
        .onChange(of: isVisible) { _, _ in enteredAt = Date() }
        .onChange(of: currentID) { old, _ in
            if let old, let g = model.items.first(where: { $0.id == old }) {
                store.recordWatch(g, seconds: Date().timeIntervalSince(enteredAt))
            }
            enteredAt = Date()
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

    var body: some View {
        VStack(spacing: 14) {
            if let err = model.errorText {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Theme.accent)
                Text(err)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                Button {
                    Task { await model.loadMore() }
                } label: {
                    Text("Retry")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                        .background(Theme.accent, in: Capsule())
                        .foregroundStyle(.white)
                }
            } else if model.canLoadMore {
                ProgressView().tint(.white).controlSize(.large)
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: 32))
                    .foregroundStyle(Theme.accent)
                Button("Refresh") {
                    Task { await model.refresh() }
                }
                .font(.subheadline.bold())
                .foregroundStyle(Theme.accent)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .onAppear { Task { await model.loadMore() } }
    }
}

// MARK: - Full-Screen Reel Cell (Hold for 2x Speed + Details, Left/Right/Center Double-Tap)

struct ReelCellView: View {
    let gif: Gif
    let isActive: Bool
    var bottomInset: CGFloat = 64

    @EnvironmentObject var store: UserStore
    @EnvironmentObject var app: AppState
    @StateObject private var player = PlayerModel()
    @State private var userPaused = false
    @State private var showHeart = false
    @State private var skipIndicator: Int? = nil // -5 or +5
    @State private var isHolding = false
    @State private var showInfoSheet = false

    private var shouldPlay: Bool { isActive && !app.isLocked && !userPaused }
    private var fill: Bool { gif.aspect < 0.72 }
    private var liked: Bool { store.isLiked(gif) }
    private var saved: Bool { store.isSaved(gif) }
    private var cat: GoonedCategory { gif.category }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                mediaView(geo.size)

                // Interactive Gesture Zones (Left = -5s, Center = Like, Right = +5s, Single Tap = Pause, Hold = 2x Speed + Video Details)
                gestureOverlay(size: geo.size)

                // Bottom legibility gradient
                VStack {
                    Spacer()
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.68)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 210)
                }
                .allowsHitTesting(false)

                // Center Play Icon when paused
                if userPaused && !isHolding {
                    Circle()
                        .fill(.black.opacity(0.42))
                        .frame(width: 72, height: 72)
                        .overlay(
                            Image(systemName: "play.fill")
                                .font(.system(size: 30))
                                .foregroundStyle(.white)
                                .offset(x: 2)
                        )
                        .allowsHitTesting(false)
                }

                // Double-tap Heart Burst
                if showHeart {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 105))
                        .foregroundStyle(Theme.accent)
                        .shadow(color: Theme.accent.opacity(0.55), radius: 16)
                        .transition(.scale.combined(with: .opacity))
                        .allowsHitTesting(false)
                }

                // Double-tap Left / Right Skip Feedback (-5s / +5s)
                if let skip = skipIndicator {
                    HStack {
                        if skip > 0 { Spacer() }
                        VStack(spacing: 4) {
                            Image(systemName: skip < 0 ? "gobackward.5" : "goforward.5")
                                .font(.system(size: 30, weight: .bold))
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

                // Hold Overlay: 2x Speed Pill at Top + Full Video Details HUD at Bottom
                if isHolding {
                    holdDetailsOverlay(width: geo.size.width)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                } else {
                    // Normal Minimal Overlay
                    VStack(spacing: 8) {
                        Spacer()
                        HStack(alignment: .bottom, spacing: 12) {
                            leftMinimalOverlay
                                .frame(maxWidth: geo.size.width * 0.76, alignment: .leading)
                            Spacer(minLength: 0)
                            rightActionRail
                        }
                        .padding(.horizontal, 14)

                        scrubberBar(width: geo.size.width)
                    }
                    .padding(.bottom, bottomInset)
                    .foregroundStyle(.white)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .sheet(isPresented: $showInfoSheet) {
            PostDetailSheet(gif: gif)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onAppear {
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

    // MARK: - Gesture Zones

    private func gestureOverlay(size: CGSize) -> some View {
        HStack(spacing: 0) {
            // Left 30%: Double-tap = -5s rewind
            zoneView(width: size.width * 0.30) {
                triggerSkip(-5)
            }
            // Center 40%: Double-tap = Like
            zoneView(width: size.width * 0.40) {
                triggerDoubleTapLike()
            }
            // Right 30%: Double-tap = +5s fast-forward
            zoneView(width: size.width * 0.30) {
                triggerSkip(5)
            }
        }
        .frame(width: size.width, height: size.height)
        .onLongPressGesture(minimumDuration: 0.22, maximumDistance: 40, pressing: { pressing in
            if pressing {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
                    // Only engage if still pressing
                }
            } else if isHolding {
                withAnimation(.easeOut(duration: 0.15)) { isHolding = false }
                player.setFastForward(false)
            }
        }, perform: {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            withAnimation(.easeInOut(duration: 0.15)) { isHolding = true }
            if !gif.isImage {
                userPaused = false
                player.setFastForward(true)
            }
        })
    }

    private func zoneView(width: CGFloat, onDoubleTap: @escaping () -> Void) -> some View {
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

    // MARK: - Hold Overlay (2x Speed + Video Details)

    private func holdDetailsOverlay(width: CGFloat) -> some View {
        VStack {
            HStack(spacing: 6) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 11, weight: .bold))
                Text(gif.isImage ? "Details" : "2x Speed")
                    .font(.system(size: 13, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.top, 56)

            Spacer()

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    AvatarRingView(username: gif.userName ?? "creator", size: 36, showRing: true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(gif.userName.map { "@\($0)" } ?? "Creator")
                            .font(.system(size: 15, weight: .bold))
                        HStack(spacing: 6) {
                            if let sub = gif.subreddit {
                                Text("r/\(sub)")
                                    .font(.caption.bold())
                                    .foregroundStyle(Theme.redditOrange)
                            }
                            Text(cat.title)
                                .font(.caption.bold())
                                .foregroundStyle(cat.color)
                            if let w = gif.width, let h = gif.height {
                                Text("• \(w)×\(h)")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            if let d = gif.duration {
                                Text("• \(Int(d))s")
                                    .font(.caption)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                    Spacer()
                }

                if let desc = gif.description, !desc.isEmpty {
                    Text(desc)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !gif.allTags.isEmpty {
                    Text(gif.allTags.prefix(10).map { "#\($0)" }.joined(separator: "  "))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }

                HStack(spacing: 16) {
                    Label("\(shortCount(gif.views)) views", systemImage: "play.fill")
                    Label("\(shortCount(gif.likes)) likes", systemImage: "heart.fill")
                }
                .font(.caption.bold())
                .foregroundStyle(Theme.textSecondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
            .padding(.horizontal, 14)
            .padding(.bottom, bottomInset + 10)
        }
        .foregroundStyle(.white)
    }

    // MARK: - Media & Normal Minimal Overlay

    @ViewBuilder
    private func mediaView(_ size: CGSize) -> some View {
        if gif.isImage {
            AsyncImage(url: gif.imageURL) { phase in
                if let img = phase.image {
                    img.resizable().aspectRatio(contentMode: .fit)
                } else {
                    ShimmerPlaceholder()
                }
            }
            .frame(width: size.width, height: size.height)
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

    private var leftMinimalOverlay: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                if let sub = gif.subreddit {
                    NavigationLink(value: Route.subreddit(sub)) {
                        HStack(spacing: 8) {
                            Circle()
                                .fill(Theme.redditOrange)
                                .frame(width: 34, height: 34)
                                .overlay(Text("r/").font(.system(size: 13, weight: .black)).foregroundStyle(.white))
                            VStack(alignment: .leading, spacing: 1) {
                                Text("r/\(sub)")
                                    .font(.system(size: 15, weight: .bold))
                                if let u = gif.userName {
                                    Text("u/\(u)")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.white.opacity(0.70))
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)

                    let joined = store.isFollowingSubreddit(sub)
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        store.toggleFollowSubreddit(sub)
                    } label: {
                        Text(joined ? "Joined" : "Join")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background(joined ? Color.white.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.82), lineWidth: 1))
                    }
                    .buttonStyle(ScalePressButtonStyle())
                } else {
                    let user = gif.userName ?? "creator"
                    NavigationLink(value: Route.creator(user)) {
                        HStack(spacing: 8) {
                            AvatarRingView(username: user, size: 34, showRing: true)
                            Text(user)
                                .font(.system(size: 15, weight: .bold))
                            if gif.verified == true {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.cyan)
                            }
                        }
                    }
                    .buttonStyle(.plain)

                    if let user = gif.userName {
                        let following = store.isFollowing(user)
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            store.toggleFollow(user)
                        } label: {
                            Text(following ? "Following" : "Follow")
                                .font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 11)
                                .padding(.vertical, 5)
                                .background(following ? Color.white.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.82), lineWidth: 1))
                        }
                        .buttonStyle(ScalePressButtonStyle())
                    }
                }
            }

            if let d = gif.description, !d.isEmpty {
                Text(d)
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.90))
            }
        }
        .shadow(color: .black.opacity(0.55), radius: 3)
    }

    private var rightActionRail: some View {
        VStack(spacing: 18) {
            railButton(
                icon: liked ? "heart.fill" : "heart",
                label: shortCount((gif.likes ?? 0) + (liked ? 1 : 0)),
                tint: liked ? Theme.accent : .white
            ) {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                store.toggleLike(gif)
            }

            railButton(
                icon: saved ? "bookmark.fill" : "bookmark",
                label: nil,
                tint: saved ? .yellow : .white
            ) {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                store.toggleSave(gif)
            }

            if !gif.isImage {
                railButton(
                    icon: store.data.settings.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    label: nil,
                    tint: .white
                ) {
                    store.data.settings.muted.toggle()
                }
            }

            ShareLink(item: gif.webURL) {
                Image(systemName: "paperplane")
                    .font(.system(size: 22, weight: .medium))
                    .frame(width: 36, height: 32)
            }

            Button {
                showInfoSheet = true
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 20, weight: .bold))
                    .frame(width: 36, height: 28)
            }
            .buttonStyle(.plain)
        }
        .shadow(color: .black.opacity(0.6), radius: 3)
    }

    private func railButton(icon: String, label: String?, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(tint)
                if let label {
                    Text(label)
                        .font(.system(size: 11, weight: .semibold))
                }
            }
        }
        .buttonStyle(ScalePressButtonStyle())
    }

    private func scrubberBar(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.20))
            Capsule().fill(Color.white.opacity(0.90))
                .frame(width: max(0, width * player.progress))
        }
        .frame(height: 2)
        .opacity(gif.isImage ? 0 : 1)
    }
}

// MARK: - Instagram-Style Inline Feed Post Card (For Home Feed)

struct SocialPostCardView: View {
    let gif: Gif
    let isPlaying: Bool
    var onOpenReels: () -> Void

    @EnvironmentObject var store: UserStore
    @EnvironmentObject var app: AppState
    @StateObject private var player = PlayerModel()
    @State private var showHeart = false
    @State private var showSheet = false

    private var liked: Bool { store.isLiked(gif) }
    private var saved: Bool { store.isSaved(gif) }
    private var shouldPlay: Bool { isPlaying && store.data.settings.autoplayFeed && !app.isLocked }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Clean Header
            HStack(spacing: 10) {
                if let sub = gif.subreddit {
                    NavigationLink(value: Route.subreddit(sub)) {
                        HStack(spacing: 9) {
                            Circle()
                                .fill(Theme.redditOrange)
                                .frame(width: 32, height: 32)
                                .overlay(Text("r/").font(.system(size: 12, weight: .black)).foregroundStyle(.white))
                            Text("r/\(sub)")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    let user = gif.userName ?? "creator"
                    NavigationLink(value: Route.creator(user)) {
                        HStack(spacing: 9) {
                            AvatarRingView(username: user, size: 32, showRing: true)
                            Text(user)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                            if gif.verified == true {
                                Image(systemName: "checkmark.seal.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.cyan)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Button {
                    showSheet = true
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)

            // Media
            GeometryReader { geo in
                ZStack {
                    Color.black
                    if gif.isImage {
                        AsyncImage(url: gif.imageURL) { phase in
                            if let img = phase.image {
                                img.resizable().aspectRatio(contentMode: .fill)
                            } else {
                                ShimmerPlaceholder()
                            }
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                    } else {
                        AsyncImage(url: gif.posterURL) { phase in
                            if let img = phase.image {
                                img.resizable().aspectRatio(contentMode: .fill)
                            } else {
                                ShimmerPlaceholder()
                            }
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()

                        if shouldPlay {
                            PlayerLayerView(player: player.player, fill: true)
                                .frame(width: geo.size.width, height: geo.size.height)
                        }
                    }

                    if showHeart {
                        Image(systemName: "heart.fill")
                            .font(.system(size: 88))
                            .foregroundStyle(Theme.accent)
                            .shadow(radius: 12)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !gif.isImage {
                        Button {
                            store.data.settings.muted.toggle()
                        } label: {
                            Image(systemName: store.data.settings.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(.black.opacity(0.60), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(10)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    store.like(gif)
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.55)) { showHeart = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.70) {
                        withAnimation(.easeOut(duration: 0.2)) { showHeart = false }
                    }
                }
                .onTapGesture {
                    onOpenReels()
                }
            }
            .aspectRatio(gif.clampedFeedAspect, contentMode: .fit)

            // Action Bar
            HStack(spacing: 16) {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    store.toggleLike(gif)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: liked ? "heart.fill" : "heart")
                            .font(.system(size: 21, weight: .medium))
                            .foregroundStyle(liked ? Theme.accent : .white)
                        Text(shortCount((gif.likes ?? 0) + (liked ? 1 : 0)))
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .buttonStyle(ScalePressButtonStyle())

                ShareLink(item: gif.webURL) {
                    Image(systemName: "paperplane")
                        .font(.system(size: 19, weight: .medium))
                }

                Spacer()

                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    store.toggleSave(gif)
                } label: {
                    Image(systemName: saved ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(saved ? .yellow : .white)
                }
                .buttonStyle(ScalePressButtonStyle())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)

            if let d = gif.description, !d.isEmpty {
                Text(d)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 6)
        .sheet(isPresented: $showSheet) {
            PostDetailSheet(gif: gif)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onAppear {
            if !gif.isImage, let url = gif.videoURL(hd: false) {
                player.prepare(url: url)
                player.setMuted(store.data.settings.muted)
                if shouldPlay { player.play() }
            }
        }
        .onDisappear { player.teardown() }
        .onChange(of: shouldPlay) { _, play in
            if play {
                if !gif.isImage, let url = gif.videoURL(hd: false) { player.prepare(url: url) }
                player.play()
            } else {
                player.pause()
            }
        }
        .onChange(of: store.data.settings.muted) { _, m in player.setMuted(m) }
    }
}

// MARK: - Post Detail Sheet

struct PostDetailSheet: View {
    let gif: Gif
    @EnvironmentObject var store: UserStore
    @Environment(\.dismiss) private var dismiss

    private var cat: GoonedCategory { gif.category }

    var body: some View {
        NavigationStack {
            List {
                if let desc = gif.description, !desc.isEmpty {
                    Section("Caption") {
                        Text(desc).font(.subheadline)
                    }
                }

                Section("Category") {
                    NavigationLink(value: Route.category(cat)) {
                        HStack(spacing: 12) {
                            Image(systemName: cat.icon)
                                .foregroundStyle(cat.color)
                            Text(cat.title).font(.headline)
                        }
                    }
                }

                if let sub = gif.subreddit {
                    Section("Subreddit") {
                        HStack {
                            NavigationLink(value: Route.subreddit(sub)) {
                                Text("r/\(sub)").font(.headline).foregroundStyle(Theme.redditOrange)
                            }
                            Spacer()
                            Button(store.isFollowingSubreddit(sub) ? "Joined" : "Join") {
                                store.toggleFollowSubreddit(sub)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(store.isFollowingSubreddit(sub) ? .gray : Theme.redditOrange)
                        }
                    }
                } else if let user = gif.userName {
                    Section("Creator") {
                        HStack {
                            AvatarRingView(username: user, size: 34, showRing: true)
                            Text("@\(user)").font(.headline)
                            Spacer()
                            Button(store.isFollowing(user) ? "Following" : "Follow") {
                                store.toggleFollow(user)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(store.isFollowing(user) ? .gray : Theme.accent)
                        }
                    }
                }

                if !gif.allTags.isEmpty {
                    Section("Tags") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(gif.allTags, id: \.self) { t in
                                    NavigationLink(value: Route.tag(t)) {
                                        Text("#\(t)")
                                            .font(.caption.bold())
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 6)
                                            .background(Theme.surfaceElevated, in: Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .withGoonedRoutes()
        }
    }
}

struct PostDetailScreen: View {
    let gif: Gif
    var body: some View {
        ReelListScreen(title: gif.category.title, items: [gif], start: gif.id)
    }
}
