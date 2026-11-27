import Foundation
import CryptoKit
import Security

/// Client-side AES-256-GCM encryption layer (`TTENC1` envelope).
/// Files sent to Seedr or user-to-user drops are encrypted locally before leaving the device,
/// and decrypted transparently on-device before playback or Vault storage.
enum CryptoBox {
    private static let seedrMasterKeyAccount = "tinytiny.seedr.masterkey.v1"
    private static let localVaultKeyAccount = "tinytiny.local.vaultkey.v1"
    private static let magicHeader = Data("TTENC1".utf8) // 6 bytes
    private static let keyLock = NSLock()
    private static var cachedLocalKey: SymmetricKey?
    private static var cachedSeedrKey: SymmetricKey?

    static func generateKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    /// Persistent 256-bit AES-GCM key stored in iOS Keychain for encrypting all local app data at rest.
    /// Serialized and cached so transient Keychain errors (e.g. `errSecInteractionNotAllowed`) never overwrite an existing key.
    static func localVaultKey() -> SymmetricKey {
        keyLock.lock()
        defer { keyLock.unlock() }
        if let cached = cachedLocalKey { return cached }
        let (existingData, status) = readKeychainStatus(account: localVaultKeyAccount)
        if let existingData, existingData.count == 32 {
            let k = SymmetricKey(data: existingData)
            cachedLocalKey = k
            return k
        }
        guard status == errSecItemNotFound else {
            // Transient Keychain unavailability — do NOT overwrite the stored key; return ephemeral key without saving.
            return generateKey()
        }
        let fresh = generateKey()
        let raw = fresh.withUnsafeBytes { Data($0) }
        let addStatus = addKeychainOnly(raw, account: localVaultKeyAccount, accessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly)
        if addStatus == errSecDuplicateItem,
           let raced = readKeychainStatus(account: localVaultKeyAccount).data,
           raced.count == 32 {
            let k = SymmetricKey(data: raced)
            cachedLocalKey = k
            return k
        }
        cachedLocalKey = fresh
        return fresh
    }

    static func sealCodable<T: Encodable>(_ value: T) -> Data? {
        guard let raw = try? JSONEncoder().encode(value) else { return nil }
        return try? seal(raw, using: localVaultKey())
    }

    /// Opens `TTENC1`-encrypted blobs, with transparent fallback to legacy plaintext JSON so existing data migrates cleanly.
    static func openCodable<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        if isEncryptedEnvelope(data) {
            guard let plain = try? open(data, using: localVaultKey()) else { return nil }
            return try? JSONDecoder().decode(type, from: plain)
        }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Persistent 256-bit AES-GCM key stored in iOS Keychain so your encrypted Seedr library remains readable across sessions.
    static func seedrVaultKey() -> SymmetricKey {
        keyLock.lock()
        defer { keyLock.unlock() }
        if let cached = cachedSeedrKey { return cached }
        let (existingData, status) = readKeychainStatus(account: seedrMasterKeyAccount)
        if let existingData, existingData.count == 32 {
            let k = SymmetricKey(data: existingData)
            cachedSeedrKey = k
            return k
        }
        guard status == errSecItemNotFound else {
            return generateKey()
        }
        let fresh = generateKey()
        let raw = fresh.withUnsafeBytes { Data($0) }
        let addStatus = addKeychainOnly(raw, account: seedrMasterKeyAccount, accessible: kSecAttrAccessibleAfterFirstUnlock)
        if addStatus == errSecDuplicateItem,
           let raced = readKeychainStatus(account: seedrMasterKeyAccount).data,
           raced.count == 32 {
            let k = SymmetricKey(data: raced)
            cachedSeedrKey = k
            return k
        }
        cachedSeedrKey = fresh
        return fresh
    }

    /// Encodes a SymmetricKey as URL-safe Base64 (no padding) so decryption keys can stay solely in URL `#k=` fragments.
    static func exportKeyBase64URL(_ key: SymmetricKey) -> String {
        let raw = key.withUnsafeBytes { Data($0) }
        return raw.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func importKeyBase64URL(_ token: String) -> SymmetricKey? {
        var b64 = token
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64.append("=") }
        guard let data = Data(base64Encoded: b64), data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    /// Exports/imports personal Seedr Master Key string so it can be restored across IPA reinstalls.
    static func exportSeedrMasterKeyString() -> String {
        exportKeyBase64URL(seedrVaultKey())
    }

    static func restoreSeedrMasterKeyIfMissing(from token: String, force: Bool = false) {
        keyLock.lock()
        defer { keyLock.unlock() }
        guard let key = importKeyBase64URL(token) else { return }
        if !force {
            let (existing, status) = readKeychainStatus(account: seedrMasterKeyAccount)
            guard existing == nil && status == errSecItemNotFound else { return }
        }
        let raw = key.withUnsafeBytes { Data($0) }
        saveKeychain(raw, account: seedrMasterKeyAccount)
        cachedSeedrKey = key
    }

    /// Seals plaintext data into `TTENC1` + combined AES-256-GCM `(nonce + ciphertext + tag)`.
    static func seal(_ plaintext: Data, using key: SymmetricKey) throws -> Data {
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else {
            throw NSError(domain: "CryptoBox", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to serialize AES-GCM envelope"])
        }
        var out = Data()
        out.reserveCapacity(magicHeader.count + combined.count)
        out.append(magicHeader)
        out.append(combined)
        return out
    }

    /// Opens either `TTENC1`-prefixed encrypted envelopes or raw combined AES-GCM blobs.
    static func open(_ ciphertext: Data, using key: SymmetricKey) throws -> Data {
        let payload = ciphertext.starts(with: magicHeader)
            ? ciphertext.dropFirst(magicHeader.count)
            : ciphertext[...]
        let box = try AES.GCM.SealedBox(combined: payload)
        return try AES.GCM.open(box, using: key)
    }

    static func isEncryptedEnvelope(_ dataPrefix: Data) -> Bool {
        dataPrefix.starts(with: magicHeader)
    }

    // MARK: - Keychain Helpers

    @discardableResult
    private static func addKeychainOnly(_ data: Data, account: String, accessible: CFString) -> OSStatus {
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessible
        ]
        return SecItemAdd(add as CFDictionary, nil)
    }

    private static func saveKeychain(_ data: Data, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            let add = query.merging(attrs) { _, new in new }
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    private static func readKeychainStatus(account: String) -> (data: Data?, status: OSStatus) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecSuccess, let d = out as? Data {
            return (d, status)
        }
        return (nil, status)
    }

    private static func readKeychain(account: String) -> Data? {
        readKeychainStatus(account: account).data
    }
}
