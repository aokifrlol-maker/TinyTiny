import SwiftUI

// MARK: - Home

struct HomeView: View {
    @EnvironmentObject var store: UserStore
    @StateObject private var forYou = FeedModel(source: .forYou)
    @StateObject private var following = FeedModel(source: .following)
    @State private var tab = 1
    @State private var followSnapshot: [String] = []

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                FeedView(model: forYou, isVisible: tab == 1)
                    .opacity(tab == 1 ? 1 : 0)
                    .allowsHitTesting(tab == 1)

                Group {
                    if store.data.following.isEmpty {
                        emptyFollowing
                    } else {
                        FeedView(model: following, isVisible: tab == 0)
                    }
                }
                .opacity(tab == 0 ? 1 : 0)
                .allowsHitTesting(tab == 0)

                HStack(spacing: 26) {
                    topTab("Following", 0)
                    topTab("For You", 1)
                }
                .padding(.top, 6)
            }
            .background(Color.black)
            .toolbar(.hidden, for: .navigationBar)
            .withRoutes()
        }
        .onChange(of: tab) { _, t in
            let names = store.data.following.map(\.username)
            if t == 0 && names != followSnapshot {
                followSnapshot = names
                Task { await following.refresh() }
            }
        }
        .onAppear { if followSnapshot.isEmpty { followSnapshot = store.data.following.map(\.username) } }
    }

    private func topTab(_ title: String, _ i: Int) -> some View {
        Button {
            if tab == i, i == 1 {
                Task { await forYou.refresh() } // tap again to refresh
            }
            tab = i
        } label: {
            VStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 17, weight: tab == i ? .bold : .semibold))
                    .foregroundStyle(tab == i ? .white : .white.opacity(0.6))
                Capsule().fill(tab == i ? Color.white : Color.clear).frame(width: 26, height: 3)
            }
        }
        .shadow(color: .black.opacity(0.5), radius: 3)
    }

    private var emptyFollowing: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.2.fill").font(.system(size: 50)).foregroundStyle(.pink)
            Text("Follow creators").font(.title2.bold())
            Text("Tap the + on a creator's picture in For You.\nTheir newest posts will show up here.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

// MARK: - Discover

struct DiscoverView: View {
    @EnvironmentObject var store: UserStore
    @State private var path = NavigationPath()
    @State private var query = ""
    @State private var suggestions: [Suggestion] = []
    @State private var niches: [Niche] = []
    @State private var nichePage = 1
    @State private var nichePages = Int.max
    @State private var loadingNiches = false
    @State private var trendingTags: [TagCount] = []

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                if query.trimmingCharacters(in: .whitespaces).isEmpty {
                    browse
                } else {
                    searchResults
                }
            }
            .background(Color.black)
            .navigationTitle("Discover")
            .searchable(text: $query, prompt: "Search tags, creators…")
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .onSubmit(of: .search) {
                let q = query.trimmingCharacters(in: .whitespaces)
                if !q.isEmpty { path.append(Route.tag(q)) }
            }
            .task(id: query) {
                let q = query.trimmingCharacters(in: .whitespaces)
                guard !q.isEmpty else { suggestions = []; return }
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                suggestions = (try? await RedGifsAPI.shared.suggest(q)) ?? []
            }
            .task {
                if trendingTags.isEmpty {
                    trendingTags = (try? await RedGifsAPI.shared.trendingTags().tags) ?? []
                }
                if niches.isEmpty { await loadNiches() }
            }
            .withRoutes()
        }
    }

    private var browse: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !store.data.joinedNiches.isEmpty {
                sectionTitle("Your categories")
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(store.data.joinedNiches) { n in
                            NavigationLink(value: Route.niche(id: n.id, name: n.name)) {
                                NicheTile(niche: n).frame(width: 150)
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }

            if !trendingTags.isEmpty {
                sectionTitle("Trending tags")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHGrid(rows: [GridItem(.fixed(34)), GridItem(.fixed(34))], spacing: 8) {
                        ForEach(trendingTags, id: \.self) { t in
                            NavigationLink(value: Route.tag(t.name)) {
                                Text("#\(t.name)")
                                    .font(.subheadline.bold())
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .background(Color.white.opacity(0.12), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
            }

            sectionTitle("Categories")
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(niches) { n in
                    NavigationLink(value: Route.niche(id: n.id, name: n.name)) {
                        NicheTile(niche: n)
                    }
                    .onAppear {
                        if n.id == niches.last?.id { Task { await loadNiches() } }
                    }
                }
            }
            .padding(.horizontal)
            if loadingNiches { ProgressView().frame(maxWidth: .infinity).padding() }
        }
        .padding(.vertical)
        .foregroundStyle(.white)
    }

    private var searchResults: some View {
        let q = query.trimmingCharacters(in: .whitespaces)
        return LazyVStack(alignment: .leading, spacing: 0) {
            NavigationLink(value: Route.tag(q)) {
                row(icon: "magnifyingglass", title: "Search \"\(q)\"", subtitle: nil)
            }
            NavigationLink(value: Route.creator(q.replacingOccurrences(of: "@", with: ""))) {
                row(icon: "person.crop.circle", title: "Creator @\(q.replacingOccurrences(of: "@", with: ""))", subtitle: nil)
            }
            ForEach(suggestions, id: \.self) { s in
                NavigationLink(value: route(for: s)) {
                    row(icon: isUser(s) ? "person.fill" : "number",
                        title: s.text,
                        subtitle: s.gifs.map { "\(shortCount($0)) posts" })
                }
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    private func isUser(_ s: Suggestion) -> Bool {
        let t = (s.type ?? "").lowercased()
        return t == "user" || t == "creator" || t == "users"
    }

    private func route(for s: Suggestion) -> Route {
        isUser(s) ? .creator(s.text) : .tag(s.text)
    }

    private func row(icon: String, title: String, subtitle: String?) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).frame(width: 28).foregroundStyle(.pink)
            VStack(alignment: .leading) {
                Text(title).font(.body)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal).padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func sectionTitle(_ s: String) -> some View {
        Text(s).font(.title3.bold()).padding(.horizontal)
    }

    private func loadNiches() async {
        guard !loadingNiches, nichePage <= nichePages else { return }
        loadingNiches = true
        defer { loadingNiches = false }
        if let p = try? await RedGifsAPI.shared.niches(page: nichePage) {
            nichePages = p.pages
            nichePage += 1
            let existing = Set(niches.map(\.id))
            niches += p.niches.filter { !existing.contains($0.id) }
        }
    }
}

struct NicheTile: View {
    let niche: Niche

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.white.opacity(0.08)
            AsyncImage(url: URL(string: niche.thumbnail ?? niche.cover ?? "")) { phase in
                if let img = phase.image { img.resizable().aspectRatio(contentMode: .fill) } else { Color.clear }
            }
            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 2) {
                Text(niche.name).font(.subheadline.bold()).lineLimit(1)
                if let g = niche.gifs {
                    Text("\(shortCount(g)) posts").font(.caption2).foregroundStyle(.white.opacity(0.75))
                }
            }
            .padding(10)
        }
        .frame(height: 110)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .foregroundStyle(.white)
    }
}

// MARK: - Tag / Niche / List feeds

struct TagFeedScreen: View {
    let tag: String
    @State private var order = "top"

    var body: some View {
        TagFeedInner(tag: tag, order: order)
            .id(order)
            .navigationTitle("#\(tag)")
            .clearNavBar()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Sort", selection: $order) {
                            Text("Top").tag("top")
                            Text("Latest").tag("latest")
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
            }
    }
}

