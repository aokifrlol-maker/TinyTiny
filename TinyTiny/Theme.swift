import SwiftUI

enum Theme {
    static let bg = Color.black
    static let surface = Color(red: 0.07, green: 0.07, blue: 0.09)
    static let surfaceElevated = Color(red: 0.12, green: 0.12, blue: 0.15)
    static let border = Color.white.opacity(0.08)
    static let borderStrong = Color.white.opacity(0.18)

    static let accent = Color(red: 1.0, green: 0.16, blue: 0.42)     // #FF296B
    static let accentSecondary = Color(red: 0.58, green: 0.20, blue: 0.96)
    static let redditOrange = Color(red: 1.0, green: 0.27, blue: 0.0)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.62)
    static let textMuted = Color.white.opacity(0.40)

    static let ringGradient = LinearGradient(
        colors: [
            Color(red: 1.0, green: 0.72, blue: 0.18),
            Color(red: 1.0, green: 0.16, blue: 0.42),
            Color(red: 0.62, green: 0.18, blue: 0.96)
        ],
        startPoint: .bottomLeading,
        endPoint: .topTrailing
    )

    static let brandGradient = LinearGradient(
        colors: [accent, accentSecondary],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

// MARK: - Centralized Fixed 10-Category System (Distinct RedGIFs Tags + Curated 18+ Subreddits)

struct GoonedCategory: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let icon: String
    let accentHex: UInt32
    let redgifsTags: [String]
    let subreddits: [String]
    let keywords: [String]

    var color: Color {
        let r = Double((accentHex >> 16) & 0xFF) / 255.0
        let g = Double((accentHex >> 8) & 0xFF) / 255.0
        let b = Double(accentHex & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    }

    static let all: [GoonedCategory] = [
        GoonedCategory(
            id: "amateur",
            title: "Amateur",
            icon: "video.fill",
            accentHex: 0xFF2D55,
            redgifsTags: ["Amateur", "Homemade", "POV", "Real"],
            subreddits: ["gonewild", "RealGirls", "Amateur", "Homegrown", "NSFWIphone"],
            keywords: ["amateur", "homemade", "real", "girlfriend", "pov", "selfie", "webcam"]
        ),
        GoonedCategory(
            id: "solo",
            title: "Solo & Tease",
            icon: "sparkles",
            accentHex: 0xAF52DE,
            redgifsTags: ["Solo", "Masturbation", "Tease", "Dancing", "Twerk"],
            subreddits: ["gwpublic", "GoneWildAudio", "ChangingRooms", "StripTease", "girlsmasturbating"],
            keywords: ["solo", "masturbation", "tease", "dancing", "twerk", "strip", "lingerie", "joi", "dildo"]
        ),
        GoonedCategory(
            id: "curves",
            title: "Busty & Curves",
            icon: "flame.fill",
            accentHex: 0xFF9500,
            redgifsTags: ["Busty", "Big Tits", "Boobs", "Big Ass", "PAWG", "Curvy"],
            subreddits: ["BustyPetite", "BiggerThanYouThought", "Boobies", "pawg", "ThickChicks", "ass"],
            keywords: ["busty", "boobs", "tits", "big tits", "natural tits", "curvy", "thick", "pawg", "big ass", "booty", "ass"]
        ),
        GoonedCategory(
            id: "petite",
            title: "Petite & Fit",
            icon: "figure.cooldown",
            accentHex: 0x32ADE6,
            redgifsTags: ["Petite", "Skinny", "Fit", "Flexible", "Cute"],
            subreddits: ["PetiteGoneWild", "FitNakedGirls", "xsmallgirls", "funsized", "skinnytail"],
            keywords: ["petite", "slim", "skinny", "tiny", "fit", "flexible", "college", "cute"]
        ),
        GoonedCategory(
            id: "hardcore",
            title: "Hardcore",
            icon: "bolt.fill",
            accentHex: 0xFF3B30,
            redgifsTags: ["Hardcore", "Blowjob", "Creampie", "Doggy Style", "Cowgirl", "Rough"],
            subreddits: ["nsfwhardcore", "NSFW_GIF", "blowjobs", "creampies", "Roughsex", "DoggyStyle"],
            keywords: ["hardcore", "rough", "doggy", "cowgirl", "missionary", "riding", "creampie", "deepthroat", "blowjob", "anal", "cum"]
        ),
        GoonedCategory(
            id: "lesbian",
            title: "Girl on Girl",
            icon: "heart.circle.fill",
            accentHex: 0xFF6482,
            redgifsTags: ["Lesbian", "Girl On Girl", "Scissoring", "Threesome"],
            subreddits: ["lesbians", "dykesgonewild", "girlskissing", "StraightGirlsPlaying"],
            keywords: ["lesbian", "girl on girl", "scissoring", "threesome", "girls", "sapphic", "kissing"]
        ),
        GoonedCategory(
            id: "milf",
            title: "MILF",
            icon: "crown.fill",
            accentHex: 0xFFD60A,
            redgifsTags: ["MILF", "Mature", "Cougar", "Mom"],
            subreddits: ["milf", "GoneWildPlus", "cougars", "MatureMilf"],
            keywords: ["milf", "mature", "cougar", "mom", "stepmom", "housewife"]
        ),
        GoonedCategory(
            id: "cosplay",
            title: "Cosplay & Alt",
            icon: "theatermasks.fill",
            accentHex: 0x5E5CE6,
            redgifsTags: ["Cosplay", "Goth", "Alt", "Tattoo", "Egirl"],
            subreddits: ["nsfwcosplay", "bigtiddygothgf", "AltGirls", "CosplayGirls", " SuicideGirls"],
            keywords: ["cosplay", "goth", "alt", "egirl", "tattoo", "tattooed", "piercing", "maid", "roleplay", "fishnets"]
        ),
        GoonedCategory(
            id: "animated",
            title: "Hentai & 3D",
            icon: "wand.and.stars",
            accentHex: 0xBF5AF2,
            redgifsTags: ["Hentai", "3D", "Anime", "SFM", "Rule 34"],
            subreddits: ["hentai", "Rule34", "SFMCompileClub", "ecchi"],
            keywords: ["hentai", "3d", "anime", "sfm", "blender", "cartoon", "animated", "rule34", "overwatch"]
        ),
        GoonedCategory(
            id: "other",
            title: "Other",
            icon: "square.grid.2x2.fill",
            accentHex: 0x64D2FF,
            redgifsTags: ["Babe", "Glamour", "Sensual", "Lingerie"],
            subreddits: ["nsfw", "nsfw_gifs", "BonerMaterial", "gentlemanbonersnsfw"],
            keywords: []
        )
    ]

    static let fallback: GoonedCategory = all.last!

    static func byID(_ id: String) -> GoonedCategory {
        all.first { $0.id == id } ?? fallback
    }

    static func categorize(_ gif: Gif) -> GoonedCategory {
        if let sub = gif.subreddit?.lowercased() {
            for cat in all {
                if cat.subreddits.contains(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == sub }) {
                    return cat
                }
            }
        }
        let bag = (gif.allTags + gif.allNiches + [gif.description ?? ""]).map { $0.lowercased() }
        var best: (GoonedCategory, Int)? = nil
        for cat in all where cat.id != "other" {
            var hits = 0
            for kw in cat.keywords {
                if bag.contains(where: { $0 == kw || $0.contains(kw) }) {
                    hits += 1
                }
            }
            if hits > 0, hits > (best?.1 ?? 0) {
                best = (cat, hits)
            }
        }
        return best?.0 ?? fallback
    }
}

