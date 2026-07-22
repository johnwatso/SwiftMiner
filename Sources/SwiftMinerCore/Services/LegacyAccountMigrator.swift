import Foundation

/// One-time migration of accounts from the legacy hardware-UUID encrypted file
/// (`KeychainTokenStore` → `~/Library/Application Support/com.swiftminer/accounts.enc`)
/// into the real macOS Keychain (`KeychainAccountStore`).
///
/// Runs in Release only — DEBUG builds keep using the legacy file store directly, so there is
/// nothing to migrate. The legacy file is **never** modified or deleted here; it stays on disk
/// as a backup until the user opts to remove it (see the weekly prompt driven by
/// `legacyBackupExists`).
public enum LegacyAccountMigrator {
    /// UserDefaults key recording when the one-time check ran. In production this lives in the
    /// same suite (`.standard`) that the app's `Settings.appStorageStore` uses.
    public static let migratedAtKey = "legacyAccountsMigratedAt"

    /// Production entry point. Safe to call on every launch; it self-guards.
    public static func migrateIfNeeded(defaults: UserDefaults = .standard) async {
        #if !DEBUG
        do {
            try await migrate(from: KeychainTokenStore(), into: KeychainAccountStore(), defaults: defaults)
        } catch {
            // Leave the flag unset so the migration is retried on the next launch.
            Logger.storage.error("Migration failed (will retry next launch): \(error.localizedDescription)")
        }
        #endif
    }

    /// Testable core. Imports legacy accounts into `target` exactly once.
    ///
    /// Guards:
    /// - **Idempotent:** if the check has already run (flag set), returns immediately so it can
    ///   never re-import — protecting against resurrecting accounts the user later deletes.
    /// - **Non-clobbering:** imports only when the target Keychain is empty, so fresh tokens
    ///   already in the Keychain are never overwritten by a stale file.
    /// - **Verified:** reads the target back and confirms the count before marking success; on
    ///   mismatch it throws and leaves the flag unset to retry.
    static func migrate(from source: any TokenStore, into target: any TokenStore, defaults: UserDefaults) async throws {
        if defaults.object(forKey: migratedAtKey) != nil { return }

        // A failed/empty legacy read (e.g. undecryptable file) yields [] — nothing to recover.
        let legacy = (try? await source.loadAllAccounts()) ?? []
        let current = try await target.loadAllAccounts()

        if !legacy.isEmpty && current.isEmpty {
            for account in legacy {
                try await target.save(account: account)
            }
            let imported = try await target.loadAllAccounts()
            guard imported.count >= legacy.count else {
                throw NSError(
                    domain: "SwiftMiner.LegacyAccountMigrator",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Keychain verification mismatch: expected \(legacy.count), found \(imported.count)"]
                )
            }
            Logger.storage.info("Migrated \(imported.count) account(s) into the Keychain")
        }

        // Mark the check as done so we never re-import, even when nothing moved.
        defaults.set(Date(), forKey: migratedAtKey)
    }

    // MARK: - Legacy backup file

    /// Location of the legacy encrypted accounts file. Single source of truth for the path so the
    /// migrator and the app's delete prompt agree.
    public static var legacyStoreFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("com.swiftminer", isDirectory: true)
            .appendingPathComponent("accounts.enc")
    }

    /// Whether a leftover legacy backup file is still present on disk.
    public static var legacyBackupExists: Bool {
        FileManager.default.fileExists(atPath: legacyStoreFileURL.path)
    }

    /// Remove the leftover legacy backup file. No-op if it is already gone.
    public static func deleteLegacyBackup() throws {
        let url = legacyStoreFileURL
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
