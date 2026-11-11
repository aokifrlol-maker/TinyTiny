import SwiftUI

// MARK: - 1. Home Feed Tab

struct HomeFeedView: View {
    @Binding var path: NavigationPath
    var isTabActive: Bool
    var switchToTab: (AppTab) -> Void

    @EnvironmentObject var store: UserStore
    @StateObject private var forYouModel = FeedModel(source: .forYou)
    @StateObject private var followingModel = FeedModel(source: .following)
    @State private var feedMode: Int = 0 // 0 = For You, 1 = Following
    @State private var activeCardID: String?

    private var activeModel: FeedModel {
        feedMode == 0 ? forYouModel : followingModel
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                topHeaderBar
                Divider().overlay(Theme.border)

                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 12) {
                        storiesTray
                            .padding(.top, 8)

                        Divider().overlay(Theme.border)

                        if feedMode == 1 && store.data.following.isEmpty && store.data.followedSubreddits.isEmpty {
                            emptyFollowingState
                        } else if activeModel.items.isEmpty && activeModel.isLoading {
                            ProgressView().tint(.white).padding(.top, 80)
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
                            ProgressView().tint(.white).padding(.vertical, 20)
                        }
                    }
                    .padding(.bottom, 78)
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
            if mode == 1 && followingModel.items.isEmpty {
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
                        .font(.system(size: 23, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.textSecondary)
                }
            }

            Spacer()

            NavigationLink(value: Route.reelList(title: "Liked", items: store.data.liked, start: store.data.liked.first?.id ?? "")) {
                Image(systemName: "heart")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(.white)
            }
            .disabled(store.data.liked.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var storiesTray: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                // Followed & Top 18+ Subreddits first
                ForEach(storySubreddits, id: \.self) { sub in
                    NavigationLink(value: Route.subreddit(sub)) {
                        VStack(spacing: 5) {
                            ZStack {
                                Circle()
                                    .stroke(Theme.ringGradient, lineWidth: 2.2)
                                    .frame(width: 64, height: 64)
                                Circle()
                                    .fill(Theme.surfaceElevated)
                                    .frame(width: 58, height: 58)
                                    .overlay(
                                        Text("r/")
                                            .font(.system(size: 18, weight: .black, design: .rounded))
                                            .foregroundStyle(Theme.redditOrange)
                                    )
                            }
                            Text("r/\(sub)")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        }
                        .frame(width: 68)
                    }
                    .buttonStyle(ScalePressButtonStyle())
                }

                // Followed & Active Creators
                ForEach(storyCreators, id: \.username) { u in
                    NavigationLink(value: Route.creator(u.username)) {
                        VStack(spacing: 5) {
                            AvatarRingView(username: u.username, imageURL: u.profileImageUrl, size: 58, showRing: true)
                            Text(u.username)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        }
                        .frame(width: 68)
                    }
                    .buttonStyle(ScalePressButtonStyle())
                }
            }
            .padding(.horizontal, 14)
        }
    }

    private var storySubreddits: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for s in store.data.followedSubreddits {
            if seen.insert(s.lowercased()).inserted { out.append(s) }
        }
        for s in ["gonewild", "RealGirls", "NSFW_GIF", "BustyPetite", "nsfwcosplay"] {
            if seen.insert(s.lowercased()).inserted { out.append(s) }
        }
        return Array(out.prefix(7))
    }

    private var storyCreators: [RGUser] {
        var seen = Set<String>()
        var list: [RGUser] = []
        for u in store.data.following {
            if seen.insert(u.username.lowercased()).inserted { list.append(u) }
        }
        for g in forYouModel.items where g.subreddit == nil {
            if let name = g.userName, seen.insert(name.lowercased()).inserted {
                list.append(RGUser(username: name, verified: g.verified))
            }
            if list.count >= 10 { break }
        }
        return list
    }

    private var emptyFollowingState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 40))
                .foregroundStyle(Theme.accent)
            Text("Nothing Followed Yet")
                .font(.headline)
            Button {
                feedMode = 0
            } label: {
                Text("Explore For You")
                    .font(.subheadline.bold())
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Theme.accent, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        .padding(.vertical, 70)
        .foregroundStyle(.white)
    }

    private func errorBanner(_ err: String) -> some View {
        VStack(spacing: 12) {
            Text(err).font(.subheadline).foregroundStyle(Theme.textSecondary)
            Button("Retry") { Task { await activeModel.refresh() } }
                .buttonStyle(.borderedProminent)
        }
        .padding(.vertical, 60)
    }
}

