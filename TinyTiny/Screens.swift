import SwiftUI

// MARK: - 1. Home Feed Tab (Instagram-Style Header, Stories Tray & Inline Autoplay Cards)

struct HomeFeedView: View {
    var isTabActive: Bool
    var switchToTab: (AppTab) -> Void

    @EnvironmentObject var store: UserStore
    @StateObject private var forYouModel = FeedModel(source: .forYou)
    @StateObject private var followingModel = FeedModel(source: .following)
    @State private var feedMode: Int = 0 // 0 = For You, 1 = Following
    @State private var activeCardID: String?
    @State private var path = NavigationPath()

    private var activeModel: FeedModel {
        feedMode == 0 ? forYouModel : followingModel
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                topHeaderBar
                Divider().overlay(Theme.border)

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 14) {
                        storiesTray
                            .padding(.top, 10)

                        categoryQuickStrip

                        Divider().overlay(Theme.border)

                        if feedMode == 1 && store.data.following.isEmpty {
                            emptyFollowingState
                        } else if activeModel.items.isEmpty && activeModel.isLoading {
                            ForEach(0..<3, id: \.self) { _ in
                                SkeletonPostCard()
                            }
                        } else if let err = activeModel.errorText, activeModel.items.isEmpty {
                            errorBanner(err)
                        } else {
                            ForEach(activeModel.items) { gif in
                                SocialPostCardView(
                                    gif: gif,
                                    isPlaying: isTabActive && (activeCardID == gif.id || activeCardID == nil && gif.id == activeModel.items.first?.id),
                                    onOpenReels: {
                                        path.append(Route.reelList(title: "Reels", items: activeModel.items, start: gif.id))
                                    }
                                )
                                .id(gif.id)
                                .onAppear {
                                    activeCardID = gif.id
                                    activeModel.onItemAppear(gif)
                                }
                                Divider().overlay(Theme.border)
                            }
                        }

                        if activeModel.isLoading && !activeModel.items.isEmpty {
                            ProgressView().tint(.white).padding(.vertical, 24)
                        }
                    }
                    .padding(.bottom, 84)
                }
                .refreshable {
                    await activeModel.refresh()
                }
            }
            .background(Theme.bg)
            .toolbar(.hidden, for: .navigationBar)
            .withGoonedRoutes()
        }
        .task {
            if forYouModel.items.isEmpty { await forYouModel.loadMore() }
        }
        .onChange(of: feedMode) { _, mode in
            if mode == 1 && followingModel.items.isEmpty && !store.data.following.isEmpty {
                Task { await followingModel.refresh() }
            }
        }
    }

    private var topHeaderBar: some View {
        HStack(spacing: 14) {
            Menu {
                Picker("Feed", selection: $feedMode) {
                    Label("For You", systemImage: "sparkles").tag(0)
                    Label("Following", systemImage: "person.2.fill").tag(1)
                }
            } label: {
                HStack(spacing: 5) {
                    Text(feedMode == 0 ? "Gooned" : "Following")
                        .font(.system(size: 24, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Spacer()

            Button {
                switchToTab(.reels)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text("Reels")
                        .font(.system(size: 13, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Theme.brandGradient, in: Capsule())
            }
            .buttonStyle(ScalePressButtonStyle())

            NavigationLink(value: Route.reelList(title: "Liked", items: store.data.liked, start: store.data.liked.first?.id ?? "")) {
                Image(systemName: "heart")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(.white)
            }
            .disabled(store.data.liked.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var storiesTray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                // "For You" live pulse circle
                Button {
                    switchToTab(.reels)
                } label: {
                    VStack(spacing: 5) {
                        ZStack {
                            Circle()
                                .stroke(Theme.ringGradient, lineWidth: 2.5)
                                .frame(width: 68, height: 68)
                            Circle()
                                .fill(Theme.surfaceElevated)
                                .frame(width: 60, height: 60)
                                .overlay(
                                    Image(systemName: "flame.fill")
                                        .font(.system(size: 26))
                                        .foregroundStyle(Theme.ringGradient)
                                )
                        }
                        Text("For You")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                    .frame(width: 72)
                }
                .buttonStyle(ScalePressButtonStyle())

                // Followed Creators + Top Feed Creators
                let creators = storyCreators
                ForEach(creators, id: \.username) { u in
                    NavigationLink(value: Route.creator(u.username)) {
                        VStack(spacing: 5) {
                            AvatarRingView(username: u.username, imageURL: u.profileImageUrl, size: 60, showRing: true)
                            Text(u.username)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        }
                        .frame(width: 72)
                    }
                    .buttonStyle(ScalePressButtonStyle())
                }
            }
            .padding(.horizontal, 14)
        }
    }

    private var storyCreators: [RGUser] {
        var seen = Set<String>()
        var list: [RGUser] = []
        for u in store.data.following {
            if seen.insert(u.username.lowercased()).inserted { list.append(u) }
        }
        for g in forYouModel.items {
            if let name = g.userName, seen.insert(name.lowercased()).inserted {
                list.append(RGUser(username: name, verified: g.verified))
            }
            if list.count >= 14 { break }
        }
        return list
    }

    private var categoryQuickStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(GoonedCategory.all) { cat in
                    NavigationLink(value: Route.category(cat)) {
                        CategoryBadgePill(category: cat, compact: false)
                    }
                    .buttonStyle(ScalePressButtonStyle())
                }
            }
            .padding(.horizontal, 14)
        }
    }

    private var emptyFollowingState: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.2.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(Theme.accent)
            Text("Follow Your Favorite Creators")
                .font(.title3.bold())
            Text("Tap Follow on any post or Reel to build your personalized Following feed.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Button {
                feedMode = 0
            } label: {
                Text("Explore For You")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 22)
                    .padding(.vertical, 11)
                    .background(Theme.accent, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        .padding(.vertical, 64)
        .foregroundStyle(.white)
    }

    private func errorBanner(_ err: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 36))
                .foregroundStyle(Theme.accent)
            Text(err)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 30)
            Button("Retry") {
                Task { await activeModel.refresh() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 60)
    }
}

