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
            // Some sideload setups have no keychain access; fall back to app storage.
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
        return (try? await ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Unlock the app")) ?? false
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
        VStack(spacing: 26) {
            Spacer()
            Image(systemName: "lock.fill").font(.system(size: 34)).foregroundStyle(.pink)
            Text(title).font(.title3.bold()).multilineTextAlignment(.center)
            if let subtitle {
                Text(subtitle).font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).padding(.horizontal, 40)
            }
            HStack(spacing: 20) {
                ForEach(0..<4, id: \.self) { i in
                    Circle()
                        .fill(i < code.count ? Color.white : Color.clear)
                        .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                        .frame(width: 15, height: 15)
                }
            }
            .modifier(Shake(animatableData: CGFloat(shakes)))
            .animation(.default, value: shakes)
            Spacer()
            VStack(spacing: 18) {
                ForEach(rows, id: \.self) { row in
                    HStack(spacing: 26) {
                        ForEach(row, id: \.self) { key in keyView(key) }
                    }
                }
            }
            .padding(.bottom, 40)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.ignoresSafeArea())
    }

    @ViewBuilder
    private func keyView(_ key: String) -> some View {
        switch key {
        case "face":
            Button(action: onFaceID) {
                Image(systemName: "faceid").font(.system(size: 30)).frame(width: 78, height: 78)
            }
            .opacity(showFaceID ? 1 : 0)
            .disabled(!showFaceID)
        case "del":
            Button {
                if !code.isEmpty { code.removeLast() }
            } label: {
                Image(systemName: "delete.left").font(.system(size: 24)).frame(width: 78, height: 78)
            }
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
                Text(key).font(.system(size: 32, weight: .regular))
                    .frame(width: 78, height: 78)
                    .background(Circle().fill(Color.white.opacity(0.13)))
            }
        }
    }
}

// MARK: - Screens

struct AgeGateView: View {
    @EnvironmentObject var app: AppState
    @State private var under = false

    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            Text("18+").font(.system(size: 72, weight: .heavy)).foregroundStyle(.pink)
            Text("Adults only").font(.title.bold())
            Text("This app shows sexually explicit content. By continuing you confirm you are at least 18 years old (or the age of majority where you live) and that viewing this content is legal for you.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 30)
            Spacer()
            Button {
                app.ageConfirmed = true
            } label: {
                Text("I'm 18 or older").bold().frame(maxWidth: .infinity).padding()
                    .background(Color.pink, in: RoundedRectangle(cornerRadius: 14))
            }
            Button("I'm under 18") { under = true }.foregroundStyle(.secondary)
        }
        .padding(24)
        .foregroundStyle(.white)
        .background(Color.black.ignoresSafeArea())
        .alert("Sorry", isPresented: $under) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("You must be 18 or older to use this app.")
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
        case .current: return "Enter current passcode"
        case .enter: return mode == .create ? "Create your 4-digit passcode" : "Enter new passcode"
        case .confirm: return "Confirm passcode"
        }
    }

    private var subtitle: String? {
        if let message { return message }
        if mode == .create && step == .enter {
            return "This passcode is your account. You'll need it every time you open the app."
        }
        return nil
    }

    var body: some View {
        PasscodePad(title: title, subtitle: subtitle, code: $code, shakes: shakes) { c in
            handle(c)
        }
        .alert("Unlock with Face ID?", isPresented: $askFaceID) {
            Button("Enable") {
                Task {
                    if await Biometrics.authenticate() { store.data.settings.faceID = true }
                    finish()
                }
            }
            Button("Not now", role: .cancel) { finish() }
        }
    }

    private func handle(_ c: String) {
        code = ""
        switch step {
        case .current:
            if Passcode.verify(c) { step = .enter; message = nil } else { fail("Wrong passcode") }
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
            PasscodePad(title: "Enter Passcode", subtitle: message, code: $code, shakes: shakes,
                        showFaceID: faceIDOn, onFaceID: tryFaceID) { c in
                check(c)
            }
            Button("Forgot passcode?") { confirmErase = true }
                .font(.footnote).foregroundStyle(.secondary).padding(.bottom, 8)
        }
        .onAppear { if phase == .active { tryFaceID() } }
        .onChange(of: phase) { _, p in if p == .active { tryFaceID() } }
        .confirmationDialog("Reset the app?", isPresented: $confirmErase, titleVisibility: .visible) {
            Button("Erase all data & reset", role: .destructive) { app.eraseEverything() }
        } message: {
            Text("Your passcode can't be recovered. Resetting deletes your likes, follows and settings.")
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
                message = "Wrong passcode"
            }
        }
    }
}

/// Shown in the app switcher so nobody sees what you were watching.
struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Image(systemName: "plus.forwardslash.minus").font(.system(size: 60)).foregroundStyle(.orange)
        }
    }
}

