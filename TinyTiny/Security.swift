import SwiftUI
import Security
import CryptoKit
import LocalAuthentication

/// Your 4-digit passcode is your account. Only a hash of it is stored (in the Keychain).
enum Passcode {
    private static let account = "tinytiny.passcode"
    private static let fallbackKey = "tinytiny.passcode.fallback"

    static func hash(_ code: String) -> Data {
        Data(SHA256.hash(data: Data(("tt.v1." + code).utf8)))
    }

    static var exists: Bool { read() != nil }

    static func set(_ code: String) {
        delete()
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecValueData as String: hash(code),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(q as CFDictionary, nil)
        if status != errSecSuccess {
            UserDefaults.standard.set(hash(code), forKey: fallbackKey)
        }
    }

    static func read() -> Data? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data {
            return d
        }
        return UserDefaults.standard.data(forKey: fallbackKey)
    }

    static func verify(_ code: String) -> Bool { read() == hash(code) }

    static func delete() {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(q as CFDictionary)
        UserDefaults.standard.removeObject(forKey: fallbackKey)
    }
}

enum Biometrics {
    static var available: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
    }

    static func authenticate() async -> Bool {
        let ctx = LAContext()
        ctx.localizedFallbackTitle = "Enter Passcode"
        return (try? await ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Unlock Gooned")) ?? false
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var ageConfirmed: Bool = UserDefaults.standard.bool(forKey: "ageConfirmed") {
        didSet { UserDefaults.standard.set(ageConfirmed, forKey: "ageConfirmed") }
    }
    @Published var onboardingCompleted: Bool = UserDefaults.standard.bool(forKey: "tt.onboardingCompleted") || LicenseManager.shared.isValidAccess {
        didSet { UserDefaults.standard.set(onboardingCompleted, forKey: "tt.onboardingCompleted") }
    }
    @Published var licenseActivated: Bool = LicenseManager.shared.isValidAccess
    @Published var passcodeChoiceCompleted: Bool = UserDefaults.standard.bool(forKey: "tt.passcodeChoiceCompleted") || Passcode.exists {
        didSet { UserDefaults.standard.set(passcodeChoiceCompleted, forKey: "tt.passcodeChoiceCompleted") }
    }
    @Published var hasPasscode: Bool = Passcode.exists
    /// By default once License + Passcode setup completes, the app never prompts for a passcode on launch
    /// (so users aren't locked out of their likes/vault), unless they explicitly turn ON "Lock on Open" in Settings.
    @Published var requirePasscodeOnOpen: Bool = UserDefaults.standard.bool(forKey: "tt.requirePasscodeOnOpen") {
        didSet { UserDefaults.standard.set(requirePasscodeOnOpen, forKey: "tt.requirePasscodeOnOpen") }
    }
    @Published var isLocked: Bool = Passcode.exists && UserDefaults.standard.bool(forKey: "tt.requirePasscodeOnOpen")
    @Published var hasUnlockedOnce = !(Passcode.exists && UserDefaults.standard.bool(forKey: "tt.requirePasscodeOnOpen"))

    func unlock() {
        isLocked = false
        hasUnlockedOnce = true
    }

    func lock() {
        if hasPasscode && requirePasscodeOnOpen { isLocked = true }
    }

    func skipPasscodeOnOnboarding() {
        Passcode.delete()
        hasPasscode = false
        passcodeChoiceCompleted = true
        isLocked = false
        hasUnlockedOnce = true
    }

    func removePasscodeKeepingData() {
        Passcode.delete()
        hasPasscode = false
        isLocked = false
        hasUnlockedOnce = true
    }

    func eraseEverything() {
        Passcode.delete()
        UserStore.shared.eraseAll()
        LicenseManager.shared.clearLicense()
        licenseActivated = false
        ageConfirmed = false
        onboardingCompleted = false
        hasPasscode = false
        passcodeChoiceCompleted = false
        isLocked = false
        hasUnlockedOnce = false
    }
}

// MARK: - Keypad UI

struct Shake: GeometryEffect {
    var animatableData: CGFloat
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 10 * sin(animatableData * .pi * 4), y: 0))
    }
}