private struct TagFeedInner: View {
    @StateObject private var model: FeedModel
    init(tag: String, order: String) {
        _model = StateObject(wrappedValue: FeedModel(source: .tag(tag, order: order)))
    }
    var body: some View { FeedView(model: model) }
}

struct NicheScreen: View {
    let id: String
    let name: String
    @EnvironmentObject var store: UserStore
    @State private var order: String = "hot"

    var body: some View {
        NicheFeedInner(id: id, order: order == "hot" ? nil : order)
            .id(order)
            .navigationTitle(name)
            .clearNavBar()
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(store.isJoined(id) ? "Joined" : "Join") {
                        store.toggleJoin(Niche(id: id, name: name))
                    }
                    .font(.subheadline.bold())
                    Menu {
                        Picker("Sort", selection: $order) {
                            Text("Hot").tag("hot")
                            Text("New").tag("new")
                            Text("Top").tag("top")
                        }
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                    }
                }
            }
    }
}

private struct NicheFeedInner: View {
    @StateObject private var model: FeedModel
    init(id: String, order: String?) {
        _model = StateObject(wrappedValue: FeedModel(source: .niche(id, order: order)))
    }
    var body: some View { FeedView(model: model) }
}

struct ListFeedScreen: View {
    @StateObject private var model: FeedModel
    private let start: String

