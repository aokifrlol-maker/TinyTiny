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

struct GoonedMainShell: View {
    @EnvironmentObject var store: UserStore
    @StateObject private var feedModel = FeedModel(source: .forYou)
    @State private var activeTab: GoonedDockTab = .home
    @State private var currentPostID: String? = nil
    @State private var showSettingsModal = false
    @State private var showXLoginSheet = false
    @State private var showIGLoginSheet = false
    @State private var showR34KeySheet = false
    @State private var pendingFeedAfterLogin: FeedSource? = nil

    private var tinted: Bool { store.data.settings.tintedGlass }

    private var isFollowingFeed: Bool {
        if case .following = feedModel.source { return true }
        return false
    }

    var body: some View {
        ZStack {
            // 1. Main Full-Screen Feed Scroller (with Horizontal Swipe between Following · For You · 𝕏 · R34 · IG)
            FeedView(
                model: feedModel,
                isVisible: activeTab == .home && !showSettingsModal && !showXLoginSheet && !showIGLoginSheet && !showR34KeySheet,
                currentID: $currentPostID,
                onOpenCategories: {
                    withAnimation(.spring(response: 0.26, dampingFraction: 0.85)) {
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
                    pendingFeedAfterLogin = feedModel.source.isXFeed ? feedModel.source : .xForYou
                    showXLoginSheet = true
                },
                onConnectIG: {
                    pendingFeedAfterLogin = feedModel.source.isIGFeed ? feedModel.source : .igReels
                    showIGLoginSheet = true
                }
            )
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
                        feedModel.switchSource(.list(title: "Liked"), initialItems: store.data.liked)
                        currentPostID = post.id
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                            activeTab = .home
                        }
                    },
                    onPlayOfflinePost: { post in
                        feedModel.switchSource(.list(title: "Offline Vault"), initialItems: store.data.downloaded)
                        currentPostID = post.id
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
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
        .animation(.easeInOut(duration: 0.18), value: activeTab)
        .animation(.easeInOut(duration: 0.18), value: showSettingsModal)
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: store.data.settings.controlsCollapsed)
        .sheet(isPresented: $showXLoginSheet) {
            XLoginSheet {
                let target = pendingFeedAfterLogin ?? .xForYou
                pendingFeedAfterLogin = nil
                selectFeed(target)
                Task { await feedModel.refresh(rotateCursor: true) }
            }
            .environmentObject(store)
        }
        .sheet(isPresented: $showIGLoginSheet) {
            InstagramLoginSheet {
                let target = pendingFeedAfterLogin ?? .igReels
                pendingFeedAfterLogin = nil
                selectFeed(target)
                Task { await feedModel.refresh(rotateCursor: true) }
            }
            .environmentObject(store)
        }
        .sheet(isPresented: $showR34KeySheet) {
            Rule34KeySheet()
                .environmentObject(store)
        }
    }

    private func selectFeed(_ src: FeedSource) {
        currentPostID = nil
        feedModel.switchSource(src)
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            activeTab = .home
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
        switch feedModel.source {
        case .following: return 0
        case .forYou: return 1
        case .xForYou, .xFollowing, .xBookmarks, .xLikes: return 2
        case .rule34: return 3
        case .igReels, .igFollowing, .igSaved: return 4
        default: return 1
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

                if case .category = feedModel.source {
                    customFeedTitlePill
                } else if case .subreddit = feedModel.source {
                    customFeedTitlePill
                } else if case .user = feedModel.source {
                    customFeedTitlePill
                } else if case .xSearch = feedModel.source {
                    customFeedTitlePill
                } else if case .xUser = feedModel.source {
                    customFeedTitlePill
                } else if case .igUser = feedModel.source {
                    customFeedTitlePill
                } else if case .list = feedModel.source {
                    customFeedTitlePill
                } else if case .rule34(let t) = feedModel.source, !t.isEmpty {
                    customFeedTitlePill
                } else {
                    HStack(spacing: 10) {
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            selectFeed(.following)
                        } label: {
                            Text("Following")
                                .font(.system(size: 13.5, weight: isFollowingFeed ? .bold : .medium))
                                .foregroundStyle(isFollowingFeed ? .white : .white.opacity(0.60))
                                .fixedSize()
                        }

                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            if case .forYou = feedModel.source {
                                currentPostID = nil
                                Task { await feedModel.refresh(rotateCursor: true) }
                            } else {
                                selectFeed(.forYou)
                            }
                        } label: {
                            let isForYou: Bool = {
                                if case .forYou = feedModel.source { return true }
                                return false
                            }()
                            Text("For You")
                                .font(.system(size: 13.5, weight: isForYou ? .bold : .medium))
                                .foregroundStyle(isForYou ? .white : .white.opacity(0.60))
                                .fixedSize()
                        }

                        // Compact Brand Logos: 𝕏 · R34 · Instagram
                        HStack(spacing: 6) {
                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                if feedModel.source.isXFeed {
                                    currentPostID = nil
                                    Task { await feedModel.refresh(rotateCursor: true) }
                                } else {
                                    selectXFeedOrLogin(.xForYou)
                                }
                            } label: {
                                BrandLogoX(active: feedModel.source.isXFeed, connected: store.data.xSession.isConnected)
                            }
                            .buttonStyle(ScalePressButtonStyle())

                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                if case .rule34 = feedModel.source {
                                    currentPostID = nil
                                    Task { await feedModel.refresh(rotateCursor: true) }
                                } else {
                                    selectFeed(.rule34(""))
                                }
                            } label: {
                                BrandLogoRule34(active: feedModel.source.isRule34Feed)
                            }
                            .buttonStyle(ScalePressButtonStyle())

                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                if feedModel.source.isIGFeed {
                                    currentPostID = nil
                                    Task { await feedModel.refresh(rotateCursor: true) }
                                } else {
                                    selectIGFeedOrLogin(.igReels)
                                }
                            } label: {
                                BrandLogoInstagram(active: feedModel.source.isIGFeed, connected: store.data.igSession.isConnected)
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
            if feedModel.source.isXFeed && (feedModel.source == .xForYou || feedModel.source == .xFollowing || feedModel.source == .xBookmarks) {
                HStack(spacing: 12) {
                    ForEach([
                        (FeedSource.xForYou, "For You"),
                        (FeedSource.xFollowing, "Following"),
                        (FeedSource.xBookmarks, "Bookmarks")
                    ], id: \.1) { src, label in
                        let active = feedModel.source == src
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
            } else if feedModel.source.isIGFeed && (feedModel.source == .igReels || feedModel.source == .igFollowing || feedModel.source == .igSaved) {
                HStack(spacing: 12) {
                    ForEach([
                        (FeedSource.igReels, "Reels"),
                        (FeedSource.igFollowing, "Following"),
                        (FeedSource.igSaved, "Saved")
                    ], id: \.1) { src, label in
                        let active = feedModel.source == src
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
                Text(feedModel.source.displayTitle)
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