// MARK: - Minimal Reusable UI Components

struct AvatarRingView: View {
    let username: String
    var imageURL: String? = nil
    var size: CGFloat = 36
    var showRing: Bool = true

    var body: some View {
        ZStack {
            if showRing {
                Circle()
                    .stroke(Theme.ringGradient, lineWidth: max(1.8, size * 0.055))
                    .frame(width: size + 5, height: size + 5)
            }
            AsyncImage(url: URL(string: imageURL ?? "")) { phase in
                if let img = phase.image {
                    img.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Theme.accent.opacity(0.85), Theme.accentSecondary.opacity(0.85)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .overlay(
                            Text(String(username.prefix(1)).uppercased())
                                .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                        )
                }
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
        }
    }
}

struct CategoryBadgePill: View {
    let category: GoonedCategory
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: category.icon)
                .font(.system(size: compact ? 10 : 11, weight: .semibold))
                .foregroundStyle(category.color)
            Text(category.title)
                .font(.system(size: compact ? 11 : 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
        }
        .padding(.horizontal, compact ? 8 : 10)
        .padding(.vertical, compact ? 4 : 5)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

struct ShimmerPlaceholder: View {
    var body: some View {
        Theme.surface
    }
}

struct ScalePressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.93 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.easeOut(duration: 0.14), value: configuration.isPressed)
    }
}
