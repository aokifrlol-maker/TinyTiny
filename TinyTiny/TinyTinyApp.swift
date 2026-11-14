import SwiftUI
import AVFoundation

final class OrientationDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .portrait

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        Self.orientationLock
    }
}

@main
struct TinyTinyApp: App {
    @UIApplicationDelegateAdaptor(OrientationDelegate.self) private var orientationDelegate
    @StateObject private var app = AppState()
    @StateObject private var store = UserStore.shared

    init() {
        UserStore.configureAudioSession(muted: UserStore.shared.data.settings.muted)
        URLCache.shared = URLCache(memoryCapacity: 64 * 1024 * 1024, diskCapacity: 400 * 1024 * 1024)
        UITabBar.appearance().isHidden = true
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: UserStore
    @ObservedObject private var license = LicenseManager.shared
    @Environment(\.scenePhase) private var phase

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            if !app.ageConfirmed {
                AgeGateView()
            } else if !app.licenseActivated {
                LicenseGateView {
                    app.licenseActivated = true
                }
            } else if !app.passcodeChoiceCompleted {
                PasscodeSetupView(mode: .create)
            } else {
                if app.hasUnlockedOnce || !app.requirePasscodeOnOpen {
                    GoonedMainShell()
                }
                if app.isLocked {
                    LockView().transition(.opacity).zIndex(10)
                }
            }
            if phase != .active && app.hasPasscode && app.requirePasscodeOnOpen {
                PrivacyCover().zIndex(20)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: app.isLocked)
        .task {
            if license.isValidAccess {
                await license.verifySilently()
                app.licenseActivated = license.isValidAccess
            }
        }
        .onOpenURL { url in
            Task {
                _ = await ShareService.shared.handleIncomingShare(url.absoluteString)
            }
        }
        .onChange(of: phase) { _, p in
            if p == .background {
                app.lock()
                store.saveNow()
                SmartTasteEngine.shared.saveNow()
                Task { await license.syncEncryptedBackupNow() }
            }
        }
    }
}

// MARK: - Exact gooned.app Bottom Dock Tabs

enum GoonedDockTab: Int, CaseIterable {
    case home = 0
    case likes = 1
    case browse = 2
    case profile = 3
}

enum HomeChannel: Hashable {
    case following, forYou
    case xForYou, xFollowing, xBookmarks
    case rule34
    case igReels, igFollowing, igSaved
    case ofTrending, ofLatest, ofDMs
    case longAll, longEporner, longPornhub, longXHamster, longSpankBang
    case custom
}

struct GoonedMainShell: View {
    @EnvironmentObject var store: UserStore
    @ObservedObject private var shareService = ShareService.shared
    @StateObject private var followingModel = FeedModel(source: .following)
    @StateObject private var forYouModel = FeedModel(source: .forYou)
    @StateObject private var xForYouModel = FeedModel(source: .xForYou)
    @StateObject private var xFollowingModel = FeedModel(source: .xFollowing)
    @StateObject private var xBookmarksModel = FeedModel(source: .xBookmarks)
    @StateObject private var r34Model = FeedModel(source: .rule34(""))
    @StateObject private var igReelsModel = FeedModel(source: .igReels)
    @StateObject private var igFollowingModel = FeedModel(source: .igFollowing)
    @StateObject private var igSavedModel = FeedModel(source: .igSaved)
    @StateObject private var ofTrendingModel = FeedModel(source: .ofTrending)
    @StateObject private var ofLatestModel = FeedModel(source: .ofLatest)
    @StateObject private var ofDMsModel = FeedModel(source: .ofDMs)
    @StateObject private var longAllModel = FeedModel(source: .longVideos(.all))
    @StateObject private var longEpornerModel = FeedModel(source: .longVideos(.eporner))
    @StateObject private var longPornhubModel = FeedModel(source: .longVideos(.pornhub))
    @StateObject private var longXHamsterModel = FeedModel(source: .longVideos(.xhamster))
    @StateObject private var longSpankBangModel = FeedModel(source: .longVideos(.spankbang))
    @StateObject private var customModel = FeedModel(source: .forYou)

    private struct CustomBackHistoryItem {
        let channel: HomeChannel
        let customSource: FeedSource?
        let customItems: [Gif]
        let postID: String?
        let returnTab: GoonedDockTab
    }

