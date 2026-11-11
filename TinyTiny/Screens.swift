import SwiftUI

// MARK: - 1. Browse / Search / Categories Fullscreen Overlay (Screenshot 3 Exact Clone + Personal X)

struct GoonedBrowseOverlay: View {
    var onClose: () -> Void
    var onSelectFeed: (FeedSource) -> Void
    var onConnectX: () -> Void

    @EnvironmentObject var store: UserStore
    @State private var query = ""
    @State private var searchResults = GoonedSearchResponsePlaceholder()
    @State private var isSearching = false

    struct GoonedSearchResponsePlaceholder {
        var subreddits: [GoonedSearchItem] = []
        var users: [GoonedSearchItem] = []
    }

    private var featuredCategories: [GoonedCategory] {
        GoonedCategory.featuredNames.compactMap { name in
            store.categories.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
    }

    private var azCategories: [GoonedCategory] {
        let featuredSet = Set(GoonedCategory.featuredNames.map { $0.lowercased() })
        return store.categories
            .filter { !featuredSet.contains($0.name.lowercased()) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var matchingCategories: [GoonedCategory] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        return store.categories.filter {
            $0.displayName.localizedCaseInsensitiveContains(q) ||
            $0.subreddits.contains(where: { $0.localizedCaseInsensitiveContains(q) })
        }
    }

    var body: some View {
        ZStack {
            Theme.modalGradient.ignoresSafeArea()

            VStack(spacing: 14) {
                // Top Search Bar + X Close Circle
                HStack(spacing: 10) {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.55))

                        TextField("Search subreddits, categories, or 𝕏", text: $query)
                            .font(.system(size: 16))
                            .foregroundStyle(.white)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .submitLabel(.search)
                            .onSubmit {
                                let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !clean.isEmpty else { return }
                                if clean.hasPrefix("@") {
                                    onSelectFeed(.xUser(clean.replacingOccurrences(of: "@", with: "")))
                                } else if let cat = matchingCategories.first {
                                    onSelectFeed(.category(cat.name))
                                } else {
                                    onSelectFeed(.subreddit(clean.replacingOccurrences(of: "r/", with: "")))
                                }
                            }

                        if !query.isEmpty {
                            Button { query = "" } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 46)
                    .liquidGlassCapsule()

                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 46, height: 46)
                            .liquidGlassCircle()
                    }
                    .buttonStyle(ScalePressButtonStyle())
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)

                ScrollView(.vertical, showsIndicators: false) {
                    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        defaultBrowseContent
                    } else {
                        liveSearchResultsContent
                    }
                }
            }
        }
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else {
                searchResults = GoonedSearchResponsePlaceholder()
                return
            }
            isSearching = true
            try? await Task.sleep(nanoseconds: 200_000_000)
            guard !Task.isCancelled else { return }
            if let res = try? await GoonedAPI.shared.search(q) {
                searchResults = GoonedSearchResponsePlaceholder(subreddits: res.subreddits, users: res.users)
            }
            isSearching = false
        }
    }

    // MARK: - Default Browse Content (Pick Up Where You Left Off + Personal X + Featured Bento + A-Z Chips)

    private var defaultBrowseContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            // PICK UP WHERE YOU LEFT OFF
            VStack(alignment: .leading, spacing: 8) {
                Text("PICK UP WHERE YOU LEFT OFF")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 18)

                let recent = store.data.recentFeeds.first
                Button {
                    if let recent {
                        switch recent.kind {
                        case "category": onSelectFeed(.category(recent.name))
                        case "subreddit": onSelectFeed(.subreddit(recent.name))
                        case "user": onSelectFeed(.user(recent.name))
                        case "xforyou": onSelectFeed(.xForYou)
                        case "xfollowing": onSelectFeed(.xFollowing)
                        case "xbookmarks": onSelectFeed(.xBookmarks)
                        case "xlikes": onSelectFeed(.xLikes)
                        case "xsearch": onSelectFeed(.xSearch(recent.name))
                        case "xuser": onSelectFeed(.xUser(recent.name))
                        default: onSelectFeed(.forYou)
                        }
                    } else {
                        onSelectFeed(.forYou)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(recent?.displayTitle ?? "For You")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)

                        Text("\(max(recent?.swipedCount ?? store.data.swipedTotal, 1)) SWIPED  ·  NOW")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.60))

                        // Progress Bar
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.16))
                                Capsule().fill(Theme.accentBright)
                                    .frame(width: max(32, min(geo.size.width, geo.size.width * 0.25)))
                            }
                        }
                        .frame(height: 3)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .liquidGlassCard(cornerRadius: 20)
                }
                .buttonStyle(ScalePressButtonStyle())
                .padding(.horizontal, 16)
            }

            // PERSONAL X (TWITTER) SECTION
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("PERSONAL 𝕏")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.55))
                    Spacer()
                    if store.data.xSession.isConnected {
                        let sn = store.data.xSession.screenName
                        Text(sn.isEmpty ? "CONNECTED" : "@\(sn.uppercased())")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .tracking(1.0)
                            .foregroundStyle(Theme.accentBright)
                    }
                }
                .padding(.horizontal, 18)

                if store.data.xSession.isConnected {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        xQuickCard(title: "𝕏 For You", subtitle: "Home video feed", icon: "sparkles") {
                            onSelectFeed(.xForYou)
                        }
                        xQuickCard(title: "𝕏 Following", subtitle: "Creators you follow", icon: "person.2.fill") {
                            onSelectFeed(.xFollowing)
                        }
                        xQuickCard(title: "𝕏 Bookmarks", subtitle: "Your saved X videos", icon: "bookmark.fill") {
                            onSelectFeed(.xBookmarks)
                        }
                        xQuickCard(title: "𝕏 Likes", subtitle: "Videos you liked on X", icon: "heart.fill") {
                            onSelectFeed(.xLikes)
                        }
                    }
                    .padding(.horizontal, 16)
                } else {
                    Button(action: onConnectX) {
                        HStack(spacing: 14) {
                            ZStack {
                                Circle()
                                    .fill(Color.black.opacity(0.55))
                                    .frame(width: 44, height: 44)
                                    .overlay(Circle().stroke(Color.white.opacity(0.28), lineWidth: 1))
                                Text("𝕏")
                                    .font(.system(size: 20, weight: .black))
                                    .foregroundStyle(.white)
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Connect Personal X")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(.white)
                                Text("Stream your X For You, Following, Bookmarks & 18+ creators")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.68))
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        .padding(14)
                        .liquidGlassCard(cornerRadius: 20)
                    }
                    .buttonStyle(ScalePressButtonStyle())
                    .padding(.horizontal, 16)
                }
            }

            // BROWSE — 50 CATEGORIES
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("BROWSE")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.55))
                    Spacer()
                    Text("\(store.categories.count) CATEGORIES")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.45))
                }
                .padding(.horizontal, 18)

                // Hero Card: Gooning
                if let hero = featuredCategories.first(where: { $0.name == "Gooning" }) ?? store.categories.first {
                    Button {
                        onSelectFeed(.category(hero.name))
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(hero.displayName)
                                    .font(.system(size: 28, weight: .heavy))
                                    .foregroundStyle(.white)

                                subscriberBadge(hero.subscribers)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.65))
                        }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .liquidGlassCard(cornerRadius: 24)
                    }
                    .buttonStyle(ScalePressButtonStyle())
                    .padding(.horizontal, 16)
                }

                // 2x2 Grid for TikTok, OnlyFans, Snapchat, Videos
                let gridTiles: [GoonedCategory] = [
                    store.categories.first { $0.name == "TikTok" },
                    store.categories.first { $0.name == "OnlyFans" },
                    store.categories.first { $0.name == "Snapchat" },
                    store.categories.first { $0.name == "Videos" }
                ].compactMap { $0 }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(gridTiles) { tile in
                        Button {
                            onSelectFeed(.category(tile.name))
                        } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                Text(tile.displayName)
                                    .font(.system(size: 22, weight: .bold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)

                                subscriberBadge(tile.subscribers)
                            }
                            .padding(18)
                            .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
                            .liquidGlassCard(cornerRadius: 22)
                        }
                        .buttonStyle(ScalePressButtonStyle())
                    }
                }
                .padding(.horizontal, 16)
            }

            // Divider: A-Z · 46 MORE
            HStack(spacing: 12) {
                Rectangle().fill(Color.white.opacity(0.14)).frame(height: 1)
                Text("A–Z  ·  \(azCategories.count) MORE")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.50))
                    .fixedSize()
                Rectangle().fill(Color.white.opacity(0.14)).frame(height: 1)
            }
            .padding(.horizontal, 18)
            .padding(.top, 4)

            // A-Z Wrapping Pill Grid
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 98), spacing: 8)], spacing: 8) {
                ForEach(azCategories) { cat in
                    Button {
                        onSelectFeed(.category(cat.name))
                    } label: {
                        Text(cat.displayName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 11)
                            .frame(maxWidth: .infinity)
                            .liquidGlassCapsule()
                    }
                    .buttonStyle(ScalePressButtonStyle())
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 40)
        }
    }

    private func xQuickCard(title: String, subtitle: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.accentBright)
                    .frame(width: 30, height: 30)
                    .background(Color.black.opacity(0.35), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.62))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .liquidGlassCard(cornerRadius: 16)
        }
        .buttonStyle(ScalePressButtonStyle())
    }

    private func subscriberBadge(_ count: Int) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "person.2")
                .font(.system(size: 10, weight: .bold))
            Text(shortCount(count))
                .font(.system(size: 12, weight: .bold))
        }
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.28), in: Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.2), lineWidth: 0.7))
    }

    // MARK: - Live Search Results Content (X Search + X Creator + Categories + Subreddits + Users)

    private var liveSearchResultsContent: some View {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "r/", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "u/", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "@", with: "")

        return VStack(alignment: .leading, spacing: 14) {
            // Direct Actions: Open r/<query>, Search X Videos, Open @<query> on X
            VStack(spacing: 8) {
                Button {
                    onSelectFeed(.subreddit(clean))
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "arrow.up.right.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Theme.accentBright)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Open r/\(clean)")
                                .font(.system(size: 15, weight: .bold))
                            Text("Go directly to subreddit feed")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.65))
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.bold())
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(13)
                    .liquidGlassCard(cornerRadius: 18)
                }
                .buttonStyle(ScalePressButtonStyle())

                Button {
                    onSelectFeed(.xSearch(clean))
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.black.opacity(0.6))
                                .frame(width: 28, height: 28)
                            Text("𝕏")
                                .font(.system(size: 14, weight: .black))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Search \"\(clean)\" Videos on 𝕏")
                                .font(.system(size: 15, weight: .bold))
                            Text("Stream 18+ video results from X.com")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.65))
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.bold())
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(13)
                    .liquidGlassCard(cornerRadius: 18)
                }
                .buttonStyle(ScalePressButtonStyle())

                Button {
                    onSelectFeed(.xUser(clean))
                } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.black.opacity(0.6))
                                .frame(width: 28, height: 28)
                            Text("@")
                                .font(.system(size: 14, weight: .black))
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Open @\(clean) on 𝕏")
                                .font(.system(size: 15, weight: .bold))
                            Text("Watch creator's X video & media timeline")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.65))
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.bold())
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(13)
                    .liquidGlassCard(cornerRadius: 18)
                }
                .buttonStyle(ScalePressButtonStyle())
            }

            // Matching Categories
            if !matchingCategories.isEmpty {
                Text("CATEGORIES")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 4)

                ForEach(matchingCategories) { cat in
                    Button {
                        onSelectFeed(.category(cat.name))
                    } label: {
                        HStack {
                            Text(cat.displayName)
                                .font(.system(size: 16, weight: .bold))
                            Spacer()
                            subscriberBadge(cat.subscribers)
                        }
                        .padding(14)
                        .liquidGlassCard(cornerRadius: 16)
                    }
                    .buttonStyle(ScalePressButtonStyle())
                }
            }

            // Subreddits from api.gooned.app/reddit/search
            if !searchResults.subreddits.isEmpty {
                Text("SUBREDDITS")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 4)

                ForEach(searchResults.subreddits) { sub in
                    Button {
                        onSelectFeed(.subreddit(sub.name))
                    } label: {
                        HStack(spacing: 12) {
                            AsyncImage(url: URL(string: sub.iconUrl ?? "")) { phase in
                                if let img = phase.image {
                                    img.resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    Circle()
                                        .fill(Theme.accent.opacity(0.45))
                                        .overlay(Text("r/").font(.system(size: 12, weight: .black)))
                                }
                            }
                            .frame(width: 36, height: 36)
                            .clipShape(Circle())

                            VStack(alignment: .leading, spacing: 2) {
                                Text("r/\(sub.name)")
                                    .font(.system(size: 15, weight: .bold))
                                if let subs = sub.subscribers {
                                    Text("\(shortCount(subs)) subscribers")
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.65))
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.bold())
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        .padding(12)
                        .liquidGlassCard(cornerRadius: 16)
                    }
                    .buttonStyle(ScalePressButtonStyle())
                }
            }

            // Users from api.gooned.app/reddit/search
            if !searchResults.users.isEmpty {
                Text("REDDIT USERS")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 4)

                ForEach(searchResults.users) { u in
                    Button {
                        onSelectFeed(.user(u.name))
                    } label: {
                        HStack(spacing: 12) {
                            Circle()
                                .fill(Color.white.opacity(0.18))
                                .frame(width: 36, height: 36)
                                .overlay(Text("u/").font(.system(size: 12, weight: .black)))
                            Text("u/\(u.name)")
                                .font(.system(size: 15, weight: .bold))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.bold())
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        .padding(12)
                        .liquidGlassCard(cornerRadius: 16)
                    }
                    .buttonStyle(ScalePressButtonStyle())
                }
            }

            if isSearching {
                HStack {
                    Spacer()
                    ProgressView().tint(.white)
                    Spacer()
                }
                .padding(.top, 12)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.bottom, 40)
    }
}

