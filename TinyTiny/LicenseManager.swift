import Foundation
import SwiftUI
import Security
import CryptoKit

// MARK: - Persistent License + Encrypted Profile Backup Manager

struct LicenseStatus: Codable, Equatable {
    var licenseKey: String = ""
    var expiresAt: TimeInterval? = nil // nil = lifetime when valid == true
    var isLifetime: Bool = false
    var durationLabel: String = ""
    var isActivated: Bool = false
    var isExpiredOrRevoked: Bool = false
    var lastVerifiedAt: TimeInterval = 0
}

struct EncryptedProfileBackup: Codable {
    var userData: UserData
    var tasteV2: TasteV2Data
    var seedrMasterKey: String
    var updatedAt: TimeInterval
}

@MainActor
final class LicenseManager: ObservableObject {
    static let shared = LicenseManager()

    private static let statusKeychainAccount = "tinytiny.license.status.v1"
    private static let deviceIdKeychainAccount = "tinytiny.device.id.v1"
    private static let serverURLDefaultsKey = "tinytiny.license.server.url"

    /// Default backend Cloudflare Worker URL (can be updated cleanly after `wrangler deploy` or customized in-app).
    static let defaultServerURL = "https://tinytiny-license.aokifrlol.workers.dev"

    @Published var status: LicenseStatus {
        didSet { saveKeychainCodable(status, account: Self.statusKeychainAccount) }
    }
    @Published var serverURL: String {
        didSet { UserDefaults.standard.set(serverURL, forKey: Self.serverURLDefaultsKey) }
    }
    @Published var isChecking: Bool = false
    @Published var errorMessage: String?