    @State private var activeChannel: HomeChannel = .forYou
    @State private var lastXChannel: HomeChannel = .xForYou
    @State private var lastIGChannel: HomeChannel = .igReels
    @State private var lastOFChannel: HomeChannel = .ofTrending
    @State private var lastLongChannel: HomeChannel = .longAll
    @State private var slotPostIDs: [HomeChannel: String] = [:]
    @State private var customBackStack: [CustomBackHistoryItem] = []
    @State private var activeTab: GoonedDockTab = .home
    @State private var showSettingsModal = false
    @State private var showXLoginSheet = false
    @State private var showIGLoginSheet = false
    @State private var showR34KeySheet = false
    @State private var pendingFeedAfterLogin: FeedSource? = nil
    @State private var didPrewarm = false

    private var tinted: Bool { store.data.settings.tintedGlass }

    private var isXChannel: Bool {
        activeChannel == .xForYou || activeChannel == .xFollowing || activeChannel == .xBookmarks
    }

    private var isIGChannel: Bool {
        activeChannel == .igReels || activeChannel == .igFollowing || activeChannel == .igSaved
    }

    private var isOFChannel: Bool {
        activeChannel == .ofTrending || activeChannel == .ofLatest || activeChannel == .ofDMs
    }

    private var isLongChannel: Bool {
        activeChannel == .longAll || activeChannel == .longEporner || activeChannel == .longPornhub || activeChannel == .longXHamster || activeChannel == .longSpankBang
    }

    private var activeModel: FeedModel {
        switch activeChannel {
        case .following: return followingModel
        case .forYou: return forYouModel
        case .xForYou: return xForYouModel
        case .xFollowing: return xFollowingModel
        case .xBookmarks: return xBookmarksModel
        case .rule34: return r34Model
        case .igReels: return igReelsModel
        case .igFollowing: return igFollowingModel
        case .igSaved: return igSavedModel
        case .ofTrending: return ofTrendingModel
        case .ofLatest: return ofLatestModel
        case .ofDMs: return ofDMsModel
        case .longAll: return longAllModel
        case .longEporner: return longEpornerModel
        case .longPornhub: return longPornhubModel
        case .longXHamster: return longXHamsterModel
        case .longSpankBang: return longSpankBangModel
        case .custom: return customModel
        }
    }

    private var currentPostIDBinding: Binding<String?> {
        Binding(
            get: { slotPostIDs[activeChannel] },
            set: { slotPostIDs[activeChannel] = $0 }
        )
    }

    private var isFollowingFeed: Bool {
        activeChannel == .following
    }

    var body: some View {
        ZStack {
            // 1. Main Full-Screen Feed Scroller (persistent per-channel models + instant horizontal swipe)
            FeedView(
                model: activeModel,
                isVisible: activeTab == .home && !showSettingsModal && !showXLoginSheet && !showIGLoginSheet && !showR34KeySheet,
                currentID: currentPostIDBinding,
                onOpenCategories: {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.88)) {
                        activeTab = .browse
                    }
                },
                onSelectSubreddit: { sub in
                    selectFeed(.subreddit(sub))
                },
                onSelectUser: { u in
                    selectFeed(.user(u))
                },
                onSelectXUser: { handle in
                    selectXFeedOrLogin(.xUser(handle))
                },
                onSelectIGUser: { handle in
                    selectIGFeedOrLogin(.igUser(handle))
                },
                onSelectRule34Tag: { tag in
                    selectFeed(.rule34(tag))
                },
                onSelectOFCreator: { creatorId, handle in
                    selectFeed(.ofCreator(id: creatorId, handle: handle, displayName: nil))
                },
                onConnectX: {
                    pendingFeedAfterLogin = activeModel.source.isXFeed ? activeModel.source : .xForYou
                    showXLoginSheet = true
                },
                onConnectIG: {
                    pendingFeedAfterLogin = activeModel.source.isIGFeed ? activeModel.source : .igReels
                    showIGLoginSheet = true
                }
            )
            .id(activeChannel)
            .simultaneousGesture(
                DragGesture(minimumDistance: 30)
                    .onEnded { val in
                        guard activeTab == .home,
                              !showSettingsModal,
                              !showXLoginSheet,
                              !showIGLoginSheet,
                              !showR34KeySheet else { return }
                        let dx = val.translation.width
                        let dy = val.translation.height
                        guard abs(dx) > 55, abs(dx) > abs(dy) * 1.5 else { return }
                        handleHorizontalFeedSwipe(dx: dx)
                    }
            )
            .opacity(activeTab == .home ? 1 : 0)
            .allowsHitTesting(activeTab == .home)