    init(items: [Gif], start: String) {
        _model = StateObject(wrappedValue: FeedModel(source: .list, items: items))
        self.start = start
    }

    var body: some View {
        FeedView(model: model, initialID: start)
            .clearNavBar()
    }
}

// MARK: - Creator profile

struct CreatorView: View {
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
            header
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(model.items) { g in
                    NavigationLink {
                        FeedView(model: model, initialID: g.id).clearNavBar()
                    } label: {
                        GridThumb(gif: g)
                    }
                    .onAppear { model.onItemAppear(g) }
                }
            }
            if model.isLoading {
                ProgressView().padding()
            } else if let err = model.errorText {
                VStack {
                    Text(model.items.isEmpty ? "Creator not found or unavailable." : err).foregroundStyle(.secondary)
                    Button("Retry") { Task { await model.loadMore() } }
                }
                .padding()
            }
        }
        .background(Color.black)
        .navigationTitle("@\(username)")
        .navigationBarTitleDisplayMode(.inline)
        .task { if model.items.isEmpty { await model.loadMore() } }
    }

    private var header: some View {
        let u = model.user
        let following = store.isFollowing(username)
        return VStack(spacing: 10) {
            AsyncImage(url: URL(string: u?.profileImageUrl ?? "")) { phase in
                if let img = phase.image {
                    img.resizable().aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(colors: [.pink, .purple], startPoint: .top, endPoint: .bottom)
                        .overlay(Text(String(username.prefix(1)).uppercased()).font(.largeTitle.bold()))
                }
            }
            .frame(width: 92, height: 92)
            .clipShape(Circle())

            HStack(spacing: 4) {
                Text(u?.name ?? username).font(.title3.bold())
                if u?.verified == true { Image(systemName: "checkmark.seal.fill").foregroundStyle(.cyan) }
            }
            HStack(spacing: 30) {
                stat(shortCount(u?.followers), "Followers")
                stat(shortCount(u?.gifs ?? (model.items.isEmpty ? nil : model.items.count)), "Posts")
                stat(shortCount(u?.views), "Views")
            }
            Button {
                store.toggleFollow(username, user: model.user)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                Text(following ? "Following" : "Follow")
                    .bold()
                    .frame(width: 180).padding(.vertical, 10)
                    .background(following ? Color.white.opacity(0.15) : Color.pink, in: RoundedRectangle(cornerRadius: 8))
            }
            if let d = u?.description, !d.isEmpty {
                Text(d).font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).lineLimit(4).padding(.horizontal)
            }
        }
        .foregroundStyle(.white)
        .padding(.vertical)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct GridThumb: View {
    let gif: Gif

    var body: some View {
        Color.white.opacity(0.06)
            .aspectRatio(9.0 / 16.0, contentMode: .fit)
            .overlay(
                AsyncImage(url: gif.thumbURL) { phase in
                    if let img = phase.image { img.resizable().aspectRatio(contentMode: .fill) } else { Color.clear }
                }
            )
            .clipped()
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 3) {
                    Image(systemName: "play.fill")
                    Text(shortCount(gif.views))
                }
                .font(.caption2.bold())
                .foregroundStyle(.white)
                .shadow(radius: 2)
                .padding(5)
            }
            .contentShape(Rectangle())
    }
}

// MARK: - Me