// MARK: - 2. Full-Screen Reels Tab

struct ReelsTabView: View {
    @Binding var path: NavigationPath
    var isTabActive: Bool
    var resetTrigger: Int

    @EnvironmentObject var store: UserStore
    @StateObject private var forYou = FeedModel(source: .forYou)
    @StateObject private var following = FeedModel(source: .following)
    @State private var mode = 0 // 0 = Reels, 1 = Following
    @State private var selectedCategory: GoonedCategory? = nil
    @State private var showFilterSheet = false

    var body: some View {
        NavigationStack(path: $path) {
            ZStack(alignment: .top) {
                if let cat = selectedCategory {
                    CategoryReelsContainer(category: cat, isVisible: isTabActive)
                        .id(cat.id)
                } else {
                    FeedView(model: forYou, isVisible: isTabActive && mode == 0)
                        .opacity(mode == 0 ? 1 : 0)
                        .allowsHitTesting(mode == 0)

                    Group {
                        if store.data.following.isEmpty && store.data.followedSubreddits.isEmpty {
                            emptyFriendsReels
                        } else {
                            FeedView(model: following, isVisible: isTabActive && mode == 1)
                        }
                    }
                    .opacity(mode == 1 ? 1 : 0)
                    .allowsHitTesting(mode == 1)
                }

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
            .onChange(of: resetTrigger) { _, _ in
                if selectedCategory != nil {
                    selectedCategory = nil
                } else {
                    mode = 0
                }
            }
        }
    }

    private var reelsTopOverlay: some View {
        HStack(spacing: 18) {
            if let cat = selectedCategory {
                Button {
                    selectedCategory = nil
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .bold))
                        Image(systemName: cat.icon)
                            .foregroundStyle(cat.color)
                        Text(cat.title)
                            .font(.system(size: 16, weight: .bold))
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
                        .font(.system(size: 19, weight: mode == 0 ? .heavy : .semibold))
                        .foregroundStyle(mode == 0 ? .white : .white.opacity(0.55))
                }

                Button {
                    mode = 1
                    if following.items.isEmpty {
                        Task { await following.refresh() }
                    }
                } label: {
                    Text("Following")
                        .font(.system(size: 19, weight: mode == 1 ? .heavy : .semibold))
                        .foregroundStyle(mode == 1 ? .white : .white.opacity(0.55))
                }
            }

            Spacer()

            Button {
                showFilterSheet = true
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.black.opacity(0.35), in: Circle())
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .shadow(color: .black.opacity(0.6), radius: 3)
    }

