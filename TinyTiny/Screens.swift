import SwiftUI

// MARK: - 1. Browse / Search / Categories / X / Instagram / Rule34 Fullscreen Overlay

struct GoonedBrowseOverlay: View {
    var onClose: () -> Void
    var onSelectFeed: (FeedSource) -> Void
    var onConnectX: () -> Void
    var onConnectIG: () -> Void
    var onSetupR34Key: () -> Void

    enum SearchScope: String, CaseIterable {
        case all = "All"
        case reddit = "Reddit"
        case rule34 = "Rule34"
        case x = "𝕏"
        case ig = "IG"
    }

    @EnvironmentObject var store: UserStore
    @State private var query = ""
    @State private var searchScope: SearchScope = .all
    @State private var searchResults = GoonedSearchResponsePlaceholder()
    @State private var r34Suggestions: [Rule34TagSuggestion] = []
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

                        TextField("Search Reddit, 𝕏, IG, or Rule34 tags...", text: $query)
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
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else {
                searchResults = GoonedSearchResponsePlaceholder()
                r34Suggestions = []
                return
            }
            isSearching = true
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            async let redditTask = try? GoonedAPI.shared.search(q)
            async let r34Task = Rule34API.shared.autocomplete(q)
            let (redditRes, r34Res) = await (redditTask, r34Task)
            if let redditRes {
                searchResults = GoonedSearchResponsePlaceholder(subreddits: redditRes.subreddits, users: redditRes.users)
            }
            r34Suggestions = r34Res
            isSearching = false
        }
    }

    // MARK: - Default Browse Content

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
                        case "igreels": onSelectFeed(.igReels)
                        case "igfollowing": onSelectFeed(.igFollowing)
                        case "igsaved": onSelectFeed(.igSaved)
                        case "iguser": onSelectFeed(.igUser(recent.name))
                        case "rule34": onSelectFeed(.rule34(recent.name == "all" ? "" : recent.name))
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
                        Text(store.data.r34Credentials.isConnected ? "API KEY ACTIVE" : "API KEY (OPTIONAL)")
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

    private func r34Chip(label: String, tag: String) -> some View {
        Button {
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
        switch searchScope {
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
        case .all:
            if clean.lowercased().hasPrefix("r34:") || clean.lowercased().hasPrefix("#") || clean.contains("_") {
                onSelectFeed(.rule34(Rule34API.parseTags(clean).joined(separator: " ")))
            } else if clean.lowercased().hasPrefix("ig:") {
                onSelectFeed(.igUser(clean.replacingOccurrences(of: "ig:", with: "", options: .caseInsensitive)))
            } else if clean.hasPrefix("@") {
                onSelectFeed(.xUser(clean.replacingOccurrences(of: "@", with: "")))
            } else if let cat = matchingCategories.first {
                onSelectFeed(.category(cat.name))
            } else if let firstSub = searchResults.subreddits.first {
                onSelectFeed(.subreddit(firstSub.name))
            } else {
                onSelectFeed(.subreddit(clean.replacingOccurrences(of: "r/", with: "").replacingOccurrences(of: " ", with: "")))
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
        let showR34 = (searchScope == .all || searchScope == .rule34)
        let showX = (searchScope == .all || searchScope == .x)
        let showIG = (searchScope == .all || searchScope == .ig)

        return VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 8) {
                if showR34 && !r34QueryString.isEmpty {
                    Button {
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

    var body: some View {
        ZStack {
            Theme.crimsonBg.ignoresSafeArea()

            VStack(spacing: 0) {
                // Top Bar: Liked vs Offline Vault Switcher + Gear on Right
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Button {
                            withAnimation { mode = "liked" }
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
                            withAnimation { mode = "offline" }
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

                        if mode == "offline", let firstOffline = filteredItems.first {
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
                                Button {
                                    if mode == "offline" {
                                        onPlayOfflinePost(post)
                                    } else {
                                        onPlayLikedPost(post)
                                    }
                                } label: {
                                    GridThumb(gif: post, isOfflineBadge: offline.isDownloaded(post))
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
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
                        .padding(.bottom, 92)
                    }
                }
            }
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
                    if gif.isXPost {
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
        !store.data.followedIGUsers.isEmpty
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
    @State private var changingPasscode = false
    @State private var confirmErase = false

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

                            if store.data.settings.algorithmEnabled && store.data.algorithm.totalSignals > 0 {
                                Divider().overlay(Color.white.opacity(0.14))
                                HStack {
                                    Text("\(store.data.algorithm.totalSignals) signals learned on-device")
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(.white.opacity(0.55))
                                    Spacer()
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
                                    Text(store.data.r34Credentials.isConnected ? "Authenticated DAPI key active" : "Built-in Rule34 active · Add key for direct DAPI")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.white.opacity(0.68))
                                }
                                Spacer()
                                Button(action: onSetupR34Key) {
                                    Text(store.data.r34Credentials.isConnected ? "Edit Key" : "API Key")
                                        .font(.caption.bold())
                                        .padding(.horizontal, 13)
                                        .padding(.vertical, 8)
                                        .liquidGlassCapsule()
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