            // 2. Top Bar on Home (auto-hides alongside bottom dock when controls are collapsed)
            if activeTab == .home && !store.data.settings.controlsCollapsed {
                VStack {
                    homeTopBar
                    Spacer()
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // 3. Likes & Offline Vault Overlay
            if activeTab == .likes {
                GoonedLikesView(
                    onOpenSettings: { showSettingsModal = true },
                    onStartStash: {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                            activeTab = .home
                        }
                    },
                    onPlayLikedPost: { post in
                        pushCustomBackHistory(returnTab: .likes)
                        customModel.switchSource(.list(title: "Liked"), initialItems: store.data.liked)
                        slotPostIDs[.custom] = post.id
                        activeChannel = .custom
                        withAnimation(.spring(response: 0.22, dampingFraction: 0.88)) {
                            activeTab = .home
                        }
                    },
                    onPlayOfflinePost: { post in
                        pushCustomBackHistory(returnTab: .likes)
                        customModel.switchSource(.list(title: "Offline Vault"), initialItems: store.data.downloaded)
                        slotPostIDs[.custom] = post.id
                        activeChannel = .custom
                        withAnimation(.spring(response: 0.22, dampingFraction: 0.88)) {
                            activeTab = .home
                        }
                    }
                )
                .transition(.opacity)
            }

            // 4. Browse / Search / Categories / X / Instagram / Rule34 Fullscreen Overlay
            if activeTab == .browse {
                GoonedBrowseOverlay(
                    onClose: {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                            activeTab = .home
                        }
                    },
                    onSelectFeed: { src in
                        if src.isXFeed {
                            selectXFeedOrLogin(src)
                        } else if src.isIGFeed {
                            selectIGFeedOrLogin(src)
                        } else {
                            selectFeed(src)
                        }
                    },
                    onOpenPost: { post in
                        openSharedPost(post)
                    },
                    onConnectX: {
                        pendingFeedAfterLogin = .xForYou
                        showXLoginSheet = true
                    },
                    onConnectIG: {
                        pendingFeedAfterLogin = .igReels
                        showIGLoginSheet = true
                    },
                    onSetupR34Key: {
                        showR34KeySheet = true
                    }
                )
                .transition(.opacity)
            }

            // 5. Profile / Follows Overlay
            if activeTab == .profile {
                GoonedFollowsView(
                    onOpenSettings: { showSettingsModal = true },
                    onSelectFeed: { src in
                        if src.isXFeed {
                            selectXFeedOrLogin(src)
                        } else if src.isIGFeed {
                            selectIGFeedOrLogin(src)
                        } else {
                            selectFeed(src)
                        }
                    },
                    onConnectX: {
                        pendingFeedAfterLogin = .xForYou
                        showXLoginSheet = true
                    },
                    onConnectIG: {
                        pendingFeedAfterLogin = .igReels
                        showIGLoginSheet = true
                    }
                )
                .transition(.opacity)
            }

            // 6. Floating Liquid Glass Bottom Dock
            if activeTab != .browse && !(activeTab == .home && store.data.settings.controlsCollapsed) {
                VStack {
                    Spacer()
                    goonedBottomDock
                        .padding(.horizontal, 28)
                        .padding(.bottom, 14)
                        .gesture(
                            DragGesture(minimumDistance: 12)
                                .onEnded { val in
                                    if val.translation.height > 16 && activeTab == .home {
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                                            store.data.settings.controlsCollapsed = true
                                        }
                                    }
                                }
                        )
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            // 7. Liquid Glass Settings Modal
            if showSettingsModal {
                GoonedSettingsModal(
                    isPresented: $showSettingsModal,
                    onConnectX: {
                        showSettingsModal = false
                        pendingFeedAfterLogin = nil
                        showXLoginSheet = true
                    },
                    onConnectIG: {
                        showSettingsModal = false
                        pendingFeedAfterLogin = nil
                        showIGLoginSheet = true
                    },
                    onSetupR34Key: {
                        showSettingsModal = false
                        showR34KeySheet = true
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(30)
            }
        }
        .animation(.easeOut(duration: 0.14), value: activeTab)
        .animation(.easeOut(duration: 0.14), value: showSettingsModal)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: store.data.settings.controlsCollapsed)
        .task {
            guard !didPrewarm else { return }
            didPrewarm = true
            try? await Task.sleep(nanoseconds: 350_000_000)
            // Pre-warm Rule34 & OnlyFans (URLSession JSON, zero WebView contention)
            if r34Model.items.isEmpty {
                Task { await r34Model.loadMore() }
            }
            if ofTrendingModel.items.isEmpty {
                Task { await ofTrendingModel.loadMore() }
            }
            if store.data.xSession.isConnected {
                Task { @MainActor in
                    if xForYouModel.items.isEmpty {
                        await xForYouModel.loadMore()
                    } else {
                        await XWebEngine.shared.warmUp()
                    }
                }
            }
            if store.data.igSession.isConnected {
                Task { @MainActor in
                    if igReelsModel.items.isEmpty {
                        await igReelsModel.loadMore()
                    } else {
                        await InstagramWebEngine.shared.warmUp()
                    }
                }
            }
        }
        .sheet(isPresented: $showXLoginSheet) {
            XLoginSheet {
                let target = pendingFeedAfterLogin ?? .xForYou
                pendingFeedAfterLogin = nil
                selectFeed(target, forceReload: true)
            }
            .environmentObject(store)
        }
        .sheet(isPresented: $showIGLoginSheet) {
            InstagramLoginSheet {
                let target = pendingFeedAfterLogin ?? .igReels
                pendingFeedAfterLogin = nil
                selectFeed(target, forceReload: true)
            }
            .environmentObject(store)
        }
        .sheet(isPresented: $showR34KeySheet) {
            Rule34KeySheet()
                .environmentObject(store)
        }
        .onChange(of: shareService.pendingReceivedPost) { _, post in
            if let post {
                openSharedPost(post)
                shareService.pendingReceivedPost = nil
            }
        }
        .onChange(of: activeChannel) { _, _ in syncOrientationLock() }
        .onChange(of: activeTab) { _, _ in syncOrientationLock() }
        .onChange(of: customModel.source) { _, _ in syncOrientationLock() }
    }

