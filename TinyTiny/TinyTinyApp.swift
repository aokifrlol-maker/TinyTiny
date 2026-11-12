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

    @State private var activeChannel: HomeChannel = .forYou
    @State private var slotPostIDs: [HomeChannel: String] = [:]
    @State private var activeTab: GoonedDockTab = .home
    @State private var showSettingsModal = false
    @State private var showXLoginSheet = false
    @State private var showIGLoginSheet = false
    @State private var showR34KeySheet = false
    @State private var pendingFeedAfterLogin: FeedSource? = nil
    @State private var didPrewarm = false

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
                        customModel.switchSource(.list(title: "Liked"), initialItems: store.data.liked)
                        slotPostIDs[.custom] = post.id
                        activeChannel = .custom
                        withAnimation(.spring(response: 0.22, dampingFraction: 0.88)) {
                            activeTab = .home
                        }
                    },
                    onPlayOfflinePost: { post in
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

    private func selectFeed(_ src: FeedSource, forceReload: Bool = false) {
        switch src {
        case .following:
            activeChannel = .following
            if forceReload {
                slotPostIDs[.following] = nil
                Task { await followingModel.refresh(rotateCursor: true) }
            }
        case .forYou:
            activeChannel = .forYou
            if forceReload {
                slotPostIDs[.forYou] = nil
                Task { await forYouModel.refresh(rotateCursor: true) }
            }
        case .xForYou, .xFollowing, .xBookmarks:
            activeChannel = .x
            if xModel.source != src || forceReload {
                slotPostIDs[.x] = nil
                xModel.switchSource(src)
            }
        case .rule34(let tag) where tag.isEmpty:
            activeChannel = .rule34
            if forceReload {
                slotPostIDs[.rule34] = nil
                Task { await r34Model.refresh(rotateCursor: true) }
            }
        case .igReels, .igFollowing, .igSaved:
            activeChannel = .ig
            if igModel.source != src || forceReload {
                slotPostIDs[.ig] = nil
                igModel.switchSource(src)
            }
        default:
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
        HStack(spacing: 8) {
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                selectFeed(.forYou)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
            }

            Button {
                activeTab = .browse
            } label: {
                Text(customModel.source.displayTitle)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .liquidGlassCapsule(tinted: tinted)
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
                if case .forYou = feedModel.source {
                    currentPostID = nil
                    Task { await feedModel.refresh(rotateCursor: true) }
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
