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
    var onFaceID: () -> Void = {}
    var onComplete: (String) -> Void

    private let rows = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["face", "0", "del"]]

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            ZStack {
                Circle()
                    .stroke(Theme.ringGradient, lineWidth: 2)
                    .frame(width: 68, height: 68)
                Circle()
                    .fill(Theme.surfaceElevated)
                    .frame(width: 60, height: 60)
                    .overlay(
                        Image(systemName: "lock.fill")
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(Theme.accent)
                    )
            }

            VStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 21, weight: .bold, design: .rounded))
                    .multilineTextAlignment(.center)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 42)
                }
            }

            HStack(spacing: 18) {
                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .fill(i < code.count ? Theme.accent : Color.white.opacity(0.10))
                        .overlay(Circle().stroke(i < code.count ? Theme.accent : Color.white.opacity(0.32), lineWidth: 1.5))
                        .frame(width: 15, height: 15)
                        .scaleEffect(i < code.count ? 1.12 : 1.0)
                        .animation(.spring(response: 0.2, dampingFraction: 0.6), value: code.count)
                }
            }
            .padding(.top, 4)
            .modifier(Shake(animatableData: CGFloat(shakes)))
            .animation(.default, value: shakes)

            Spacer()

            VStack(spacing: 16) {
                ForEach(rows, id: \.self) { row in
                    HStack(spacing: 24) {
                        ForEach(row, id: \.self) { key in keyView(key) }
                    }
                }
            }
            .padding(.bottom, 36)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg.ignoresSafeArea())
    }

    @ViewBuilder
    private func keyView(_ key: String) -> some View {
        switch key {
        case "face":
            Button(action: onFaceID) {
                Image(systemName: "faceid")
                    .font(.system(size: 28))
                    .frame(width: 76, height: 76)
            }
            .opacity(showFaceID ? 1 : 0)
            .disabled(!showFaceID)
        case "del":
            Button {
                if !code.isEmpty { code.removeLast() }
            } label: {
                Image(systemName: "delete.left.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(width: 76, height: 76)
            }
        default:
            Button {
                guard code.count < 4 else { return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                code.append(key)
                if code.count == 4 {
                    let c = code
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { onComplete(c) }
                }
            } label: {
                Text(key)
                    .font(.system(size: 30, weight: .medium, design: .rounded))
                    .frame(width: 76, height: 76)
                    .background(
                        Circle()
                            .fill(Theme.surfaceElevated)
                            .overlay(Circle().stroke(Theme.border, lineWidth: 1))
                    )
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

    var body: some View {
        PasscodePad(title: title, subtitle: subtitle, code: $code, shakes: shakes) { c in
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
