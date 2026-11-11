import SwiftUI

enum Theme {
    // gooned.app signature #E53164 Crimson-Rose Liquid Glass palette
    static let bg = Color(red: 0.05, green: 0.02, blue: 0.04)
    static let crimsonBg = Color(red: 0.56, green: 0.14, blue: 0.28)
    static let crimsonModal = Color(red: 0.44, green: 0.12, blue: 0.23)
    static let crimsonCard = Color(red: 0.62, green: 0.20, blue: 0.34)
    static let accent = Color(red: 0.90, green: 0.19, blue: 0.39) // #E53164
    static let accentBright = Color(red: 1.0, green: 0.24, blue: 0.46)

    static let surface = Color.white.opacity(0.11)
    static let surfaceElevated = Color.white.opacity(0.17)
    static let border = Color.white.opacity(0.22)
    static let borderSubtle = Color.white.opacity(0.14)

    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.68)
    static let textMuted = Color.white.opacity(0.42)

    static let ringGradient = LinearGradient(
        colors: [accentBright, accent, Color(red: 0.68, green: 0.14, blue: 0.36)],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let brandGradient = LinearGradient(
        colors: [accentBright, accent],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let modalGradient = LinearGradient(
        colors: [
            Color(red: 0.58, green: 0.16, blue: 0.30),
            Color(red: 0.42, green: 0.11, blue: 0.22),
            Color(red: 0.28, green: 0.07, blue: 0.15)
        ],
        startPoint: .top,
        endPoint: .bottom
    )
}

// MARK: - Liquid Glass Modifiers (Tinted vs Clear, matching gooned.app Settings)

struct LiquidGlassCapsule: ViewModifier {
    var tinted: Bool = true
    var active: Bool = false

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    Capsule().fill(.ultraThinMaterial)
                    if active {
                        Capsule().fill(Theme.accent.opacity(0.85))
                    } else if tinted {
                        Capsule().fill(Color(red: 0.22, green: 0.06, blue: 0.12).opacity(0.55))
                    } else {
                        Capsule().fill(Color.black.opacity(0.25))
                    }
                }
            )
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(active ? 0.42 : 0.22), lineWidth: 0.9)
            )
    }
}

struct LiquidGlassCircle: ViewModifier {
    var tinted: Bool = true
    var active: Bool = false

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    Circle().fill(.ultraThinMaterial)
                    if active {
                        Circle().fill(Theme.accent.opacity(0.85))
                    } else if tinted {
                        Circle().fill(Color(red: 0.22, green: 0.06, blue: 0.12).opacity(0.55))
                    } else {
                        Circle().fill(Color.black.opacity(0.28))
                    }
                }
            )
            .overlay(
                Circle()
                    .stroke(Color.white.opacity(active ? 0.42 : 0.22), lineWidth: 0.9)
            )
    }
}

struct LiquidGlassCard: ViewModifier {
    var cornerRadius: CGFloat = 22
    var tinted: Bool = true

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(tinted ? Color.white.opacity(0.10) : Color.white.opacity(0.05))
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(0.22), lineWidth: 0.9)
            )
    }
}

extension View {
    func liquidGlassCapsule(tinted: Bool = true, active: Bool = false) -> some View {
        modifier(LiquidGlassCapsule(tinted: tinted, active: active))
    }

    func liquidGlassCircle(tinted: Bool = true, active: Bool = false) -> some View {
        modifier(LiquidGlassCircle(tinted: tinted, active: active))
    }

    func liquidGlassCard(cornerRadius: CGFloat = 22, tinted: Bool = true) -> some View {
        modifier(LiquidGlassCard(cornerRadius: cornerRadius, tinted: tinted))
    }
}

// MARK: - Exact gooned.app Category Catalog (Featured + A-Z)

struct GoonedCategory: Identifiable, Hashable, Codable {
    var id: String { name }
    let name: String
    var displayName: String {
        switch name {
        case "BigTits": return "Big Tits"
        case "Rule34": return "Rule 34"
        default: return name
        }
    }
    var subscribers: Int
    var subreddits: [String]

    static let featuredNames = ["Gooning", "TikTok", "OnlyFans", "Snapchat"]

