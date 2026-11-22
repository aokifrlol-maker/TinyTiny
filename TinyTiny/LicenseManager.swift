import Foundation
import SwiftUI
import UIKit
import Security
import CryptoKit
import WebKit

struct RemoteAppConfig: Codable, Equatable {
    var announcement: String?
    var announcementId: String?
    var minVersion: String?
    var maintenance: String?
}

enum DeviceTelemetry {
    static var modelIdentifier: String {
        var sysinfo = utsname()
        uname(&sysinfo)
        return withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }

    static var friendlyModel: String {
        let id = modelIdentifier
        let map: [String: String] = [
            "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max",
            "iPhone12,8": "iPhone SE (2nd)",
            "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
            "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max", "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13",
            "iPhone14,6": "iPhone SE (3rd)", "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus",
            "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
            "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus",
            "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
            "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
            "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus", "iPhone17,5": "iPhone 16e",
            "x86_64": "Simulator", "arm64": "Simulator"
        ]
        return map[id] ?? id
    }

    @MainActor
    static var payload: [String: String] {
        [
            "model": friendlyModel,
            "modelId": modelIdentifier,
            "ios": UIDevice.current.systemVersion,
            "app": (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
        ]
    }
}

// MARK: - Persistent License + Encrypted Profile Backup Manager

struct LicenseStatus: Codable, Equatable {
    var licenseKey: String = ""
    var isAdmin: Bool = false
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
    @Published var isChecking: Bool = false
    @Published var errorMessage: String?
    @Published var remoteConfig: RemoteAppConfig?
    @Published var dismissedAnnouncementId: String = UserDefaults.standard.string(forKey: "tinytiny.dismissed.announcement") ?? ""

    private var lastErrorReportAt: [String: Date] = [:]

    var activeAnnouncement: (id: String, text: String)? {
        guard let text = remoteConfig?.announcement?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        let id = remoteConfig?.announcementId ?? text
        guard id != dismissedAnnouncementId else { return nil }
        return (id, text)
    }

    var isUpdateRequired: Bool {
        guard let minVer = remoteConfig?.minVersion?.trimmingCharacters(in: .whitespacesAndNewlines),
              !minVer.isEmpty else { return false }
        let current = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.0"
        return Self.compareVersions(current, minVer) < 0
    }

    func dismissAnnouncement(_ id: String) {
        dismissedAnnouncementId = id
        UserDefaults.standard.set(id, forKey: "tinytiny.dismissed.announcement")
    }

    private static func compareVersions(_ a: String, _ b: String) -> Int {
        let pa = a.split(separator: ".").compactMap { Int($0) }
        let pb = b.split(separator: ".").compactMap { Int($0) }
        let n = max(pa.count, pb.count)
        for i in 0..<n {
            let va = i < pa.count ? pa[i] : 0
            let vb = i < pb.count ? pb[i] : 0
            if va != vb { return va < vb ? -1 : 1 }
        }
        return 0
    }

    private func applyRemoteConfig(from json: [String: Any]) {
        guard let cfgDict = json["config"] as? [String: Any],
              let data = try? JSONSerialization.data(withJSONObject: cfgDict),
              let cfg = try? JSONDecoder().decode(RemoteAppConfig.self, from: data) else {
            return
        }
        remoteConfig = cfg
    }

