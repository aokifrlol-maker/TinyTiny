import SwiftUI
import AVFoundation

@main
struct TinyTinyApp: App {
    @StateObject private var app = AppState()
    @StateObject private var store = UserStore.shared

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        URLCache.shared = URLCache(memoryCapacity: 64 * 1024 * 1024, diskCapacity: 400 * 1024 * 1024)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .environmentObject(store)
                .preferredColorScheme(.dark)
                .tint(.pink)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: UserStore
    @Environment(\.scenePhase) private var phase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if !app.ageConfirmed {
                AgeGateView()
            } else if !app.hasPasscode {
                PasscodeSetupView(mode: .create)
            } else {
                if app.hasUnlockedOnce {
                    MainTabView()
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

enum Route: Hashable {
    case tag(String)
    case niche(id: String, name: String)
    case creator(String)
    case list(items: [Gif], start: String)
}

extension View {
    func withRoutes() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .tag(let t): TagFeedScreen(tag: t)
            case .niche(let id, let name): NicheScreen(id: id, name: name)
            case .creator(let u): CreatorView(username: u)
            case .list(let items, let start): ListFeedScreen(items: items, start: start)
            }
        }
    }

    func blackTabBar() -> some View {
        self.toolbarBackground(.visible, for: .tabBar)
            .toolbarBackground(Color.black, for: .tabBar)
    }

    func clearNavBar() -> some View {
        self.navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            HomeView()
                .blackTabBar()
                .tabItem { Label("Home", systemImage: "house.fill") }
            DiscoverView()
                .blackTabBar()
                .tabItem { Label("Discover", systemImage: "magnifyingglass") }
            MeView()
                .blackTabBar()
                .tabItem { Label("Me", systemImage: "person.fill") }
        }
    }
}