struct SkeletonPostCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle().fill(Theme.surfaceElevated).frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 5) {
                    RoundedRectangle(cornerRadius: 4).fill(Theme.surfaceElevated).frame(width: 110, height: 11)
                    RoundedRectangle(cornerRadius: 4).fill(Theme.surface).frame(width: 75, height: 9)
                }
                Spacer()
            }
            .padding(.horizontal, 12)

            ShimmerPlaceholder()
                .frame(height: 410)

            HStack(spacing: 16) {
                RoundedRectangle(cornerRadius: 4).fill(Theme.surfaceElevated).frame(width: 50, height: 18)
                RoundedRectangle(cornerRadius: 4).fill(Theme.surfaceElevated).frame(width: 50, height: 18)
                Spacer()
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - 2. Full-Screen Reels Tab (Instagram Reels / TikTok Style)

struct ReelsTabView: View {
    var isTabActive: Bool

    @EnvironmentObject var store: UserStore
    @StateObject private var forYou = FeedModel(source: .forYou)
    @StateObject private var following = FeedModel(source: .following)
    @State private var mode = 0 // 0 = Reels (For You), 1 = Friends / Following
    @State private var selectedCategory: GoonedCategory? = nil
    @State private var showFilterSheet = false

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                if let cat = selectedCategory {
                    CategoryReelsContainer(category: cat, isVisible: isTabActive)
                        .id(cat.id)
                } else {
                    FeedView(model: forYou, isVisible: isTabActive && mode == 0)
                        .opacity(mode == 0 ? 1 : 0)
                        .allowsHitTesting(mode == 0)

                    Group {
                        if store.data.following.isEmpty {
                            emptyFriendsReels
                        } else {
                            FeedView(model: following, isVisible: isTabActive && mode == 1)
                        }
                    }
                    .opacity(mode == 1 ? 1 : 0)
                    .allowsHitTesting(mode == 1)
                }

                // Instagram Reels Top Bar: "Reels  Following" + Category Filter Button
                reelsTopOverlay
            }
            .background(Color.black)
            .toolbar(.hidden, for: .navigationBar)
            .withGoonedRoutes()
            .sheet(isPresented: $showFilterSheet) {
                ReelsCategoryFilterSheet(selected: $selectedCategory)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
    }

    private var reelsTopOverlay: some View {
        HStack(spacing: 18) {
            if let cat = selectedCategory {
                Button {
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                        selectedCategory = nil
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 14, weight: .bold))
                        Image(systemName: cat.icon)
                            .foregroundStyle(cat.color)
                        Text(cat.title)
                            .font(.system(size: 17, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                }
            } else {
                Button {
                    if mode == 0 { Task { await forYou.refresh() } }
                    mode = 0
                } label: {
                    Text("Reels")
                        .font(.system(size: 20, weight: mode == 0 ? .heavy : .semibold))
                        .foregroundStyle(mode == 0 ? .white : .white.opacity(0.55))
                }

                Button {
                    mode = 1
                    if following.items.isEmpty && !store.data.following.isEmpty {
                        Task { await following.refresh() }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("Following")
                            .font(.system(size: 20, weight: mode == 1 ? .heavy : .semibold))
                            .foregroundStyle(mode == 1 ? .white : .white.opacity(0.55))
                        if !store.data.following.isEmpty {
                            HStack(spacing: -6) {
                                ForEach(store.data.following.prefix(3)) { u in
                                    AvatarRingView(username: u.username, imageURL: u.profileImageUrl, size: 18, showRing: false)
                                        .overlay(Circle().stroke(Color.black, lineWidth: 1.2))
                                }
                            }
                        }
                    }
                }
            }

            Spacer()

            Button {
                showFilterSheet = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 36, height: 36)
                    .background(.black.opacity(0.35), in: Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .shadow(color: .black.opacity(0.6), radius: 4)
    }

    private var emptyFriendsReels: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 46))
                .foregroundStyle(Theme.accent)
            Text("No Followed Creators Yet")
                .font(.title3.bold())
            Text("Follow creators from the Reels feed to watch their latest clips here.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Button("Back to Reels") { mode = 0 }
                .buttonStyle(.borderedProminent)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

private struct CategoryReelsContainer: View {
    @StateObject private var model: FeedModel
    let isVisible: Bool

    init(category: GoonedCategory, isVisible: Bool) {
        _model = StateObject(wrappedValue: FeedModel(source: .category(category, order: "top")))
        self.isVisible = isVisible
    }

    var body: some View {
        FeedView(model: model, isVisible: isVisible)
    }
}

struct ReelsCategoryFilterSheet: View {
    @Binding var selected: GoonedCategory?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        selected = nil
                        dismiss()
                    } label: {
                        HStack {
                            Label("All Personalized Reels", systemImage: "sparkles")
                                .foregroundStyle(.white)
                            Spacer()
                            if selected == nil {
                                Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                            }
                        }
                    }
                }

                Section("Filter by Category") {
                    ForEach(GoonedCategory.all) { cat in
                        Button {
                            selected = cat
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: cat.icon)
                                    .foregroundStyle(cat.color)
                                    .frame(width: 28)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(cat.title).font(.subheadline.bold()).foregroundStyle(.white)
                                    Text(cat.subtitle).font(.caption).foregroundStyle(Theme.textSecondary)
                                }
                                Spacer()
                                if selected == cat {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                                }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Reels Filter")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 3. Controlled Predefined Categories Tab (Fixed 10 Categories Only)

struct CategoriesTabView: View {
    @EnvironmentObject var store: UserStore
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    // Pinned Favorites Row
                    if !store.favoriteCategories.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Pinned Categories")
                                .font(.headline)
                                .foregroundStyle(Theme.textSecondary)
                                .padding(.horizontal, 16)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 10) {
                                    ForEach(store.favoriteCategories) { cat in
                                        NavigationLink(value: Route.category(cat)) {
                                            CategoryBadgePill(category: cat, compact: false)
                                        }
                                        .buttonStyle(ScalePressButtonStyle())
                                    }
                                }
                                .padding(.horizontal, 16)
                            }
                        }
                    }

                    // All 10 Predefined Curated Categories
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Browse Categories")
                                .font(.title3.bold())
                            Spacer()
                            Text("\(GoonedCategory.all.count) curated")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.horizontal, 16)

                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(GoonedCategory.all) { cat in
                                NavigationLink(value: Route.category(cat)) {
                                    CategoryCardTile(category: cat)
                                }
                                .buttonStyle(ScalePressButtonStyle())
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.top, 10)
                .padding(.bottom, 90)
            }
            .background(Theme.bg)
            .navigationTitle("Categories")
            .withGoonedRoutes()
        }
    }
}

