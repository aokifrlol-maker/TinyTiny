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
    @Published var hasPasscode: Bool = Passcode.exists
    @Published var isLocked = true
    @Published var hasUnlockedOnce = false

    func unlock() {
        isLocked = false
        hasUnlockedOnce = true
    }

    func lock() {
        if hasPasscode { isLocked = true }
    }

    func eraseEverything() {
        Passcode.delete()
        UserStore.shared.eraseAll()
        ageConfirmed = false
        hasPasscode = false
        isLocked = true
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
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.white.opacity(0.62), Color(red: 1.0, green: 0.72, blue: 0.85).opacity(0.52)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(
                        Capsule()
                            .stroke(
                                LinearGradient(
                                    colors: [.white.opacity(0.24), .white.opacity(0.06)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.7
                            )
                    )
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
            return "Your passcode is your private Gooned vault key."
        }
        return nil
    }

    private var stepBadge: String? {
        guard mode == .create else { return nil }
        switch step {
        case .enter: return "STEP 1 OF 2"
        case .confirm: return "STEP 2 OF 2"
        case .current: return nil
        }
    }

    var body: some View {
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
    @State private var confirmErase = false

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
            Button("Forgot Passcode?") { confirmErase = true }
                .font(.footnote)
                .foregroundStyle(Theme.textSecondary)
                .padding(.bottom, 10)
        }
        .onAppear { if phase == .active { tryFaceID() } }
        .onChange(of: phase) { _, p in if p == .active { tryFaceID() } }
        .confirmationDialog("Reset Gooned Vault?", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("Erase All Data & Reset", role: .destructive) { app.eraseEverything() }
        } message: {
            Text("Your passcode cannot be recovered. Resetting permanently deletes saved likes, follows, and preferences.")
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