    static let defaultCategories: [GoonedCategory] = [
        GoonedCategory(name: "Gooning", subscribers: 7_834_580, subreddits: ["GOONED", "pornrelapsed", "PORNism", "PornIsCheating"]),
        GoonedCategory(name: "TikTok", subscribers: 8_886_694, subreddits: ["tiktokthots", "tiktokporn", "tiktoknsfw", "TikTok_Ass", "TikTok_Tits"]),
        GoonedCategory(name: "OnlyFans", subscribers: 5_433_860, subreddits: ["OnlyFans101", "Slutsofonlyfans", "onlyfanshottest", "onlyfans_blessed", "onlyfans_wild"]),
        GoonedCategory(name: "Snapchat", subscribers: 2_908_652, subreddits: ["slutsofsnapchat", "NSFW_Snapchat"]),
        GoonedCategory(name: "Ahegao", subscribers: 2_911_729, subreddits: ["RealAhegao", "Ahegao_IRL", "AhegaoGirls", "Ahegaos", "AhegaoHardcore"]),
        GoonedCategory(name: "Amateur", subscribers: 14_945_068, subreddits: ["RealGirls", "homemadexxx", "OnOff", "gonewild", "Amateur"]),
        GoonedCategory(name: "Anal", subscribers: 5_254_238, subreddits: ["AnalGW", "analgonewild", "anal_gifs", "upherbutt", "buttsex"]),
        GoonedCategory(name: "Asian", subscribers: 9_708_194, subreddits: ["AsiansGoneWild", "AsianHotties", "bustyasians", "NSFW_Japan", "AsianCumsluts"]),
        GoonedCategory(name: "Ass", subscribers: 11_378_541, subreddits: ["ass", "bigasses", "booty", "twerking", "pawg"]),
        GoonedCategory(name: "BBW", subscribers: 3_450_607, subreddits: ["chubby", "BBWHardcore", "BBWVideos"]),
        GoonedCategory(name: "BDSM", subscribers: 5_481_168, subreddits: ["SheLikesItRough", "bdsm", "BDSMGW", "Dominated", "Spanking"]),
        GoonedCategory(name: "BigTits", subscribers: 10_623_705, subreddits: ["TittyDrop", "boobbounce", "boobs", "Stacked", "Boobies"]),
        GoonedCategory(name: "Bimbo", subscribers: 2_368_502, subreddits: ["bimbofetish", "BimboCumsluts", "bimbo", "EnhancedFucktoys", "BimboLovers"]),
        GoonedCategory(name: "Blowjob", subscribers: 10_519_362, subreddits: ["Blowjobs", "GirlsFinishingTheJob", "deepthroat", "FaceFuck", "gawkgawkgawk"]),
        GoonedCategory(name: "Cosplay", subscribers: 6_591_046, subreddits: ["cosplaygirls", "nsfwcosplay", "cosplaybabes", "CosplayPornVideos", "CosplayLewd"]),
        GoonedCategory(name: "Creampie", subscribers: 1_959_609, subreddits: ["CreamPieFlowingOut", "Breeding_her", "BreedMeDaddy"]),
        GoonedCategory(name: "Cuckold", subscribers: 6_949_714, subreddits: ["Cuckold", "HotwifeCuckolds", "Hotwife", "wifesharing", "WouldYouFuckMyWife"]),
        GoonedCategory(name: "Cumshot", subscribers: 10_061_699, subreddits: ["cumsluts", "cumshots", "facials", "coveredincum", "creampies"]),
        GoonedCategory(name: "Curvy", subscribers: 8_816_287, subreddits: ["MassiveTitsNAss", "SlimThick", "ThickWhiteGirls", "thick", "curvy"]),
        GoonedCategory(name: "Ebony", subscribers: 5_906_600, subreddits: ["BBCParadise", "EbonyHomemade", "EbonyThroatQueens", "BlackTittyWorld", "EbonyCuties"]),
        GoonedCategory(name: "Feet", subscribers: 3_651_481, subreddits: ["feetfuckers", "Feet_NSFW", "FeetInYourFace", "VIPFeet", "ButtsAndBareFeet"]),
        GoonedCategory(name: "Femboy", subscribers: 3_133_290, subreddits: ["Sissies", "StraightToSissy", "trapsgonewild"]),
        GoonedCategory(name: "Femdom", subscribers: 3_372_328, subreddits: ["Femdom", "FuckingMachines", "facesitting", "pegging", "strapon"]),
        GoonedCategory(name: "Fisting", subscribers: 1_474_341, subreddits: ["Fisting", "gape", "pussystretching"]),
        GoonedCategory(name: "Gangbang", subscribers: 1_360_401, subreddits: ["gangbang", "groupsex_gw", "GroupSexNSFW"]),
        GoonedCategory(name: "Gay", subscribers: 2_527_557, subreddits: ["gayporn", "MalesMasturbating", "GaybrosGoneWild"]),
        GoonedCategory(name: "Goth", subscribers: 7_686_633, subreddits: ["bigtiddygothgf", "gothsluts", "altgonewild", "gothgirlsgw", "suicidegirls"]),
        GoonedCategory(name: "Handjob", subscribers: 1_344_247, subreddits: ["Handjob", "FemdomHandjob", "EliteHandjob"]),
        GoonedCategory(name: "Hardcore", subscribers: 11_145_695, subreddits: ["HardcoreNSFW", "nsfwhardcore", "RoughPorn", "freeuse", "BreedingMaterial"]),
        GoonedCategory(name: "Hentai", subscribers: 8_596_507, subreddits: ["hentai", "HENTAI_GIF", "doujinshi", "Hentai__videos", "Tentai"]),
        GoonedCategory(name: "Indian", subscribers: 2_491_611, subreddits: ["IndiansGoneWild", "IndianHotwife", "desiindiansex"]),
        GoonedCategory(name: "Interracial", subscribers: 3_282_794, subreddits: ["blackchickswhitedicks", "blacked", "BLACKEDPawgs"]),
        GoonedCategory(name: "Latina", subscribers: 5_952_742, subreddits: ["LatinaCuties", "mexicana", "latinchickswhitedicks", "latinas", "Delicias_do_Brasil"]),
        GoonedCategory(name: "Lesbian", subscribers: 5_628_522, subreddits: ["girlskissing", "lesbians", "GirlsWithGirls", "Lesbian_gifs", "CuteLesbians"]),
        GoonedCategory(name: "MILF", subscribers: 7_335_454, subreddits: ["milf", "maturemilf", "MILFs", "gonewild30plus", "realmoms"]),
        GoonedCategory(name: "Petite", subscribers: 12_520_619, subreddits: ["BustyPetite", "PetiteGoneWild", "adorableporn", "LipsThatGrip", "petite"]),
        GoonedCategory(name: "POV", subscribers: 2_197_024, subreddits: ["CheatingPOV", "femalepov", "DoggyStylePOV"]),
        GoonedCategory(name: "Public", subscribers: 8_310_431, subreddits: ["PublicSexPorn", "PublicFlashing", "workgonewild", "Upskirt", "public"]),
        GoonedCategory(name: "Pussy", subscribers: 8_451_811, subreddits: ["grool", "rearpussy", "Innies", "pussy", "Pussy_Perfection"]),
        GoonedCategory(name: "Redheads", subscribers: 2_129_486, subreddits: ["GingerBeauties", "PetiteGingers", "RedheadMILFs", "RedheadsPorn", "redheads"]),
        GoonedCategory(name: "Rule34", subscribers: 5_579_189, subreddits: ["rule34", "FutanariGifs", "Overwatch_Porn"]),
        GoonedCategory(name: "Sluts", subscribers: 7_161_572, subreddits: ["Slut", "sluts", "needysluts"]),
        GoonedCategory(name: "Solo", subscribers: 5_415_854, subreddits: ["gettingherselfoff", "Orgasms", "orgasmcontrol", "jilling", "fingering"]),
        GoonedCategory(name: "Squirt", subscribers: 3_222_102, subreddits: ["Squirting", "Oilporn", "WetOil"]),
        GoonedCategory(name: "Teen", subscribers: 11_487_517, subreddits: ["LegalTeens", "barelylegalteens", "18_19", "TeenBeauties", "CollegeAmateurs"]),
        GoonedCategory(name: "Threesome", subscribers: 2_284_337, subreddits: ["Threesome", "threesomesNSFW", "ThreesomeGW"]),
        GoonedCategory(name: "Toys", subscribers: 2_247_175, subreddits: ["dildo", "HugeDildos", "ToysGW"]),
        GoonedCategory(name: "Trans", subscribers: 8_245_889, subreddits: ["traps", "FemBoys", "transporn", "Tgirls", "GoneWildTrans"]),
        GoonedCategory(name: "Videos", subscribers: 8_023_026, subreddits: ["NSFW_GIF", "nsfw_gifs", "porninfifteenseconds"]),
        GoonedCategory(name: "Vintage", subscribers: 502_444, subreddits: ["VintageBabes", "VintageSmut"])
    ]
}

struct ScalePressButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.easeOut(duration: 0.13), value: configuration.isPressed)
    }
}

struct ShimmerPlaceholder: View {
    var body: some View {
        Color(red: 0.12, green: 0.04, blue: 0.08)
    }
}