struct CategoryCardTile: View {
    let category: GoonedCategory
    @EnvironmentObject var store: UserStore

    private var isPinned: Bool { store.isFavoriteCategory(category.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(category.color.opacity(0.20))
                        .frame(width: 42, height: 42)
                    Image(systemName: category.icon)
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(category.color)
                }
                Spacer()
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    store.toggleFavoriteCategory(category)
                } label: {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isPinned ? category.color : Theme.textMuted)
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.06), in: Circle())
                }
                .buttonStyle(.plain)
            }

            Spacer(minLength: 4)

            VStack(alignment: .leading, spacing: 4) {
                Text(category.title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(category.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
        }
        .padding(14)
        .frame(height: 138)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Theme.surface)
                .overlay(
                    LinearGradient(
                        colors: [category.color.opacity(0.18), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isPinned ? category.color.opacity(0.55) : Theme.border, lineWidth: 1)
        )
    }
}

// MARK: - Category Detail Screen (Switchable Grid + Fullscreen Reels + Sort)

struct CategoryDetailScreen: View {
    let category: GoonedCategory
    @EnvironmentObject var store: UserStore
    @State private var order: String = "top" // "top" or "latest"
    @State private var viewMode: Int = 0    // 0 = Grid, 1 = Reels

    var body: some View {
        CategoryDetailInner(category: category, order: order, viewMode: viewMode)
            .id("\(category.id)-\(order)")
            .navigationTitle(category.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        store.toggleFavoriteCategory(category)
                    } label: {
                        Image(systemName: store.isFavoriteCategory(category.id) ? "pin.fill" : "pin")
                            .foregroundStyle(store.isFavoriteCategory(category.id) ? category.color : .white)
                    }

                    Button {
                        withAnimation { viewMode = viewMode == 0 ? 1 : 0 }
                    } label: {
                        Image(systemName: viewMode == 0 ? "play.rectangle.fill" : "square.grid.3x3.fill")
                    }

                    Menu {
                        Picker("Sort By", selection: $order) {
                            Label("Top Rated", systemImage: "flame.fill").tag("top")
                            Label("Latest", systemImage: "clock.fill").tag("latest")
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down.circle")
                    }
                }
            }
    }
}