    private func openSharedPost(_ post: Gif) {
        pushCustomBackHistory(returnTab: activeTab)
        customModel.switchSource(.list(title: "Shared Drop"), initialItems: [post])
        slotPostIDs[.custom] = post.id
        activeChannel = .custom
        withAnimation(.spring(response: 0.22, dampingFraction: 0.88)) {
            activeTab = .home
        }
    }

    private func syncOrientationLock() {
        let allowLandscape = (activeTab == .home && activeModel.source.isLongVideoFeed)
        let target: UIInterfaceOrientationMask = allowLandscape ? .allButUpsideDown : .portrait
        guard OrientationDelegate.orientationLock != target else { return }
        OrientationDelegate.orientationLock = target
        if !allowLandscape, let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait)) { _ in }
        }
    }

    private func pushCustomBackHistory(returnTab: GoonedDockTab = .home) {
        let item = CustomBackHistoryItem(
            channel: activeChannel,
            customSource: activeChannel == .custom ? customModel.source : nil,
            customItems: activeChannel == .custom && customModel.source.isList ? customModel.items : [],
            postID: slotPostIDs[activeChannel],
            returnTab: returnTab
        )
        customBackStack.append(item)
        if customBackStack.count > 16 {
            customBackStack.removeFirst(customBackStack.count - 16)
        }
    }

    private func popCustomFeed() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if let prev = customBackStack.popLast() {
            if prev.channel == .custom {
                customModel.switchSource(prev.customSource ?? .forYou, initialItems: prev.customItems)
                slotPostIDs[.custom] = prev.postID
                activeChannel = .custom
            } else {
                activeChannel = prev.channel
                if let pid = prev.postID {
                    slotPostIDs[prev.channel] = pid
                }
            }
            if activeTab != prev.returnTab {
                withAnimation(.easeOut(duration: 0.16)) {
                    activeTab = prev.returnTab
                }
            }
        } else {
            selectFeed(.forYou)
        }
    }

    private func selectFeed(_ src: FeedSource, forceReload: Bool = false) {
        switch src {
        case .following:
            customBackStack.removeAll()
            activeChannel = .following
            if forceReload {
                slotPostIDs[.following] = nil
                Task { await followingModel.refresh(rotateCursor: true) }
            }
        case .forYou:
            customBackStack.removeAll()
            activeChannel = .forYou
            if forceReload {
                slotPostIDs[.forYou] = nil
                Task { await forYouModel.refresh(rotateCursor: true) }
            }
        case .xForYou:
            customBackStack.removeAll()
            activeChannel = .xForYou
            lastXChannel = .xForYou
            if forceReload {
                slotPostIDs[.xForYou] = nil
                Task { await xForYouModel.refresh(rotateCursor: true) }
            }
        case .xFollowing:
            customBackStack.removeAll()
            activeChannel = .xFollowing
            lastXChannel = .xFollowing
            if forceReload {
                slotPostIDs[.xFollowing] = nil
                Task { await xFollowingModel.refresh(rotateCursor: true) }
            }
        case .xBookmarks:
            customBackStack.removeAll()
            activeChannel = .xBookmarks
            lastXChannel = .xBookmarks
            if forceReload {
                slotPostIDs[.xBookmarks] = nil
                Task { await xBookmarksModel.refresh(rotateCursor: true) }
            }
        case .rule34(let tag) where tag.isEmpty:
            customBackStack.removeAll()
            activeChannel = .rule34
            if forceReload {
                slotPostIDs[.rule34] = nil
                Task { await r34Model.refresh(rotateCursor: true) }
            }
        case .igReels:
            customBackStack.removeAll()
            activeChannel = .igReels
            lastIGChannel = .igReels
            if forceReload {
                slotPostIDs[.igReels] = nil
                Task { await igReelsModel.refresh(rotateCursor: true) }
            }
        case .igFollowing:
            customBackStack.removeAll()
            activeChannel = .igFollowing
            lastIGChannel = .igFollowing
            if forceReload {
                slotPostIDs[.igFollowing] = nil
                Task { await igFollowingModel.refresh(rotateCursor: true) }
            }
        case .igSaved:
            customBackStack.removeAll()
            activeChannel = .igSaved
            lastIGChannel = .igSaved
            if forceReload {
                slotPostIDs[.igSaved] = nil
                Task { await igSavedModel.refresh(rotateCursor: true) }
            }
        case .ofTrending:
            customBackStack.removeAll()
            activeChannel = .ofTrending
            lastOFChannel = .ofTrending
            if forceReload {
                slotPostIDs[.ofTrending] = nil
                Task { await ofTrendingModel.refresh(rotateCursor: true) }
            }
        case .ofLatest:
            customBackStack.removeAll()
            activeChannel = .ofLatest
            lastOFChannel = .ofLatest
            if forceReload {
                slotPostIDs[.ofLatest] = nil
                Task { await ofLatestModel.refresh(rotateCursor: true) }
            }
        case .ofDMs:
            customBackStack.removeAll()
            activeChannel = .ofDMs
            lastOFChannel = .ofDMs
            if forceReload {
                slotPostIDs[.ofDMs] = nil
                Task { await ofDMsModel.refresh(rotateCursor: true) }
            }
        case .longVideos(let site):
            customBackStack.removeAll()
            let mapped: HomeChannel
            let model: FeedModel
            switch site {
            case .all: mapped = .longAll; model = longAllModel
            case .eporner: mapped = .longEporner; model = longEpornerModel
            case .pornhub: mapped = .longPornhub; model = longPornhubModel
            case .xhamster: mapped = .longXHamster; model = longXHamsterModel
            case .spankbang: mapped = .longSpankBang; model = longSpankBangModel
            }
            activeChannel = mapped
            lastLongChannel = mapped
            if forceReload {
                slotPostIDs[mapped] = nil
                Task { await model.refresh(rotateCursor: true) }
            }
        default:
            if activeChannel != .custom || customModel.source != src {
                pushCustomBackHistory(returnTab: .home)
            }
            activeChannel = .custom
            if customModel.source != src || forceReload {
                slotPostIDs[.custom] = nil
                customModel.switchSource(src)
            }
        }

        if activeTab != .home {
            withAnimation(.easeOut(duration: 0.16)) {
                activeTab = .home
            }
        }
    }

    private func selectXFeedOrLogin(_ src: FeedSource) {
        if store.data.xSession.isConnected {
            selectFeed(src)
        } else {
            pendingFeedAfterLogin = src
            showXLoginSheet = true
        }
    }

    private func selectIGFeedOrLogin(_ src: FeedSource) {
        if store.data.igSession.isConnected {
            selectFeed(src)
        } else {
            pendingFeedAfterLogin = src
            showIGLoginSheet = true
        }
    }

    private var homeChannelIndex: Int {
        switch activeChannel {
        case .following: return 0
        case .forYou, .custom: return 1
        case .xForYou, .xFollowing, .xBookmarks: return 2
        case .rule34: return 3
        case .igReels, .igFollowing, .igSaved: return 4
        case .ofTrending, .ofLatest, .ofDMs: return 5
        case .longAll, .longEporner, .longPornhub, .longXHamster, .longSpankBang: return 6
        }
    }

    private func handleHorizontalFeedSwipe(dx: CGFloat) {
        let channels: [FeedSource] = [.following, .forYou, .xForYou, .rule34(""), .igReels, .ofTrending, .longVideos(.all)]
        let cur = homeChannelIndex
        // Swipe left (dx < 0) moves forward: Following -> For You -> X -> R34 -> IG -> OF -> Long Videos
        // Swipe right (dx > 0) moves backward
        let nextIdx = dx < 0 ? cur + 1 : cur - 1
        guard channels.indices.contains(nextIdx) else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let target = channels[nextIdx]
        if target.isXFeed {
            selectXFeedOrLogin(target)
        } else if target.isIGFeed {
            selectIGFeedOrLogin(target)
        } else {
            selectFeed(target)
        }
    }

    // MARK: - Home Top Bar (`🔍` | Auto-Centered Channel Rail | `⚙️`)

    private var homeTopBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                // Left: Search Circle Button
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    activeTab = .browse
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .liquidGlassCircle(tinted: tinted)
                }
                .buttonStyle(ScalePressButtonStyle())
                .fixedSize()

                if activeChannel == .custom {
                    Spacer(minLength: 4)
                    customFeedTitlePill
                    Spacer(minLength: 4)
                } else {
                    channelRail
                }

                // Right: Gear Settings Circle Button
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    showSettingsModal = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .liquidGlassCircle(tinted: tinted)
                }
                .buttonStyle(ScalePressButtonStyle())
                .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)

            // Secondary sub-feed switcher directly beneath the centered channel
            if isXChannel {
                subChannelBar([
                    (.xForYou, "For You", .xForYou),
                    (.xFollowing, "Following", .xFollowing),
                    (.xBookmarks, "Bookmarks", .xBookmarks)
                ]) { selectXFeedOrLogin($0) }
            } else if isIGChannel {
                subChannelBar([
                    (.igReels, "Reels", .igReels),
                    (.igFollowing, "Following", .igFollowing),
                    (.igSaved, "Saved", .igSaved)
                ]) { selectIGFeedOrLogin($0) }
            } else if isOFChannel {
                subChannelBar([
                    (.ofTrending, "Trending", .ofTrending),
                    (.ofLatest, "Latest", .ofLatest),
                    (.ofDMs, "DMs", .ofDMs)
                ]) { selectFeed($0) }
            } else if isLongChannel {
                subChannelBar([
                    (.longVideos(.all), "All", .longAll),
                    (.longVideos(.eporner), "Eporner", .longEporner),
                    (.longVideos(.pornhub), "Pornhub", .longPornhub),
                    (.longVideos(.xhamster), "xHamster", .longXHamster),
                    (.longVideos(.spankbang), "SpankBang", .longSpankBang)
                ]) { selectFeed($0) }
            }
        }
    }

    /// Horizontally scrollable channel rail that smoothly glides the active channel to center.
    private var channelRail: some View {
        GeometryReader { geo in
            let edgePad = max(12, (geo.size.width - 72) / 2)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        Color.clear.frame(width: edgePad, height: 1)

                        textChannelButton(
                            id: 0,
                            title: "Following",
                            active: isFollowingFeed
                        ) {
                            selectFeed(.following, forceReload: activeChannel == .following)
                        }

                        textChannelButton(
                            id: 1,
                            title: "For You",
                            active: activeChannel == .forYou
                        ) {
                            selectFeed(.forYou, forceReload: activeChannel == .forYou)
                        }

                        brandChannelButton(id: 2, active: isXChannel) {
                            if isXChannel {
                                selectFeed(activeModel.source, forceReload: true)
                            } else {
                                let target: FeedSource = lastXChannel == .xFollowing ? .xFollowing : (lastXChannel == .xBookmarks ? .xBookmarks : .xForYou)
                                selectXFeedOrLogin(target)
                            }
                        } label: {
                            BrandLogoX(active: isXChannel, connected: store.data.xSession.isConnected)
                        }

                        brandChannelButton(id: 3, active: activeChannel == .rule34) {
                            selectFeed(.rule34(""), forceReload: activeChannel == .rule34)
                        } label: {
                            BrandLogoRule34(active: activeChannel == .rule34)
                        }

                        brandChannelButton(id: 4, active: isIGChannel) {
                            if isIGChannel {
                                selectFeed(activeModel.source, forceReload: true)
                            } else {
                                let target: FeedSource = lastIGChannel == .igFollowing ? .igFollowing : (lastIGChannel == .igSaved ? .igSaved : .igReels)
                                selectIGFeedOrLogin(target)
                            }
                        } label: {
                            BrandLogoInstagram(active: isIGChannel, connected: store.data.igSession.isConnected)
                        }

                        brandChannelButton(id: 5, active: isOFChannel) {
                            if isOFChannel {
                                selectFeed(activeModel.source, forceReload: true)
                            } else {
                                let target: FeedSource = lastOFChannel == .ofLatest ? .ofLatest : (lastOFChannel == .ofDMs ? .ofDMs : .ofTrending)
                                selectFeed(target)
                            }
                        } label: {
                            BrandLogoOnlyFans(active: isOFChannel)
                        }

                        brandChannelButton(id: 6, active: isLongChannel) {
                            if isLongChannel {
                                selectFeed(activeModel.source, forceReload: true)
                            } else {
                                let targetSite: LongVideoSite
                                switch lastLongChannel {
                                case .longEporner: targetSite = .eporner
                                case .longPornhub: targetSite = .pornhub
                                case .longXHamster: targetSite = .xhamster
                                case .longSpankBang: targetSite = .spankbang
                                default: targetSite = .all
                                }
                                selectFeed(.longVideos(targetSite))
                            }
                        } label: {
                            BrandLogoLongVideos(active: isLongChannel)
                        }

                        Color.clear.frame(width: edgePad, height: 1)
                    }
                    .frame(minHeight: 38)
                    .shadow(color: .black.opacity(0.6), radius: 4)
                }
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: .black, location: 0.09),
                            .init(color: .black, location: 0.91),
                            .init(color: .clear, location: 1.0)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .onAppear {
                    proxy.scrollTo(homeChannelIndex, anchor: .center)
                    DispatchQueue.main.async {
                        proxy.scrollTo(homeChannelIndex, anchor: .center)
                    }
                }
                .onChange(of: activeChannel) { _, _ in
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        proxy.scrollTo(homeChannelIndex, anchor: .center)
                    }
                }
            }
        }
        .frame(height: 38)
    }

    private func textChannelButton(id: Int, title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            VStack(spacing: 3) {
                Text(title)
                    .font(.system(size: active ? 15 : 13.5, weight: active ? .bold : .medium))
                    .foregroundStyle(active ? .white : .white.opacity(0.60))
                    .fixedSize()
                Capsule()
                    .fill(active ? Color.white : Color.clear)
                    .frame(width: 16, height: 2.5)
            }
            .padding(.horizontal, 2)
        }
        .buttonStyle(ScalePressButtonStyle())
        .id(id)
    }

    private func brandChannelButton<Content: View>(
        id: Int,
        active: Bool,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Content
    ) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            label()
                .scaleEffect(active ? 1.08 : 0.90)
                .opacity(active ? 1.0 : 0.70)
                .animation(.easeOut(duration: 0.16), value: active)
        }
        .buttonStyle(ScalePressButtonStyle())
        .id(id)
    }

    private func subChannelBar(
        _ items: [(FeedSource, String, HomeChannel)],
        onSelect: @escaping (FeedSource) -> Void
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: items.count > 3 ? 12 : 14) {
                ForEach(items, id: \.1) { src, label, chan in
                    let active = activeChannel == chan
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        onSelect(src)
                    } label: {
                        Text(label)
                            .font(.system(size: 12, weight: active ? .bold : .medium))
                            .foregroundStyle(active ? .white : .white.opacity(0.60))
                            .fixedSize()
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
        }
        .fixedSize(horizontal: items.count <= 3, vertical: true)
        .liquidGlassCapsule(tinted: tinted)
        .padding(.horizontal, items.count > 3 ? 16 : 0)
    }

    private var customFeedTitlePill: some View {
        Button {
            popCustomFeed()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))

                Text(customModel.source.displayTitle)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 8)
            .contentShape(Capsule())
            .liquidGlassCapsule(tinted: tinted)
        }
        .buttonStyle(ScalePressButtonStyle())
    }

    // MARK: - Floating Liquid Glass Bottom Dock (`🏠` `🤍` `🧭` `👤`)

    private var goonedBottomDock: some View {
        HStack(spacing: 6) {
            dockButton(tab: .home, icon: "house", activeIcon: "house.fill")
            dockButton(tab: .likes, icon: "heart", activeIcon: "heart.fill")
            dockButton(tab: .browse, icon: "safari", activeIcon: "safari.fill")
            dockButton(tab: .profile, icon: "person", activeIcon: "person.fill")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(height: 58)
        .liquidGlassCapsule(tinted: tinted)
        .shadow(color: .black.opacity(0.45), radius: 16, y: 6)
    }

    private func dockButton(tab: GoonedDockTab, icon: String, activeIcon: String) -> some View {
        let isSelected = activeTab == tab
        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if isSelected && tab == .home {
                if activeChannel == .forYou {
                    slotPostIDs[.forYou] = nil
                    Task { await forYouModel.refresh(rotateCursor: true) }
                } else {
                    selectFeed(.forYou)
                }
            } else {
                activeTab = tab
            }
        } label: {
            ZStack {
                if isSelected {
                    Circle()
                        .fill(Color.white.opacity(0.20))
                        .overlay(Circle().stroke(Color.white.opacity(0.32), lineWidth: 0.9))
                        .frame(width: 46, height: 46)
                }
                Image(systemName: isSelected ? activeIcon : icon)
                    .font(.system(size: 20, weight: isSelected ? .bold : .medium))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Compact Brand Logos for Top Bar

struct BrandLogoX: View {
    var active: Bool
    var connected: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Circle()
                .fill(active ? Color.white : Color.black.opacity(0.55))
                .frame(width: 26, height: 26)
                .overlay(
                    Circle().stroke(active ? Color.white : Color.white.opacity(0.28), lineWidth: active ? 1.5 : 0.8)
                )
                .overlay(
                    Text("𝕏")
                        .font(.system(size: 13.5, weight: .black))
                        .foregroundStyle(active ? Color.black : Color.white)
                )

            if connected {
                Circle()
                    .fill(Theme.accentBright)
                    .frame(width: 6, height: 6)
                    .overlay(Circle().stroke(Color.black, lineWidth: 1))
                    .offset(x: 1, y: -1)
            }
        }
        .frame(width: 26, height: 26)
    }
}

struct BrandLogoRule34: View {
    var active: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color(red: 0.69, green: 0.92, blue: 0.65), Color(red: 0.45, green: 0.77, blue: 0.42)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 26, height: 26)
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(active ? Color.white : Color.white.opacity(0.28), lineWidth: active ? 1.8 : 0.7)
            )
            .overlay(
                Text("34")
                    .font(.system(size: 12, weight: .black, design: .rounded))
                    .foregroundStyle(Color(red: 0.06, green: 0.22, blue: 0.06))
            )
            .opacity(active ? 1.0 : 0.88)
            .frame(width: 26, height: 26)
    }
}

