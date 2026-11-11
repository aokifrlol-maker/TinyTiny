import SwiftUI
import AVFoundation

@main
struct TinyTinyApp: App {
    @StateObject private var app = AppState()
    @StateObject private var store = UserStore.shared

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
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
    @State private var pendingXFeedAfterLogin: FeedSource? = nil

    private var tinted: Bool { store.data.settings.tintedGlass }

    private var isFollowingFeed: Bool {
        if case .following = feedModel.source { return true }
        return false
    }

    var body: some View {
        ZStack {
            // 1. Main Full-Screen Feed Scroller (always mounted for instant responsiveness)
            FeedView(
                model: feedModel,
                isVisible: activeTab == .home && !showSettingsModal && !showXLoginSheet,
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
                onConnectX: {
                    pendingXFeedAfterLogin = feedModel.source.isXFeed ? feedModel.source : .xForYou
                    showXLoginSheet = true
                }
            )
            .opacity(activeTab == .home ? 1 : 0)
            .allowsHitTesting(activeTab == .home)

            // 2. Top Bar on Home: Search Circle (left) | Following / For You / 𝕏 | Gear Circle (right)
            if activeTab == .home {
                VStack {
                    homeTopBar
                    Spacer()
                }
            }

            // 3. Likes / Stash Overlay (Screenshot 2)
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
                    }
                )
                .transition(.opacity)
            }

            // 4. Browse / Search / Categories Fullscreen Overlay (Screenshot 3)
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
                        } else {
                            selectFeed(src)
                        }
                    },
                    onConnectX: {
                        pendingXFeedAfterLogin = .xForYou
                        showXLoginSheet = true
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
                        } else {
                            selectFeed(src)
                        }
                    },
                    onConnectX: {
                        pendingXFeedAfterLogin = .xForYou
                        showXLoginSheet = true
                    }
                )
                .transition(.opacity)
            }

            // 6. Floating Liquid Glass Bottom Dock (Hidden when full-screen Browse modal is open, matching gooned.app)
            if activeTab != .browse {
                VStack {
                    Spacer()
                    goonedBottomDock
                        .padding(.horizontal, 28)
                        .padding(.bottom, 14)
                }
            }

            // 7. Liquid Glass Settings Modal (Screenshot 4)
            if showSettingsModal {
                GoonedSettingsModal(
                    isPresented: $showSettingsModal,
                    onConnectX: {
                        showSettingsModal = false
                        pendingXFeedAfterLogin = nil
                        showXLoginSheet = true
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
                .zIndex(30)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: activeTab)
        .animation(.easeInOut(duration: 0.18), value: showSettingsModal)
        .sheet(isPresented: $showXLoginSheet) {
            XLoginSheet {
                let target = pendingXFeedAfterLogin ?? .xForYou
                pendingXFeedAfterLogin = nil
                selectFeed(target)
                Task { await feedModel.refresh() }
            }
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
            pendingXFeedAfterLogin = src
            showXLoginSheet = true
        }
    }

    // MARK: - Home Top Bar (`🔍` | `Following   For You   𝕏` | `⚙️`)

    private var homeTopBar: some View {
        HStack {
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

            Spacer()

            // Center: `Following   For You   𝕏` or active X / Category / Subreddit breadcrumb pill
            switch feedModel.source {
            case .forYou, .following:
                HStack(spacing: 16) {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        selectFeed(.following)
                    } label: {
                        Text("Following")
                            .font(.system(size: 16, weight: isFollowingFeed ? .bold : .medium))
                            .foregroundStyle(isFollowingFeed ? .white : .white.opacity(0.62))
                    }

                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        if case .forYou = feedModel.source {
                            Task { await feedModel.refresh() }
                        } else {
                            selectFeed(.forYou)
                        }
                    } label: {
                        Text("For You")
                            .font(.system(size: 16, weight: !isFollowingFeed ? .bold : .medium))
                            .foregroundStyle(!isFollowingFeed ? .white : .white.opacity(0.62))
                    }

                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        selectXFeedOrLogin(.xForYou)
                    } label: {
                        HStack(spacing: 4) {
                            Text("𝕏")
                                .font(.system(size: 15, weight: .black))
                            if store.data.xSession.isConnected {
                                Circle()
                                    .fill(Theme.accentBright)
                                    .frame(width: 5, height: 5)
                            }
                        }
                        .foregroundStyle(.white.opacity(0.78))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .liquidGlassCapsule(tinted: tinted)
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
                                Task { await feedModel.refresh() }
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

            Spacer()

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
                    Task { await feedModel.refresh() }
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