private struct CategoryDetailInner: View {
    let category: GoonedCategory
    let viewMode: Int
    @StateObject private var model: FeedModel
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    init(category: GoonedCategory, order: String, viewMode: Int) {
        self.category = category
        self.viewMode = viewMode
        _model = StateObject(wrappedValue: FeedModel(source: .category(category, order: order)))
    }

    var body: some View {
        Group {
            if viewMode == 1 {
                FeedView(model: model, bottomInset: 72)
            } else {
                ScrollView {
                    // Category Hero Banner
                    HStack(spacing: 14) {
                        Image(systemName: category.icon)
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(category.color)
                            .frame(width: 52, height: 52)
                            .background(category.color.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(category.title).font(.headline)
                            Text(category.subtitle).font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                        Spacer()
                    }
                    .padding(14)

                    if model.items.isEmpty && model.isLoading {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(0..<12, id: \.self) { _ in
                                ShimmerPlaceholder().aspectRatio(9.0 / 16.0, contentMode: .fit)
                            }
                        }
                    } else {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(model.items) { g in
                                NavigationLink(value: Route.reelList(title: category.title, items: model.items, start: g.id)) {
                                    GridThumb(gif: g)
                                }
                                .onAppear { model.onItemAppear(g) }
                            }
                        }
                    }

                    if model.isLoading && !model.items.isEmpty {
                        ProgressView().padding(24)
                    }
                }
                .padding(.bottom, 74)
                .background(Theme.bg)
                .task {
                    if model.items.isEmpty { await model.loadMore() }
                }
            }
        }
    }
}

// MARK: - 4. Search & Explore Tab (Instagram Explore Grid + Autocomplete + Recent Searches)