    func reportError(source: String, detail: String) {
        let now = Date()
        if let prev = lastErrorReportAt[source], now.timeIntervalSince(prev) < 300 { return }
        lastErrorReportAt[source] = now
        guard let url = URL(string: "\(normalizedBaseURL)/v1/report-error") else { return }
        let devInfo = DeviceTelemetry.payload
        let key = status.licenseKey
        let devId = deviceId
        Task.detached(priority: .utility) { [session] in
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: [
                "key": key,
                "deviceId": devId,
                "deviceInfo": devInfo,
                "source": String(source.prefix(40)),
                "detail": String(detail.prefix(240))
            ])
            _ = try? await session.data(for: req)
        }
    }

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
    }

    var normalizedBaseURL: String {
        Self.defaultServerURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    var isValidAccess: Bool {
        guard status.isActivated, !status.isExpiredOrRevoked else { return false }
        if status.isLifetime { return true }
        if let exp = status.expiresAt {
            return Date().timeIntervalSince1970 < exp
        }
        return true
    }

    var isAdmin: Bool {
        isValidAccess && status.isAdmin
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

    func clearLicense() {
        status = LicenseStatus()
        errorMessage = nil
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: Self.statusKeychainAccount
        ]
        SecItemDelete(q as CFDictionary)
    }

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
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "key": cleanKey,
            "deviceId": deviceId,
            "deviceInfo": DeviceTelemetry.payload
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                errorMessage = "Server error (HTTP \(code)). Check Worker URL."
                return false
            }

            if (json["valid"] as? Bool) == true {
                applyRemoteConfig(from: json)
                var next = LicenseStatus()
                next.licenseKey = cleanKey
                next.isAdmin = (json["admin"] as? Bool) ?? false
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
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "key": status.licenseKey,
            "deviceId": deviceId,
            "deviceInfo": DeviceTelemetry.payload
        ])

        guard let (data, resp) = try? await session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        applyRemoteConfig(from: json)
        var next = status
        next.lastVerifiedAt = Date().timeIntervalSince1970
        if let valid = json["valid"] as? Bool {
            next.isExpiredOrRevoked = !valid
            if valid {
                next.isAdmin = (json["admin"] as? Bool) ?? next.isAdmin
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
        guard !entered.isEmpty else { return false }
        return await activate(rawKey: entered)
    }

    // MARK: - Zero-Knowledge Encrypted Profile Sync (Likes, Follows, Taste)

    private func backupKey(for licenseKey: String) -> SymmetricKey {
        let input = SymmetricKey(data: Data(licenseKey.uppercased().utf8))
        let salt = Data("tinytiny.backup.v2.salt".utf8)
        let info = Data("tinytiny.profile.backup".utf8)
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: input, salt: salt, info: info, outputByteCount: 32)
    }

    private func legacyBackupKey(for licenseKey: String) -> SymmetricKey {
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

    @discardableResult
    func restoreEncryptedBackupIfPresent() async -> Bool {
        guard !status.licenseKey.isEmpty,
              let url = URL(string: "\(normalizedBaseURL)/v1/backup/get") else { return false }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "key": status.licenseKey,
            "deviceId": deviceId
        ])

        guard let (data, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse else {
            return false
        }
        if http.statusCode == 404 {
            // No cloud backup exists yet for this key — safe to upload local state
            return true
        }
        guard http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let b64 = json["blob"] as? String,
              let cipher = Data(base64Encoded: b64),
              let plain = (try? CryptoBox.open(cipher, using: backupKey(for: status.licenseKey)))
                ?? (try? CryptoBox.open(cipher, using: legacyBackupKey(for: status.licenseKey))),
              let backup = try? JSONDecoder().decode(EncryptedProfileBackup.self, from: plain) else {
            return false
        }

        // Merge non-destructively so existing local likes/follows/sessions aren't overwritten if newer
        let local = UserStore.shared.data
        let isTrulyEmpty = local.liked.isEmpty && local.downloaded.isEmpty
            && !local.xSession.isConnected && !local.igSession.isConnected
            && local.followedUsers.isEmpty && local.followedXUsers.isEmpty
            && local.followedIGUsers.isEmpty && local.followedSubreddits.isEmpty
            && local.followedOFCreators.isEmpty
        if isTrulyEmpty && !backup.userData.liked.isEmpty {
            UserStore.shared.data = backup.userData
        } else {
            var existingIds = Set(UserStore.shared.data.liked.map(\.id))
            for item in backup.userData.liked where existingIds.insert(item.id).inserted {
                UserStore.shared.data.liked.append(item)
            }
            var dlIds = Set(UserStore.shared.data.downloaded.map(\.id))
            for item in backup.userData.downloaded where dlIds.insert(item.id).inserted {
                UserStore.shared.data.downloaded.append(item)
            }
            for u in backup.userData.followedUsers where !UserStore.shared.isFollowingUser(u) {
                UserStore.shared.toggleFollowUser(u)
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
            if !UserStore.shared.data.xSession.isConnected && backup.userData.xSession.isConnected {
                UserStore.shared.data.xSession = backup.userData.xSession
            }
            if !UserStore.shared.data.igSession.isConnected && backup.userData.igSession.isConnected {
                UserStore.shared.data.igSession = backup.userData.igSession
            }
            for seenId in backup.userData.seenIDs {
                UserStore.shared.markSeen(seenId)
            }
        }
        SmartTasteEngine.shared.applyImportedBackup(backup.tasteV2)
        CryptoBox.restoreSeedrMasterKeyIfMissing(from: backup.seedrMasterKey)
        UserStore.shared.saveNow()
        await injectRestoredSocialCookies()
        return true
    }

    private func injectRestoredSocialCookies() async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        let x = UserStore.shared.data.xSession
        if x.isConnected {
            let xPairs: [(String, String)] = [
                ("auth_token", x.authToken),
                ("ct0", x.ct0),
            ]
            for (name, val) in xPairs where !val.isEmpty {
                for domain in [".x.com", ".twitter.com"] {
                    if let cookie = HTTPCookie(properties: [
                        .domain: domain,
                        .path: "/",
                        .name: name,
                        .value: val,
                        .secure: "TRUE",
                        .expires: Date().addingTimeInterval(365 * 86400)
                    ]) {
                        await store.setCookie(cookie)
                    }
                }
            }
        }
        let ig = UserStore.shared.data.igSession
        if ig.isConnected {
            let igPairs: [(String, String)] = [
                ("sessionid", ig.sessionId),
                ("csrftoken", ig.csrfToken),
                ("ds_user_id", ig.userId),
            ]
            for (name, val) in igPairs where !val.isEmpty {
                if let cookie = HTTPCookie(properties: [
                    .domain: ".instagram.com",
                    .path: "/",
                    .name: name,
                    .value: val,
                    .secure: "TRUE",
                    .expires: Date().addingTimeInterval(365 * 86400)
                ]) {
                    await store.setCookie(cookie)
                }
            }
        }
    }

    func syncBidirectionalBackup() async -> String {
        let restoredOK = await restoreEncryptedBackupIfPresent()
        guard restoredOK else {
            return "Sync paused: couldn't restore cloud backup (kept cloud data safe)."
        }
        let d = UserStore.shared.data
        let hasAnyData = !d.liked.isEmpty
            || !d.downloaded.isEmpty
            || d.xSession.isConnected
            || d.igSession.isConnected
            || !d.followedUsers.isEmpty
            || !d.followedXUsers.isEmpty
            || !d.followedIGUsers.isEmpty
            || !d.followedSubreddits.isEmpty
            || !d.followedOFCreators.isEmpty
        if hasAnyData {
            await syncEncryptedBackupNow()
        }
        var parts = ["\(d.liked.count) likes", "\(d.downloaded.count) saved"]
        if d.xSession.isConnected { parts.append("X login") }
        if d.igSession.isConnected { parts.append("IG login") }
        return "Synced: " + parts.joined(separator: " · ")
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
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account]
        let attrs: [String: Any] = [
            kSecValueData as String: Data(str.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        if SecItemUpdate(query as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            let add = query.merging(attrs) { _, new in new }
            SecItemAdd(add as CFDictionary, nil)
        }
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
        guard let d = try? JSONEncoder().encode(val) else { return }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: account]
        let attrs: [String: Any] = [
            kSecValueData as String: d,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        if SecItemUpdate(query as CFDictionary, attrs as CFDictionary) == errSecItemNotFound {
            let add = query.merging(attrs) { _, new in new }
            SecItemAdd(add as CFDictionary, nil)
        }
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
    @State private var copiedToast = false

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
                         ? "Your license key expired. Enter a valid key below — all likes & follows stay saved."
                         : "Enter your license key to unlock & sync your vault.")
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

                    if !license.status.licenseKey.isEmpty {
                        HStack(spacing: 10) {
                            Button {
                                UIPasteboard.general.string = license.status.licenseKey
                                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                copiedToast = true
                                Task {
                                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                                    copiedToast = false
                                }
                            } label: {
                                Label(copiedToast ? "Copied!" : "Copy Key", systemImage: "doc.on.doc")
                                    .font(.caption.bold())
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 9)
                                    .liquidGlassCapsule()
                            }

                            Button {
                                Task {
                                    await license.verifySilently()
                                    if license.isValidAccess {
                                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                                        onActivated()
                                    } else {
                                        UINotificationFeedbackGenerator().notificationOccurred(.error)
                                    }
                                }
                            } label: {
                                Label("Check Status", systemImage: "arrow.clockwise")
                                    .font(.caption.bold())
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 9)
                                    .liquidGlassCapsule()
                            }
                        }
                    }
                }
                .padding(18)
                .liquidGlassCard(cornerRadius: 22)
                .padding(.horizontal, 20)

                Spacer()
            }
            .foregroundStyle(.white)
            .padding(.bottom, 24)
        }
        .onAppear {
            if keyInput.isEmpty && !license.status.licenseKey.isEmpty {
                keyInput = license.status.licenseKey
            }
        }
    }
}