// MARK: - 2. Likes / Stash Screen (Screenshot 2 Exact Clone)

struct GoonedLikesView: View {
    var onOpenSettings: () -> Void
    var onStartStash: () -> Void
    var onPlayLikedPost: (Gif) -> Void

    @EnvironmentObject var store: UserStore
    @State private var filter: String = "all" // "all", "videos", "gifs", "images"
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    private var filteredLikes: [Gif] {
        switch filter {
        case "videos":
            return store.data.liked.filter { !$0.isImage && $0.mediaType != "gif" }
        case "gifs":
            return store.data.liked.filter { $0.mediaType == "gif" }
        case "images":
            return store.data.liked.filter { $0.isImage }
        default:
            return store.data.liked
        }
    }

    var body: some View {
        ZStack {
            Theme.crimsonBg.ignoresSafeArea()

            VStack(spacing: 0) {
                // Top Bar with Gear on Right
                HStack {
                    if !store.data.liked.isEmpty {
                        HStack(spacing: 6) {
                            ForEach([("all", "All"), ("videos", "Videos"), ("images", "Images")], id: \.0) { id, label in
                                Button {
                                    filter = id
                                } label: {
                                    Text(label)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 7)
                                        .liquidGlassCapsule(active: filter == id)
                                }
                            }
                        }
                    }
                    Spacer()
                    Button(action: onOpenSettings) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 42, height: 42)
                            .liquidGlassCircle()
                    }
                    .buttonStyle(ScalePressButtonStyle())
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)