    private var emptyFriendsReels: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 42))
                .foregroundStyle(Theme.accent)
            Text("No Followed Creators or Subreddits")
                .font(.headline)
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
                Button {
                    selected = nil
                    dismiss()
                } label: {
                    HStack {
                        Label("All Reels", systemImage: "sparkles").foregroundStyle(.white)
                        Spacer()
                        if selected == nil { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                    }
                }

                ForEach(GoonedCategory.all) { cat in
                    Button {
                        selected = cat
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: cat.icon).foregroundStyle(cat.color).frame(width: 26)
                            Text(cat.title).font(.subheadline.bold()).foregroundStyle(.white)
                            Spacer()
                            if selected == cat { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 3. Categories Tab (Clean Visual Cards — No Clutter)

struct CategoriesTabView: View {
    @Binding var path: NavigationPath
    @EnvironmentObject var store: UserStore
    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    // Curated 10 Categories
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(GoonedCategory.all) { cat in
                            NavigationLink(value: Route.category(cat)) {
                                CategoryCardTile(category: cat)
                            }
                            .buttonStyle(ScalePressButtonStyle())
                        }
                    }
                    .padding(.horizontal, 14)

                    // Top 18+ Subreddits Quick Grid
                    VStack(alignment: .leading, spacing: 10) {
                        Text("18+ Subreddits")
                            .font(.headline)
                            .padding(.horizontal, 14)

                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(RedGifsAPI.popularNSFWSubreddits) { sub in
                                NavigationLink(value: Route.subreddit(sub.display_name)) {
                                    HStack(spacing: 10) {
                                        Circle()
                                            .fill(Theme.redditOrange)
                                            .frame(width: 32, height: 32)
                                            .overlay(Text("r/").font(.system(size: 12, weight: .black)).foregroundStyle(.white))
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text("r/\(sub.display_name)")
                                                .font(.system(size: 13, weight: .bold))
                                                .foregroundStyle(.white)
                                                .lineLimit(1)
                                            Text("\(shortCount(sub.subscribers))")
                                                .font(.system(size: 11))
                                                .foregroundStyle(Theme.textSecondary)
                                        }
                                        Spacer()
                                    }
                                    .padding(10)
                                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.border, lineWidth: 0.8))
                                }
                                .buttonStyle(ScalePressButtonStyle())
                            }
                        }
                        .padding(.horizontal, 14)
                    }
                }
                .padding(.top, 10)
                .padding(.bottom, 86)
            }
            .background(Theme.bg)
            .navigationTitle("Categories")
            .navigationBarTitleDisplayMode(.inline)
            .withGoonedRoutes()
        }
    }
}

struct CategoryCardTile: View {
    let category: GoonedCategory
    @EnvironmentObject var store: UserStore

    private var isPinned: Bool { store.isFavoriteCategory(category.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: category.icon)
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(category.color)
                    .frame(width: 38, height: 38)
                    .background(category.color.opacity(0.18), in: RoundedRectangle(cornerRadius: 10))
                Spacer()
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    store.toggleFavoriteCategory(category)
                } label: {
                    Image(systemName: isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isPinned ? category.color : Theme.textMuted)
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Text(category.title)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(14)
        .frame(height: 98)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Theme.surface)
                .overlay(
                    LinearGradient(
                        colors: [category.color.opacity(0.18), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(isPinned ? category.color.opacity(0.55) : Theme.border, lineWidth: 0.8)
        )
    }
}

// MARK: - Category Detail Screen

struct CategoryDetailScreen: View {
    let category: GoonedCategory
    @State private var order: String = "top"
    @State private var viewMode: Int = 0 // 0 = Grid, 1 = Reels

