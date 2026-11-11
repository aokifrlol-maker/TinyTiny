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
    @Published var isBuffering: Bool = true
    private var looper: AVPlayerLooper?
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?
    private var prepared = false

    func prepare(url: URL) {
        guard !prepared else { return }
        prepared = true
        isBuffering = true
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["User-Agent": Config.userAgent]])
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 4
        looper = AVPlayerLooper(player: player, templateItem: item)

        statusObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] p, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if p.timeControlStatus == .playing {
                    self.isBuffering = false
                }
            }
        }

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.15, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 else { return }
                self.progress = min(max(time.seconds / d, 0), 1)
                if time.seconds > 0.05 { self.isBuffering = false }
            }
        }
    }

    func play() { player.play() }
    func pause() { player.pause() }
    func setMuted(_ m: Bool) { player.isMuted = m }

    func seek(fraction: Double) {
        guard let d = player.currentItem?.duration.seconds, d.isFinite, d > 0 else { return }
        let target = CMTime(seconds: d * min(max(fraction, 0), 1), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func teardown() {
        player.pause()
        statusObserver?.invalidate()
        statusObserver = nil
        if let o = timeObserver { player.removeTimeObserver(o); timeObserver = nil }
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        prepared = false
        progress = 0
        isBuffering = true
    }
}

// MARK: - Full-Screen Immersive Reels Scroller

struct FeedView: View {
    @ObservedObject var model: FeedModel
    var isVisible: Bool = true
    var bottomInset: CGFloat = 68

    @EnvironmentObject var store: UserStore
    @State private var currentID: String?
    @State private var onScreen = false
    @State private var enteredAt = Date()

    init(model: FeedModel, isVisible: Bool = true, initialID: String? = nil, bottomInset: CGFloat = 68) {
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
                        bottomInset: bottomInset,
                        onDismissNotInterested: { advanceOrRemove(gif) }
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

    private func advanceOrRemove(_ gif: Gif) {
        if let idx = model.items.firstIndex(where: { $0.id == gif.id }) {
            if idx + 1 < model.items.count {
                withAnimation(.easeInOut(duration: 0.25)) {
                    currentID = model.items[idx + 1].id
                }
            } else {
                model.removeItem(gif.id)
            }
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
        VStack(spacing: 16) {
            if let err = model.errorText {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Theme.accent)
                Text(err)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 36)
                Button {
                    Task { await model.loadMore() }
                } label: {
                    Text("Try Again")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 24)
                        .padding(.vertical, 11)
                        .background(Theme.accent, in: Capsule())
                        .foregroundStyle(.white)
                }
            } else if model.canLoadMore {
                ProgressView()
                    .tint(.white)
                    .controlSize(.large)
                Text("Loading Reels…")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: 38))
                    .foregroundStyle(Theme.accent)
                Text("You're all caught up")
                    .font(.headline)
                Button("Refresh Feed") {
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

// MARK: - Instagram Reels / TikTok Full-Screen Cell

struct ReelCellView: View {
    let gif: Gif
    let isActive: Bool
    var bottomInset: CGFloat = 68
    var onDismissNotInterested: () -> Void = {}

    @EnvironmentObject var store: UserStore
    @EnvironmentObject var app: AppState
    @StateObject private var player = PlayerModel()
    @State private var userPaused = false
    @State private var showHeart = false
    @State private var feedbackBanner: String? = nil
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

                // Subtle top & bottom legibility gradients
                VStack(spacing: 0) {
                    LinearGradient(
                        colors: [.black.opacity(0.55), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 110)
                    Spacer()
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.45), .black.opacity(0.85)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 280)
                }
                .allowsHitTesting(false)

                if userPaused {
                    Circle()
                        .fill(.black.opacity(0.45))
                        .frame(width: 78, height: 78)
                        .overlay(
                            Image(systemName: "play.fill")
                                .font(.system(size: 34))
                                .foregroundStyle(.white)
                                .offset(x: 2)
                        )
                        .allowsHitTesting(false)
                }

                if showHeart {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 108))
                        .foregroundStyle(Theme.accent)
                        .shadow(color: Theme.accent.opacity(0.55), radius: 18)
                        .transition(.scale.combined(with: .opacity))
                        .allowsHitTesting(false)
                }

                if let banner = feedbackBanner {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.accent)
                        Text(banner)
                            .font(.subheadline.weight(.semibold))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .allowsHitTesting(false)
                }

                // Bottom Overlay: Creator Row + Caption + Interested/Not Interested Bar + Right Rail
                VStack(spacing: 10) {
                    Spacer()

                    HStack(alignment: .bottom, spacing: 12) {
                        leftCreatorOverlay
                            .frame(maxWidth: geo.size.width * 0.76, alignment: .leading)
                        Spacer(minLength: 0)
                        rightActionRail
                    }
                    .padding(.horizontal, 14)

                    // Instagram Reels style "Not interested" / "Interested" pill bar
                    interestedBar
                        .padding(.horizontal, 14)

                    scrubberBar(width: geo.size.width)
                }
                .padding(.bottom, bottomInset)
                .foregroundStyle(.white)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { triggerDoubleTapLike() }
            .onTapGesture { userPaused.toggle() }
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
        }
        .onChange(of: shouldPlay) { _, _ in syncPlayback() }
        .onChange(of: store.data.settings.muted) { _, m in player.setMuted(m) }
    }

    private func syncPlayback() {
        if shouldPlay { player.play() } else { player.pause() }
    }

    private func triggerDoubleTapLike() {
        store.like(gif)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.55)) { showHeart = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
            withAnimation(.easeOut(duration: 0.22)) { showHeart = false }
        }
    }

    private func showToast(_ text: String) {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.78)) { feedbackBanner = text }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            withAnimation(.easeOut(duration: 0.2)) { feedbackBanner = nil }
        }
    }

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

    private var leftCreatorOverlay: some View {
        VStack(alignment: .leading, spacing: 9) {
            // Creator Avatar + Handle + Inline Outlined Follow Pill (matches Instagram Reels screenshot)
            HStack(spacing: 10) {
                let user = gif.userName ?? "creator"
                NavigationLink(value: Route.creator(user)) {
                    HStack(spacing: 9) {
                        AvatarRingView(username: user, size: 36, showRing: true)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text(user)
                                    .font(.system(size: 15, weight: .bold))
                                if gif.verified == true {
                                    Image(systemName: "checkmark.seal.fill")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.cyan)
                                }
                            }
                            HStack(spacing: 5) {
                                Image(systemName: gif.hasAudio == true ? "waveform" : "play.fill")
                                    .font(.system(size: 10))
                                Text("\(cat.title) • \(shortCount(gif.views)) views")
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(.white.opacity(0.75))
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
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(following ? Color.white.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.white.opacity(0.85), lineWidth: 1)
                            )
                    }
                    .buttonStyle(ScalePressButtonStyle())
                }
            }

            // Fixed Category Badge + Description
            HStack(spacing: 6) {
                NavigationLink(value: Route.category(cat)) {
                    CategoryBadgePill(category: cat, compact: true)
                }
                .buttonStyle(.plain)

                if let d = gif.description, !d.isEmpty {
                    Text(d)
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .foregroundStyle(.white.opacity(0.92))
                }
            }
        }
        .shadow(color: .black.opacity(0.55), radius: 4)
    }

    private var rightActionRail: some View {
        VStack(spacing: 20) {
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
                label: saved ? "Saved" : "Save",
                tint: saved ? .yellow : .white
            ) {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                store.toggleSave(gif)
                showToast(store.isSaved(gif) ? "Saved to collection" : "Removed from Saved")
            }

            if !gif.isImage {
                railButton(
                    icon: store.data.settings.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    label: store.data.settings.muted ? "Muted" : "Audio",
                    tint: .white
                ) {
                    store.data.settings.muted.toggle()
                }
            }

            ShareLink(item: gif.webURL) {
                VStack(spacing: 4) {
                    Image(systemName: "paperplane")
                        .font(.system(size: 24, weight: .medium))
                    Text("Share")
                        .font(.system(size: 11, weight: .semibold))
                }
            }

            Button {
                showInfoSheet = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 20, weight: .medium))
                    .frame(width: 36, height: 30)
            }
            .buttonStyle(.plain)
        }
        .shadow(color: .black.opacity(0.6), radius: 4)
    }

    private func railButton(icon: String, label: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(tint)
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
            }
        }
        .buttonStyle(ScalePressButtonStyle())
    }

    private var interestedBar: some View {
        HStack(spacing: 10) {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                store.markNotInterested(gif)
                showToast("Showing less from \(cat.title)")
                onDismissNotInterested()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                    Text("Not interested")
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.14), lineWidth: 0.8)
                )
            }
            .buttonStyle(ScalePressButtonStyle())

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                store.markInterested(gif)
                showToast("Showing more like \(cat.title)")
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                    Text("Interested")
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.white.opacity(0.14), lineWidth: 0.8)
                )
            }
            .buttonStyle(ScalePressButtonStyle())
        }
    }

    private func scrubberBar(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.22))
            Capsule().fill(Color.white.opacity(0.92))
                .frame(width: max(0, width * player.progress))
        }
        .frame(height: 2.5)
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
    private var cat: GoonedCategory { gif.category }
    private var shouldPlay: Bool { isPlaying && store.data.settings.autoplayFeed && !app.isLocked }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Card Header: Avatar Ring + Username + Category Subtitle + Follow / Menu
            HStack(spacing: 10) {
                let user = gif.userName ?? "creator"
                NavigationLink(value: Route.creator(user)) {
                    HStack(spacing: 10) {
                        AvatarRingView(username: user, size: 34, showRing: true)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text(user)
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(.white)
                                if gif.verified == true {
                                    Image(systemName: "checkmark.seal.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.cyan)
                                }
                            }
                            Text("\(cat.title) • \(gif.relativeTime)")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
                .buttonStyle(.plain)

                Spacer()

                if let user = gif.userName, !store.isFollowing(user) {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        store.toggleFollow(user)
                    } label: {
                        Text("Follow")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.borderStrong, lineWidth: 0.8))
                    }
                    .buttonStyle(ScalePressButtonStyle())
                }

                Button {
                    showSheet = true
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)

            // Media Container
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
                            .font(.system(size: 92))
                            .foregroundStyle(Theme.accent)
                            .shadow(radius: 14)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .overlay(alignment: .topLeading) {
                    NavigationLink(value: Route.category(cat)) {
                        CategoryBadgePill(category: cat, compact: true)
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                }
                .overlay(alignment: .bottomTrailing) {
                    if !gif.isImage {
                        Button {
                            store.data.settings.muted.toggle()
                        } label: {
                            Image(systemName: store.data.settings.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background(.black.opacity(0.65), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .padding(10)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    store.like(gif)
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.55)) { showHeart = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) {
                        withAnimation(.easeOut(duration: 0.2)) { showHeart = false }
                    }
                }
                .onTapGesture {
                    onOpenReels()
                }
            }
            .aspectRatio(gif.clampedFeedAspect, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            // Instagram Action Bar
            HStack(spacing: 16) {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    store.toggleLike(gif)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: liked ? "heart.fill" : "heart")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(liked ? Theme.accent : .white)
                        Text(shortCount((gif.likes ?? 0) + (liked ? 1 : 0)))
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .buttonStyle(ScalePressButtonStyle())

                Button(action: onOpenReels) {
                    HStack(spacing: 5) {
                        Image(systemName: "play.rectangle")
                            .font(.system(size: 20, weight: .medium))
                        Text(shortCount(gif.views))
                            .font(.system(size: 13, weight: .semibold))
                    }
                }
                .buttonStyle(.plain)

                ShareLink(item: gif.webURL) {
                    Image(systemName: "paperplane")
                        .font(.system(size: 20, weight: .medium))
                }

                Spacer()

                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    store.toggleSave(gif)
                } label: {
                    Image(systemName: saved ? "bookmark.fill" : "bookmark")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(saved ? .yellow : .white)
                }
                .buttonStyle(ScalePressButtonStyle())
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)

            // Caption
            if let d = gif.description, !d.isEmpty {
                (Text((gif.userName ?? "creator") + " ").font(.system(size: 13, weight: .bold)) +
                 Text(d).font(.system(size: 13)))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .padding(.horizontal, 12)
            }
        }
        .padding(.vertical, 8)
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