                if filteredLikes.isEmpty {
                    // Exact Screenshot 2 Empty State
                    Spacer()
                    VStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(Color(red: 0.42, green: 0.10, blue: 0.20).opacity(0.85))
                                .frame(width: 68, height: 68)
                                .overlay(Circle().stroke(Color.white.opacity(0.22), lineWidth: 1))
                            Image(systemName: "heart.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(.white)
                        }

                        Text("No liked posts yet")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)

                        Text("Double-tap a post to save it here.")
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.72))

                        Button(action: onStartStash) {
                            Text("Start your stash")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 28)
                                .padding(.vertical, 13)
                                .liquidGlassCapsule()
                        }
                        .buttonStyle(ScalePressButtonStyle())
                        .padding(.top, 4)
                    }
                    Spacer()
                    Spacer().frame(height: 76)
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVGrid(columns: columns, spacing: 2) {
                            ForEach(filteredLikes) { post in
                                Button {
                                    onPlayLikedPost(post)
                                } label: {
                                    GridThumb(gif: post)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.top, 12)
                        .padding(.bottom, 92)
                    }
                }
            }
        }
    }
}

struct GridThumb: View {
    let gif: Gif

    var body: some View {
        Color(red: 0.25, green: 0.06, blue: 0.14)
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
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 4) {
                    if gif.isXPost {
                        Text("𝕏")
                            .font(.system(size: 10, weight: .black))
                    } else {
                        Image(systemName: gif.isImage ? "photo" : "play.fill")
                    }
                    Text(shortCount(gif.upvotes))
                }
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.6), radius: 2)
                .padding(6)
            }
            .contentShape(Rectangle())
    }
}