    var body: some View {
        CategoryDetailInner(category: category, order: order, viewMode: viewMode)
            .id("\(category.id)-\(order)")
            .navigationTitle(category.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        viewMode = viewMode == 0 ? 1 : 0
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
                FeedView(model: model, bottomInset: 68)
            } else {
                ScrollView {
                    // Quick Subreddit Pills for this Category
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(category.subreddits, id: \.self) { sub in
                                let clean = sub.trimmingCharacters(in: .whitespaces)
                                NavigationLink(value: Route.subreddit(clean)) {
                                    Text("r/\(clean)")
                                        .font(.system(size: 12, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 11)
                                        .padding(.vertical, 6)
                                        .background(Theme.redditOrange.opacity(0.22), in: Capsule())
                                        .overlay(Capsule().stroke(Theme.redditOrange.opacity(0.5), lineWidth: 0.8))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }

                    if model.items.isEmpty && model.isLoading {
                        ProgressView().tint(.white).padding(.top, 80)
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
                        ProgressView().padding(20)
                    }
                }
                .padding(.bottom, 70)
                .background(Theme.bg)
                .task {
                    if model.items.isEmpty { await model.loadMore() }
                }
            }
        }
    }
}

// MARK: - 4. Search Tab (Working Tag Search + 18+ Subreddit Search + Creator Search)

struct SearchTabView: View {
    @Binding var path: NavigationPath
    @EnvironmentObject var store: UserStore
    @StateObject private var exploreFeed = FeedModel(source: .forYou)
    @State private var query = ""
    @State private var suggestions: [Suggestion] = []
    @State private var subredditResults: [SubredditInfo] = []
    @State private var trendingTags: [TagCount] = []

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

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
            .searchable(text: $query, prompt: "Search r/subreddits, tags, creators…")
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .onSubmit(of: .search) {
                let q = query.trimmingCharacters(in: .whitespaces)
                guard !q.isEmpty else { return }
                store.addRecentSearch(q)
                if q.lowercased().hasPrefix("r/") {
                    let sub = String(q.dropFirst(2))
                    path.append(Route.subreddit(sub))
                } else {
                    path.append(Route.tag(q))
                }
            }
            .task(id: query) {
                let q = query.trimmingCharacters(in: .whitespaces)
                guard !q.isEmpty else {
                    suggestions = []
                    subredditResults = []
                    return
                }
                try? await Task.sleep(nanoseconds: 220_000_000)
                guard !Task.isCancelled else { return }
                async let sugTask = try? RedGifsAPI.shared.suggest(q)
                async let subTask = try? RedGifsAPI.shared.searchNSFWSubreddits(q, limit: 12)
                suggestions = (await sugTask) ?? []
                subredditResults = (await subTask) ?? []
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
        VStack(alignment: .leading, spacing: 12) {
            // Popular 18+ Subreddits Strip
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(RedGifsAPI.popularNSFWSubreddits) { sub in
                        NavigationLink(value: Route.subreddit(sub.display_name)) {
                            HStack(spacing: 5) {
                                Text("r/\(sub.display_name)")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Theme.redditOrange.opacity(0.22), in: Capsule())
                            .overlay(Capsule().stroke(Theme.redditOrange.opacity(0.45), lineWidth: 0.8))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
            }

            // Trending Tags Strip
            if !trendingTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(trendingTags.prefix(16), id: \.self) { t in
                            NavigationLink(value: Route.tag(t.name)) {
                                Text("#\(t.name)")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Theme.textSecondary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Theme.surface, in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }

            // 3-Column Visual Grid
            if exploreFeed.items.isEmpty && exploreFeed.isLoading {
                ProgressView().tint(.white).frame(maxWidth: .infinity).padding(.top, 60)
            } else {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(exploreFeed.items) { g in
                        NavigationLink(value: Route.reelList(title: "Explore", items: exploreFeed.items, start: g.id)) {
                            GridThumb(gif: g)
                        }
                        .onAppear {
                            if g.id == exploreFeed.items.last?.id {
                                Task { await exploreFeed.loadMore() }
                            }
                        }
                    }
                }
            }
        }
        .padding(.bottom, 84)
    }

    private var liveSearchSuggestions: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        let cleanSub = q.replacingOccurrences(of: "r/", with: "", options: .caseInsensitive).replacingOccurrences(of: " ", with: "")
        let cleanCreator = q.replacingOccurrences(of: "@", with: "").replacingOccurrences(of: " ", with: "")

        return LazyVStack(alignment: .leading, spacing: 0) {
            // Direct actions
            NavigationLink(value: Route.tag(q)) {
                searchRow(icon: "number", tint: Theme.accent, title: "#\(q)", subtitle: "Tag")
            }
            .simultaneousGesture(TapGesture().onEnded { store.addRecentSearch(q) })

            NavigationLink(value: Route.subreddit(cleanSub)) {
                searchRow(icon: "flame.fill", tint: Theme.redditOrange, title: "r/\(cleanSub)", subtitle: "18+ Subreddit")
            }
            .simultaneousGesture(TapGesture().onEnded { store.addRecentSearch("r/\(cleanSub)") })

            NavigationLink(value: Route.creator(cleanCreator)) {
                searchRow(icon: "person.fill", tint: .cyan, title: "@\(cleanCreator)", subtitle: "Creator")
            }
            .simultaneousGesture(TapGesture().onEnded { store.addRecentSearch(cleanCreator) })

            // Matching 18+ Subreddits from Reddit API
            if !subredditResults.isEmpty {
                Text("18+ Subreddits")
                    .font(.caption.bold())
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 4)

                ForEach(subredditResults) { sub in
                    NavigationLink(value: Route.subreddit(sub.display_name)) {
                        searchRow(
                            icon: "r.circle.fill",
                            tint: Theme.redditOrange,
                            title: "r/\(sub.display_name)",
                            subtitle: sub.subscribers.map { "\(shortCount($0)) members" }
                        )
                    }
                    .simultaneousGesture(TapGesture().onEnded { store.addRecentSearch("r/\(sub.display_name)") })
                }
            }

            // Matching RedGIFs Tags & Creators
            if !suggestions.isEmpty {
                Text("Tags & Creators")
                    .font(.caption.bold())
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 4)

                ForEach(suggestions, id: \.self) { s in
                    let isUser = (s.type ?? "").lowercased().contains("user")
                    NavigationLink(value: isUser ? Route.creator(s.text) : Route.tag(s.text)) {
                        searchRow(
                            icon: isUser ? "person.fill" : "number",
                            tint: isUser ? .cyan : Theme.accent,
                            title: isUser ? "@\(s.text)" : "#\(s.text)",
                            subtitle: s.gifs.map { "\(shortCount($0))" }
                        )
                    }
                    .simultaneousGesture(TapGesture().onEnded { store.addRecentSearch(s.text) })
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.bottom, 86)
    }