    let deviceId: String

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 12
        return URLSession(configuration: cfg)
    }()

    private init() {
        if let loaded: LicenseStatus = Self.loadKeychainCodable(account: Self.statusKeychainAccount) {
            self.status = loaded
        } else {
            self.status = LicenseStatus()
        }

        if let existingId = Self.readRawKeychain(account: Self.deviceIdKeychainAccount), !existingId.isEmpty {
            self.deviceId = existingId
        } else {
            let fresh = UUID().uuidString
            Self.saveRawKeychain(fresh, account: Self.deviceIdKeychainAccount)
            self.deviceId = fresh
        }

        let storedURL = UserDefaults.standard.string(forKey: Self.serverURLDefaultsKey) ?? ""
        self.serverURL = storedURL.isEmpty ? Self.defaultServerURL : storedURL
    }

    var normalizedBaseURL: String {
        serverURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    var isValidAccess: Bool {
        guard status.isActivated, !status.isExpiredOrRevoked else { return false }
        if status.isLifetime { return true }
        if let exp = status.expiresAt {
            return Date().timeIntervalSince1970 < exp
        }
        return true
    }

    var expirySummary: String {
        guard status.isActivated else { return "Not activated" }
        if status.isExpiredOrRevoked { return "Expired / Revoked" }
        if status.isLifetime || status.expiresAt == nil { return "Lifetime License" }
        let rem = max(0, Int((status.expiresAt ?? 0) - Date().timeIntervalSince1970))
        let days = rem / 86400
        let hours = (rem % 86400) / 3600
        if days > 0 { return "\(days)d \(hours)h remaining" }
        let mins = max(1, (rem % 3600) / 60)
        return "\(hours)h \(mins)m remaining"
    }

    // MARK: - Activation & Verification

    func activate(rawKey: String) async -> Bool {
        let cleanKey = rawKey
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        guard cleanKey.count >= 6 else {
            errorMessage = "Enter a valid License Key."
            return false
        }

        isChecking = true
        errorMessage = nil
        defer { isChecking = false }

        // Call License Server (`/v1/activate`)
        guard let url = URL(string: "\(normalizedBaseURL)/v1/activate") else {
            errorMessage = "Invalid License Server URL."
            return false
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["key": cleanKey, "deviceId": deviceId]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                errorMessage = "Server error (HTTP \(code)). Check Worker URL."
                return false
            }

            if (json["valid"] as? Bool) == true {
                var next = LicenseStatus()
                next.licenseKey = cleanKey
                next.isActivated = true
                next.isExpiredOrRevoked = false
                next.isLifetime = (json["lifetime"] as? Bool) ?? (json["expiresAt"] == nil)
                next.expiresAt = json["expiresAt"] as? TimeInterval
                next.durationLabel = (json["durationLabel"] as? String) ?? ""
                next.lastVerifiedAt = Date().timeIntervalSince1970
                status = next

                // Auto-restore encrypted cloud profile (Likes, Follows, Taste) if one exists for this key!
                await restoreEncryptedBackupIfPresent()
                return true
            } else {
                errorMessage = (json["error"] as? String) ?? "Invalid, expired, or device-locked key."
                return false
            }
        } catch {
            errorMessage = "Connection failed: \(error.localizedDescription)"
            return false
        }
    }

    /// Silent check on cold launch / foreground; only flags expired/revoked when server definitively rejects.
    func verifySilently() async {
        guard status.isActivated, !status.licenseKey.isEmpty,
              let url = URL(string: "\(normalizedBaseURL)/v1/verify") else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "key": status.licenseKey,
            "deviceId": deviceId
        ])

        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        var next = status
        next.lastVerifiedAt = Date().timeIntervalSince1970
        if let valid = json["valid"] as? Bool {
            next.isExpiredOrRevoked = !valid
            if valid {
                next.isLifetime = (json["lifetime"] as? Bool) ?? (json["expiresAt"] == nil)
                next.expiresAt = json["expiresAt"] as? TimeInterval
                if let lbl = json["durationLabel"] as? String, !lbl.isEmpty {
                    next.durationLabel = lbl
                }
            }
        }
        status = next
    }

    func verifyPasscodeRecovery(rawKey: String) async -> Bool {
        let entered = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if !status.licenseKey.isEmpty && entered == status.licenseKey {
            return true
        }
        return await activate(rawKey: entered)
    }

    // MARK: - Zero-Knowledge Encrypted Profile Sync (Likes, Follows, Taste)

    private func backupKey(for licenseKey: String) -> SymmetricKey {
        let digest = SHA256.hash(data: Data(("tinytiny.backup.v1." + licenseKey.uppercased()).utf8))
        return SymmetricKey(data: digest)
    }

    func syncEncryptedBackupNow() async {
        guard isValidAccess, !status.licenseKey.isEmpty,
              let url = URL(string: "\(normalizedBaseURL)/v1/backup") else { return }

        let snapshot = EncryptedProfileBackup(
            userData: UserStore.shared.data,
            tasteV2: SmartTasteEngine.shared.state,
            seedrMasterKey: CryptoBox.exportSeedrMasterKeyString(),
            updatedAt: Date().timeIntervalSince1970
        )
        guard let rawJson = try? JSONEncoder().encode(snapshot),
              let sealed = try? CryptoBox.seal(rawJson, using: backupKey(for: status.licenseKey)) else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "key": status.licenseKey,
            "deviceId": deviceId,
            "blob": sealed.base64EncodedString()
        ])
        _ = try? await session.data(for: req)
    }

    func restoreEncryptedBackupIfPresent() async {
        guard !status.licenseKey.isEmpty,
              let url = URL(string: "\(normalizedBaseURL)/v1/backup/get") else { return }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "key": status.licenseKey,
            "deviceId": deviceId
        ])

        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let b64 = json["blob"] as? String,
              let cipher = Data(base64Encoded: b64),
              let plain = try? CryptoBox.open(cipher, using: backupKey(for: status.licenseKey)),
              let backup = try? JSONDecoder().decode(EncryptedProfileBackup.self, from: plain) else {
            return
        }

        // Merge non-destructively so existing local likes/follows aren't overwritten if newer
        if UserStore.shared.data.liked.isEmpty && !backup.userData.liked.isEmpty {
            UserStore.shared.data = backup.userData
        } else {
            var existingIds = Set(UserStore.shared.data.liked.map(\.id))
            for item in backup.userData.liked where existingIds.insert(item.id).inserted {
                UserStore.shared.data.liked.append(item)
            }
            for s in backup.userData.followedSubreddits where !UserStore.shared.isFollowingSubreddit(s) {
                UserStore.shared.toggleFollowSubreddit(s)
            }
            for x in backup.userData.followedXUsers where !UserStore.shared.isFollowingXUser(x) {
                UserStore.shared.toggleFollowXUser(x)
            }
            for ig in backup.userData.followedIGUsers where !UserStore.shared.isFollowingIGUser(ig) {
                UserStore.shared.toggleFollowIGUser(ig)
            }
            for of in backup.userData.followedOFCreators where !UserStore.shared.isFollowingOFCreator(id: of.id, handle: of.name) {
                UserStore.shared.toggleFollowOFCreator(id: of.id, name: of.name, displayName: of.displayName)
            }
        }
        SmartTasteEngine.shared.applyImportedBackup(backup.tasteV2)
        CryptoBox.restoreSeedrMasterKeyIfMissing(from: backup.seedrMasterKey)
    }

    // MARK: - Encrypted Drop Relay Helper

    func uploadTemporaryEncryptedBlob(_ cipherData: Data, filename: String) async -> URL? {
        guard isValidAccess, !status.licenseKey.isEmpty,
              let url = URL(string: "\(normalizedBaseURL)/v1/blob") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue(status.licenseKey, forHTTPHeaderField: "X-License-Key")
        req.setValue(deviceId, forHTTPHeaderField: "X-Device-Id")
        req.setValue(filename, forHTTPHeaderField: "X-File-Name")
        req.httpBody = cipherData

        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let uStr = json["url"] as? String else {
            return nil
        }
        return URL(string: uStr)
    }

    // MARK: - Keychain Persistence

    private static func saveRawKeychain(_ str: String, account: String) {
        let del: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account]
        SecItemDelete(del as CFDictionary)
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(str.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func readRawKeychain(account: String) -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data {
            return String(data: d, encoding: .utf8)
        }
        return nil
    }

    private func saveKeychainCodable<T: Encodable>(_ val: T, account: String) {
        let del: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account]
        SecItemDelete(del as CFDictionary)
        guard let d = try? JSONEncoder().encode(val) else { return }
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecValueData as String: d,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemAdd(add as CFDictionary, nil)
    }

    private static func loadKeychainCodable<T: Decodable>(account: String) -> T? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data {
            return try? JSONDecoder().decode(T.self, from: d)
        }
        return nil
    }
}