struct PasscodePad: View {
    let title: String
    var subtitle: String?
    @Binding var code: String
    var shakes: Int
    var showFaceID = false
    var stepBadge: String? = nil
    var showSignature: Bool = false
    var onFaceID: () -> Void = {}
    var onComplete: (String) -> Void

    private let rows = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["face", "0", "del"]]

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            // Soft Ambient Liquid Glass Backdrop
            ZStack {
                Theme.bg.ignoresSafeArea()

                RadialGradient(
                    colors: [
                        Color(red: 0.72, green: 0.16, blue: 0.38).opacity(0.28),
                        Color(red: 0.36, green: 0.08, blue: 0.24).opacity(0.12),
                        .clear
                    ],
                    center: UnitPoint(x: 0.22, y: 0.16),
                    startRadius: 20,
                    endRadius: 380
                )
                .ignoresSafeArea()

                RadialGradient(
                    colors: [
                        Color(red: 0.44, green: 0.14, blue: 0.52).opacity(0.20),
                        .clear
                    ],
                    center: UnitPoint(x: 0.84, y: 0.82),
                    startRadius: 15,
                    endRadius: 340
                )
                .ignoresSafeArea()
            }

            VStack(spacing: 22) {
                Spacer()

                if let stepBadge {
                    Text(stepBadge)
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .tracking(1.6)
                        .foregroundStyle(.white.opacity(0.68))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(
                            Capsule()
                                .stroke(
                                    LinearGradient(
                                        colors: [.white.opacity(0.32), .white.opacity(0.08)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 0.8
                                )
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                }

                // Liquid Glass Lock Emblem
                ZStack {
                    Circle()
                        .fill(Theme.accent.opacity(0.22))
                        .frame(width: 78, height: 78)
                        .blur(radius: 16)

                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 68, height: 68)
                        .overlay(
                            Circle()
                                .fill(
                                    LinearGradient(
                                        colors: [.white.opacity(0.18), .white.opacity(0.02)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        )
                        .overlay(
                            Circle()
                                .stroke(
                                    LinearGradient(
                                        colors: [.white.opacity(0.55), Theme.accentBright.opacity(0.35), .white.opacity(0.10)],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    lineWidth: 1.1
                                )
                        )
                        .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
                        .overlay(
                            Image(systemName: "lock.fill")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [.white, Color(red: 1.0, green: 0.72, blue: 0.84)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                        )
                }

                VStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 23, weight: .semibold, design: .rounded))
                        .tracking(-0.3)
                        .multilineTextAlignment(.center)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 13.5, weight: .regular))
                            .foregroundStyle(.white.opacity(0.68))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 42)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: title)

                // Liquid Glass Passcode Indicator Well
                HStack(spacing: 20) {
                    ForEach(0..<4, id: \.self) { i in
                        let filled = i < code.count
                        Circle()
                            .fill(filled ? Theme.accentBright : Color.white.opacity(0.10))
                            .overlay(
                                Circle()
                                    .stroke(filled ? Color.white.opacity(0.55) : Color.white.opacity(0.28), lineWidth: 1)
                            )
                            .frame(width: 13, height: 13)
                            .shadow(color: filled ? Theme.accentBright.opacity(0.70) : .clear, radius: 7)
                            .scaleEffect(filled ? 1.18 : 1.0)
                            .animation(.spring(response: 0.24, dampingFraction: 0.68), value: code.count)
                    }
                }
                .padding(.horizontal, 26)
                .padding(.vertical, 14)
                .background(
                    ZStack {
                        Capsule().fill(.ultraThinMaterial)
                        Capsule().fill(Color.white.opacity(0.05))
                    }
                )
                .overlay(
                    Capsule()
                        .stroke(
                            LinearGradient(
                                colors: [.white.opacity(0.34), .white.opacity(0.10)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.9
                        )
                )
                .shadow(color: .black.opacity(0.28), radius: 12, y: 6)
                .padding(.top, 2)
                .modifier(Shake(animatableData: CGFloat(shakes)))
                .animation(.default, value: shakes)

                Spacer()

                // Apple-style Translucent Glass Keypad
                VStack(spacing: 16) {
                    ForEach(rows, id: \.self) { row in
                        HStack(spacing: 24) {
                            ForEach(row, id: \.self) { key in keyView(key) }
                        }
                    }
                }
                .padding(.bottom, showSignature ? 46 : 36)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if showSignature {
                Text("by bella")
                    .font(.system(size: 12, weight: .medium, design: .serif))
                    .italic()
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.24))
                    .padding(.trailing, 22)
                    .padding(.bottom, 16)
            }
        }
    }

    @ViewBuilder
    private func keyView(_ key: String) -> some View {
        switch key {
        case "face":
            Button(action: onFaceID) {
                Image(systemName: "faceid")
                    .font(.system(size: 26, weight: .light))
                    .foregroundStyle(.white.opacity(0.88))
                    .frame(width: 78, height: 78)
                    .background(
                        ZStack {
                            Circle().fill(.ultraThinMaterial)
                            Circle().fill(Color.white.opacity(0.04))
                        }
                    )
                    .overlay(
                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: [.white.opacity(0.28), .white.opacity(0.06)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.85
                            )
                    )
            }
            .buttonStyle(ScalePressButtonStyle())
            .opacity(showFaceID ? 1 : 0)
            .disabled(!showFaceID)
        case "del":
            Button {
                if !code.isEmpty {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    code.removeLast()
                }
            } label: {
                Image(systemName: "delete.backward")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(.white.opacity(code.isEmpty ? 0.35 : 0.82))
                    .frame(width: 78, height: 78)
                    .contentShape(Circle())
            }
            .buttonStyle(ScalePressButtonStyle())
        default:
            Button {
                guard code.count < 4 else { return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                code.append(key)
                if code.count == 4 {
                    let c = code
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { onComplete(c) }
                }
            } label: {
                Text(key)
                    .font(.system(size: 30, weight: .regular, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 78, height: 78)
                    .background(
                        ZStack {
                            Circle().fill(.ultraThinMaterial)
                            Circle().fill(
                                LinearGradient(
                                    colors: [.white.opacity(0.15), .white.opacity(0.03)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        }
                    )
                    .overlay(
                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: [.white.opacity(0.42), .white.opacity(0.10)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.9
                            )
                    )
                    .shadow(color: .black.opacity(0.30), radius: 10, y: 5)
            }
            .buttonStyle(ScalePressButtonStyle())
        }
    }
}

// MARK: - Age Gate & Lock Screens

struct AgeGateView: View {
    @EnvironmentObject var app: AppState
    @State private var under = false

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .stroke(Theme.ringGradient, lineWidth: 3)
                    .frame(width: 108, height: 108)
                Circle()
                    .fill(Theme.surfaceElevated)
                    .frame(width: 96, height: 96)
                    .overlay(
                        Text("18+")
                            .font(.system(size: 36, weight: .black, design: .rounded))
                            .foregroundStyle(Theme.ringGradient)
                    )
            }

            VStack(spacing: 10) {
                Text("Welcome to Gooned")
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                Text("Adults Only (18+)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                Text("This platform contains sexually explicit adult media. By entering, you confirm you are at least 18 years old (or the legal age of majority in your jurisdiction).")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }

            Spacer()

            VStack(spacing: 12) {
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    app.ageConfirmed = true
                } label: {
                    Text("I am 18 or older — Continue")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Theme.brandGradient, in: RoundedRectangle(cornerRadius: 16))
                        .foregroundStyle(.white)
                }
                .buttonStyle(ScalePressButtonStyle())

                Button("I am under 18") { under = true }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.vertical, 6)
            }
        }
        .padding(24)
        .foregroundStyle(.white)
        .background(Theme.bg.ignoresSafeArea())
        .alert("Access Restricted", isPresented: $under) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("You must be at least 18 years old to use Gooned.")
        }
    }
}