    private func searchRow(icon: String, tint: Color, title: String, subtitle: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.15), in: Circle())
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            Spacer()
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
    }
}

// MARK: - Subreddit Feed Screen (`r/subreddit`)

struct SubredditFeedScreen: View {
    let subreddit: String
    @EnvironmentObject var store: UserStore
    @StateObject private var model: FeedModel
    @State private var viewMode = 0 // 0 = Grid, 1 = Reels

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    init(subreddit: String) {
        self.subreddit = subreddit
        _model = StateObject(wrappedValue: FeedModel(source: .subreddit(subreddit)))
    }

    var body: some View {
        Group {
            if viewMode == 1 {
                FeedView(model: model, bottomInset: 68)
            } else {
                ScrollView {
                    if model.items.isEmpty && model.isLoading {
                        ProgressView().tint(.white).padding(.top, 80)
                    } else if model.items.isEmpty {
                        VStack(spacing: 10) {
                            Text("No posts found in r/\(subreddit)")
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                            Button("Retry") { Task { await model.refresh() } }
                                .buttonStyle(.borderedProminent)
                        }
                        .padding(.top, 70)
                    } else {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(model.items) { g in
                                NavigationLink(value: Route.reelList(title: "r/\(subreddit)", items: model.items, start: g.id)) {
                                    GridThumb(gif: g)
                                }
                                .onAppear { model.onItemAppear(g) }
                            }
                        }
                    }
                    if model.isLoading && !model.items.isEmpty {
                        ProgressView().padding(20)
                    }
                }
                .padding(.bottom, 70)
                .background(Theme.bg)
            }
        }
        .navigationTitle("r/\(subreddit)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button(store.isFollowingSubreddit(subreddit) ? "Joined" : "Join") {
                    store.toggleFollowSubreddit(subreddit)
                }
                .font(.subheadline.bold())

                Button {
                    viewMode = viewMode == 0 ? 1 : 0
                } label: {
                    Image(systemName: viewMode == 0 ? "play.rectangle.fill" : "square.grid.3x3.fill")
                }
            }
        }
        .task {
            if model.items.isEmpty { await model.loadMore() }
        }
    }
}

// MARK: - Tag & Reel List Screens

struct TagFeedScreen: View {
    let tag: String
    @State private var order = "top"
    @State private var viewMode = 0