struct MeView: View {
    @EnvironmentObject var store: UserStore
    @State private var section = 0
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    Circle()
                        .fill(LinearGradient(colors: [.pink, .purple], startPoint: .top, endPoint: .bottom))
                        .frame(width: 84, height: 84)
                        .overlay(Image(systemName: "lock.fill").font(.title))
                    Text("Private profile").font(.title3.bold())
                    HStack(spacing: 30) {
                        stat(store.data.liked.count, "Likes")
                        stat(store.data.following.count, "Following")
                        stat(store.data.joinedNiches.count, "Categories")
                    }
                    Picker("", selection: $section) {
                        Image(systemName: "heart.fill").tag(0)
                        Image(systemName: "person.2.fill").tag(1)
                        Image(systemName: "square.grid.2x2.fill").tag(2)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                }
                .foregroundStyle(.white)
                .padding(.vertical)

                switch section {
                case 0: likedGrid
                case 1: followingList
                default: categoriesGrid
                }
            }
            .background(Color.black)
            .navigationTitle("Me")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink { SettingsView() } label: { Image(systemName: "gearshape.fill") }
                }
            }
            .withRoutes()
        }
    }

    private var likedGrid: some View {
        Group {
            if store.data.liked.isEmpty {
                empty("No likes yet", "Double-tap a video to like it.")
            } else {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(store.data.liked) { g in
                        NavigationLink(value: Route.list(items: store.data.liked, start: g.id)) {
                            GridThumb(gif: g)
                        }
                    }
                }
            }
        }
    }

    private var followingList: some View {
        Group {
            if store.data.following.isEmpty {
                empty("Not following anyone", "Tap + on a creator to follow them.")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(store.data.following) { u in
                        HStack {
                            NavigationLink(value: Route.creator(u.username)) {
                                HStack(spacing: 12) {
                                    Circle()
                                        .fill(LinearGradient(colors: [.pink, .purple], startPoint: .top, endPoint: .bottom))
                                        .frame(width: 44, height: 44)
                                        .overlay(Text(String(u.username.prefix(1)).uppercased()).bold())
                                    VStack(alignment: .leading) {
                                        Text(u.name ?? u.username).bold()
                                        Text("@\(u.username)").font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Button("Unfollow") { store.toggleFollow(u.username) }
                                .font(.caption.bold())
                                .buttonStyle(.bordered)
                        }
                        .padding(.horizontal).padding(.vertical, 8)
                    }
                }
                .foregroundStyle(.white)
            }
        }
    }

    private var categoriesGrid: some View {
        Group {
            if store.data.joinedNiches.isEmpty {
                empty("No categories", "Join categories from Discover.")
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(store.data.joinedNiches) { n in
                        NavigationLink(value: Route.niche(id: n.id, name: n.name)) { NicheTile(niche: n) }
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func empty(_ title: String, _ sub: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.headline)
            Text(sub).font(.subheadline).foregroundStyle(.secondary)
        }
        .foregroundStyle(.white)
        .padding(.top, 50)
    }

    private func stat(_ n: Int, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text("\(n)").font(.headline)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var store: UserStore
    @EnvironmentObject var app: AppState
    @State private var changingPasscode = false
    @State private var confirmReset = false
    @State private var confirmErase = false

    var body: some View {
        Form {
            Section("Playback") {
                Toggle("HD video (uses more data)", isOn: $store.data.settings.hd)
                Toggle("Muted", isOn: $store.data.settings.muted)
            }

            Section("Security") {
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
                Button("Change passcode") { changingPasscode = true }
                Button("Lock now") { app.lock() }
            }

            Section {
                let top = store.topTags(8).map(\.0)
                Text(top.isEmpty ? "Still learning what you like…" : top.joined(separator: ", "))
                    .font(.footnote).foregroundStyle(.secondary)
                Button("Reset recommendations", role: .destructive) { confirmReset = true }
            } header: {
                Text("Your top interests")
            }

            Section {
                Button("Erase all data", role: .destructive) { confirmErase = true }
            } footer: {
                Text("Content comes from RedGIFs' public API. Your passcode, likes, follows and interests are stored only on this device.")
            }
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $changingPasscode) {
            PasscodeSetupView(mode: .change)
        }
        .confirmationDialog("Reset recommendations?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { store.resetAlgorithm() }
        }
        .confirmationDialog("Erase everything?", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("Erase all data", role: .destructive) { app.eraseEverything() }
        } message: {
            Text("Deletes your passcode, likes, follows and settings.")
        }
    }
}

