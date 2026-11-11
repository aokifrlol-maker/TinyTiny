import SwiftUI

// MARK: - Design Tokens & Gooned Brand Identity

enum Theme {
    static let bg = Color(red: 0.03, green: 0.03, blue: 0.04)
    static let surface = Color(red: 0.08, green: 0.08, blue: 0.10)
    static let surfaceElevated = Color(red: 0.13, green: 0.13, blue: 0.16)
    static let border = Color.white.opacity(0.09)
    static let borderStrong = Color.white.opacity(0.18)

    static let accent = Color(red: 1.0, green: 0.16, blue: 0.42)     // #FF296B
    static let accentSecondary = Color(red: 0.58, green: 0.20, blue: 0.96) // #9433F5
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.64)
    static let textMuted = Color.white.opacity(0.42)

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

// MARK: - Centralized Fixed Category System (No Dynamic / AI Categories)

struct GoonedCategory: Identifiable, Hashable, Codable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let accentHex: UInt32
    let query: String
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
            title: "Amateur & Homemade",
            subtitle: "Real creators, bedroom clips & POV",
            icon: "video.fill",
            accentHex: 0xFF2D55,
            query: "Amateur",
            keywords: ["amateur", "homemade", "real", "girlfriend", "pov", "selfie", "webcam", "couple"]
        ),
        GoonedCategory(
            id: "solo",
            title: "Solo & Tease",
            subtitle: "Solo play, dancing, strip & tease",
            icon: "sparkles",
            accentHex: 0xAF52DE,
            query: "Solo Female",
            keywords: ["solo", "masturbation", "tease", "dancing", "twerk", "strip", "lingerie", "JOI", "dildo"]
        ),
        GoonedCategory(
            id: "curves",
            title: "Busty & Curves",
            subtitle: "Thick, curvy, natural & voluptuous",
            icon: "flame.fill",
            accentHex: 0xFF9500,
            query: "Busty",
            keywords: ["busty", "boobs", "tits", "big tits", "natural tits", "curvy", "thick", "pawg", "big ass", "booty", "ass"]
        ),
        GoonedCategory(
            id: "petite",
            title: "Petite & Slim",
            subtitle: "Fit, flexible, spinner & toned",
            icon: "figure.cooldown",
            accentHex: 0x32ADE6,
            query: "Petite",
            keywords: ["petite", "slim", "skinny", "tiny", "fit", "flexible", "college", "cute", "teen", "18"]
        ),
        GoonedCategory(
            id: "hardcore",
            title: "Hardcore",
            subtitle: "High-intensity action & couples",
            icon: "bolt.fill",
            accentHex: 0xFF3B30,
            query: "Hardcore",
            keywords: ["hardcore", "rough", "doggy", "cowgirl", "missionary", "riding", "creampie", "deepthroat", "blowjob", "anal", "cum"]
        ),
        GoonedCategory(
            id: "lesbian",
            title: "Girl on Girl",
            subtitle: "Lesbian, duos & Sapphic scenes",
            icon: "heart.circle.fill",
            accentHex: 0xFF6482,
            query: "Lesbian",
            keywords: ["lesbian", "girl on girl", "scissoring", "threesome", "girls", "sapphic", "kissing"]
        ),
        GoonedCategory(
            id: "milf",
            title: "MILF & Mature",
            subtitle: "Experienced, confident & cougars",
            icon: "crown.fill",
            accentHex: 0xFFD60A,
            query: "MILF",
            keywords: ["milf", "mature", "cougar", "mom", "stepmom", "housewife", "older"]
        ),
        GoonedCategory(
            id: "cosplay",
            title: "Cosplay & Alt",
            subtitle: "Goth, e-girl, costumes & tattooed",
            icon: "theatermasks.fill",
            accentHex: 0x5E5CE6,
            query: "Cosplay",
            keywords: ["cosplay", "goth", "alt", "egirl", "tattoo", "tattooed", "piercing", "maid", "roleplay", "fishnets"]
        ),
        GoonedCategory(
            id: "animated",
            title: "Hentai & 3D",
            subtitle: "2D animation, SFM & 3D renders",
            icon: "wand.and.stars",
            accentHex: 0xBF5AF2,
            query: "Hentai",
            keywords: ["hentai", "3d", "anime", "sfm", "blender", "cartoon", "animated", "rule34", "overwatch"]
        ),
        GoonedCategory(
            id: "other",
            title: "Other",
            subtitle: "Trending variety & uncategorized",
            icon: "square.grid.2x2.fill",
            accentHex: 0x64D2FF,
            query: "Babe",
            keywords: []
        )
    ]

    static let fallback: GoonedCategory = all.last!

    static func byID(_ id: String) -> GoonedCategory {
        all.first { $0.id == id } ?? fallback
    }

    /// Maps any Gif deterministically into one of the 10 fixed categories, with "Other" as fallback.
    static func categorize(_ gif: Gif) -> GoonedCategory {
        let bag = (gif.allTags + gif.allNiches).map { $0.lowercased() }
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

// MARK: - Reusable UI Components

struct AvatarRingView: View {
    let username: String
    var imageURL: String? = nil
    var size: CGFloat = 38
    var showRing: Bool = true

    var body: some View {
        ZStack {
            if showRing {
                Circle()
                    .stroke(Theme.ringGradient, lineWidth: max(2, size * 0.06))
                    .frame(width: size + 6, height: size + 6)
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
                                .font(.system(size: size * 0.44, weight: .bold, design: .rounded))
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
        HStack(spacing: 5) {
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
        .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 0.8))
    }
}

struct ShimmerPlaceholder: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = -1

    var body: some View {
        GeometryReader { geo in
            Theme.surface
                .overlay(
                    LinearGradient(
                        colors: [.clear, Color.white.opacity(0.07), .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: geo.size.width * 0.8)
                    .offset(x: phase * geo.size.width * 1.4)
                )
                .clipped()
        }
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.35).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }
}

struct ScalePressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