// MARK: - 3. Profile / Follows View (Subreddits, Reddit Creators & Personal X)

struct GoonedFollowsView: View {
    var onOpenSettings: () -> Void
    var onSelectFeed: (FeedSource) -> Void
    var onConnectX: () -> Void

    @EnvironmentObject var store: UserStore
    @EnvironmentObject var app: AppState

    private var hasAnyFollows: Bool {
        !store.data.followedSubreddits.isEmpty ||
        !store.data.followedUsers.isEmpty ||
        !store.data.followedXUsers.isEmpty
    }

    var body: some View {
        ZStack {
            Theme.crimsonBg.ignoresSafeArea()

            VStack(spacing: 14) {
                HStack {
                    Text("Following")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                    Spacer()
                    Button {
                        app.lock()
                    } label: {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 42, height: 42)
                            .liquidGlassCircle()
                    }
                    Button(action: onOpenSettings) {
                        Image(systemName: "gearshape")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 42, height: 42)
                            .liquidGlassCircle()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 14) {
                        // Personal X Account Card
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(Color.black.opacity(0.6))
                                        .frame(width: 42, height: 42)
                                        .overlay(Circle().stroke(Color.white.opacity(0.28), lineWidth: 1))
                                    Text("𝕏")
                                        .font(.system(size: 19, weight: .black))
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    if store.data.xSession.isConnected {
                                        let sn = store.data.xSession.screenName
                                        Text(sn.isEmpty ? "Personal X Connected" : "@\(sn)")
                                            .font(.system(size: 16, weight: .bold))
                                        Text("Streaming personal X timeline & 18+ media")
                                            .font(.caption)
                                            .foregroundStyle(.white.opacity(0.68))
                                    } else {
                                        Text("Personal X Account")
                                            .font(.system(size: 16, weight: .bold))
                                        Text("Connect your X to watch For You & Bookmarks")
                                            .font(.caption)
                                            .foregroundStyle(.white.opacity(0.68))
                                    }
                                }
                                Spacer()
                                if !store.data.xSession.isConnected {
                                    Button(action: onConnectX) {
                                        Text("Connect")
                                            .font(.subheadline.bold())
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 8)
                                            .liquidGlassCapsule(active: true)
                                    }
                                }
                            }