struct SearchTabView: View {
    @EnvironmentObject var store: UserStore
    @StateObject private var exploreFeed = FeedModel(source: .forYou)
    @State private var path = NavigationPath()
    @State private var query = ""
    @State private var suggestions: [Suggestion] = []
    @State private var trendingTags: [TagCount] = []
    @State private var selectedFilterCategory: GoonedCategory? = nil

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    private var filteredExploreItems: [Gif] {
        guard let cat = selectedFilterCategory else { return exploreFeed.items }
        return exploreFeed.items.filter { $0.category == cat }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView(.vertical, showsIndicators: false) {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    exploreGridContent
                } else {
                    liveSearchSuggestions
                }
            }
            .background(Theme.bg)
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "Search creators, tags, or topics…")
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .onSubmit(of: .search) {
                let q = query.trimmingCharacters(in: .whitespaces)
                guard !q.isEmpty else { return }
                store.addRecentSearch(q)
                path.append(Route.tag(q))
            }
            .task(id: query) {
                let q = query.trimmingCharacters(in: .whitespaces)
                guard !q.isEmpty else { suggestions = []; return }
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                suggestions = (try? await RedGifsAPI.shared.suggest(q)) ?? []
            }
            .task {
                if trendingTags.isEmpty {
                    trendingTags = (try? await RedGifsAPI.shared.trendingTags().tags) ?? []
                }
                if exploreFeed.items.isEmpty {
                    await exploreFeed.loadMore()
                }
            }
            .refreshable {
                await exploreFeed.refresh()
            }
            .withGoonedRoutes()
        }
    }

    private var exploreGridContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Recent Searches
            if !store.data.recentSearches.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Recent")
                            .font(.subheadline.bold())
                            .foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Button("Clear") { store.clearRecentSearches() }
                            .font(.caption.bold())
                            .foregroundStyle(Theme.accent)
                    }
                    .padding(.horizontal, 14)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(store.data.recentSearches, id: \.self) { term in
                                NavigationLink(value: Route.tag(term)) {
                                    HStack(spacing: 5) {
                                        Image(systemName: "clock.arrow.circlepath")
                                            .font(.system(size: 11))
                                        Text(term)
                                            .font(.system(size: 12, weight: .semibold))
                                    }
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 6)
                                    .background(Theme.surfaceElevated, in: Capsule())
                                    .foregroundStyle(.white)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 14)
                    }
                }
            }

            // Predefined Category Filter Pills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button {
                        selectedFilterCategory = nil
                    } label: {
                        Text("All")
                            .font(.system(size: 12, weight: .bold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .background(selectedFilterCategory == nil ? Theme.accent : Theme.surfaceElevated, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)

                    ForEach(GoonedCategory.all) { cat in
                        Button {
                            selectedFilterCategory = (selectedFilterCategory == cat) ? nil : cat
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: cat.icon)
                                    .font(.system(size: 11))
                                    .foregroundStyle(selectedFilterCategory == cat ? .white : cat.color)
                                Text(cat.title)
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(selectedFilterCategory == cat ? cat.color : Theme.surfaceElevated, in: Capsule())
                            .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14)
            }

            // Trending Tags Strip
            if !trendingTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(trendingTags.prefix(16), id: \.self) { t in
                            NavigationLink(value: Route.tag(t.name)) {
                                Text("#\(t.name)")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Theme.textSecondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Theme.surface, in: Capsule())
                                    .overlay(Capsule().stroke(Theme.border, lineWidth: 0.8))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 14)
                }
            }

            // Instagram 3-Column Explore Visual Grid
            if exploreFeed.items.isEmpty && exploreFeed.isLoading {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(0..<12, id: \.self) { _ in
                        ShimmerPlaceholder().aspectRatio(9.0 / 16.0, contentMode: .fit)
                    }
                }
            } else {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(filteredExploreItems) { g in
                        NavigationLink(value: Route.reelList(title: "Explore", items: filteredExploreItems, start: g.id)) {
                            GridThumb(gif: g, showCategoryDot: true)
                        }
                        .onAppear {
                            if g.id == exploreFeed.items.last?.id {
                                Task { await exploreFeed.loadMore() }
                            }
                        }
                    }
                }
            }

            if exploreFeed.isLoading && !exploreFeed.items.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding(20)
            }
        }
        .padding(.bottom, 86)
    }

    private var liveSearchSuggestions: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        let cleanCreator = q.replacingOccurrences(of: "@", with: "")
        return LazyVStack(alignment: .leading, spacing: 0) {
            // Matching Fixed Categories first
            let matchingCats = GoonedCategory.all.filter {
                $0.title.localizedCaseInsensitiveContains(q) || $0.subtitle.localizedCaseInsensitiveContains(q)
            }
            ForEach(matchingCats) { cat in
                NavigationLink(value: Route.category(cat)) {
                    searchRow(icon: cat.icon, tint: cat.color, title: cat.title, subtitle: "Category • \(cat.subtitle)")
                }
            }

            NavigationLink(value: Route.tag(q)) {
                searchRow(icon: "magnifyingglass", tint: Theme.accent, title: "Search \"\(q)\"", subtitle: "Posts & Reels")
            }
            .simultaneousGesture(TapGesture().onEnded { store.addRecentSearch(q) })

            NavigationLink(value: Route.creator(cleanCreator)) {
                searchRow(icon: "person.crop.circle.fill", tint: .cyan, title: "@\(cleanCreator)", subtitle: "Creator Profile")
            }
            .simultaneousGesture(TapGesture().onEnded { store.addRecentSearch(cleanCreator) })

            ForEach(suggestions, id: \.self) { s in
                let isUser = (s.type ?? "").lowercased().contains("user")
                NavigationLink(value: isUser ? Route.creator(s.text) : Route.tag(s.text)) {
                    searchRow(
                        icon: isUser ? "person.fill" : "number",
                        tint: isUser ? .cyan : Theme.accent,
                        title: s.text,
                        subtitle: s.gifs.map { "\(shortCount($0)) posts" }
                    )
                }
                .simultaneousGesture(TapGesture().onEnded { store.addRecentSearch(s.text) })
            }
        }
        .buttonStyle(.plain)
        .padding(.bottom, 86)
    }

    private func searchRow(icon: String, tint: Color, title: String, subtitle: String?) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(Theme.textMuted)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