struct BrandLogoInstagram: View {
    var active: Bool
    var connected: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.99, green: 0.76, blue: 0.28),
                            Color(red: 0.96, green: 0.27, blue: 0.34),
                            Color(red: 0.76, green: 0.16, blue: 0.65),
                            Color(red: 0.38, green: 0.24, blue: 0.88)
                        ],
                        startPoint: .bottomLeading,
                        endPoint: .topTrailing
                    )
                )
                .frame(width: 26, height: 26)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(active ? Color.white : Color.white.opacity(0.28), lineWidth: active ? 1.8 : 0.7)
                )
                .overlay(
                    ZStack {
                        RoundedRectangle(cornerRadius: 4.5, style: .continuous)
                            .stroke(Color.white, lineWidth: 1.5)
                            .frame(width: 15, height: 15)
                        Circle()
                            .stroke(Color.white, lineWidth: 1.5)
                            .frame(width: 7, height: 7)
                        Circle()
                            .fill(Color.white)
                            .frame(width: 2.2, height: 2.2)
                            .offset(x: 4.4, y: -4.4)
                    }
                )

            if connected {
                Circle()
                    .fill(Theme.accentBright)
                    .frame(width: 6, height: 6)
                    .overlay(Circle().stroke(Color.black, lineWidth: 1))
                    .offset(x: 1, y: -1)
            }
        }
        .opacity(active ? 1.0 : 0.90)
        .frame(width: 26, height: 26)
    }
}

struct BrandLogoLongVideos: View {
    var active: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color(red: 1.0, green: 0.56, blue: 0.14), Color(red: 0.90, green: 0.24, blue: 0.44)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 26, height: 26)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(active ? Color.white : Color.white.opacity(0.28), lineWidth: active ? 1.8 : 0.7)
                )
            Image(systemName: "play.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .offset(x: 0.5)
        }
        .opacity(active ? 1.0 : 0.90)
        .frame(width: 26, height: 26)
    }
}

struct BrandLogoOnlyFans: View {
    var active: Bool

    var body: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [Color(red: 0.0, green: 0.72, blue: 0.96), Color(red: 0.0, green: 0.52, blue: 0.84)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 26, height: 26)
            .overlay(
                Circle().stroke(active ? Color.white : Color.white.opacity(0.28), lineWidth: active ? 1.8 : 0.7)
            )
            .overlay(
                Text("OF")
                    .font(.system(size: 10.5, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
            )
            .opacity(active ? 1.0 : 0.90)
            .frame(width: 26, height: 26)
    }
}
