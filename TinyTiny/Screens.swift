import SwiftUI

// MARK: - 1. Browse / Search / Categories / X / Instagram / Rule34 Fullscreen Overlay

struct GoonedBrowseOverlay: View {
    var onClose: () -> Void
    var onSelectFeed: (FeedSource) -> Void
    var onOpenPost: (Gif) -> Void = { _ in }
    var onConnectX: () -> Void
    var onConnectIG: () -> Void
    var onSetupR34Key: () -> Void

    enum SearchScope: String, CaseIterable {
        case all = "All"
        case of = "OnlyFans"
        case reddit = "Reddit"
        case rule34 = "Rule34"
        case x = "𝕏"
        case ig = "IG"
        case long = "Long"
    }

    @EnvironmentObject var store: UserStore
    @State private var query = ""
    @State private var searchScope: SearchScope = .all
    @State private var searchResults = GoonedSearchResponsePlaceholder()
    @State private var r34Suggestions: [Rule34TagSuggestion] = []
    @State private var ofCreators: [OFCreator] = []
    @State private var featuredOFCreators: [OFCreator] = []
    @State private var isSearching = false
    @State private var showReceiveDrop = false

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

                        TextField("Search OF creators, Reddit, 𝕏, IG, R34...", text: $query)
                            .font(.system(size: 16))
                            .foregroundStyle(.white)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .submitLabel(.search)
                            .onSubmit {
                                submitSearch()
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

                // Scope selector + Live Rule34 Multi-Tag Pills when typing
                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(SearchScope.allCases, id: \.self) { scope in
                                    let active = searchScope == scope
                                    Button {
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        searchScope = scope
                                    } label: {
                                        Text(scope.rawValue)
                                            .font(.system(size: 12.5, weight: active ? .bold : .medium))
                                            .foregroundStyle(active ? .white : .white.opacity(0.68))
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 6)
                                            .liquidGlassCapsule(tinted: true, active: active)
                                    }
                                    .buttonStyle(ScalePressButtonStyle())
                                }
                            }
                            .padding(.horizontal, 16)
                        }

                        let parsedTags = Rule34API.parseTags(query)
                        if (searchScope == .rule34 || searchScope == .all) && (!parsedTags.isEmpty && (parsedTags.count > 1 || query.contains("_") || query.hasPrefix("#"))) {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 6) {
                                    ForEach(parsedTags, id: \.self) { tag in
                                        Text("#\(tag)")
                                            .font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(Color(red: 0.72, green: 0.96, blue: 0.70))
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 5)
                                            .background(Color(red: 0.25, green: 0.45, blue: 0.25).opacity(0.45), in: Capsule())
                                            .overlay(Capsule().stroke(Color(red: 0.67, green: 0.90, blue: 0.64).opacity(0.45), lineWidth: 0.8))
                                    }
                                    Text("Space = new tag · _ = combine")
                                        .font(.system(size: 10.5))
                                        .foregroundStyle(.white.opacity(0.45))
                                }
                                .padding(.horizontal, 16)
                            }
                        }
                    }
                }

                ScrollView(.vertical, showsIndicators: false) {
                    if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        defaultBrowseContent
                    } else {
                        liveSearchResultsContent
                    }
                }
            }
        }
        .task {
            if featuredOFCreators.isEmpty {
                featuredOFCreators = await OnlyFansAPI.shared.topCreators(limit: 12)
            }
        }
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else {
                searchResults = GoonedSearchResponsePlaceholder()
                r34Suggestions = []
                ofCreators = []
                return
            }
            isSearching = true
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            async let redditTask = try? GoonedAPI.shared.search(q)
            async let r34Task = Rule34API.shared.autocomplete(q)
            async let ofTask = OnlyFansAPI.shared.searchCreators(q, limit: 25)
            let (redditRes, r34Res, ofRes) = await (redditTask, r34Task, ofTask)
            if let redditRes {
                searchResults = GoonedSearchResponsePlaceholder(subreddits: redditRes.subreddits, users: redditRes.users)
            }
            r34Suggestions = r34Res
            ofCreators = ofRes
            isSearching = false
        }
        .sheet(isPresented: $showReceiveDrop) {
            ReceiveDropSheet { post in
                showReceiveDrop = false
                onOpenPost(post)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Default Browse Content

    private var defaultBrowseContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Encrypted Share Drop Quick Open
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                showReceiveDrop = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "lock.doc.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Theme.accentBright)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Receive Encrypted Share Drop")
                            .font(.system(size: 14.5, weight: .bold))
                        Text("Paste a drop link or code shared by a friend")
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
            .padding(.horizontal, 16)

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
                        case "igreels": onSelectFeed(.igReels)
                        case "igfollowing": onSelectFeed(.igFollowing)
                        case "igsaved": onSelectFeed(.igSaved)
                        case "iguser": onSelectFeed(.igUser(recent.name))
                        case "rule34": onSelectFeed(.rule34(recent.name == "all" ? "" : recent.name))
                        case "offoryou": onSelectFeed(.ofForYou)
                        case "oftrending": onSelectFeed(.ofTrending)
                        case "oflatest": onSelectFeed(.ofLatest)
                        case "ofdms": onSelectFeed(.ofDMs)
                        case "ofcreator":
                            let parts = recent.name.split(separator: "|", maxSplits: 1).map(String.init)
                            onSelectFeed(.ofCreator(id: parts.first ?? recent.name, handle: parts.count > 1 ? parts[1] : recent.name, displayName: nil))
                        case "ofsearch": onSelectFeed(.ofSearch(recent.name))
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

            // RULE34.XXX HUB
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("RULE34.XXX")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(Color(red: 0.72, green: 0.96, blue: 0.70))
                    Spacer()
                    Button(action: onSetupR34Key) {
                        Text(store.data.r34Credentials.hasCustomCredentials ? "CUSTOM API" : "DEFAULT API ACTIVE")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }
                .padding(.horizontal, 18)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        r34Chip(label: "🔥 Rule34 Feed", tag: "")
                        r34Chip(label: "🎬 Animated / MP4", tag: "video")
                        r34Chip(label: "Overwatch", tag: "overwatch")
                        r34Chip(label: "Genshin Impact", tag: "genshin_impact")
                        r34Chip(label: "Fortnite", tag: "fortnite")
                        r34Chip(label: "Futanari", tag: "futanari")
                        r34Chip(label: "Cyberpunk", tag: "cyberpunk")
                        r34Chip(label: "Pokemon", tag: "pokemon")
                    }
                    .padding(.horizontal, 16)
                }
            }

            // ONLYFANS HUB
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("ONLYFANS")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(Color(red: 0.25, green: 0.80, blue: 1.0))
                    Spacer()
                    Text("SEARCH CREATORS ABOVE")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.5))
                }
                .padding(.horizontal, 18)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ofFeedChip(label: "✨ For You", source: .ofForYou)
                        ofFeedChip(label: "🔥 Trending", source: .ofTrending)
                        ofFeedChip(label: "⚡ Latest Videos", source: .ofLatest)
                        ofFeedChip(label: "💬 Unlocked DMs", source: .ofDMs)
                        ForEach(featuredOFCreators.prefix(10)) { creator in
                            Button {
                                onSelectFeed(.ofCreator(id: creator.id, handle: creator.name, displayName: creator.displayName))
                            } label: {
                                HStack(spacing: 7) {
                                    ofAvatar(url: creator.avatarURL, size: 22)
                                    Text(creator.displayTitle)
                                        .font(.system(size: 12.5, weight: .bold))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                }
                                .padding(.leading, 7)
                                .padding(.trailing, 12)
                                .padding(.vertical, 7)
                                .liquidGlassCapsule()
                            }
                            .buttonStyle(ScalePressButtonStyle())
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }

            // PERSONAL X & INSTAGRAM SECTION
            VStack(alignment: .leading, spacing: 8) {
                Text("CONNECTED ACCOUNTS (𝕏 & INSTAGRAM)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 18)

                // Personal X Row
                if store.data.xSession.isConnected {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        quickCard(title: "𝕏 For You", subtitle: "Home video feed", icon: "sparkles") {
                            onSelectFeed(.xForYou)
                        }
                        quickCard(title: "𝕏 Following", subtitle: "Creators you follow", icon: "person.2.fill") {
                            onSelectFeed(.xFollowing)
                        }
                        quickCard(title: "𝕏 Bookmarks", subtitle: "Your saved X videos", icon: "bookmark.fill") {
                            onSelectFeed(.xBookmarks)
                        }
                        quickCard(title: "𝕏 Likes", subtitle: "Videos you liked on X", icon: "heart.fill") {
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
                                    .frame(width: 42, height: 42)
                                    .overlay(Circle().stroke(Color.white.opacity(0.28), lineWidth: 1))
                                Text("𝕏")
                                    .font(.system(size: 19, weight: .black))
                                    .foregroundStyle(.white)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Connect Personal X")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(.white)
                                Text("Stream your X For You, Following, Bookmarks & 18+ creators")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.68))
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        .padding(13)
                        .liquidGlassCard(cornerRadius: 18)
                    }
                    .buttonStyle(ScalePressButtonStyle())
                    .padding(.horizontal, 16)
                }

                // Personal Instagram Row
                if store.data.igSession.isConnected {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
                        quickCard(title: "IG Reels", subtitle: "Personal Reels feed", icon: "film.stack") {
                            onSelectFeed(.igReels)
                        }
                        quickCard(title: "IG Following", subtitle: "Accounts you follow", icon: "person.2.fill") {
                            onSelectFeed(.igFollowing)
                        }
                        quickCard(title: "IG Saved", subtitle: "Bookmarked Reels", icon: "bookmark.fill") {
                            onSelectFeed(.igSaved)
                        }
                    }
                    .padding(.horizontal, 16)
                } else {
                    Button(action: onConnectIG) {
                        HStack(spacing: 14) {
                            ZStack {
                                Circle()
                                    .fill(
                                        LinearGradient(
                                            colors: [
                                                Color(red: 0.98, green: 0.35, blue: 0.35),
                                                Color(red: 0.85, green: 0.18, blue: 0.56),
                                                Color(red: 0.55, green: 0.22, blue: 0.85)
                                            ],
                                            startPoint: .bottomLeading,
                                            endPoint: .topTrailing
                                        )
                                    )
                                    .frame(width: 42, height: 42)
                                Image(systemName: "camera.fill")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundStyle(.white)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Connect Personal Instagram")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(.white)
                                Text("Stream your personal Instagram Reels, Saved & creators")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.68))
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.6))
                        }
                        .padding(13)
                        .liquidGlassCard(cornerRadius: 18)
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

                if let hero = featuredCategories.first(where: { $0.name == "Gooning" }) ?? store.categories.first {
                    Button {
                        store.recordSearchSignal(hero.name)
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

                let gridTiles: [GoonedCategory] = [
                    store.categories.first { $0.name == "TikTok" },
                    store.categories.first { $0.name == "OnlyFans" },
                    store.categories.first { $0.name == "Snapchat" },
                    store.categories.first { $0.name == "Videos" }
                ].compactMap { $0 }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                    ForEach(gridTiles) { tile in
                        Button {
                            store.recordSearchSignal(tile.name)
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

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 98), spacing: 8)], spacing: 8) {
                ForEach(azCategories) { cat in
                    Button {
                        store.recordSearchSignal(cat.name)
                        if cat.name.caseInsensitiveCompare("Rule34") == .orderedSame {
                            onSelectFeed(.rule34(""))
                        } else {
                            onSelectFeed(.category(cat.name))
                        }
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

    private func r34Chip(label: String, tag: String) -> some View {
        Button {
            store.recordSearchSignal(tag)
            onSelectFeed(.rule34(tag))
        } label: {
            Text(label)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .liquidGlassCapsule()
        }
        .buttonStyle(ScalePressButtonStyle())
    }

    private func ofFeedChip(label: String, source: FeedSource) -> some View {
        Button {
            onSelectFeed(source)
        } label: {
            Text(label)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .liquidGlassCapsule()
        }
        .buttonStyle(ScalePressButtonStyle())
    }

    private func ofAvatar(url: URL?, size: CGFloat) -> some View {
        AsyncImage(url: url) { phase in
            if let img = phase.image {
                img.resizable().aspectRatio(contentMode: .fill)
            } else {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.0, green: 0.72, blue: 0.96), Color(red: 0.0, green: 0.52, blue: 0.84)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        Text("OF")
                            .font(.system(size: max(9, size * 0.36), weight: .black, design: .rounded))
                            .foregroundStyle(.white)
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private func quickCard(title: String, subtitle: String, icon: String, action: @escaping () -> Void) -> some View {
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

    // MARK: - Search Helpers & Scoped Live Results

    private func submitSearch() {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        store.recordSearchSignal(clean)
        switch searchScope {
        case .of:
            if let bestCreator = ofCreators.first {
                onSelectFeed(.ofCreator(id: bestCreator.id, handle: bestCreator.name, displayName: bestCreator.displayName))
            } else {
                onSelectFeed(.ofSearch(clean))
            }
        case .rule34:
            onSelectFeed(.rule34(Rule34API.parseTags(clean).joined(separator: " ")))
        case .x:
            if clean.hasPrefix("@") {
                onSelectFeed(.xUser(clean.replacingOccurrences(of: "@", with: "")))
            } else {
                onSelectFeed(.xSearch(clean))
            }
        case .ig:
            onSelectFeed(.igUser(clean.replacingOccurrences(of: "@", with: "").replacingOccurrences(of: "ig:", with: "", options: .caseInsensitive)))
        case .reddit:
            onSelectFeed(.subreddit(clean.replacingOccurrences(of: "r/", with: "", options: .caseInsensitive).replacingOccurrences(of: " ", with: "")))
        case .long:
            onSelectFeed(.longSearch(.all, clean))
        case .all:
            if clean.lowercased().hasPrefix("of:") {
                let q = clean.replacingOccurrences(of: "of:", with: "", options: .caseInsensitive).trimmingCharacters(in: .whitespaces)
                if let c = ofCreators.first {
                    onSelectFeed(.ofCreator(id: c.id, handle: c.name, displayName: c.displayName))
                } else {
                    onSelectFeed(.ofSearch(q))
                }
            } else if clean.lowercased().hasPrefix("r34:") || clean.lowercased().hasPrefix("#") {
                onSelectFeed(.rule34(Rule34API.parseTags(clean).joined(separator: " ")))
            } else if clean.lowercased().hasPrefix("ig:") {
                onSelectFeed(.igUser(clean.replacingOccurrences(of: "ig:", with: "", options: .caseInsensitive)))
            } else if clean.hasPrefix("@") {
                onSelectFeed(.xUser(clean.replacingOccurrences(of: "@", with: "")))
            } else {
                onSelectFeed(.multiSearch(clean))
            }
        }
    }

    private func completeRule34Tag(_ tagValue: String) {
        var tags = Rule34API.parseTags(query)
        if tags.isEmpty {
            query = tagValue + " "
        } else {
            tags[tags.count - 1] = tagValue
            query = tags.joined(separator: " ") + " "
        }
    }

    private var liveSearchResultsContent: some View {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "r/", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "u/", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "@", with: "")
        let parsedR34Tags = Rule34API.parseTags(query)
        let r34QueryString = parsedR34Tags.joined(separator: " ")
        let showReddit = (searchScope == .all || searchScope == .reddit)
        let showOF = (searchScope == .all || searchScope == .of)
        let showR34 = (searchScope == .all || searchScope == .rule34)
        let showX = (searchScope == .all || searchScope == .x)
        let showIG = (searchScope == .all || searchScope == .ig)
        let showLong = (searchScope == .all || searchScope == .long)

        return VStack(alignment: .leading, spacing: 14) {
            if searchScope == .all && clean.count >= 2 {
                Button {
                    store.recordSearchSignal(clean)
                    onSelectFeed(.multiSearch(clean))
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Theme.accentBright)
                            .frame(width: 34, height: 34)
                            .liquidGlassCircle(tinted: true, active: true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Search \"\(clean)\" Across All Sources")
                                .font(.system(size: 15, weight: .bold))
                            Text("𝕏, OnlyFans, Rule34, Reddit & Long Videos combined")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.68))
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.bold())
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .padding(13)
                    .liquidGlassCard(cornerRadius: 18)
                }
                .buttonStyle(ScalePressButtonStyle())
            }
            if showOF && !ofCreators.isEmpty {
                Text("ONLYFANS CREATORS")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(red: 0.25, green: 0.80, blue: 1.0))
                    .padding(.horizontal, 4)

                ForEach(ofCreators) { creator in
                    let isFollowing = store.isFollowingOFCreator(id: creator.id, handle: creator.name)
                    HStack(spacing: 10) {
                        Button {
                            onSelectFeed(.ofCreator(id: creator.id, handle: creator.name, displayName: creator.displayName))
                        } label: {
                            HStack(spacing: 12) {
                                ofAvatar(url: creator.avatarURL, size: 42)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(creator.displayTitle)
                                        .font(.system(size: 15, weight: .bold))
                                        .lineLimit(1)
                                    Text("@\(creator.name) · \(shortCount(creator.videoCount)) videos")
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.68))
                                        .lineLimit(1)
                                    if let tags = creator.creatorTags, !tags.isEmpty {
                                        Text(tags.prefix(3).map { "#\($0)" }.joined(separator: " "))
                                            .font(.system(size: 10.5, weight: .medium))
                                            .foregroundStyle(Color(red: 0.45, green: 0.86, blue: 1.0))
                                            .lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 4)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            store.toggleFollowOFCreator(id: creator.id, name: creator.name, displayName: creator.displayName)
                        } label: {
                            Text(isFollowing ? "Following" : "Follow")
                                .font(.caption.bold())
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6)
                                .liquidGlassCapsule(active: isFollowing)
                        }
                        .buttonStyle(ScalePressButtonStyle())
                    }
                    .padding(12)
                    .liquidGlassCard(cornerRadius: 16)
                }
            }

            if showOF && clean.count >= 3 {
                Button {
                    onSelectFeed(.ofSearch(clean))
                } label: {
                    HStack(spacing: 12) {
                        BrandLogoOnlyFans(active: true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Search \"\(clean)\" in OnlyFans Videos")
                                .font(.system(size: 15, weight: .bold))
                            Text("Captions, tags & matching creators")
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
            } else if searchScope == .of && clean.count < 3 && ofCreators.isEmpty && !isSearching {
                Text("Type at least 3 characters to search all 56,000+ OnlyFans creators.")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 6)
            }

            VStack(spacing: 8) {
                if showR34 && !r34QueryString.isEmpty {
                    Button {
                        store.recordSearchSignal(r34QueryString)
                        onSelectFeed(.rule34(r34QueryString))
                    } label: {
                        HStack(spacing: 12) {
                            BrandLogoRule34(active: true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Rule34: \(parsedR34Tags.map { "#\($0)" }.joined(separator: " "))")
                                    .font(.system(size: 15, weight: .bold))
                                    .lineLimit(1)
                                Text(parsedR34Tags.count > 1 ? "Combined multi-tag search" : "Videos, GIFs & artwork")
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

                if showReddit && !clean.isEmpty {
                    let subClean = clean.replacingOccurrences(of: " ", with: "")
                    Button {
                        onSelectFeed(.subreddit(subClean))
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "arrow.up.right.circle.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(Theme.accentBright)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("r/\(subClean)")
                                    .font(.system(size: 15, weight: .bold))
                                Text("Open subreddit feed")
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

                if showX && !clean.isEmpty {
                    Button {
                        onSelectFeed(.xSearch(clean))
                    } label: {
                        HStack(spacing: 12) {
                            BrandLogoX(active: false, connected: store.data.xSession.isConnected)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Search \"\(clean)\" on 𝕏")
                                    .font(.system(size: 15, weight: .bold))
                                Text("18+ video posts")
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

                if showLong && !clean.isEmpty {
                    Button {
                        store.recordSearchSignal(clean)
                        onSelectFeed(.longSearch(.all, clean))
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "play.rectangle.fill")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(Color(red: 1.0, green: 0.62, blue: 0.16))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Search \"\(clean)\" in Long Videos")
                                    .font(.system(size: 15, weight: .bold))
                                Text("Eporner, Pornhub, xHamster & SpankBang")
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

                if (showX || showIG) && !clean.isEmpty {
                    let handleClean = clean.replacingOccurrences(of: " ", with: "")
                    HStack(spacing: 8) {
                        if showX {
                            Button {
                                onSelectFeed(.xUser(handleClean))
                            } label: {
                                HStack(spacing: 8) {
                                    BrandLogoX(active: false, connected: false)
                                    Text("@\(handleClean)")
                                        .font(.system(size: 14, weight: .bold))
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .padding(10)
                                .liquidGlassCard(cornerRadius: 16)
                            }
                            .buttonStyle(ScalePressButtonStyle())
                        }

                        if showIG {
                            Button {
                                onSelectFeed(.igUser(handleClean))
                            } label: {
                                HStack(spacing: 8) {
                                    BrandLogoInstagram(active: false, connected: false)
                                    Text("@\(handleClean)")
                                        .font(.system(size: 14, weight: .bold))
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .padding(10)
                                .liquidGlassCard(cornerRadius: 16)
                            }
                            .buttonStyle(ScalePressButtonStyle())
                        }
                    }
                }
            }

            // Live Rule34 Autocomplete Tag Suggestions (Tap `+` to chain tags, or row to open!)
            if showR34 && !r34Suggestions.isEmpty {
                Text("RULE34 TAG SUGGESTIONS")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color(red: 0.72, green: 0.96, blue: 0.70))
                    .padding(.horizontal, 4)

                ForEach(r34Suggestions.prefix(7)) { item in
                    HStack(spacing: 8) {
                        Button {
                            var tags = Rule34API.parseTags(query)
                            if tags.isEmpty {
                                onSelectFeed(.rule34(item.value))
                            } else {
                                tags[tags.count - 1] = item.value
                                onSelectFeed(.rule34(tags.joined(separator: " ")))
                            }
                        } label: {
                            HStack {
                                Text("#\(item.label)")
                                    .font(.system(size: 14.5, weight: .semibold))
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            completeRule34Tag(item.value)
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 20))
                                .foregroundStyle(Color(red: 0.67, green: 0.90, blue: 0.64))
                        }
                        .buttonStyle(ScalePressButtonStyle())
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .liquidGlassCard(cornerRadius: 14)
                }
            }

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

// MARK: - 2. Likes & Offline Vault Screen (Screenshot 2 + Offline Vault Mode)

struct GoonedLikesView: View {
    var onOpenSettings: () -> Void
    var onStartStash: () -> Void
    var onPlayLikedPost: (Gif) -> Void
    var onPlayOfflinePost: (Gif) -> Void

    @EnvironmentObject var store: UserStore
    @ObservedObject private var offline = OfflineManager.shared
    @State private var mode: String = "liked" // "liked" or "offline"
    @State private var filter: String = "all" // "all", "videos", "images"
    @State private var shareTarget: Gif? = nil
    @State private var isSelecting: Bool = false
    @State private var selectedIDs: Set<String> = []
    @State private var showCollectionShare: Bool = false
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    private var sourceItems: [Gif] {
        mode == "offline" ? store.data.downloaded : store.data.liked
    }

    private var filteredItems: [Gif] {
        switch filter {
        case "videos":
            return sourceItems.filter { !$0.isImage }
        case "images":
            return sourceItems.filter { $0.isImage }
        default:
            return sourceItems
        }
    }

    private var selectedPosts: [Gif] {
        filteredItems.filter { selectedIDs.contains($0.id) }
    }

    var body: some View {
        ZStack {
            Theme.crimsonBg.ignoresSafeArea()

            VStack(spacing: 0) {
                // Top Bar: Liked vs Offline Vault Switcher + Gear on Right
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Button {
                            withAnimation {
                                mode = "liked"
                                isSelecting = false
                                selectedIDs.removeAll()
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "heart.fill")
                                    .font(.system(size: 12))
                                Text("Liked (\(store.data.liked.count))")
                                    .font(.system(size: 13, weight: .bold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .liquidGlassCapsule(active: mode == "liked")
                        }

                        Button {
                            withAnimation {
                                mode = "offline"
                                isSelecting = false
                                selectedIDs.removeAll()
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.system(size: 12))
                                Text("Offline (\(store.data.downloaded.count))")
                                    .font(.system(size: 13, weight: .bold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .liquidGlassCapsule(active: mode == "offline")
                        }
                    }

                    Spacer()

                    if !filteredItems.isEmpty {
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                isSelecting.toggle()
                                if !isSelecting { selectedIDs.removeAll() }
                            }
                        } label: {
                            Text(isSelecting ? "Done" : "Select")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .liquidGlassCapsule(active: isSelecting)
                        }
                        .buttonStyle(ScalePressButtonStyle())
                    }

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

                // Sub-toolbar when items exist
                if !sourceItems.isEmpty {
                    HStack {
                        HStack(spacing: 6) {
                            ForEach([("all", "All"), ("videos", "Videos"), ("images", "Images")], id: \.0) { id, label in
                                Button {
                                    filter = id
                                } label: {
                                    Text(label)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 11)
                                        .padding(.vertical, 6)
                                        .liquidGlassCapsule(active: filter == id)
                                }
                            }
                        }

                        Spacer()

                        if isSelecting {
                            Button {
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                if selectedIDs.count == filteredItems.count {
                                    selectedIDs.removeAll()
                                } else {
                                    selectedIDs = Set(filteredItems.map(\.id))
                                }
                            } label: {
                                Text(selectedIDs.count == filteredItems.count ? "Clear All" : "Select All")
                                    .font(.system(size: 11.5, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 11)
                                    .padding(.vertical, 6)
                                    .liquidGlassCapsule(tinted: true)
                            }
                        } else if mode == "offline", let firstOffline = filteredItems.first {
                            Button {
                                onPlayOfflinePost(firstOffline)
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 10, weight: .bold))
                                    Text("Play Offline (\(offline.totalDiskUsageString()))")
                                        .font(.system(size: 11, weight: .bold))
                                }
                                .foregroundStyle(.white)
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6)
                                .liquidGlassCapsule(active: true)
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                }

                if filteredItems.isEmpty {
                    Spacer()
                    VStack(spacing: 14) {
                        ZStack {
                            Circle()
                                .fill(Color(red: 0.42, green: 0.10, blue: 0.20).opacity(0.85))
                                .frame(width: 68, height: 68)
                                .overlay(Circle().stroke(Color.white.opacity(0.22), lineWidth: 1))
                            Image(systemName: mode == "offline" ? "arrow.down.to.line" : "heart.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(.white)
                        }

                        Text(mode == "offline" ? "No offline downloads yet" : "No liked posts yet")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white)

                        Text(mode == "offline"
                             ? "Tap Save (↓) on any video to watch it offline anytime."
                             : "Double-tap a post to save it here.")
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.72))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 36)

                        Button(action: onStartStash) {
                            Text(mode == "offline" ? "Browse videos to download" : "Start your stash")
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
                            ForEach(filteredItems) { post in
                                let isChosen = selectedIDs.contains(post.id)
                                Button {
                                    if isSelecting {
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        if isChosen {
                                            selectedIDs.remove(post.id)
                                        } else {
                                            selectedIDs.insert(post.id)
                                        }
                                    } else if mode == "offline" {
                                        onPlayOfflinePost(post)
                                    } else {
                                        onPlayLikedPost(post)
                                    }
                                } label: {
                                    GridThumb(gif: post, isOfflineBadge: !isSelecting && offline.isDownloaded(post))
                                        .overlay {
                                            if isSelecting {
                                                ZStack(alignment: .bottomTrailing) {
                                                    Color.black.opacity(isChosen ? 0.28 : 0.05)
                                                    Image(systemName: isChosen ? "checkmark.circle.fill" : "circle")
                                                        .font(.system(size: 22, weight: .bold))
                                                        .foregroundStyle(isChosen ? Theme.accentBright : .white.opacity(0.85))
                                                        .shadow(color: .black.opacity(0.7), radius: 3)
                                                        .padding(7)
                                                }
                                            }
                                        }
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button {
                                        shareTarget = post
                                    } label: {
                                        Label("Share Encrypted Drop", systemImage: "paperplane.fill")
                                    }
                                    if offline.isDownloaded(post) {
                                        if let localURL = offline.localMediaURL(for: post) {
                                            ShareLink(item: localURL) {
                                                Label("Export / Share File", systemImage: "square.and.arrow.up")
                                            }
                                        }
                                        Button(role: .destructive) {
                                            offline.removeDownload(post)
                                        } label: {
                                            Label("Delete Offline Copy", systemImage: "trash")
                                        }
                                    } else {
                                        Button {
                                            Task { await offline.download(post) }
                                        } label: {
                                            Label("Download for Offline", systemImage: "arrow.down.to.line")
                                        }
                                    }
                                    if store.isLiked(post) {
                                        Button(role: .destructive) {
                                            store.toggleLike(post)
                                        } label: {
                                            Label("Remove from Likes", systemImage: "heart.slash")
                                        }
                                    }
                                }
                            }
                        }
                        .padding(.top, 12)
                        .padding(.bottom, isSelecting ? 150 : 92)
                    }
                }
            }

            if isSelecting {
                VStack {
                    Spacer()
                    HStack(spacing: 12) {
                        Text("\(selectedIDs.count) selected")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                        Spacer()
                        Button {
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                            showCollectionShare = true
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "paperplane.fill")
                                    .font(.system(size: 13, weight: .bold))
                                Text("Share (\(selectedIDs.count))")
                                    .font(.system(size: 14, weight: .bold))
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                            .liquidGlassCapsule(active: !selectedIDs.isEmpty)
                        }
                        .disabled(selectedIDs.isEmpty)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .liquidGlassCard(cornerRadius: 22)
                    .padding(.horizontal, 18)
                    .padding(.bottom, 86)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(item: $shareTarget) { post in
            ShareItemSheet(gif: post)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showCollectionShare) {
            ShareCollectionSheet(posts: selectedPosts)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }
}

struct GridThumb: View {
    let gif: Gif
    var isOfflineBadge: Bool = false

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
            .overlay(alignment: .topTrailing) {
                if isOfflineBadge {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.accentBright)
                        .shadow(color: .black.opacity(0.6), radius: 2)
                        .padding(6)
                }
            }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 4) {
                    if gif.isOnlyFansPost {
                        Text("OF").font(.system(size: 10, weight: .black))
                    } else if gif.isXPost {
                        Text("𝕏").font(.system(size: 10, weight: .black))
                    } else if gif.isIGPost {
                        Image(systemName: "camera.fill").font(.system(size: 9, weight: .bold))
                    } else if gif.isRule34Post {
                        Text("34").font(.system(size: 10, weight: .black))
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

// MARK: - 3. Profile / Follows View (Subreddits, Reddit Creators, X Creators, Instagram Creators)

struct GoonedFollowsView: View {
    var onOpenSettings: () -> Void
    var onSelectFeed: (FeedSource) -> Void
    var onConnectX: () -> Void
    var onConnectIG: () -> Void

    @EnvironmentObject var store: UserStore
    @EnvironmentObject var app: AppState

    private var hasAnyFollows: Bool {
        !store.data.followedSubreddits.isEmpty ||
        !store.data.followedUsers.isEmpty ||
        !store.data.followedXUsers.isEmpty ||
        !store.data.followedIGUsers.isEmpty ||
        !store.data.followedOFCreators.isEmpty
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
                                        .frame(width: 40, height: 40)
                                        .overlay(Circle().stroke(Color.white.opacity(0.28), lineWidth: 1))
                                    Text("𝕏").font(.system(size: 18, weight: .black))
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    if store.data.xSession.isConnected {
                                        let sn = store.data.xSession.screenName
                                        Text(sn.isEmpty ? "Personal X Connected" : "@\(sn)")
                                            .font(.system(size: 15, weight: .bold))
                                        Text("Streaming personal X timeline & 18+ media")
                                            .font(.caption)
                                            .foregroundStyle(.white.opacity(0.68))
                                    } else {
                                        Text("Personal X Account")
                                            .font(.system(size: 15, weight: .bold))
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
                                    Button { onSelectFeed(.xForYou) } label: {
                                        Text("𝕏 For You").font(.caption.bold()).frame(maxWidth: .infinity).padding(.vertical, 8).liquidGlassCapsule(active: true)
                                    }
                                    Button { onSelectFeed(.xFollowing) } label: {
                                        Text("𝕏 Following").font(.caption.bold()).frame(maxWidth: .infinity).padding(.vertical, 8).liquidGlassCapsule()
                                    }
                                    Button { onSelectFeed(.xBookmarks) } label: {
                                        Text("𝕏 Saved").font(.caption.bold()).frame(maxWidth: .infinity).padding(.vertical, 8).liquidGlassCapsule()
                                    }
                                }
                            }
                        }
                        .padding(14)
                        .liquidGlassCard(cornerRadius: 20)

                        // Personal Instagram Account Card
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(
                                            LinearGradient(
                                                colors: [
                                                    Color(red: 0.98, green: 0.35, blue: 0.35),
                                                    Color(red: 0.85, green: 0.18, blue: 0.56),
                                                    Color(red: 0.55, green: 0.22, blue: 0.85)
                                                ],
                                                startPoint: .bottomLeading,
                                                endPoint: .topTrailing
                                            )
                                        )
                                        .frame(width: 40, height: 40)
                                    Image(systemName: "camera.fill").font(.system(size: 15, weight: .bold))
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    if store.data.igSession.isConnected {
                                        let un = store.data.igSession.username
                                        Text(un.isEmpty ? "Instagram Connected" : "@\(un)")
                                            .font(.system(size: 15, weight: .bold))
                                        Text("Streaming your personal Instagram Reels & Saved")
                                            .font(.caption)
                                            .foregroundStyle(.white.opacity(0.68))
                                    } else {
                                        Text("Personal Instagram")
                                            .font(.system(size: 15, weight: .bold))
                                        Text("Connect Instagram for Reels, Following & Saved")
                                            .font(.caption)
                                            .foregroundStyle(.white.opacity(0.68))
                                    }
                                }
                                Spacer()
                                if !store.data.igSession.isConnected {
                                    Button(action: onConnectIG) {
                                        Text("Connect")
                                            .font(.subheadline.bold())
                                            .padding(.horizontal, 14)
                                            .padding(.vertical, 8)
                                            .liquidGlassCapsule(active: true)
                                    }
                                }
                            }

                            if store.data.igSession.isConnected {
                                HStack(spacing: 8) {
                                    Button { onSelectFeed(.igReels) } label: {
                                        Text("IG Reels").font(.caption.bold()).frame(maxWidth: .infinity).padding(.vertical, 8).liquidGlassCapsule(active: true)
                                    }
                                    Button { onSelectFeed(.igFollowing) } label: {
                                        Text("IG Following").font(.caption.bold()).frame(maxWidth: .infinity).padding(.vertical, 8).liquidGlassCapsule()
                                    }
                                    Button { onSelectFeed(.igSaved) } label: {
                                        Text("IG Saved").font(.caption.bold()).frame(maxWidth: .infinity).padding(.vertical, 8).liquidGlassCapsule()
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
                                Text("Tap + on any video to follow its subreddit, Reddit creator, 𝕏 creator, or Instagram creator.")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.white.opacity(0.72))
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 32)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 36)
                        } else {
                            if !store.data.followedXUsers.isEmpty {
                                Text("𝕏 CREATORS")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.6))
                                    .padding(.horizontal, 4)

                                ForEach(store.data.followedXUsers, id: \.self) { handle in
                                    HStack {
                                        Button { onSelectFeed(.xUser(handle)) } label: {
                                            HStack(spacing: 10) {
                                                Circle().fill(Color.black.opacity(0.55)).frame(width: 36, height: 36)
                                                    .overlay(Text("𝕏").font(.system(size: 13, weight: .black)))
                                                Text("@\(handle)").font(.system(size: 16, weight: .bold))
                                                Spacer()
                                            }
                                        }
                                        Button { store.toggleFollowXUser(handle) } label: {
                                            Text("Unfollow").font(.caption.bold()).padding(.horizontal, 12).padding(.vertical, 6).liquidGlassCapsule()
                                        }
                                    }
                                    .padding(12)
                                    .liquidGlassCard(cornerRadius: 16)
                                }
                            }

                            if !store.data.followedOFCreators.isEmpty {
                                Text("ONLYFANS CREATORS")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(Color(red: 0.25, green: 0.80, blue: 1.0))
                                    .padding(.horizontal, 4)

                                ForEach(store.data.followedOFCreators) { creator in
                                    HStack {
                                        Button {
                                            onSelectFeed(.ofCreator(id: creator.id, handle: creator.name, displayName: creator.displayName))
                                        } label: {
                                            HStack(spacing: 10) {
                                                AsyncImage(url: creator.avatarURL) { phase in
                                                    if let img = phase.image {
                                                        img.resizable().aspectRatio(contentMode: .fill)
                                                    } else {
                                                        Circle()
                                                            .fill(Color(red: 0.0, green: 0.65, blue: 0.92).opacity(0.65))
                                                            .overlay(Text("OF").font(.system(size: 11, weight: .black)))
                                                    }
                                                }
                                                .frame(width: 36, height: 36)
                                                .clipShape(Circle())

                                                VStack(alignment: .leading, spacing: 1) {
                                                    Text(creator.displayName?.isEmpty == false ? creator.displayName! : "@\(creator.name)")
                                                        .font(.system(size: 15.5, weight: .bold))
                                                    Text("@\(creator.name)")
                                                        .font(.caption)
                                                        .foregroundStyle(.white.opacity(0.65))
                                                }
                                                Spacer()
                                            }
                                        }
                                        Button {
                                            store.toggleFollowOFCreator(id: creator.id, name: creator.name, displayName: creator.displayName)
                                        } label: {
                                            Text("Unfollow").font(.caption.bold()).padding(.horizontal, 12).padding(.vertical, 6).liquidGlassCapsule()
                                        }
                                    }
                                    .padding(12)
                                    .liquidGlassCard(cornerRadius: 16)
                                }
                            }

                            if !store.data.followedIGUsers.isEmpty {
                                Text("INSTAGRAM CREATORS")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.6))
                                    .padding(.horizontal, 4)

                                ForEach(store.data.followedIGUsers, id: \.self) { handle in
                                    HStack {
                                        Button { onSelectFeed(.igUser(handle)) } label: {
                                            HStack(spacing: 10) {
                                                Circle().fill(Theme.accent.opacity(0.55)).frame(width: 36, height: 36)
                                                    .overlay(Image(systemName: "camera.fill").font(.system(size: 12, weight: .bold)))
                                                Text("IG @\(handle)").font(.system(size: 16, weight: .bold))
                                                Spacer()
                                            }
                                        }
                                        Button { store.toggleFollowIGUser(handle) } label: {
                                            Text("Unfollow").font(.caption.bold()).padding(.horizontal, 12).padding(.vertical, 6).liquidGlassCapsule()
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
                                        Button { onSelectFeed(.subreddit(sub)) } label: {
                                            HStack(spacing: 10) {
                                                Circle().fill(Theme.accent.opacity(0.5)).frame(width: 36, height: 36)
                                                    .overlay(Text("r/").font(.system(size: 12, weight: .black)))
                                                Text("r/\(sub)").font(.system(size: 16, weight: .bold))
                                                Spacer()
                                            }
                                        }
                                        Button { store.toggleFollowSubreddit(sub) } label: {
                                            Text("Unfollow").font(.caption.bold()).padding(.horizontal, 12).padding(.vertical, 6).liquidGlassCapsule()
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
                                        Button { onSelectFeed(.user(u)) } label: {
                                            HStack(spacing: 10) {
                                                Circle().fill(Color.white.opacity(0.18)).frame(width: 36, height: 36)
                                                    .overlay(Text("u/").font(.system(size: 12, weight: .black)))
                                                Text("u/\(u)").font(.system(size: 16, weight: .bold))
                                                Spacer()
                                            }
                                        }
                                        Button { store.toggleFollowUser(u) } label: {
                                            Text("Unfollow").font(.caption.bold()).padding(.horizontal, 12).padding(.vertical, 6).liquidGlassCapsule()
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

// MARK: - 4. Settings Modal (X, Instagram, Rule34, Offline Vault, Autoplay, Video Fit, Appearance, Security)

struct GoonedSettingsModal: View {
    @Binding var isPresented: Bool
    var onConnectX: () -> Void
    var onConnectIG: () -> Void
    var onSetupR34Key: () -> Void
    @EnvironmentObject var store: UserStore
    @EnvironmentObject var app: AppState
    @ObservedObject private var offline = OfflineManager.shared
    @ObservedObject private var taste = SmartTasteEngine.shared
    @ObservedObject private var license = LicenseManager.shared
    @State private var changingPasscode = false
    @State private var settingPasscode = false
    @State private var confirmErase = false
    @State private var showAlgorithmEditor = false
    @State private var syncStatusMessage: String? = nil

    private let delays = [3, 6, 10, 15]

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            VStack(spacing: 0) {
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
                        // FOR YOU ALGORITHM
                        sectionHeader("FOR YOU ALGORITHM")

                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Smart Personalization")
                                        .font(.system(size: 16, weight: .bold))
                                    Text(store.data.settings.algorithmEnabled ? store.topTasteSummary : "Off — showing unranked discovery feed")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.white.opacity(0.68))
                                        .lineLimit(2)
                                }
                                Spacer()
                                Toggle("", isOn: $store.data.settings.algorithmEnabled)
                                    .labelsHidden()
                                    .tint(Theme.accent)
                            }

                            if store.data.settings.algorithmEnabled {
                                Divider().overlay(Color.white.opacity(0.14))

                                if !store.data.algorithm.boostedTags.isEmpty {
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 6) {
                                            ForEach(store.data.algorithm.boostedTags, id: \.self) { tag in
                                                HStack(spacing: 5) {
                                                    Text("#\(tag)")
                                                        .font(.system(size: 11.5, weight: .bold))
                                                    Button {
                                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                                        store.removeBoostedTag(tag)
                                                    } label: {
                                                        Image(systemName: "xmark")
                                                            .font(.system(size: 9, weight: .bold))
                                                            .foregroundStyle(.white.opacity(0.8))
                                                    }
                                                }
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 5)
                                                .liquidGlassCapsule(active: true)
                                            }
                                        }
                                    }
                                }

                                HStack(spacing: 10) {
                                    Button {
                                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        showAlgorithmEditor = true
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "slider.horizontal.3")
                                                .font(.system(size: 12, weight: .bold))
                                            Text("Edit #Tags & Taste")
                                                .font(.caption.bold())
                                        }
                                        .padding(.horizontal, 13)
                                        .padding(.vertical, 8)
                                        .liquidGlassCapsule(tinted: true)
                                    }

                                    Spacer()

                                    if store.data.algorithm.totalSignals > 0 {
                                        Button {
                                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                            store.resetAlgorithm()
                                        } label: {
                                            Text("Reset Taste")
                                                .font(.caption.bold())
                                                .foregroundStyle(Theme.accentBright)
                                        }
                                    }
                                }

                                if store.data.algorithm.totalSignals > 0 {
                                    Text("\(store.data.algorithm.totalSignals) signals learned on-device · \(store.topAlgorithmTags.count) #tags tracked")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.white.opacity(0.5))
                                }
                            }
                        }
                        .padding(16)
                        .liquidGlassCard(cornerRadius: 20)

                        // CONNECTED ACCOUNTS (X, INSTAGRAM, RULE34)
                        sectionHeader("CONNECTED ACCOUNTS")

                        VStack(alignment: .leading, spacing: 14) {
                            // X.com
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle().fill(Color.black.opacity(0.6)).frame(width: 38, height: 38)
                                        .overlay(Circle().stroke(Color.white.opacity(0.28), lineWidth: 1))
                                    Text("𝕏").font(.system(size: 17, weight: .black))
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    let sn = store.data.xSession.screenName
                                    Text(store.data.xSession.isConnected ? (sn.isEmpty ? "Personal X Connected" : "𝕏 @\(sn)") : "Personal X.com")
                                        .font(.system(size: 15, weight: .bold))
                                    Text(store.data.xSession.isConnected ? "For You, Following & Bookmarks active" : "Sign in to stream 18+ X videos")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.white.opacity(0.68))
                                }
                                Spacer()
                                Button {
                                    if store.data.xSession.isConnected {
                                        store.disconnectX()
                                    } else {
                                        onConnectX()
                                    }
                                } label: {
                                    Text(store.data.xSession.isConnected ? "Disconnect" : "Connect")
                                        .font(.caption.bold())
                                        .padding(.horizontal, 13)
                                        .padding(.vertical, 8)
                                        .liquidGlassCapsule(active: !store.data.xSession.isConnected)
                                }
                            }

                            if store.data.xSession.isConnected {
                                HStack {
                                    Text("Mix 𝕏 into For You")
                                        .font(.system(size: 14, weight: .semibold))
                                    Spacer()
                                    Toggle("", isOn: $store.data.xSession.mixIntoForYou)
                                        .labelsHidden()
                                        .tint(Theme.accent)
                                }
                            }

                            Divider().overlay(Color.white.opacity(0.14))

                            // Instagram
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(
                                            LinearGradient(
                                                colors: [
                                                    Color(red: 0.98, green: 0.35, blue: 0.35),
                                                    Color(red: 0.85, green: 0.18, blue: 0.56),
                                                    Color(red: 0.55, green: 0.22, blue: 0.85)
                                                ],
                                                startPoint: .bottomLeading,
                                                endPoint: .topTrailing
                                            )
                                        )
                                        .frame(width: 38, height: 38)
                                    Image(systemName: "camera.fill").font(.system(size: 14, weight: .bold))
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    let un = store.data.igSession.username
                                    Text(store.data.igSession.isConnected ? (un.isEmpty ? "Instagram Connected" : "IG @\(un)") : "Personal Instagram")
                                        .font(.system(size: 15, weight: .bold))
                                    Text(store.data.igSession.isConnected ? "Reels, Following & Saved active" : "Sign in to stream your IG Reels")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.white.opacity(0.68))
                                }
                                Spacer()
                                Button {
                                    if store.data.igSession.isConnected {
                                        store.disconnectIG()
                                    } else {
                                        onConnectIG()
                                    }
                                } label: {
                                    Text(store.data.igSession.isConnected ? "Disconnect" : "Connect")
                                        .font(.caption.bold())
                                        .padding(.horizontal, 13)
                                        .padding(.vertical, 8)
                                        .liquidGlassCapsule(active: !store.data.igSession.isConnected)
                                }
                            }

                            if store.data.igSession.isConnected {
                                HStack {
                                    Text("Mix IG Reels into For You")
                                        .font(.system(size: 14, weight: .semibold))
                                    Spacer()
                                    Toggle("", isOn: $store.data.igSession.mixIntoForYou)
                                        .labelsHidden()
                                        .tint(Theme.accent)
                                }
                            }

                            Divider().overlay(Color.white.opacity(0.14))

                            // Rule34.xxx API Key
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle().fill(Color(red: 0.42, green: 0.72, blue: 0.40)).frame(width: 38, height: 38)
                                    Text("34").font(.system(size: 14, weight: .black, design: .rounded)).foregroundStyle(.black)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Rule34.xxx DAPI Key")
                                        .font(.system(size: 15, weight: .bold))
                                    Text(store.data.r34Credentials.hasCustomCredentials ? "Custom DAPI key active (User #\(store.data.r34Credentials.effectiveUserId))" : "Default DAPI key active · Tap to customize")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.white.opacity(0.68))
                                }
                                Spacer()
                                Button(action: onSetupR34Key) {
                                    Text(store.data.r34Credentials.hasCustomCredentials ? "Custom" : "API Key")
                                        .font(.caption.bold())
                                        .padding(.horizontal, 13)
                                        .padding(.vertical, 8)
                                        .liquidGlassCapsule()
                                }
                            }
                        }
                        .padding(16)
                        .liquidGlassCard(cornerRadius: 20)

                        // GENERAL FOR YOU SOURCES
                        sectionHeader("SOURCES IN GENERAL FOR YOU")

                        VStack(alignment: .leading, spacing: 12) {
                            Text("Balanced split shaped by your likes and Not Interested feedback.")
                                .font(.system(size: 12.5))
                                .foregroundStyle(.white.opacity(0.68))

                            Toggle("Reddit", isOn: $taste.state.sourceSettings.includeReddit)
                                .tint(Theme.accent)
                            Toggle("𝕏 (When connected)", isOn: $taste.state.sourceSettings.includeX)
                                .tint(Theme.accent)
                            Toggle("OnlyFans", isOn: $taste.state.sourceSettings.includeOnlyFans)
                                .tint(Theme.accent)
                            Toggle("Instagram Reels (When connected)", isOn: $taste.state.sourceSettings.includeInstagram)
                                .tint(Theme.accent)
                        }
                        .font(.system(size: 15, weight: .semibold))
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

                            Divider().overlay(Color.white.opacity(0.14))

                            Text("Screen Fit")
                                .font(.system(size: 16, weight: .bold))
                            Text("Fit Screen shows the entire video with zero cropping. Fill expands vertical clips edge-to-edge.")
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.68))

                            HStack(spacing: 10) {
                                pillOption(title: "Fit Screen", active: store.data.settings.videoFitScreen) {
                                    store.data.settings.videoFitScreen = true
                                }
                                pillOption(title: "Fill Screen", active: !store.data.settings.videoFitScreen) {
                                    store.data.settings.videoFitScreen = false
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

                            Divider().overlay(Color.white.opacity(0.14))

                            Text("Bottom Controls & Dock")
                                .font(.system(size: 16, weight: .bold))
                            Text("Collapse the bottom-left controls and dock down so they don't cover the video.")
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.68))

                            HStack(spacing: 10) {
                                pillOption(title: "Expanded", active: !store.data.settings.controlsCollapsed) {
                                    store.data.settings.controlsCollapsed = false
                                }
                                pillOption(title: "Collapsed Down", active: store.data.settings.controlsCollapsed) {
                                    store.data.settings.controlsCollapsed = true
                                }
                            }
                        }
                        .padding(16)
                        .liquidGlassCard(cornerRadius: 20)

                        // OFFLINE VAULT, ROTATION & SECURITY
                        sectionHeader("OFFLINE VAULT & SECURITY")

                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Offline Vault Storage")
                                        .font(.system(size: 15, weight: .bold))
                                    Text("\(store.data.downloaded.count) saved offline · \(offline.totalDiskUsageString())")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.white.opacity(0.68))
                                }
                                Spacer()
                                if !store.data.downloaded.isEmpty {
                                    Button {
                                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                        offline.clearAllDownloads()
                                    } label: {
                                        Text("Clear Vault")
                                            .font(.caption.bold())
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 8)
                                            .liquidGlassCapsule()
                                    }
                                }
                            }

                            Divider().overlay(Color.white.opacity(0.14))

                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Feed Rotation History")
                                        .font(.system(size: 15, weight: .bold))
                                    Text("\(store.data.seenIDs.count) watched videos excluded from repeating")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.white.opacity(0.68))
                                }
                                Spacer()
                                Button {
                                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                    store.clearSeenHistory()
                                } label: {
                                    Text("Reset Seen")
                                        .font(.caption.bold())
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .liquidGlassCapsule()
                                }
                            }

                            Divider().overlay(Color.white.opacity(0.14))

                            // License Key & Encrypted Cloud Sync
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("License Access")
                                            .font(.system(size: 15, weight: .bold))
                                        Text("\(license.expirySummary) · \(license.status.licenseKey.isEmpty ? "Unbound" : license.status.licenseKey)")
                                            .font(.system(size: 12, design: .monospaced))
                                            .foregroundStyle(.white.opacity(0.68))
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Button {
                                        Task {
                                            syncStatusMessage = "Syncing..."
                                            await license.syncEncryptedBackupNow()
                                            syncStatusMessage = "Backup encrypted & synced"
                                        }
                                    } label: {
                                        Text("Sync Backup")
                                            .font(.caption.bold())
                                            .padding(.horizontal, 11)
                                            .padding(.vertical, 7)
                                            .liquidGlassCapsule(active: true)
                                    }
                                }
                                if let syncStatusMessage {
                                    Text(syncStatusMessage)
                                        .font(.caption)
                                        .foregroundStyle(Theme.accentBright)
                                }
                            }

                            Divider().overlay(Color.white.opacity(0.14))

                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Ask Passcode on Open")
                                        .font(.system(size: 15, weight: .bold))
                                    Text(app.hasPasscode
                                         ? "Off by default so you never lose your Likes"
                                         : "Optional extra lock screen")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.white.opacity(0.68))
                                }
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { app.hasPasscode && app.requirePasscodeOnOpen },
                                    set: { on in
                                        if on && !app.hasPasscode {
                                            settingPasscode = true
                                        } else {
                                            app.requirePasscodeOnOpen = on
                                        }
                                    }
                                ))
                                .labelsHidden()
                                .tint(Theme.accent)
                            }

                            if Biometrics.available && app.hasPasscode && app.requirePasscodeOnOpen {
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
                                pillOption(title: app.hasPasscode ? "Change Passcode" : "Set Passcode", active: false) {
                                    if app.hasPasscode {
                                        changingPasscode = true
                                    } else {
                                        settingPasscode = true
                                    }
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
        .sheet(isPresented: $settingPasscode) {
            PasscodeSetupView(mode: .create)
        }
        .sheet(isPresented: $showAlgorithmEditor) {
            AlgorithmEditorSheet()
                .environmentObject(store)
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

// MARK: - Editable Smart Personalization (`#Tags`, Learned Sources, & Blocked `#Tags`)

struct AlgorithmEditorSheet: View {
    @EnvironmentObject var store: UserStore
    @ObservedObject private var taste = SmartTasteEngine.shared
    @Environment(\.dismiss) private var dismiss

    @State private var boostInput = ""
    @State private var blockInput = ""
    @State private var suggestions: [Rule34TagSuggestion] = []
    @State private var autocompleteTask: Task<Void, Never>?

    private var parsedBoostTags: [String] {
        Rule34API.parseTags(boostInput)
    }

    private var parsedBlockTags: [String] {
        Rule34API.parseTags(blockInput)
    }

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Edit Smart Personalization")
                            .font(.system(size: 20, weight: .bold))
                        Text("Spaces create new #tags · Underscores combine words")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.white.opacity(0.62))
                    }
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .frame(width: 36, height: 36)
                            .liquidGlassCircle()
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 12)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        // 0. Orthogonal Archetype Guardrails (Separate Femboy/Trans/Futa from Gay/Yaoi)
                        VStack(alignment: .leading, spacing: 10) {
                            Text("SMART ARCHETYPE GUARDRAILS")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .tracking(1.2)
                                .foregroundStyle(.white.opacity(0.58))

                            Text("Independently boost or hide categories. Hiding Gay / Yaoi will never hide Femboy, Trans Women, or Futanari.")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.65))

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    guardrailToggleChip(label: "Hide Gay (M/M)", tag: "gay", isBlock: true)
                                    guardrailToggleChip(label: "Hide Yaoi / Bara", tag: "yaoi", isBlock: true)
                                    guardrailToggleChip(label: "Boost Femboy", tag: "femboy", isBlock: false)
                                    guardrailToggleChip(label: "Boost Trans Women", tag: "trans_woman", isBlock: false)
                                    guardrailToggleChip(label: "Boost Futanari", tag: "futanari", isBlock: false)
                                }
                            }
                        }
                        .padding(16)
                        .liquidGlassCard(cornerRadius: 20)

                        // 1. Pinned #Tags (Heavy For You Boost)
                        VStack(alignment: .leading, spacing: 12) {
                            Text("PINNED #TAGS (BOOSTED)")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .tracking(1.2)
                                .foregroundStyle(.white.opacity(0.58))

                            HStack(spacing: 8) {
                                HStack(spacing: 8) {
                                    Text("#")
                                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                                        .foregroundStyle(Theme.accentBright)
                                    TextField("e.g. hentai_femboy goth", text: $boostInput)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                        .font(.system(size: 15))
                                        .onSubmit { addPinnedTags() }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                                Button {
                                    addPinnedTags()
                                } label: {
                                    Text("Add")
                                        .font(.system(size: 14, weight: .bold))
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 10)
                                        .liquidGlassCapsule(active: !parsedBoostTags.isEmpty)
                                }
                                .disabled(parsedBoostTags.isEmpty)
                            }

                            if !parsedBoostTags.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 6) {
                                        ForEach(parsedBoostTags, id: \.self) { tag in
                                            Text("#\(tag)")
                                                .font(.system(size: 12, weight: .bold))
                                                .padding(.horizontal, 10)
                                                .padding(.vertical, 5)
                                                .liquidGlassCapsule(active: true)
                                        }
                                    }
                                }
                            }

                            if !suggestions.isEmpty {
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 6) {
                                        ForEach(suggestions.prefix(8)) { s in
                                            Button {
                                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                                store.addBoostedTags(s.value)
                                                boostInput = ""
                                                suggestions = []
                                            } label: {
                                                Text("+ #\(s.value)")
                                                    .font(.system(size: 11.5, weight: .semibold))
                                                    .padding(.horizontal, 10)
                                                    .padding(.vertical, 5)
                                                    .liquidGlassCapsule(tinted: true)
                                            }
                                        }
                                    }
                                }
                            }

                            if store.data.algorithm.boostedTags.isEmpty {
                                Text("No pinned #tags yet. Add any tag above or tap a category below to prioritize it in For You.")
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(.white.opacity(0.55))
                            } else {
                                editableTagGrid(
                                    items: store.data.algorithm.boostedTags.map { ("#\($0)", $0) },
                                    tintActive: true
                                ) { raw in
                                    store.removeBoostedTag(raw)
                                }
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                Text("RECOGNIZED PORN CATEGORIES (TAP TO PIN)")
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .tracking(1.1)
                                    .foregroundStyle(.white.opacity(0.52))

                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 7) {
                                        ForEach(PornTagCatalog.quickPickerCategories, id: \.self) { category in
                                            let isPinned = store.data.algorithm.boostedTags.contains {
                                                (PornTagCatalog.normalize($0, categories: store.categories) ?? $0.lowercased()) == category
                                            }
                                            Button {
                                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                                if isPinned {
                                                    store.removeBoostedTag(category)
                                                } else {
                                                    store.addBoostedTags(category)
                                                    store.adjustLearnedTag(category, delta: 2.0)
                                                }
                                            } label: {
                                                HStack(spacing: 4) {
                                                    Image(systemName: isPinned ? "checkmark" : "plus")
                                                        .font(.system(size: 10, weight: .bold))
                                                    Text(PornTagCatalog.displayTitle(for: category))
                                                        .font(.system(size: 12, weight: .semibold))
                                                }
                                                .padding(.horizontal, 11)
                                                .padding(.vertical, 6)
                                                .liquidGlassCapsule(tinted: !isPinned, active: isPinned)
                                            }
                                            .buttonStyle(ScalePressButtonStyle())
                                        }
                                    }
                                }
                            }
                        }
                        .padding(16)
                        .liquidGlassCard(cornerRadius: 20)

                        // 2. Learned #Tags & Creators / Subreddits
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("LEARNED TASTE SIGNALS")
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .tracking(1.2)
                                    .foregroundStyle(.white.opacity(0.58))
                                Spacer()
                                if !store.topAlgorithmTags.isEmpty || !store.topAlgorithmSubredditEntries.isEmpty {
                                    Button {
                                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                                        store.resetAlgorithm()
                                    } label: {
                                        Text("Reset Profile")
                                            .font(.system(size: 11, weight: .bold))
                                            .foregroundStyle(Theme.accentBright)
                                            .padding(.horizontal, 10)
                                            .padding(.vertical, 4)
                                            .liquidGlassCapsule(tinted: true, active: false)
                                    }
                                }
                            }

                            if !store.topAlgorithmTags.isEmpty {
                                Text("Adjust affinity with − / + or tap × to unlearn any recognized category or tag.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.6))

                                VStack(spacing: 8) {
                                    ForEach(store.topAlgorithmTags, id: \.tag) { entry in
                                        HStack(spacing: 10) {
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(PornTagCatalog.displayTitle(for: entry.tag))
                                                    .font(.system(size: 14, weight: .semibold))
                                                    .foregroundStyle(.white)
                                                Text("#\(entry.tag)")
                                                    .font(.system(size: 11, design: .monospaced))
                                                    .foregroundStyle(.white.opacity(0.52))
                                            }
                                            Spacer()
                                            Text("+\(Int(entry.score.rounded()))")
                                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                                .foregroundStyle(Theme.accentBright)
                                                .frame(minWidth: 32, alignment: .trailing)

                                            Button {
                                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                                store.adjustLearnedTag(entry.tag, delta: -3.0)
                                            } label: {
                                                Image(systemName: "minus")
                                                    .font(.system(size: 11, weight: .bold))
                                                    .frame(width: 28, height: 28)
                                                    .liquidGlassCircle()
                                            }

                                            Button {
                                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                                store.adjustLearnedTag(entry.tag, delta: 3.0)
                                            } label: {
                                                Image(systemName: "plus")
                                                    .font(.system(size: 11, weight: .bold))
                                                    .frame(width: 28, height: 28)
                                                    .liquidGlassCircle()
                                            }

                                            Button {
                                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                                store.removeLearnedTag(entry.tag)
                                            } label: {
                                                Image(systemName: "xmark")
                                                    .font(.system(size: 10.5, weight: .bold))
                                                    .foregroundStyle(.white.opacity(0.72))
                                                    .frame(width: 28, height: 28)
                                                    .liquidGlassCircle()
                                            }
                                        }
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 8)
                                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    }
                                }
                            }

                            if !store.topAlgorithmSubredditEntries.isEmpty {
                                Divider().overlay(Color.white.opacity(0.14))
                                Text("Top sources & subreddits (tap × to unlearn)")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.6))

                                editableTagGrid(
                                    items: store.topAlgorithmSubredditEntries.map { ("r/\($0.name)", $0.name) },
                                    tintActive: false
                                ) { sub in
                                    store.removeLearnedSubreddit(sub)
                                }
                            }

                            if store.topAlgorithmTags.isEmpty && store.topAlgorithmSubredditEntries.isEmpty {
                                Text("Watch, loop, like, save, or search adult categories and your learned taste profile will build here.")
                                    .font(.system(size: 12.5))
                                    .foregroundStyle(.white.opacity(0.55))
                            }
                        }
                        .padding(16)
                        .liquidGlassCard(cornerRadius: 20)

                        // 3. Blocked / Muted #Tags
                        VStack(alignment: .leading, spacing: 12) {
                            Text("BLOCKED #TAGS (HIDDEN EVERYWHERE)")
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .tracking(1.2)
                                .foregroundStyle(.white.opacity(0.58))

                            HStack(spacing: 8) {
                                HStack(spacing: 8) {
                                    Text("#")
                                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.red.opacity(0.85))
                                    TextField("e.g. tag_to_hide", text: $blockInput)
                                        .textInputAutocapitalization(.never)
                                        .autocorrectionDisabled()
                                        .font(.system(size: 15))
                                        .onSubmit { addBlockedTags() }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                                Button {
                                    addBlockedTags()
                                } label: {
                                    Text("Block")
                                        .font(.system(size: 14, weight: .bold))
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 10)
                                        .liquidGlassCapsule()
                                }
                                .disabled(parsedBlockTags.isEmpty)
                            }

                            if !store.data.algorithm.blockedTags.isEmpty {
                                editableTagGrid(
                                    items: store.data.algorithm.blockedTags.map { ("#\($0)", $0) },
                                    tintActive: false
                                ) { tag in
                                    store.removeBlockedTag(tag)
                                }
                            } else {
                                Text("No blocked #tags. Anything added here is automatically filtered out of For You, Search, Rule34, X, and IG.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.55))
                            }

                            if !taste.state.suppressedTags.isEmpty || !taste.state.hiddenOFGenders.isEmpty {
                                Divider().overlay(Color.white.opacity(0.14))
                                Text("AUTO-SUPPRESSED FROM DISLIKES (TAP × TO UNHIDE)")
                                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(.orange.opacity(0.9))
                                if !taste.state.hiddenOFGenders.isEmpty {
                                    editableTagGrid(
                                        items: taste.state.hiddenOFGenders.map { ("gender:\($0)", $0) },
                                        tintActive: false
                                    ) { g in
                                        taste.unhideOFGender(g)
                                    }
                                }
                                if !taste.state.suppressedTags.isEmpty {
                                    editableTagGrid(
                                        items: taste.state.suppressedTags.map { ("#\($0)", $0) },
                                        tintActive: false
                                    ) { tag in
                                        taste.unblockTag(tag)
                                    }
                                }
                            }
                        }
                        .padding(16)
                        .liquidGlassCard(cornerRadius: 20)
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 28)
                }
            }
            .foregroundStyle(.white)
        }
        .onChange(of: boostInput) { _, newValue in
            autocompleteTask?.cancel()
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                suggestions = []
                return
            }
            autocompleteTask = Task {
                try? await Task.sleep(nanoseconds: 220_000_000)
                guard !Task.isCancelled else { return }
                let fetched = await Rule34API.shared.autocomplete(trimmed)
                await MainActor.run { suggestions = fetched }
            }
        }
    }

    private func guardrailToggleChip(label: String, tag: String, isBlock: Bool) -> some View {
        let lower = tag.lowercased()
        let isActive: Bool = isBlock
            ? (store.data.algorithm.blockedTags.contains { $0.lowercased() == lower } || taste.state.suppressedTags.contains(lower))
            : store.data.algorithm.boostedTags.contains { $0.lowercased() == lower }

        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if isBlock {
                if isActive {
                    store.removeBlockedTag(lower)
                    taste.unblockTag(lower)
                } else {
                    store.addBlockedTags(lower)
                    taste.blockDislikedTag(lower)
                }
            } else {
                if isActive {
                    store.removeBoostedTag(lower)
                } else {
                    store.addBoostedTags(lower)
                    store.adjustLearnedTag(lower, delta: 4.0)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isActive ? (isBlock ? "eye.slash.fill" : "checkmark") : (isBlock ? "hand.raised" : "plus"))
                    .font(.system(size: 10.5, weight: .bold))
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .liquidGlassCapsule(tinted: !isActive, active: isActive)
        }
        .buttonStyle(ScalePressButtonStyle())
    }

    private func addPinnedTags() {
        guard !boostInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        store.addBoostedTags(boostInput)
        boostInput = ""
        suggestions = []
    }

    private func addBlockedTags() {
        guard !blockInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        store.addBlockedTags(blockInput)
        blockInput = ""
    }

    private func editableTagGrid(
        items: [(label: String, key: String)],
        tintActive: Bool,
        onRemove: @escaping (String) -> Void
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items, id: \.key) { item in
                    HStack(spacing: 6) {
                        Text(item.label)
                            .font(.system(size: 12.5, weight: .semibold))
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            onRemove(item.key)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.75))
                        }
                    }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .liquidGlassCapsule(tinted: !tintActive, active: tintActive)
                }
            }
        }
    }
}
