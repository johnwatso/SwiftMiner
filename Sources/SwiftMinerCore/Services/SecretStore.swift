import Foundation
import Security

/// Keychain storage for this installation's shared secrets.
///
/// The SwiftBot HMAC pairing secret, the local HTTP API key, and the web dashboard's Twitch
/// client secret are bearer credentials: anything holding one can sign requests to the local
/// API or complete the dashboard's OAuth exchange. As ordinary `UserDefaults` entries they sat
/// in the user's preferences plist, where another process running as that user — and any backup
/// or sync of that folder — could read them.
///
/// Release builds keep them in the login Keychain, one `kSecClassGenericPassword` item per key,
/// mirroring the pattern already used for the dashboard's local password. Unsigned DEBUG builds
/// use separate, debug-prefixed defaults instead: their changing code identity would otherwise
/// make macOS request Keychain authorization repeatedly during normal development.
///
/// Reads fall back to `UserDefaults` for values written by older builds, and `migrateIfNeeded`
/// moves those into the Keychain and clears the plaintext copy on first launch.
public enum SecretStore {
    /// `kSecAttrService` namespace for every secret stored here.
    public static let service = "com.swiftminer.app.secrets"

    /// The keys this store owns. `UserDefaults` entries with these names are legacy copies to
    /// be migrated and removed.
    public enum Key: String, CaseIterable, Sendable {
        case swiftBotHmacSecret
        case swiftMinerAPIKey
        case webDashboardTwitchClientSecret
        case webDashboardDiscordClientSecret
    }

    private static let logger = Logger.storage

    #if DEBUG
    /// Kept separate from the legacy keys so a release build can never migrate a development
    /// credential into the production Keychain.
    private static let debugDefaultsPrefix = "SwiftMinerDebugSecret."
    #endif

    /// Tests must never touch — or leave items in — the developer's real login Keychain, so
    /// they get a process-local store instead. Mirrors `Settings.appStorageStore`.
    private static let testStore = TestSecretBox()

    // MARK: - Access

    /// The stored secret, or `nil` when there is none.
    ///
    /// `defaults`, when given, is consulted only if the Keychain has no item — a build that has
    /// not run `migrateIfNeeded` yet must not lose its configuration.
    public static func read(_ key: Key, legacyDefaults defaults: UserDefaults? = nil) -> String? {
        if SwiftMinerRuntime.isRunningTests {
            if let value = testStore.get(key.rawValue), !value.isEmpty { return value }
            if let legacy = defaults?.string(forKey: key.rawValue), !legacy.isEmpty { return legacy }
            return nil
        }

        #if DEBUG
        if let value = UserDefaults.standard.string(forKey: debugDefaultsKey(key)), !value.isEmpty {
            return value
        }
        if let legacy = defaults?.string(forKey: key.rawValue), !legacy.isEmpty { return legacy }
        return nil
        #else
        if let value = readKeychain(key), !value.isEmpty { return value }
        if let legacy = defaults?.string(forKey: key.rawValue), !legacy.isEmpty { return legacy }
        return nil
        #endif
    }

    /// Stores `value`, or removes the item when `value` is empty.
    public static func write(_ key: Key, _ value: String) throws {
        guard !value.isEmpty else {
            delete(key)
            return
        }

        if SwiftMinerRuntime.isRunningTests {
            testStore.set(key.rawValue, value)
            return
        }

        #if DEBUG
        UserDefaults.standard.set(value, forKey: debugDefaultsKey(key))
        #else
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            throw keychainError(status, operation: "update", key: key)
        }

        var add = query(key)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw keychainError(addStatus, operation: "save", key: key)
        }
        #endif
    }

    public static func delete(_ key: Key) {
        if SwiftMinerRuntime.isRunningTests {
            testStore.set(key.rawValue, nil)
            return
        }
        #if DEBUG
        UserDefaults.standard.removeObject(forKey: debugDefaultsKey(key))
        #else
        SecItemDelete(query(key) as CFDictionary)
        #endif
    }

    // MARK: - Migration

    /// Moves any plaintext secrets left in `defaults` into the Keychain, then removes them.
    ///
    /// Safe to call on every launch. A key already in the Keychain is left alone, so a failed
    /// or partial run simply retries: the plaintext copy is cleared only once the Keychain
    /// write has succeeded.
    @discardableResult
    public static func migrateIfNeeded(defaults: UserDefaults = .standard) -> Int {
        #if DEBUG
        // Tests still exercise the release migration semantics against `testStore` below.
        guard SwiftMinerRuntime.isRunningTests else { return 0 }
        #endif

        var migrated = 0
        for key in Key.allCases {
            guard let legacy = defaults.string(forKey: key.rawValue), !legacy.isEmpty else { continue }
            if let existing = readKeychain(key), !existing.isEmpty {
                // The Keychain is authoritative; drop the stale plaintext copy.
                defaults.removeObject(forKey: key.rawValue)
                continue
            }
            do {
                try write(key, legacy)
                defaults.removeObject(forKey: key.rawValue)
                migrated += 1
            } catch {
                // Keep the plaintext value rather than losing the configuration; retry next launch.
                logger.error("Could not move \(key.rawValue) into the Keychain: \(error.localizedDescription)")
            }
        }
        if migrated > 0 {
            logger.info("Moved \(migrated) secret(s) out of UserDefaults into the Keychain")
        }
        return migrated
    }

    // MARK: - Keychain helpers

    private static func readKeychain(_ key: Key) -> String? {
        if SwiftMinerRuntime.isRunningTests {
            return testStore.get(key.rawValue)
        }
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    #if DEBUG
    private static func debugDefaultsKey(_ key: Key) -> String {
        debugDefaultsPrefix + key.rawValue
    }
    #endif

    private static func query(_ key: Key) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue
        ]
    }

    private static func keychainError(_ status: OSStatus, operation: String, key: Key) -> NSError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return NSError(
            domain: "SwiftMiner.SecretStore",
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: "Could not \(operation) \(key.rawValue) in Keychain: \(message)"]
        )
    }
}

/// Process-local stand-in for the Keychain, used only under XCTest.
private final class TestSecretBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func get(_ key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func set(_ key: String, _ value: String?) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }
}