struct WelcomeOnboardingView: View {
    var onContinue: () -> Void

    @State private var page = 0
    @State private var heroEntered = false
    @State private var pulseRing = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()

            // Animated ambient motion-graphics aura
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
                let t = tl.date.timeIntervalSinceReferenceDate
                ZStack {
                    Circle()
                        .fill(Color(red: 0.88, green: 0.16, blue: 0.48).opacity(0.28))
                        .frame(width: 340, height: 340)
                        .blur(radius: 75)
                        .offset(
                            x: CGFloat(cos(t * 0.55) * 60) - 40,
                            y: CGFloat(sin(t * 0.42) * 50) - 180
                        )
                    Circle()
                        .fill(Color(red: 0.42, green: 0.18, blue: 0.88).opacity(0.24))
                        .frame(width: 300, height: 300)
                        .blur(radius: 70)
                        .offset(
                            x: CGFloat(sin(t * 0.48) * 65) + 70,
                            y: CGFloat(cos(t * 0.37) * 55) + 190
                        )
                }
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    HStack(spacing: 6) {
                        ForEach(0..<4, id: \.self) { idx in
                            Capsule()
                                .fill(idx == page ? Color.white : Color.white.opacity(0.24))
                                .frame(width: idx == page ? 24 : 7, height: 7)
                                .animation(.spring(response: 0.35, dampingFraction: 0.8), value: page)
                        }
                    }
                    Spacer()
                    if page < 3 {
                        Button("Skip") {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            onContinue()
                        }
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 16)