// MARK: - Post Detail Sheet & Full Detail Screen

struct PostDetailSheet: View {
    let gif: Gif
    @EnvironmentObject var store: UserStore
    @Environment(\.dismiss) private var dismiss

    private var cat: GoonedCategory { gif.category }

    var body: some View {
        NavigationStack {
            List {
                Section("Category") {
                    NavigationLink(value: Route.category(cat)) {
                        HStack(spacing: 12) {
                            Image(systemName: cat.icon)
                                .font(.title3)
                                .foregroundStyle(cat.color)
                                .frame(width: 34, height: 34)
                                .background(cat.color.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(cat.title).font(.headline)
                                Text(cat.subtitle).font(.caption).foregroundStyle(Theme.textSecondary)
                            }
                        }
                    }
                }

                if let user = gif.userName {
                    Section("Creator") {
                        HStack {
                            AvatarRingView(username: user, size: 36, showRing: true)
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

                Section("Preferences") {
                    Button {
                        store.markInterested(gif)
                        dismiss()
                    } label: {
                        Label("Interested — show more like this", systemImage: "checkmark.circle")
                    }
                    Button(role: .destructive) {
                        store.markNotInterested(gif)
                        dismiss()
                    } label: {
                        Label("Not interested — hide & show less", systemImage: "xmark.circle")
                    }
                }

                if !gif.allTags.isEmpty {
                    Section("Post Tags") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(gif.allTags, id: \.self) { t in
                                    Text("#\(t)")
                                        .font(.caption.bold())
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(Theme.surfaceElevated, in: Capsule())
                                }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Post Details")
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