// MARK: - Tag & Reel List Screens

struct TagFeedScreen: View {
    let tag: String
    @State private var order = "top"
    @State private var viewMode = 0 // 0 = Grid, 1 = Reels

    var body: some View {
        TagFeedInner(tag: tag, order: order, viewMode: viewMode)
            .id("\(tag)-\(order)")
            .navigationTitle("#\(tag)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        withAnimation { viewMode = viewMode == 0 ? 1 : 0 }
                    } label: {
                        Image(systemName: viewMode == 0 ? "play.rectangle.fill" : "square.grid.3x3.fill")
                    }

                    Menu {
                        Picker("Sort", selection: $order) {
                            Text("Top").tag("top")
                            Text("Latest").tag("latest")
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down.circle")
                    }
                }
            }
    }
}

private struct TagFeedInner: View {
    let tag: String
    let viewMode: Int
    @StateObject private var model: FeedModel
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    init(tag: String, order: String, viewMode: Int) {
        self.tag = tag
        self.viewMode = viewMode
        _model = StateObject(wrappedValue: FeedModel(source: .tag(tag, order: order)))
    }

    var body: some View {
        if viewMode == 1 {
            FeedView(model: model, bottomInset: 72)
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(model.items) { g in
                        NavigationLink(value: Route.reelList(title: "#\(tag)", items: model.items, start: g.id)) {
                            GridThumb(gif: g)
                        }
                        .onAppear { model.onItemAppear(g) }
                    }
                }
                if model.isLoading { ProgressView().padding(24) }
            }
            .padding(.bottom, 74)
            .background(Theme.bg)
            .task { if model.items.isEmpty { await model.loadMore() } }
        }
    }
}

struct ReelListScreen: View {
    let title: String
    @StateObject private var model: FeedModel
    private let start: String

    init(title: String, items: [Gif], start: String) {
        self.title = title
        _model = StateObject(wrappedValue: FeedModel(source: .list, items: items))
        self.start = start
    }

    var body: some View {
        FeedView(model: model, initialID: start, bottomInset: 72)
            .navigationTitle(title)
            .clearNavBar()
    }
}

// MARK: - Creator Profile Screen

struct CreatorProfileScreen: View {
    let username: String
    @EnvironmentObject var store: UserStore
    @StateObject private var model: FeedModel

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    init(username: String) {
        self.username = username
        _model = StateObject(wrappedValue: FeedModel(source: .user(username)))
    }

    var body: some View {
        ScrollView {
            headerSection
            Divider().overlay(Theme.border)

            if model.items.isEmpty && model.isLoading {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(0..<9, id: \.self) { _ in
                        ShimmerPlaceholder().aspectRatio(9.0 / 16.0, contentMode: .fit)
                    }
                }
            } else {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(model.items) { g in
                        NavigationLink {
                            FeedView(model: model, initialID: g.id, bottomInset: 72).clearNavBar()
                        } label: {
                            GridThumb(gif: g, showCategoryDot: true)
                        }
                        .onAppear { model.onItemAppear(g) }
                    }
                }
            }

            if model.isLoading && !model.items.isEmpty {
                ProgressView().padding(20)
            } else if let err = model.errorText, model.items.isEmpty {
                VStack(spacing: 10) {
                    Text("Creator unavailable or has no public posts.").foregroundStyle(Theme.textSecondary)
                    Text(err).font(.caption).foregroundStyle(Theme.textMuted)
                    Button("Retry") { Task { await model.loadMore() } }
                        .buttonStyle(.borderedProminent)
                }
                .padding(.top, 40)
            }
        }
        .padding(.bottom, 76)
        .background(Theme.bg)
        .navigationTitle("@\(username)")
        .navigationBarTitleDisplayMode(.inline)
        .task { if model.items.isEmpty { await model.loadMore() } }
    }

    private var headerSection: some View {
        let u = model.user
        let following = store.isFollowing(username)
        return VStack(spacing: 14) {
            HStack(spacing: 22) {
                AvatarRingView(username: username, imageURL: u?.profileImageUrl, size: 80, showRing: true)

                HStack(spacing: 22) {
                    profileStat(shortCount(u?.gifs ?? (model.items.isEmpty ? nil : model.items.count)), "Posts")
                    profileStat(shortCount(u?.followers), "Followers")
                    profileStat(shortCount(u?.views), "Views")
                }
            }
            .padding(.horizontal, 18)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(u?.name ?? username).font(.headline)
                    if u?.verified == true {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(.cyan).font(.subheadline)
                    }
                }
                if let d = u?.description, !d.isEmpty {
                    Text(d)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)

            HStack(spacing: 10) {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    store.toggleFollow(username, user: model.user)
                } label: {
                    Text(following ? "Following" : "Follow")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(following ? Theme.surfaceElevated : Theme.accent, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.white)
                }
                .buttonStyle(ScalePressButtonStyle())

                if let first = model.items.first {
                    NavigationLink {
                        FeedView(model: model, initialID: first.id, bottomInset: 72).clearNavBar()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                            Text("Watch Reels")
                        }
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.white)
                    }
                }
            }
            .padding(.horizontal, 18)
        }
        .foregroundStyle(.white)
        .padding(.vertical, 14)
    }

    private func profileStat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 17, weight: .bold))
            Text(label).font(.caption).foregroundStyle(Theme.textSecondary)
        }
    }
}

