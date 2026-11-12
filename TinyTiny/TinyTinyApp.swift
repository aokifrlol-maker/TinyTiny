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
            // 1. Main Full-Screen Feed Scroller
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

    // MARK: - Home Top Bar (`🔍` | `Following  For You  𝕏  IG  34` | `⚙️`)

    private var homeTopBar: some View {
        HStack(spacing: 8) {
            // Left: Search Circle Button
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                activeTab = .browse
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .liquidGlassCircle(tinted: tinted)
            }
            .buttonStyle(ScalePressButtonStyle())

            Spacer(minLength: 4)

            switch feedModel.source {
            case .forYou, .following:
                HStack(spacing: 12) {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        selectFeed(.following)
                    } label: {
                        Text("Following")
                            .font(.system(size: 15, weight: isFollowingFeed ? .bold : .medium))
                            .foregroundStyle(isFollowingFeed ? .white : .white.opacity(0.62))
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
                        Text("For You")
                            .font(.system(size: 15, weight: !isFollowingFeed ? .bold : .medium))
                            .foregroundStyle(!isFollowingFeed ? .white : .white.opacity(0.62))
                    }

                    // Quick Platform Pills: 𝕏, IG, R34
                    HStack(spacing: 5) {
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            selectXFeedOrLogin(.xForYou)
                        } label: {
                            HStack(spacing: 3) {
                                Text("𝕏")
                                    .font(.system(size: 13, weight: .black))
                                if store.data.xSession.isConnected {
                                    Circle().fill(Theme.accentBright).frame(width: 4, height: 4)
                                }
                            }
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .liquidGlassCapsule(tinted: tinted)
                        }

                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            selectIGFeedOrLogin(.igReels)
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "camera.fill")
                                    .font(.system(size: 11, weight: .bold))
                                if store.data.igSession.isConnected {
                                    Circle().fill(Theme.accentBright).frame(width: 4, height: 4)
                                }
                            }
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .liquidGlassCapsule(tinted: tinted)
                        }

                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            selectFeed(.rule34(""))
                        } label: {
                            Text("34")
                                .font(.system(size: 12, weight: .black, design: .rounded))
                                .foregroundStyle(Color(red: 0.72, green: 0.96, blue: 0.70))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .liquidGlassCapsule(tinted: tinted)
                        }
                    }
                }
                .shadow(color: .black.opacity(0.5), radius: 4)

            case .xForYou, .xFollowing, .xBookmarks:
                HStack(spacing: 10) {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        selectFeed(.forYou)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white.opacity(0.75))
                    }

                    ForEach([
                        (FeedSource.xForYou, "𝕏 For You"),
                        (FeedSource.xFollowing, "Following"),
                        (FeedSource.xBookmarks, "Saved")
                    ], id: \.1) { src, title in
                        let active = feedModel.source == src
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            if active {
                                currentPostID = nil
                                Task { await feedModel.refresh(rotateCursor: true) }
                            } else {
                                selectXFeedOrLogin(src)
                            }
                        } label: {
                            Text(title)
                                .font(.system(size: 14, weight: active ? .bold : .medium))
                                .foregroundStyle(active ? .white : .white.opacity(0.62))
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .liquidGlassCapsule(tinted: tinted)

            case .igReels, .igFollowing, .igSaved:
                HStack(spacing: 10) {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        selectFeed(.forYou)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white.opacity(0.75))
                    }

                    ForEach([
                        (FeedSource.igReels, "IG Reels"),
                        (FeedSource.igFollowing, "Following"),
                        (FeedSource.igSaved, "Saved")
                    ], id: \.1) { src, title in
                        let active = feedModel.source == src
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            if active {
                                currentPostID = nil
                                Task { await feedModel.refresh(rotateCursor: true) }
                            } else {
                                selectIGFeedOrLogin(src)
                            }
                        } label: {
                            Text(title)
                                .font(.system(size: 14, weight: active ? .bold : .medium))
                                .foregroundStyle(active ? .white : .white.opacity(0.62))
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .liquidGlassCapsule(tinted: tinted)

            default:
                HStack(spacing: 8) {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        selectFeed(.forYou)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white.opacity(0.8))
                    }

                    Button {
                        activeTab = .browse
                    } label: {
                        Text(feedModel.source.displayTitle)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .liquidGlassCapsule(tinted: tinted)
            }

            Spacer(minLength: 4)

            // Right: Gear Settings Circle Button
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                showSettingsModal = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 42)
                    .liquidGlassCircle(tinted: tinted)
            }
            .buttonStyle(ScalePressButtonStyle())
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
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