                TabView(selection: $page) {
                    heroPage.tag(0)
                    featuresPage.tag(1)
                    settingsGuidePage.tag(2)
                    readyPage.tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.spring(response: 0.45, dampingFraction: 0.85), value: page)
            }
        }
        .foregroundStyle(.white)
        .onAppear {
            withAnimation(.spring(response: 0.75, dampingFraction: 0.82)) {
                heroEntered = true
            }
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                pulseRing = true
            }
        }
    }

    private var heroPage: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .stroke(Theme.ringGradient, lineWidth: 2.5)
                    .frame(width: pulseRing ? 132 : 116, height: pulseRing ? 132 : 116)
                    .opacity(pulseRing ? 0.35 : 0.85)
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 96, height: 96)
                    .overlay(Circle().stroke(Color.white.opacity(0.28), lineWidth: 1))
                    .overlay(
                        Image(systemName: "sparkles")
                            .font(.system(size: 36, weight: .bold))
                            .foregroundStyle(Theme.ringGradient)
                    )
            }
            .scaleEffect(heroEntered ? 1 : 0.72)
            .opacity(heroEntered ? 1 : 0)

            VStack(spacing: 12) {
                Text("Welcome to Gooned")
                    .font(.system(size: 34, weight: .black, design: .rounded))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.white, Color(red: 1.0, green: 0.72, blue: 0.88)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .offset(y: heroEntered ? 0 : 18)
                    .opacity(heroEntered ? 1 : 0)

                Text("by bella")
                    .font(.system(size: 15, weight: .medium, design: .serif))
                    .italic()
                    .tracking(1.0)
                    .foregroundStyle(.white.opacity(0.36))
                    .scaleEffect(heroEntered ? 1 : 0.92)
                    .opacity(heroEntered ? 1 : 0)

                Text("Every feed you actually want, all in one fast private app.")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.68))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
                    .padding(.top, 4)
            }

            Spacer()

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation { page = 1 }
            } label: {
                HStack(spacing: 8) {
                    Text("Swipe to see what's inside")
                        .font(.system(size: 15, weight: .bold))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .bold))
                }
                .foregroundStyle(.white.opacity(0.88))
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .background(Color.white.opacity(0.10), in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.22), lineWidth: 0.9))
            }
            .padding(.bottom, 34)
        }
        .padding(.horizontal, 20)
    }

    private var featuresPage: some View {
        VStack(spacing: 20) {
            Spacer()

            VStack(spacing: 6) {
                Text("All you need")
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                Text("to goon your brains out")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.68))
            }

            VStack(spacing: 12) {
                onboardingCard(
                    icon: "square.stack.3d.up.fill",
                    accent: Color(red: 0.96, green: 0.28, blue: 0.56),
                    title: "6 Sites, 1 Spot",
                    detail: "X, Instagram, OnlyFans, Reddit, Rule34, and Long Videos — all right here."
                )
                onboardingCard(
                    icon: "brain.head.profile",
                    accent: Color(red: 0.56, green: 0.36, blue: 0.98),
                    title: "Learns Your Type",
                    detail: "Picks up on what you actually like, even on untagged videos, without mixing up your niches."
                )
                onboardingCard(
                    icon: "lock.shield.fill",
                    accent: Color(red: 0.20, green: 0.82, blue: 0.68),
                    title: "Send Drops Privately",
                    detail: "Select a bunch of liked vids and send an encrypted tinytiny://drop/ link."
                )
            }
            .padding(.horizontal, 20)

            Spacer()

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation { page = 2 }
            } label: {
                Text("How it works")
                    .font(.system(size: 15.5, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Theme.brandGradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 30)
        }
    }

    private var settingsGuidePage: some View {
        VStack(spacing: 20) {
            Spacer()

            VStack(spacing: 6) {
                Text("Quick rundown")
                    .font(.system(size: 26, weight: .heavy, design: .rounded))
                    .multilineTextAlignment(.center)
                Text("Everything lives in the ⚙️ Gear menu")
                    .font(.system(size: 14.5))
                    .foregroundStyle(.white.opacity(0.68))
            }

            VStack(spacing: 12) {
                onboardingCard(
                    icon: "hand.tap.fill",
                    accent: Color(red: 0.98, green: 0.62, blue: 0.22),
                    title: "Tap & Hold",
                    detail: "Double-tap to like, hold anywhere for 2x speed, or hit Full Wide to flip sideways."
                )
                onboardingCard(
                    icon: "slider.horizontal.3",
                    accent: Color(red: 0.28, green: 0.72, blue: 0.98),
                    title: "Tune Your Feed",
                    detail: "Open ⚙️ → Smart Algorithm to boost tags, block stuff you hate, or lock in guardrails."
                )
                onboardingCard(
                    icon: "key.icloud.fill",
                    accent: Color(red: 0.78, green: 0.36, blue: 0.96),
                    title: "Accounts & Lock",
                    detail: "Sign into X/IG, turn on Auto-Scroll, or set a 4-digit passcode whenever you want."
                )
            }
            .padding(.horizontal, 20)

            Spacer()

            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation { page = 3 }
            } label: {
                Text("Almost done")
                    .font(.system(size: 15.5, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Theme.brandGradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 30)
        }
    }

    private var readyPage: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Theme.accent.opacity(0.22))
                    .frame(width: 96, height: 96)
                    .blur(radius: 18)
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 82, height: 82)
                    .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 1))
                    .overlay(
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 34, weight: .bold))
                            .foregroundStyle(Theme.ringGradient)
                    )
            }

            VStack(spacing: 8) {
                Text("One last thing")
                    .font(.system(size: 30, weight: .black, design: .rounded))
                Text("Drop in your license key, set a passcode if you want one, and you're in.")
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 28)
            }

            Spacer()

            Button {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                onContinue()
            } label: {
                Text("Enter License Key")
                    .font(.system(size: 16.5, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Theme.brandGradient, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .foregroundStyle(.white)
            }
            .buttonStyle(ScalePressButtonStyle())
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
    }

    private func onboardingCard(icon: String, accent: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(accent.opacity(0.20))
                    .frame(width: 42, height: 42)
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(accent)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15.5, weight: .bold, design: .rounded))
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.70))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.14), lineWidth: 0.8)
        )
    }
}