// MARK: - Thumbnail Grid Cell

struct GridThumb: View {
    let gif: Gif
    var showCategoryDot: Bool = false

    var body: some View {
        Theme.surface
            .aspectRatio(9.0 / 16.0, contentMode: .fit)
            .overlay(
                AsyncImage(url: gif.thumbURL) { phase in
                    if let img = phase.image {
                        img.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        ShimmerPlaceholder()
                    }
                }
            )
            .clipped()
            .overlay(
                LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .center, endPoint: .bottom)
            )
            .overlay(alignment: .topTrailing) {
                if showCategoryDot {
                    Image(systemName: gif.category.icon)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(gif.category.color)
                        .padding(5)
                        .background(.black.opacity(0.55), in: Circle())
                        .padding(5)
                }
            }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 4) {
                    Image(systemName: "play.fill")
                    Text(shortCount(gif.views))
                }
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .padding(6)
            }
            .contentShape(Rectangle())
    }
}

// MARK: - 5. Profile & Vault Tab (Likes, Saved, Following & Settings)

struct ProfileTabView: View {
    @EnvironmentObject var store: UserStore
    @EnvironmentObject var app: AppState
    @State private var tab = 0 // 0 = Liked, 1 = Saved, 2 = Following
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        NavigationStack {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 16) {
                    // Profile Header
                    HStack(spacing: 20) {
                        ZStack {
                            Circle()
                                .stroke(Theme.ringGradient, lineWidth: 2.5)
                                .frame(width: 78, height: 78)
                            Circle()
                                .fill(Theme.surfaceElevated)
                                .frame(width: 70, height: 70)
                                .overlay(
                                    Image(systemName: "lock.shield.fill")
                                        .font(.system(size: 30))
                                        .foregroundStyle(Theme.accent)
                                )
                        }

                        HStack(spacing: 24) {
                            statButton(store.data.liked.count, "Liked", 0)
                            statButton(store.data.saved.count, "Saved", 1)
                            statButton(store.data.following.count, "Following", 2)
                        }
                    }
                    .padding(.horizontal, 18)

                    // Taste Profile Summary Chips
                    let topCats = store.topCategories(4).map(\.0)
                    if !topCats.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                Text("Top Taste:")
                                    .font(.caption.bold())
                                    .foregroundStyle(Theme.textSecondary)
                                ForEach(topCats) { cat in
                                    NavigationLink(value: Route.category(cat)) {
                                        CategoryBadgePill(category: cat, compact: true)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 18)
                        }
                    }

                    // Segmented Tab Bar
                    HStack(spacing: 0) {
                        segButton(icon: "heart.fill", label: "Liked", index: 0)
                        segButton(icon: "bookmark.fill", label: "Saved", index: 1)
                        segButton(icon: "person.2.fill", label: "Following", index: 2)
                    }
                    .overlay(alignment: .bottom) { Divider().overlay(Theme.border) }