    var body: some View {
        TagFeedInner(tag: tag, order: order, viewMode: viewMode)
            .id("\(tag)-\(order)")
            .navigationTitle("#\(tag)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        viewMode = viewMode == 0 ? 1 : 0
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
            FeedView(model: model, bottomInset: 68)
        } else {
            ScrollView {
                if model.items.isEmpty && model.isLoading {
                    ProgressView().tint(.white).padding(.top, 80)
                } else if model.items.isEmpty {
                    VStack(spacing: 10) {
                        Text("No results for #\(tag)")
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
                        NavigationLink(value: Route.subreddit(tag.replacingOccurrences(of: " ", with: ""))) {
                            Text("Try r/\(tag.replacingOccurrences(of: " ", with: "")) on Reddit")
                                .font(.subheadline.bold())
                                .foregroundStyle(Theme.redditOrange)
                        }
                    }
                    .padding(.top, 70)
                } else {
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(model.items) { g in
                            NavigationLink(value: Route.reelList(title: "#\(tag)", items: model.items, start: g.id)) {
                                GridThumb(gif: g)
                            }
                            .onAppear { model.onItemAppear(g) }
                        }
                    }
                }
                if model.isLoading && !model.items.isEmpty { ProgressView().padding(20) }
            }
            .padding(.bottom, 70)
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
        FeedView(model: model, initialID: start, bottomInset: 68)
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
                ProgressView().tint(.white).padding(.top, 60)
            } else {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(model.items) { g in
                        NavigationLink {
                            FeedView(model: model, initialID: g.id, bottomInset: 68).clearNavBar()
                        } label: {
                            GridThumb(gif: g)
                        }
                        .onAppear { model.onItemAppear(g) }
                    }
                }
            }
        }
        .padding(.bottom, 72)
        .background(Theme.bg)
        .navigationTitle("@\(username)")
        .navigationBarTitleDisplayMode(.inline)
        .task { if model.items.isEmpty { await model.loadMore() } }
    }

    private var headerSection: some View {
        let u = model.user
        let following = store.isFollowing(username)
        return VStack(spacing: 12) {
            HStack(spacing: 22) {
                AvatarRingView(username: username, imageURL: u?.profileImageUrl, size: 74, showRing: true)
                HStack(spacing: 22) {
                    profileStat(shortCount(u?.gifs ?? (model.items.isEmpty ? nil : model.items.count)), "Posts")
                    profileStat(shortCount(u?.followers), "Followers")
                    profileStat(shortCount(u?.views), "Views")
                }
            }
            .padding(.horizontal, 18)

            HStack(spacing: 10) {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    store.toggleFollow(username, user: model.user)
                } label: {
                    Text(following ? "Following" : "Follow")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(following ? Theme.surfaceElevated : Theme.accent, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.white)
                }
                .buttonStyle(ScalePressButtonStyle())

                if let first = model.items.first {
                    NavigationLink {
                        FeedView(model: model, initialID: first.id, bottomInset: 68).clearNavBar()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "play.fill")
                            Text("Reels")
                        }
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(Theme.surfaceElevated, in: RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(.white)
                    }
                }
            }
            .padding(.horizontal, 18)
        }
        .foregroundStyle(.white)
        .padding(.vertical, 12)
    }

    private func profileStat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 16, weight: .bold))
            Text(label).font(.caption).foregroundStyle(Theme.textSecondary)
        }
    }
}

// MARK: - Thumbnail Grid Cell

struct GridThumb: View {
    let gif: Gif

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
                LinearGradient(colors: [.clear, .black.opacity(0.60)], startPoint: .center, endPoint: .bottom)
            )
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 4) {
                    Image(systemName: gif.isImage ? "photo" : "play.fill")
                    Text(shortCount(gif.views))
                }
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .padding(6)
            }
            .contentShape(Rectangle())
    }
}

// MARK: - 5. Profile & Vault Tab (No "Top Taste" — Clean Likes, Saved, Following)