struct PasscodeSetupView: View {
    enum Mode { case create, change }
    let mode: Mode

    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: UserStore
    @Environment(\.dismiss) private var dismiss

    private enum Step { case current, enter, confirm }
    @State private var step: Step
    @State private var first = ""
    @State private var code = ""
    @State private var shakes = 0
    @State private var message: String?
    @State private var askFaceID = false

    init(mode: Mode) {
        self.mode = mode
        _step = State(initialValue: mode == .change ? .current : .enter)
    }

    private var title: String {
        switch step {
        case .current: return "Enter Current Passcode"
        case .enter: return mode == .create ? "Create 4-Digit Passcode" : "Enter New Passcode"
        case .confirm: return "Confirm Passcode"
        }
    }

    private var subtitle: String? {
        if let message { return message }
        if mode == .create && step == .enter {
            return "Optional — skip below to stay unlocked"
        }
        return nil
    }

    private var stepBadge: String? {
        guard mode == .create else { return nil }
        switch step {
        case .enter: return "OPTIONAL LOCK"
        case .confirm: return "CONFIRM LOCK"
        case .current: return nil
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            PasscodePad(
                title: title,
                subtitle: subtitle,
                code: $code,
                shakes: shakes,
                stepBadge: stepBadge,
                showSignature: true
            ) { c in
                handle(c)
            }

            if mode == .create {
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    app.skipPasscodeOnOnboarding()
                } label: {
                    Text("Skip Passcode")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                }
                .padding(.bottom, 10)
            }
        }
        .alert("Enable Face ID Unlock?", isPresented: $askFaceID) {
            Button("Enable Face ID") {
                Task {
                    if await Biometrics.authenticate() { store.data.settings.faceID = true }
                    finish()
                }
            }
            Button("Not Now", role: .cancel) { finish() }
        }
    }

    private func handle(_ c: String) {
        code = ""
        switch step {
        case .current:
            if Passcode.verify(c) { step = .enter; message = nil } else { fail("Incorrect passcode") }
        case .enter:
            first = c
            step = .confirm
            message = nil
        case .confirm:
            if c == first {
                Passcode.set(c)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                if mode == .create && Biometrics.available { askFaceID = true } else { finish() }
            } else {
                step = .enter
                fail("Passcodes didn't match. Try again.")
            }
        }
    }

    private func fail(_ msg: String) {
        message = msg
        shakes += 1
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    private func finish() {
        app.passcodeChoiceCompleted = true
        if mode == .create {
            app.hasPasscode = true
            app.unlock()
        } else {
            dismiss()
        }
    }
}