                            if store.data.xSession.isConnected {
                                HStack(spacing: 8) {
                                    Button {
                                        onSelectFeed(.xForYou)
                                    } label: {
                                        Text("𝕏 For You")
                                            .font(.caption.bold())
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 9)
                                            .liquidGlassCapsule(active: true)
                                    }
                                    Button {
                                        onSelectFeed(.xFollowing)
                                    } label: {
                                        Text("𝕏 Following")
                                            .font(.caption.bold())
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 9)
                                            .liquidGlassCapsule()
                                    }
                                    Button {
                                        onSelectFeed(.xBookmarks)
                                    } label: {
                                        Text("𝕏 Saved")
                                            .font(.caption.bold())
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 9)
                                            .liquidGlassCapsule()
                                    }
                                }
                            }
                        }
                        .padding(14)
                        .liquidGlassCard(cornerRadius: 20)

                        if !hasAnyFollows {
                            VStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(Color(red: 0.42, green: 0.10, blue: 0.20).opacity(0.85))
                                        .frame(width: 64, height: 64)
                                        .overlay(Circle().stroke(Color.white.opacity(0.22), lineWidth: 1))
                                    Image(systemName: "person.badge.plus")
                                        .font(.system(size: 24))
                                        .foregroundStyle(.white)
                                }
                                Text("No follows yet")
                                    .font(.system(size: 19, weight: .bold))
                                    .foregroundStyle(.white)
                                Text("Tap + on any video to follow its subreddit, Reddit creator, or 𝕏 creator.")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.white.opacity(0.72))
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 32)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 48)
                        } else {
                            if !store.data.followedXUsers.isEmpty {
                                Text("𝕏 CREATORS")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.6))
                                    .padding(.horizontal, 4)

                                ForEach(store.data.followedXUsers, id: \.self) { handle in
                                    HStack {
                                        Button {
                                            onSelectFeed(.xUser(handle))
                                        } label: {
                                            HStack(spacing: 10) {
                                                Circle()
                                                    .fill(Color.black.opacity(0.55))
                                                    .frame(width: 36, height: 36)
                                                    .overlay(Text("𝕏").font(.system(size: 13, weight: .black)))
                                                Text("@\(handle)")
                                                    .font(.system(size: 16, weight: .bold))
                                                Spacer()
                                            }
                                        }
                                        Button {
                                            store.toggleFollowXUser(handle)
                                        } label: {
                                            Text("Unfollow")
                                                .font(.caption.bold())
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 6)
                                                .liquidGlassCapsule()
                                        }
                                    }
                                    .padding(12)
                                    .liquidGlassCard(cornerRadius: 16)
                                }
                            }

                            if !store.data.followedSubreddits.isEmpty {
                                Text("SUBREDDITS")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.6))
                                    .padding(.horizontal, 4)

                                ForEach(store.data.followedSubreddits, id: \.self) { sub in
                                    HStack {
                                        Button {
                                            onSelectFeed(.subreddit(sub))
                                        } label: {
                                            HStack(spacing: 10) {
                                                Circle()
                                                    .fill(Theme.accent.opacity(0.5))
                                                    .frame(width: 36, height: 36)
                                                    .overlay(Text("r/").font(.system(size: 12, weight: .black)))
                                                Text("r/\(sub)")
                                                    .font(.system(size: 16, weight: .bold))
                                                Spacer()
                                            }
                                        }
                                        Button {
                                            store.toggleFollowSubreddit(sub)
                                        } label: {
                                            Text("Unfollow")
                                                .font(.caption.bold())
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 6)
                                                .liquidGlassCapsule()
                                        }
                                    }
                                    .padding(12)
                                    .liquidGlassCard(cornerRadius: 16)
                                }
                            }

                            if !store.data.followedUsers.isEmpty {
                                Text("REDDIT CREATORS")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.6))
                                    .padding(.horizontal, 4)
                                    .padding(.top, 4)

                                ForEach(store.data.followedUsers, id: \.self) { u in
                                    HStack {
                                        Button {
                                            onSelectFeed(.user(u))
                                        } label: {
                                            HStack(spacing: 10) {
                                                Circle()
                                                    .fill(Color.white.opacity(0.18))
                                                    .frame(width: 36, height: 36)
                                                    .overlay(Text("u/").font(.system(size: 12, weight: .black)))
                                                Text("u/\(u)")
                                                    .font(.system(size: 16, weight: .bold))
                                                Spacer()
                                            }
                                        }
                                        Button {
                                            store.toggleFollowUser(u)
                                        } label: {
                                            Text("Unfollow")
                                                .font(.caption.bold())
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 6)
                                                .liquidGlassCapsule()
                                        }
                                    }
                                    .padding(12)
                                    .liquidGlassCard(cornerRadius: 16)
                                }
                            }
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 92)
                }
            }
        }
    }
}

