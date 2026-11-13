import SwiftUI
import AVFoundation

@main
struct TinyTinyApp: App {
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
    @Environment(\.scenePhase) private var phase

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            if !app.ageConfirmed {
                AgeGateView()
            } else if !app.hasPasscode {
                PasscodeSetupView(mode: .create)
            } else {
                if app.hasUnlockedOnce {
                    GoonedMainShell()
                }
                if app.isLocked {
                    LockView().transition(.opacity).zIndex(10)
                }
            }
            if phase != .active && app.hasPasscode {
                PrivacyCover().zIndex(20)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: app.isLocked)
        .onChange(of: phase) { _, p in
            if p == .background {
                app.lock()
                store.saveNow()
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
    case following, forYou, x, rule34, ig, custom
}

struct GoonedMainShell: View {
    @EnvironmentObject var store: UserStore
    @StateObject private var followingModel = FeedModel(source: .following)
    @StateObject private var forYouModel = FeedModel(source: .forYou)
    @StateObject private var xModel = FeedModel(source: .xForYou)
    @StateObject private var r34Model = FeedModel(source: .rule34(""))
    @StateObject private var igModel = FeedModel(source: .igReels)
    @StateObject private var customModel = FeedModel(source: .forYou)

    private struct CustomBackHistoryItem {
        let channel: HomeChannel
        let customSource: FeedSource?
        let customItems: [Gif]
        let postID: String?
        let returnTab: GoonedDockTab
    }

    @State private var activeChannel: HomeChannel = .forYou
    @State private var slotPostIDs: [HomeChannel: String] = [:]
    @State private var customBackStack: [CustomBackHistoryItem] = []
    @State private var activeTab: GoonedDockTab = .home
    @State private var showSettingsModal = false
    @State private var showXLoginSheet = false
    @State private var showIGLoginSheet = false
    @State private var showR34KeySheet = false
    @State private var pendingFeedAfterLogin: FeedSource? = nil
    @State private var didPrewarm = false
    @AppStorage("tt_bella_intro_seen_v1") private var hasSeenBellaIntro = false

    private var tinted: Bool { store.data.settings.tintedGlass }

    private var activeModel: FeedModel {
        switch activeChannel {
        case .following: return followingModel
        case .forYou: return forYouModel
        case .x: return xModel
        case .rule34: return r34Model
        case .ig: return igModel
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
                isVisible: activeTab == .home && hasSeenBellaIntro && !showSettingsModal && !showXLoginSheet && !showIGLoginSheet && !showR34KeySheet,
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

            // 2. Top Bar on Home
            if activeTab == .home {
                VStack {
                    homeTopBar
                    Spacer()
                }
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
                    },
                    onReplayIntro: {
                        showSettingsModal = false
                        withAnimation(.easeInOut(duration: 0.25)) {
                            hasSeenBellaIntro = false
                        }
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(30)
            }

            // 8. First-Time 5-Second 18+ Motion Graphics Intro ("Welcome to Gooned / By Bella")
            if !hasSeenBellaIntro {
                BellaGoonedIntroOverlay {
                    withAnimation(.easeInOut(duration: 0.38)) {
                        hasSeenBellaIntro = true
                    }
                }
                .transition(.opacity)
                .zIndex(80)
            }
        }
        .animation(.easeOut(duration: 0.14), value: activeTab)
        .animation(.easeOut(duration: 0.14), value: showSettingsModal)
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: store.data.settings.controlsCollapsed)
        .task {
            guard !didPrewarm else { return }
            didPrewarm = true
            try? await Task.sleep(nanoseconds: 900_000_000)
            // Silently pre-warm Rule34, X, and Instagram so swiping left is instant!
            if r34Model.items.isEmpty {
                Task { await r34Model.loadMore() }
            }
            if store.data.xSession.isConnected && xModel.items.isEmpty {
                Task { await xModel.loadMore() }
            }
            if store.data.igSession.isConnected && igModel.items.isEmpty {
                Task { await igModel.loadMore() }
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
        case .xForYou, .xFollowing, .xBookmarks:
            customBackStack.removeAll()
            activeChannel = .x
            if xModel.source != src || forceReload {
                slotPostIDs[.x] = nil
                xModel.switchSource(src)
            }
        case .rule34(let tag) where tag.isEmpty:
            customBackStack.removeAll()
            activeChannel = .rule34
            if forceReload {
                slotPostIDs[.rule34] = nil
                Task { await r34Model.refresh(rotateCursor: true) }
            }
        case .igReels, .igFollowing, .igSaved:
            customBackStack.removeAll()
            activeChannel = .ig
            if igModel.source != src || forceReload {
                slotPostIDs[.ig] = nil
                igModel.switchSource(src)
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
        case .x: return 2
        case .rule34: return 3
        case .ig: return 4
        }
    }

    private func handleHorizontalFeedSwipe(dx: CGFloat) {
        let channels: [FeedSource] = [.following, .forYou, .xForYou, .rule34(""), .igReels]
        let cur = homeChannelIndex
        // Swipe left (dx < 0) moves forward: Following -> For You -> X -> R34 -> IG
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

    // MARK: - Home Top Bar (`🔍` | `Following · For You · 𝕏 · R34 · IG` | `⚙️`)

    private var homeTopBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
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

                Spacer(minLength: 2)

                if activeChannel == .custom {
                    customFeedTitlePill
                } else {
                    HStack(spacing: 10) {
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            if activeChannel == .following {
                                selectFeed(.following, forceReload: true)
                            } else {
                                selectFeed(.following)
                            }
                        } label: {
                            Text("Following")
                                .font(.system(size: 13.5, weight: isFollowingFeed ? .bold : .medium))
                                .foregroundStyle(isFollowingFeed ? .white : .white.opacity(0.60))
                                .fixedSize()
                        }

                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            if activeChannel == .forYou {
                                selectFeed(.forYou, forceReload: true)
                            } else {
                                selectFeed(.forYou)
                            }
                        } label: {
                            let isForYou = activeChannel == .forYou
                            Text("For You")
                                .font(.system(size: 13.5, weight: isForYou ? .bold : .medium))
                                .foregroundStyle(isForYou ? .white : .white.opacity(0.60))
                                .fixedSize()
                        }

                        // Compact Brand Logos: 𝕏 · R34 · Instagram
                        HStack(spacing: 6) {
                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                if activeChannel == .x {
                                    selectFeed(xModel.source, forceReload: true)
                                } else {
                                    selectXFeedOrLogin(xModel.source)
                                }
                            } label: {
                                BrandLogoX(active: activeChannel == .x, connected: store.data.xSession.isConnected)
                            }
                            .buttonStyle(ScalePressButtonStyle())

                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                if activeChannel == .rule34 {
                                    selectFeed(.rule34(""), forceReload: true)
                                } else {
                                    selectFeed(.rule34(""))
                                }
                            } label: {
                                BrandLogoRule34(active: activeChannel == .rule34)
                            }
                            .buttonStyle(ScalePressButtonStyle())

                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                if activeChannel == .ig {
                                    selectFeed(igModel.source, forceReload: true)
                                } else {
                                    selectIGFeedOrLogin(igModel.source)
                                }
                            } label: {
                                BrandLogoInstagram(active: activeChannel == .ig, connected: store.data.igSession.isConnected)
                            }
                            .buttonStyle(ScalePressButtonStyle())
                        }
                        .fixedSize()
                    }
                    .shadow(color: .black.opacity(0.55), radius: 4)
                }

                Spacer(minLength: 2)

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

            // Secondary sub-feed switcher when inside X or IG
            if activeChannel == .x {
                HStack(spacing: 12) {
                    ForEach([
                        (FeedSource.xForYou, "For You"),
                        (FeedSource.xFollowing, "Following"),
                        (FeedSource.xBookmarks, "Bookmarks")
                    ], id: \.1) { src, label in
                        let active = xModel.source == src
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            selectXFeedOrLogin(src)
                        } label: {
                            Text(label)
                                .font(.system(size: 12, weight: active ? .bold : .medium))
                                .foregroundStyle(active ? .white : .white.opacity(0.6))
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .liquidGlassCapsule(tinted: tinted)
            } else if activeChannel == .ig {
                HStack(spacing: 12) {
                    ForEach([
                        (FeedSource.igReels, "Reels"),
                        (FeedSource.igFollowing, "Following"),
                        (FeedSource.igSaved, "Saved")
                    ], id: \.1) { src, label in
                        let active = igModel.source == src
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            selectIGFeedOrLogin(src)
                        } label: {
                            Text(label)
                                .font(.system(size: 12, weight: active ? .bold : .medium))
                                .foregroundStyle(active ? .white : .white.opacity(0.6))
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .liquidGlassCapsule(tinted: tinted)
            }
        }
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

// MARK: - First-Time 5-Second 18+ Motion Graphics Intro ("Welcome to Gooned / By Bella")

struct BellaGoonedIntroOverlay: View {
    var onFinish: () -> Void

    @State private var startDate = Date()
    @State private var finished = false
    @State private var lastSwipeStage = 0

    private let totalDuration: Double = 5.0

    var body: some View {
        TimelineView(.animation) { timeline in
            let elapsed = min(totalDuration, max(0, timeline.date.timeIntervalSince(startDate)))
            let outroP = smoothstep(4.35, 5.0, elapsed)
            let zoomScale = 1.0 + outroP * 0.14
            let overallOpacity = 1.0 - smoothstep(4.5, 5.0, elapsed)

            ZStack {
                // Deep obsidian + velvet rose/magenta 18+ ambient stage
                Color(red: 0.025, green: 0.012, blue: 0.032)
                    .ignoresSafeArea()

                ambientAura(t: elapsed)
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    Spacer(minLength: 18)

                    // Top 18+ Editorial Tagline
                    let badgeIn = smoothstep(0.12, 0.72, elapsed)
                    HStack(spacing: 8) {
                        Text("18+")
                            .font(.system(size: 11, weight: .black, design: .rounded))
                            .foregroundStyle(.black)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(
                                LinearGradient(
                                    colors: [Color(red: 1.0, green: 0.25, blue: 0.56), Color(red: 1.0, green: 0.50, blue: 0.72)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                in: Capsule()
                            )

                        Text("PRIVATE REEL VAULT")
                            .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                            .tracking(2.2)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.06), in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 0.8))
                    .opacity(badgeIn)
                    .offset(y: (1.0 - badgeIn) * 14)

                    Spacer(minLength: 18)

                    // Hero Kinetic Title: "Welcome to Gooned" + "By Bella"
                    let welcomeIn = smoothstep(0.32, 0.95, elapsed)
                    let goonedIn = smoothstep(0.50, 1.20, elapsed)
                    let bellaIn = smoothstep(0.85, 1.45, elapsed)
                    let shimmerX = (elapsed - 0.8) * 1.15

                    VStack(spacing: 6) {
                        Text("WELCOME TO")
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .tracking(4.5)
                            .foregroundStyle(.white.opacity(0.68))
                            .opacity(welcomeIn)
                            .offset(y: (1.0 - welcomeIn) * 12)

                        Text("Gooned")
                            .font(.system(size: 54, weight: .black, design: .rounded))
                            .tracking(-1.2)
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [
                                        .white,
                                        Color(red: 1.0, green: 0.78, blue: 0.90),
                                        Color(red: 1.0, green: 0.22, blue: 0.54)
                                    ],
                                    startPoint: UnitPoint(x: max(-0.4, min(1.2, shimmerX - 0.3)), y: 0),
                                    endPoint: UnitPoint(x: max(0.0, min(1.6, shimmerX + 0.5)), y: 1)
                                )
                            )
                            .shadow(color: Color(red: 1.0, green: 0.16, blue: 0.52).opacity(0.45), radius: 22, y: 6)
                            .scaleEffect(0.86 + 0.14 * goonedIn)
                            .opacity(goonedIn)

                        HStack(spacing: 6) {
                            Image(systemName: "sparkle")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color(red: 1.0, green: 0.40, blue: 0.68))
                            Text("By Bella")
                                .font(.system(size: 15, weight: .semibold, design: .serif))
                                .italic()
                                .foregroundStyle(.white.opacity(0.92))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(Color(red: 1.0, green: 0.18, blue: 0.52).opacity(0.14))
                                .overlay(Capsule().stroke(Color(red: 1.0, green: 0.42, blue: 0.72).opacity(0.38), lineWidth: 0.9))
                        )
                        .opacity(bellaIn)
                        .scaleEffect(0.92 + 0.08 * bellaIn)
                    }

                    Spacer(minLength: 20)

                    // 3D Floating Scrolling iPhone Mockup
                    let phoneIn = smoothstep(0.95, 1.65, elapsed)
                    phoneScrollingShowcase(t: elapsed)
                        .scaleEffect(0.84 + 0.16 * phoneIn)
                        .opacity(phoneIn)
                        .offset(y: (1.0 - phoneIn) * 38)

                    Spacer(minLength: 18)

                    // Subtle Progress Timeline Bar + Skip Pill
                    HStack(spacing: 12) {
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.14))
                            Capsule()
                                .fill(
                                    LinearGradient(
                                        colors: [Color(red: 1.0, green: 0.25, blue: 0.56), Color.white],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: max(8, 128 * CGFloat(elapsed / totalDuration)))
                        }
                        .frame(width: 128, height: 3)

                        if elapsed > 0.9 {
                            Button {
                                complete()
                            } label: {
                                Text("Skip")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.75))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 5)
                                    .background(Color.white.opacity(0.08), in: Capsule())
                                    .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.7))
                            }
                            .transition(.opacity)
                        }
                    }
                    .padding(.bottom, 28)
                }
                .padding(.horizontal, 20)
                .scaleEffect(zoomScale)
                .opacity(overallOpacity)
            }
            .onChange(of: swipeStage(for: elapsed)) { _, newStage in
                if newStage > lastSwipeStage {
                    lastSwipeStage = newStage
                    UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.75)
                }
            }
        }
        .onAppear {
            startDate = Date()
        }
        .task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            complete()
        }
    }

    private func complete() {
        guard !finished else { return }
        finished = true
        onFinish()
    }

    private func swipeStage(for t: Double) -> Int {
        if t >= 3.45 { return 3 }
        if t >= 2.65 { return 2 }
        if t >= 1.85 { return 1 }
        return 0
    }

    @ViewBuilder
    private func ambientAura(t: Double) -> some View {
        let pulse = sin(t * 1.8) * 0.5 + 0.5
        ZStack {
            RadialGradient(
                colors: [
                    Color(red: 0.96, green: 0.14, blue: 0.48).opacity(0.32 + 0.10 * pulse),
                    Color(red: 0.48, green: 0.06, blue: 0.34).opacity(0.18),
                    .clear
                ],
                center: UnitPoint(x: 0.5 + 0.08 * cos(t * 1.1), y: 0.36 + 0.05 * sin(t * 0.9)),
                startRadius: 20,
                endRadius: 340
            )

            RadialGradient(
                colors: [
                    Color(red: 0.65, green: 0.16, blue: 0.92).opacity(0.22),
                    .clear
                ],
                center: UnitPoint(x: 0.25, y: 0.78),
                startRadius: 10,
                endRadius: 290
            )
        }
    }

    @ViewBuilder
    private func phoneScrollingShowcase(t: Double) -> some View {
        let scrollOffset =
            smoothstep(1.85, 2.35, t) * 1.0 +
            smoothstep(2.65, 3.15, t) * 1.0 +
            smoothstep(3.45, 3.95, t) * 1.0
        let swipeVelocity =
            pulseWindow(1.85, 2.35, t) +
            pulseWindow(2.65, 3.15, t) +
            pulseWindow(3.45, 3.95, t)
        let tiltY = sin(t * 1.5) * 7.0
        let tiltX = 6.0 - swipeVelocity * 4.0

        let cardH: CGFloat = 296
        let cardW: CGFloat = 172

        let reels: [(badge: String, title: String, subtitle: String, colors: [Color])] = [
            ("For You", "Smart Taste Engine", "#neon · #afterhours", [Color(red: 0.88, green: 0.12, blue: 0.46), Color(red: 0.16, green: 0.04, blue: 0.14)]),
            ("𝕏 Videos", "HD Loop Stream", "@nightfall · 4K 60fps", [Color(red: 0.14, green: 0.16, blue: 0.28), Color(red: 0.58, green: 0.12, blue: 0.44)]),
            ("Rule34.xxx", "Instant Zero-Wait", "#animated_mp4 · #hq", [Color(red: 0.14, green: 0.42, blue: 0.22), Color(red: 0.06, green: 0.12, blue: 0.10)]),
            ("IG Reels", "Personal Vault", "Zero repeats · Offline", [Color(red: 0.82, green: 0.22, blue: 0.48), Color(red: 0.34, green: 0.12, blue: 0.62)])
        ]

        ZStack {
            // Outer glow behind the phone
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(Color(red: 1.0, green: 0.18, blue: 0.52).opacity(0.24 + 0.14 * swipeVelocity))
                .frame(width: cardW + 24, height: cardH + 24)
                .blur(radius: 26)

            // Phone Chassis
            ZStack(alignment: .top) {
                // Viewport Screen clipping vertical reel stack
                ZStack(alignment: .top) {
                    VStack(spacing: 0) {
                        ForEach(0..<reels.count, id: \.self) { idx in
                            let reel = reels[idx]
                            ZStack(alignment: .bottomLeading) {
                                LinearGradient(
                                    colors: reel.colors,
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )

                                // Animated ambient motion bar inside reel
                                Circle()
                                    .fill(Color.white.opacity(0.14))
                                    .frame(width: 96, height: 96)
                                    .blur(radius: 18)
                                    .offset(x: 40 + sin(t * 2.4 + Double(idx)) * 18, y: -110)

                                // Simulated right-side action buttons inside the mini phone
                                VStack(spacing: 12) {
                                    Image(systemName: "heart.fill")
                                        .font(.system(size: 15, weight: .bold))
                                        .foregroundStyle(Color(red: 1.0, green: 0.28, blue: 0.56))
                                        .scaleEffect(1.0 + 0.22 * swipeVelocity)
                                    Image(systemName: "arrow.down.circle.fill")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.85))
                                    Image(systemName: "speaker.wave.2.fill")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.75))
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                                .padding(.trailing, 10)
                                .padding(.bottom, 34)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text(reel.badge)
                                        .font(.system(size: 10, weight: .black, design: .rounded))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2.5)
                                        .background(.white.opacity(0.18), in: Capsule())
                                    Text(reel.title)
                                        .font(.system(size: 13, weight: .bold))
                                    Text(reel.subtitle)
                                        .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.76))
                                }
                                .foregroundStyle(.white)
                                .padding(12)
                                .padding(.bottom, 12)
                            }
                            .frame(width: cardW, height: cardH)
                        }
                    }
                    .offset(y: -scrollOffset * cardH)

                    // Simulated animated finger / swipe-up ribbon gesture inside screen
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.white.opacity(0.85), Color(red: 1.0, green: 0.25, blue: 0.56).opacity(0.15)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 18, height: 42 + swipeVelocity * 28)
                        .blur(radius: 1.5)
                        .opacity(0.20 + swipeVelocity * 0.72)
                        .offset(y: cardH * 0.58 - swipeVelocity * 74)
                }
                .frame(width: cardW, height: cardH)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))

                // Top Status Bar & Dynamic Island overlay inside phone
                Capsule()
                    .fill(Color.black)
                    .frame(width: 54, height: 15)
                    .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.6))
                    .padding(.top, 9)

                // Subtle bottom home indicator inside phone
                VStack {
                    Spacer()
                    Capsule()
                        .fill(Color.white.opacity(0.65))
                        .frame(width: 54, height: 3.5)
                        .padding(.bottom, 7)
                }
            }
            .frame(width: cardW, height: cardH)
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 34, style: .continuous)
                    .fill(Color(red: 0.08, green: 0.05, blue: 0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 34, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [.white.opacity(0.50), Color(red: 1.0, green: 0.30, blue: 0.62).opacity(0.45), .white.opacity(0.18)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.4
                            )
                    )
            )
            .shadow(color: .black.opacity(0.65), radius: 24, y: 14)

            // Floating Heart Sparks popping beside phone on swipes
            ForEach(0..<3, id: \.self) { i in
                Image(systemName: "heart.fill")
                    .font(.system(size: CGFloat(12 + i * 3)))
                    .foregroundStyle(Color(red: 1.0, green: 0.25 + Double(i) * 0.12, blue: 0.58))
                    .opacity(swipeVelocity * (0.9 - Double(i) * 0.2))
                    .offset(
                        x: cardW * 0.58 + CGFloat(i * 10),
                        y: CGFloat(40 - i * 36) - swipeVelocity * CGFloat(44 + i * 16)
                    )
                    .scaleEffect(0.75 + swipeVelocity * 0.45)
            }
        }
        .rotation3DEffect(.degrees(tiltY), axis: (x: 0, y: 1, z: 0), perspective: 0.55)
        .rotation3DEffect(.degrees(tiltX), axis: (x: 1, y: 0, z: 0), perspective: 0.55)
    }

    private func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = max(0, min(1, (x - edge0) / max(0.0001, edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }

    private func pulseWindow(_ start: Double, _ end: Double, _ x: Double) -> Double {
        guard x >= start, x <= end else { return 0 }
        let p = (x - start) / max(0.0001, end - start)
        return sin(p * .pi)
    }
}