struct LockView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var store: UserStore
    @Environment(\.scenePhase) private var phase

    @State private var code = ""
    @State private var shakes = 0
    @State private var failures = 0
    @State private var lockedUntil: Date?
    @State private var message: String?
    @State private var showKeyRecovery = false
    @State private var recoveryKeyInput = ""
    @State private var recoveryError: String?

    private var faceIDOn: Bool { store.data.settings.faceID && Biometrics.available }

    var body: some View {
        ZStack(alignment: .bottom) {
            PasscodePad(
                title: "Unlock Vault",
                subtitle: message,
                code: $code,
                shakes: shakes,
                showFaceID: faceIDOn,
                onFaceID: tryFaceID
            ) { c in
                check(c)
            }
            Button("Forgot Passcode? Recover with License Key") { showKeyRecovery = true }
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.textSecondary)
                .padding(.bottom, 12)
        }
        .onAppear { if phase == .active { tryFaceID() } }
        .onChange(of: phase) { _, p in if p == .active { tryFaceID() } }
        .alert("Reset Passcode (Keep All Likes & Data)", isPresented: $showKeyRecovery) {
            TextField("TT-XXXX-XXXX-XXXX", text: $recoveryKeyInput)
                .textInputAutocapitalization(.characters)
            Button("Remove Passcode") {
                Task {
                    if await LicenseManager.shared.verifyPasscodeRecovery(rawKey: recoveryKeyInput) {
                        app.removePasscodeKeepingData()
                    } else {
                        message = "License key did not match."
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter your active License Key to remove your lock passcode without losing likes, follows, or downloads.")
        }
    }

    private func tryFaceID() {
        guard faceIDOn, app.isLocked else { return }
        Task {
            if await Biometrics.authenticate() { app.unlock() }
        }
    }

    private func check(_ c: String) {
        code = ""
        if let until = lockedUntil, until > Date() {
            message = "Too many attempts. Try again in \(Int(until.timeIntervalSinceNow) + 1)s."
            shakes += 1
            return
        }
        if Passcode.verify(c) {
            failures = 0
            message = nil
            app.unlock()
        } else {
            failures += 1
            shakes += 1
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            if failures >= 5 {
                failures = 0
                lockedUntil = Date().addingTimeInterval(30)
                message = "Too many attempts. Wait 30 seconds."
            } else {
                message = "Incorrect passcode"
            }
        }
    }
}

/// Shown in the iOS App Switcher so nobody sees what you were watching.
struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Image(systemName: "plus.forwardslash.minus")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
        }
    }
}