// MARK: - License Key Gate View (Replaces Mandatory First-Launch Passcode)

struct LicenseGateView: View {
    @ObservedObject private var license = LicenseManager.shared
    var onActivated: () -> Void

    @State private var keyInput = ""
    @State private var showServerConfig = false

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            RadialGradient(
                colors: [Color(red: 0.72, green: 0.16, blue: 0.38).opacity(0.28), .clear],
                center: UnitPoint(x: 0.25, y: 0.2),
                startRadius: 20,
                endRadius: 360
            )
            .ignoresSafeArea()

            VStack(spacing: 22) {
                Spacer()

                ZStack {
                    Circle().fill(Theme.accent.opacity(0.24)).frame(width: 78, height: 78).blur(radius: 16)
                    Circle().fill(.ultraThinMaterial).frame(width: 68, height: 68)
                        .overlay(Circle().stroke(Color.white.opacity(0.32), lineWidth: 1))
                        .overlay(
                            Image(systemName: license.status.isExpiredOrRevoked ? "key.slash.fill" : "key.fill")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(.white)
                        )
                }

                VStack(spacing: 6) {
                    Text(license.status.isExpiredOrRevoked ? "License Expired" : "Activate Access")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text(license.status.isExpiredOrRevoked
                         ? "Your license key expired. Enter a new key below — all likes & follows stay saved."
                         : "Enter the license key sent by @JarveyIsBot to unlock & sync your vault.")
                        .font(.system(size: 13.5))
                        .foregroundStyle(.white.opacity(0.70))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)
                }

                VStack(spacing: 12) {
                    TextField("TT-XXXX-XXXX-XXXX", text: $keyInput)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .multilineTextAlignment(.center)
                        .font(.system(size: 17, weight: .bold, design: .monospaced))
                        .padding(.vertical, 14)
                        .padding(.horizontal, 16)
                        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.white.opacity(0.22), lineWidth: 0.9)
                        )

                    if let err = license.errorMessage {
                        Text(err)
                            .font(.caption.bold())
                            .foregroundStyle(.red.opacity(0.9))
                            .multilineTextAlignment(.center)
                    }

                    Button {
                        Task {
                            if await license.activate(rawKey: keyInput) {
                                UINotificationFeedbackGenerator().notificationOccurred(.success)
                                onActivated()
                            } else {
                                UINotificationFeedbackGenerator().notificationOccurred(.error)
                            }
                        }
                    } label: {
                        Group {
                            if license.isChecking {
                                ProgressView().tint(.white)
                            } else {
                                Text("Activate License Key")
                                    .font(.system(size: 16, weight: .bold))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .liquidGlassCapsule(active: !keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .disabled(license.isChecking || keyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(18)
                .liquidGlassCard(cornerRadius: 22)
                .padding(.horizontal, 20)

                Spacer()

                Button {
                    withAnimation { showServerConfig.toggle() }
                } label: {
                    Text(showServerConfig ? "Hide Server Endpoint" : "Server Settings")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.45))
                }

                if showServerConfig {
                    TextField("Worker URL (https://...workers.dev)", text: $license.serverURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 12, design: .monospaced))
                        .padding(10)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                        .padding(.horizontal, 28)
                }
            }
            .foregroundStyle(.white)
            .padding(.bottom, 24)
        }
    }
}
