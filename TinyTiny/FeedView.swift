import SwiftUI
import AVFoundation

// MARK: - Player

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
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, let d = self.player.currentItem?.duration.seconds, d.isFinite, d > 0 else { return }
                self.progress = min(max(time.seconds / d, 0), 1)
            }
        }
    }

    func play() { player.play() }
    func pause() { player.pause() }
    func setMuted(_ m: Bool) { player.isMuted = m }

    func teardown() {
        player.pause()
        if let o = timeObserver { player.removeTimeObserver(o); timeObserver = nil }
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
        prepared = false
        progress = 0
    }
}

// MARK: - Feed

struct FeedView: View {
    @ObservedObject var model: FeedModel
    var isVisible: Bool = true

    @EnvironmentObject var store: UserStore
    @State private var currentID: String?
    @State private var onScreen = false
    @State private var enteredAt = Date()

    init(model: FeedModel, isVisible: Bool = true, initialID: String? = nil) {
        self.model = model
        self.isVisible = isVisible
        _currentID = State(initialValue: initialID)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(model.items) { gif in
                    VideoCell(gif: gif, isActive: onScreen && isVisible && currentID == gif.id)
                        .containerRelativeFrame([.horizontal, .vertical])
                        .id(gif.id)
                        .onAppear { model.onItemAppear(gif) }
                }
                if model.canLoadMore || model.errorText != nil || model.items.isEmpty {
                    FeedFooter(model: model)
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

struct FeedFooter: View {
    @ObservedObject var model: FeedModel

    var body: some View {
        VStack(spacing: 14) {
            if let err = model.errorText {
                Image(systemName: "wifi.exclamationmark").font(.largeTitle)
                Text(err).foregroundStyle(.secondary)
                Button("Retry") { Task { await model.loadMore() } }.buttonStyle(.borderedProminent)
            } else if model.canLoadMore {
                ProgressView().controlSize(.large)
            } else {
                Image(systemName: "sparkles").font(.largeTitle)
                Text("Nothing here yet").foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .onAppear { Task { await model.loadMore() } }
    }
}

// MARK: - Cell

struct VideoCell: View {
    let gif: Gif
    let isActive: Bool

    @EnvironmentObject var store: UserStore
    @EnvironmentObject var app: AppState
    @StateObject private var player = PlayerModel()
    @State private var userPaused = false
    @State private var showHeart = false
    @State private var dislikedFlash = false

    private var shouldPlay: Bool { isActive && !app.isLocked && !userPaused }
    private var fill: Bool { gif.aspect < 0.7 }
    private var liked: Bool { store.isLiked(gif) }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                media(geo.size)

                LinearGradient(colors: [.clear, .clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)

                if userPaused {
                    Image(systemName: "play.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.white.opacity(0.75))
                        .allowsHitTesting(false)
                }
                if showHeart {
                    Image(systemName: "heart.fill")
                        .font(.system(size: 110))
                        .foregroundStyle(.pink)
                        .shadow(radius: 10)
                        .transition(.scale.combined(with: .opacity))
                        .allowsHitTesting(false)
                }
                if dislikedFlash {
                    Text("Showing less like this")
                        .font(.subheadline.bold())
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }

                VStack {
                    Spacer()
                    HStack(alignment: .bottom, spacing: 12) {
                        info.frame(maxWidth: geo.size.width * 0.74, alignment: .leading)
                        Spacer(minLength: 0)
                        actions
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 14)
                    progressBar(width: geo.size.width)
                }
                .foregroundStyle(.white)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { doubleTapLike() }
            .onTapGesture { userPaused.toggle() }
        }
        .onAppear {
            if !gif.isImage, let url = gif.videoURL(hd: store.data.settings.hd) {
                player.prepare(url: url)
            }
            player.setMuted(store.data.settings.muted)
            update()
        }
        .onDisappear {
            player.teardown()
            userPaused = false
        }
        .onChange(of: shouldPlay) { _, _ in update() }
        .onChange(of: store.data.settings.muted) { _, m in player.setMuted(m) }
    }

    private func update() {
        if shouldPlay { player.play() } else { player.pause() }
    }

    private func doubleTapLike() {
        store.like(gif)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { showHeart = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            withAnimation(.easeOut(duration: 0.25)) { showHeart = false }
        }
    }

    @ViewBuilder
    private func media(_ size: CGSize) -> some View {
        if gif.isImage {
            AsyncImage(url: gif.imageURL) { phase in
                if let img = phase.image {
                    img.resizable().aspectRatio(contentMode: .fit)
                } else {
                    ProgressView()
                }
            }
            .frame(width: size.width, height: size.height)
        } else {
            ZStack {
                AsyncImage(url: gif.posterURL) { phase in
                    if let img = phase.image {
                        img.resizable().aspectRatio(contentMode: fill ? .fill : .fit)
                    } else {
                        Color.black
                    }
                }
                .frame(width: size.width, height: size.height)
                .clipped()
                PlayerLayerView(player: player.player, fill: fill)
                    .frame(width: size.width, height: size.height)
            }
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let user = gif.userName {
                NavigationLink(value: Route.creator(user)) {
                    HStack(spacing: 4) {
                        Text("@\(user)").font(.headline)
                        if gif.verified == true {
                            Image(systemName: "checkmark.seal.fill").foregroundStyle(.cyan).font(.caption)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            if let d = gif.description, !d.isEmpty {
                Text(d).font(.subheadline).lineLimit(2)
            }
            if !gif.allTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(gif.allTags.prefix(10), id: \.self) { t in
                            NavigationLink(value: Route.tag(t)) {
                                Text("#\(t)")
                                    .font(.caption.bold())
                                    .padding(.horizontal, 9).padding(.vertical, 5)
                                    .background(Color.white.opacity(0.18), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            HStack(spacing: 4) {
                Image(systemName: "play.fill")
                Text(shortCount(gif.views))
            }
            .font(.caption).foregroundStyle(.white.opacity(0.8))
        }
        .shadow(color: .black.opacity(0.6), radius: 3)
    }

    private var actions: some View {
        VStack(spacing: 22) {
            if let user = gif.userName {
                ZStack(alignment: .bottom) {
                    NavigationLink(value: Route.creator(user)) {
                        Circle()
                            .fill(LinearGradient(colors: [.pink, .purple], startPoint: .top, endPoint: .bottom))
                            .frame(width: 48, height: 48)
                            .overlay(Text(String(user.prefix(1)).uppercased()).font(.title3.bold()))
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    if !store.isFollowing(user) {
                        Button {
                            store.toggleFollow(user)
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 22))
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, .pink)
                        }
                        .offset(y: 12)
                    }
                }
                .padding(.bottom, 6)
            }

            actionButton(liked ? "heart.fill" : "heart", shortCount((gif.likes ?? 0) + (liked ? 1 : 0)),
                         color: liked ? .pink : .white) {
                store.toggleLike(gif)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }

            if gif.hasAudio != false && !gif.isImage {
                actionButton(store.data.settings.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                             store.data.settings.muted ? "Muted" : "Sound") {
                    store.data.settings.muted.toggle()
                }
            }

            actionButton("hand.thumbsdown.fill", "Less") {
                store.notInterested(gif)
                withAnimation { dislikedFlash = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { withAnimation { dislikedFlash = false } }
            }

            ShareLink(item: gif.webURL) {
                VStack(spacing: 3) {
                    Image(systemName: "arrowshape.turn.up.right.fill").font(.system(size: 28))
                    Text("Share").font(.caption2.bold())
                }
            }
        }
        .shadow(color: .black.opacity(0.6), radius: 3)
    }

    private func actionButton(_ icon: String, _ label: String, color: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 30)).foregroundStyle(color)
                Text(label).font(.caption2.bold())
            }
        }
        .buttonStyle(.plain)
    }

    private func progressBar(width: CGFloat) -> some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(Color.white.opacity(0.2))
            Rectangle().fill(Color.white.opacity(0.85)).frame(width: width * player.progress)
        }
        .frame(height: 2)
        .opacity(gif.isImage ? 0 : 1)
    }
}

