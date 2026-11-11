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
                    MainShellView()
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

// MARK: - Unified Navigation Routes

enum Route: Hashable {
    case category(GoonedCategory)
    case tag(String)
    case creator(String)
    case reelList(title: String, items: [Gif], start: String)
    case postDetail(Gif)
}

extension View {
    func withGoonedRoutes() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .category(let cat):
                CategoryDetailScreen(category: cat)
            case .tag(let t):
                TagFeedScreen(tag: t)
            case .creator(let u):
                CreatorProfileScreen(username: u)
            case .reelList(let title, let items, let start):
                ReelListScreen(title: title, items: items, start: start)
            case .postDetail(let gif):
                PostDetailScreen(gif: gif)
            }
        }
    }

    func clearNavBar() -> some View {
        self.navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
    }
}

// MARK: - 5-Tab Floating Pill Navigation Shell (Home, Reels, Categories, Search, Profile)

enum AppTab: Int, CaseIterable {
    case home = 0
    case reels = 1
    case categories = 2
    case search = 3
    case profile = 4

    var icon: String {
        switch self {
        case .home: return "house"
        case .reels: return "play.square"
        case .categories: return "square.grid.2x2"
        case .search: return "magnifyingglass"
        case .profile: return "person.crop.circle"
        }
    }

    var activeIcon: String {
        switch self {
        case .home: return "house.fill"
        case .reels: return "play.square.fill"
        case .categories: return "square.grid.2x2.fill"
        case .search: return "magnifyingglass"
        case .profile: return "person.crop.circle.fill"
        }
    }
}

struct MainShellView: View {
    @State private var selectedTab: AppTab = .home
    @Namespace private var navAnim

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selectedTab) {
                HomeFeedView(isTabActive: selectedTab == .home, switchToTab: { selectedTab = $0 })
                    .tag(AppTab.home)

                ReelsTabView(isTabActive: selectedTab == .reels)
                    .tag(AppTab.reels)

                CategoriesTabView()
                    .tag(AppTab.categories)

                SearchTabView()
                    .tag(AppTab.search)

                ProfileTabView()
                    .tag(AppTab.profile)
            }

            FloatingDockBar(selectedTab: $selectedTab, namespace: navAnim)
                .padding(.horizontal, 22)
                .padding(.bottom, 6)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }
}

struct FloatingDockBar: View {
    @Binding var selectedTab: AppTab
    var namespace: Namespace.ID

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppTab.allCases, id: \.rawValue) { tab in
                let active = selectedTab == tab
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                        selectedTab = tab
                    }
                } label: {
                    ZStack {
                        if active {
                            Capsule()
                                .fill(Color.white.opacity(0.16))
                                .matchedGeometryEffect(id: "dockPill", in: namespace)
                        }
                        Image(systemName: active ? tab.activeIcon : tab.icon)
                            .font(.system(size: 20, weight: active ? .bold : .medium))
                            .foregroundStyle(active ? .white : Color.white.opacity(0.60))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(Color(red: 0.09, green: 0.09, blue: 0.11).opacity(0.92))
                .background(.ultraThinMaterial, in: Capsule())
        )
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.13), lineWidth: 0.8)
        )
        .shadow(color: .black.opacity(0.55), radius: 18, y: 8)
    }
}