// MARK: - 4. Settings Modal (Screenshot 4 Exact Clone + Personal X Account Section)

struct GoonedSettingsModal: View {
    @Binding var isPresented: Bool
    var onConnectX: () -> Void
    @EnvironmentObject var store: UserStore
    @EnvironmentObject var app: AppState
    @State private var changingPasscode = false
    @State private var confirmErase = false

    private let delays = [3, 6, 10, 15]

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            VStack(spacing: 0) {
                // Header: Settings + X Circle
                HStack {
                    Text("Settings")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                    Spacer()
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 38, height: 38)
                            .liquidGlassCircle()
                    }
                    .buttonStyle(ScalePressButtonStyle())
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        // X.COM PERSONAL ACCOUNT
                        sectionHeader("𝕏 (TWITTER) ACCOUNT")

                        VStack(alignment: .leading, spacing: 12) {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(Color.black.opacity(0.6))
                                        .frame(width: 40, height: 40)
                                        .overlay(Circle().stroke(Color.white.opacity(0.28), lineWidth: 1))
                                    Text("𝕏")
                                        .font(.system(size: 18, weight: .black))
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    if store.data.xSession.isConnected {
                                        let sn = store.data.xSession.screenName
                                        Text(sn.isEmpty ? "Personal X Connected" : "Connected as @\(sn)")
                                            .font(.system(size: 16, weight: .bold))
                                        Text("Your personal X feed, search & bookmarks are active.")
                                            .font(.system(size: 12))
                                            .foregroundStyle(.white.opacity(0.68))
                                    } else {
                                        Text("Connect Personal X")
                                            .font(.system(size: 16, weight: .bold))
                                        Text("Sign in to stream your X For You, Following & 18+ videos.")
                                            .font(.system(size: 12))
                                            .foregroundStyle(.white.opacity(0.68))
                                    }
                                }
                                Spacer()
                            }

                            if store.data.xSession.isConnected {
                                Divider().overlay(Color.white.opacity(0.14))

                                HStack(spacing: 12) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Mix 𝕏 into For You")
                                            .font(.system(size: 15, weight: .bold))
                                        Text("Blend videos from your X timeline into the main For You feed.")
                                            .font(.system(size: 12))
                                            .foregroundStyle(.white.opacity(0.68))
                                    }
                                    Spacer()
                                    Toggle("", isOn: $store.data.xSession.mixIntoForYou)
                                        .labelsHidden()
                                        .tint(Theme.accent)
                                }

                                HStack(spacing: 10) {
                                    pillOption(title: "Reconnect 𝕏", active: false) {
                                        onConnectX()
                                    }
                                    pillOption(title: "Disconnect", active: false) {
                                        store.disconnectX()
                                    }
                                }
                            } else {
                                pillOption(title: "Sign in with Personal 𝕏", active: true) {
                                    onConnectX()
                                }
                            }
                        }
                        .padding(16)
                        .liquidGlassCard(cornerRadius: 20)

                        // AUTOPLAY
                        sectionHeader("AUTOPLAY")

                        VStack(alignment: .leading, spacing: 14) {
                            Text("Delay")
                                .font(.system(size: 16, weight: .bold))
                            Text("How long each post stays before the feed advances.")
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.68))

                            HStack(spacing: 8) {
                                ForEach(delays, id: \.self) { sec in
                                    let active = store.data.settings.autoScrollDelay == sec
                                    Button {
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        store.data.settings.autoScrollDelay = sec
                                    } label: {
                                        Text("\(sec)s")
                                            .font(.system(size: 15, weight: .bold))
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 12)
                                            .background(
                                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                    .fill(active ? Theme.accent : Color.white.opacity(0.10))
                                            )
                                            .overlay(
                                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                                    .stroke(Color.white.opacity(active ? 0.45 : 0.12), lineWidth: 1)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }

                            Divider().overlay(Color.white.opacity(0.14))

                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Play videos to the end")
                                        .font(.system(size: 16, weight: .bold))
                                    Text("Wait for the whole clip instead of using the delay.")
                                        .font(.system(size: 13))
                                        .foregroundStyle(.white.opacity(0.68))
                                }
                                Spacer()
                                Toggle("", isOn: $store.data.settings.playVideosToEnd)
                                    .labelsHidden()
                                    .tint(Theme.accent)
                            }
                        }
                        .padding(16)
                        .liquidGlassCard(cornerRadius: 20)

                        // VIDEO
                        sectionHeader("VIDEO")

                        VStack(alignment: .leading, spacing: 12) {
                            Text("Quality")
                                .font(.system(size: 16, weight: .bold))
                            Text("HD uses more data.")
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.68))

                            HStack(spacing: 10) {
                                pillOption(title: "SD", active: !store.data.settings.hd) {
                                    store.data.settings.hd = false
                                }
                                pillOption(title: "HD", active: store.data.settings.hd) {
                                    store.data.settings.hd = true
                                }
                            }
                        }
                        .padding(16)
                        .liquidGlassCard(cornerRadius: 20)

                        // APPEARANCE
                        sectionHeader("APPEARANCE")

                        VStack(alignment: .leading, spacing: 12) {
                            Text("Liquid Glass")
                                .font(.system(size: 16, weight: .bold))
                            Text("Tinted makes buttons and panels more solid and darkens the background.")
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.68))

                            HStack(spacing: 10) {
                                pillOption(title: "Clear", active: !store.data.settings.tintedGlass) {
                                    store.data.settings.tintedGlass = false
                                }
                                pillOption(title: "Tinted", active: store.data.settings.tintedGlass) {
                                    store.data.settings.tintedGlass = true
                                }
                            }
                        }
                        .padding(16)
                        .liquidGlassCard(cornerRadius: 20)

                        // VAULT SECURITY
                        sectionHeader("SECURITY")

                        VStack(alignment: .leading, spacing: 12) {
                            if Biometrics.available {
                                HStack {
                                    Text("Face ID Unlock")
                                        .font(.system(size: 15, weight: .bold))
                                    Spacer()
                                    Toggle("", isOn: Binding(
                                        get: { store.data.settings.faceID },
                                        set: { on in
                                            if on {
                                                Task { if await Biometrics.authenticate() { store.data.settings.faceID = true } }
                                            } else {
                                                store.data.settings.faceID = false
                                            }
                                        }
                                    ))
                                    .labelsHidden()
                                    .tint(Theme.accent)
                                }
                            }

                            HStack(spacing: 10) {
                                pillOption(title: "Change Passcode", active: false) {
                                    changingPasscode = true
                                }
                                pillOption(title: "Reset App", active: false) {
                                    confirmErase = true
                                }
                            }
                        }
                        .padding(16)
                        .liquidGlassCard(cornerRadius: 20)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                }
            }
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .fill(Theme.modalGradient)
                    .overlay(
                        RoundedRectangle(cornerRadius: 30, style: .continuous)
                            .stroke(Color.white.opacity(0.25), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 36)
        }
        .sheet(isPresented: $changingPasscode) {
            PasscodeSetupView(mode: .change)
        }
        .confirmationDialog("Erase all data and passcode?", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("Erase Everything", role: .destructive) {
                isPresented = false
                app.eraseEverything()
            }
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .tracking(1.2)
            .foregroundStyle(.white.opacity(0.55))
            .padding(.leading, 4)
    }

    private func pillOption(title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(active ? Theme.accent : Color.white.opacity(0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(active ? 0.45 : 0.12), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}