                    switch tab {
                    case 0:
                        mediaGrid(items: store.data.liked, title: "Liked", emptyTitle: "No Liked Reels Yet", emptySub: "Double-tap any post or Reel to add it to your Likes.")
                    case 1:
                        mediaGrid(items: store.data.saved, title: "Saved", emptyTitle: "No Saved Posts Yet", emptySub: "Tap the bookmark icon on any video to save it for later.")
                    default:
                        followingSection
                    }
                }
                .padding(.top, 10)
                .padding(.bottom, 88)
            }
            .background(Theme.bg)
            .navigationTitle("Vault")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        app.lock()
                    } label: {
                        Image(systemName: "lock.fill")
                    }
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape.fill")
                    }
                }
            }
            .withGoonedRoutes()
        }
    }

    private func statButton(_ count: Int, _ label: String, _ idx: Int) -> some View {
        Button {
            withAnimation { tab = idx }
        } label: {
            VStack(spacing: 2) {
                Text("\(count)").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                Text(label).font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func segButton(icon: String, label: String, index: Int) -> some View {
        let active = tab == index
        return Button {
            withAnimation(.easeInOut(duration: 0.18)) { tab = index }
        } label: {
            VStack(spacing: 8) {
                HStack(spacing: 5) {
                    Image(systemName: icon).font(.system(size: 13))
                    Text(label).font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(active ? .white : Theme.textSecondary)
                Rectangle()
                    .fill(active ? Theme.accent : Color.clear)
                    .frame(height: 2)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func mediaGrid(items: [Gif], title: String, emptyTitle: String, emptySub: String) -> some View {
        if items.isEmpty {
            VStack(spacing: 8) {
                Text(emptyTitle).font(.headline)
                Text(emptySub)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            .padding(.top, 56)
        } else {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(items) { g in
                    NavigationLink(value: Route.reelList(title: title, items: items, start: g.id)) {
                        GridThumb(gif: g, showCategoryDot: true)
                    }
                }
            }
        }
    }

    private var followingSection: some View {
        Group {
            if store.data.following.isEmpty {
                VStack(spacing: 8) {
                    Text("Not Following Anyone").font(.headline)
                    Text("Creators you follow will appear here for quick access.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                }
                .padding(.top, 56)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(store.data.following) { u in
                        HStack(spacing: 12) {
                            NavigationLink(value: Route.creator(u.username)) {
                                HStack(spacing: 12) {
                                    AvatarRingView(username: u.username, imageURL: u.profileImageUrl, size: 44, showRing: true)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(u.name ?? u.username).font(.subheadline.bold()).foregroundStyle(.white)
                                        Text("@\(u.username)").font(.caption).foregroundStyle(Theme.textSecondary)
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            Button("Unfollow") {
                                store.toggleFollow(u.username)
                            }
                            .font(.caption.bold())
                            .buttonStyle(.bordered)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                    }
                }
            }
        }
    }
}

// MARK: - Settings View

struct SettingsView: View {
    @EnvironmentObject var store: UserStore
    @EnvironmentObject var app: AppState
    @State private var changingPasscode = false
    @State private var confirmReset = false
    @State private var confirmErase = false

    var body: some View {
        Form {
            Section("Feed & Playback") {
                Toggle("HD Video Quality", isOn: $store.data.settings.hd)
                Toggle("Mute Audio by Default", isOn: $store.data.settings.muted)
                Toggle("Autoplay Home Feed Videos", isOn: $store.data.settings.autoplayFeed)
            }

            Section("Passcode & Privacy") {
                if Biometrics.available {
                    Toggle("Unlock with Face ID", isOn: Binding(
                        get: { store.data.settings.faceID },
                        set: { on in
                            if on {
                                Task { if await Biometrics.authenticate() { store.data.settings.faceID = true } }
                            } else {
                                store.data.settings.faceID = false
                            }
                        }
                    ))
                }
                Button("Change 4-Digit Passcode") { changingPasscode = true }
                Button("Lock App Immediately") { app.lock() }
            }

            Section("Recommendation Algorithm") {
                let topCats = store.topCategories(5).map { "\($0.0.title) (+\(Int($0.1)))" }
                Text(topCats.isEmpty ? "Watching & liking posts will personalize your feed across Gooned's 10 categories." : topCats.joined(separator: " • "))
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                Button("Reset Recommendation Taste", role: .destructive) { confirmReset = true }
            }

            Section {
                Button("Panic Erase All Data", role: .destructive) { confirmErase = true }
            } footer: {
                Text("All likes, saved videos, followed creators, and your passcode are encrypted on-device only.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("Settings")
        .sheet(isPresented: $changingPasscode) {
            PasscodeSetupView(mode: .change)
        }
        .confirmationDialog("Reset recommendation history?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset Algorithm", role: .destructive) { store.resetAlgorithm() }
        }
        .confirmationDialog("Erase everything from this device?", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("Erase All Data & Passcode", role: .destructive) { app.eraseEverything() }
        } message: {
            Text("Permanently removes your passcode, likes, saved posts, follows, and history.")
        }
    }
}