struct ProfileTabView: View {
    @Binding var path: NavigationPath
    @EnvironmentObject var store: UserStore
    @EnvironmentObject var app: AppState
    @State private var tab = 0 // 0 = Liked, 1 = Saved, 2 = Following
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 14) {
                    HStack(spacing: 26) {
                        statButton(store.data.liked.count, "Liked", 0)
                        statButton(store.data.saved.count, "Saved", 1)
                        statButton(store.data.following.count + store.data.followedSubreddits.count, "Following", 2)
                    }
                    .padding(.top, 8)

                    HStack(spacing: 0) {
                        segButton(icon: "heart.fill", index: 0)
                        segButton(icon: "bookmark.fill", index: 1)
                        segButton(icon: "person.2.fill", index: 2)
                    }
                    .overlay(alignment: .bottom) { Divider().overlay(Theme.border) }

                    switch tab {
                    case 0:
                        mediaGrid(items: store.data.liked, title: "Liked")
                    case 1:
                        mediaGrid(items: store.data.saved, title: "Saved")
                    default:
                        followingSection
                    }
                }
                .padding(.bottom, 84)
            }
            .background(Theme.bg)
            .navigationTitle("Vault")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { app.lock() } label: { Image(systemName: "lock.fill") }
                    NavigationLink { SettingsView() } label: { Image(systemName: "gearshape.fill") }
                }
            }
            .withGoonedRoutes()
        }
    }

    private func statButton(_ count: Int, _ label: String, _ idx: Int) -> some View {
        Button {
            tab = idx
        } label: {
            VStack(spacing: 2) {
                Text("\(count)").font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
                Text(label).font(.caption).foregroundStyle(Theme.textSecondary)
            }
        }
        .buttonStyle(.plain)
    }

    private func segButton(icon: String, index: Int) -> some View {
        let active = tab == index
        return Button {
            tab = index
        } label: {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 16))
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
    private func mediaGrid(items: [Gif], title: String) -> some View {
        if items.isEmpty {
            Text("Empty")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 60)
        } else {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(items) { g in
                    NavigationLink(value: Route.reelList(title: title, items: items, start: g.id)) {
                        GridThumb(gif: g)
                    }
                }
            }
        }
    }

    private var followingSection: some View {
        LazyVStack(spacing: 0) {
            ForEach(store.data.followedSubreddits, id: \.self) { sub in
                HStack(spacing: 12) {
                    NavigationLink(value: Route.subreddit(sub)) {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Theme.redditOrange)
                                .frame(width: 40, height: 40)
                                .overlay(Text("r/").font(.system(size: 13, weight: .black)).foregroundStyle(.white))
                            Text("r/\(sub)").font(.subheadline.bold()).foregroundStyle(.white)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)

                    Button("Leave") {
                        store.toggleFollowSubreddit(sub)
                    }
                    .font(.caption.bold())
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }

            ForEach(store.data.following) { u in
                HStack(spacing: 12) {
                    NavigationLink(value: Route.creator(u.username)) {
                        HStack(spacing: 12) {
                            AvatarRingView(username: u.username, imageURL: u.profileImageUrl, size: 40, showRing: true)
                            Text("@\(u.username)").font(.subheadline.bold()).foregroundStyle(.white)
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
                .padding(.vertical, 8)
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
            Section("Playback") {
                Toggle("HD Video", isOn: $store.data.settings.hd)
                Toggle("Mute Audio", isOn: $store.data.settings.muted)
                Toggle("Autoplay Home Feed", isOn: $store.data.settings.autoplayFeed)
            }

            Section("Security") {
                if Biometrics.available {
                    Toggle("Face ID Unlock", isOn: Binding(
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
                Button("Change Passcode") { changingPasscode = true }
                Button("Lock Now") { app.lock() }
            }

            Section {
                Button("Reset Recommendations", role: .destructive) { confirmReset = true }
                Button("Erase All Data", role: .destructive) { confirmErase = true }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("Settings")
        .sheet(isPresented: $changingPasscode) {
            PasscodeSetupView(mode: .change)
        }
        .confirmationDialog("Reset recommendations?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { store.resetAlgorithm() }
        }
        .confirmationDialog("Erase everything?", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("Erase All Data", role: .destructive) { app.eraseEverything() }
        }
    }
}
