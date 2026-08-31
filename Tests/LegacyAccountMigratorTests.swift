import XCTest
@testable import SwiftMinerCore

/// Verifies the one-time legacy-file → Keychain migration guards. Uses in-memory
/// `TestTokenStore` for source/target and a throwaway `UserDefaults` suite for the flag,
/// so it never touches the real Keychain or the user's defaults.
final class LegacyAccountMigratorTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "com.swiftminer.tests.migrator.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeAccount(_ id: String) -> Account {
        Account(
            id: id, username: "user-\(id)",
            accessToken: "access-\(id)", refreshToken: "refresh-\(id)",
            tokenExpiry: Date().addingTimeInterval(3600), scopes: []
        )
    }

    func testImportsWhenTargetEmpty() async throws {
        let source = TestTokenStore()
        try await source.save(account: makeAccount("1"))
        try await source.save(account: makeAccount("2"))
        let target = TestTokenStore()
        let defaults = makeDefaults()

        try await LegacyAccountMigrator.migrate(from: source, into: target, defaults: defaults)

        let imported = try await target.loadAllAccounts()
        XCTAssertEqual(imported.count, 2)
        XCTAssertNotNil(defaults.object(forKey: LegacyAccountMigrator.migratedAtKey))
    }

    func testNoOpWhenAlreadyMigrated() async throws {
        let source = TestTokenStore()
        try await source.save(account: makeAccount("1"))
        let target = TestTokenStore()
        let defaults = makeDefaults()
        defaults.set(Date(), forKey: LegacyAccountMigrator.migratedAtKey)

        try await LegacyAccountMigrator.migrate(from: source, into: target, defaults: defaults)

        let result = try await target.loadAllAccounts()
        XCTAssertTrue(result.isEmpty)
    }

    func testDoesNotClobberExistingTarget() async throws {
        let source = TestTokenStore()
        try await source.save(account: makeAccount("legacy"))
        let target = TestTokenStore()
        try await target.save(account: makeAccount("fresh"))
        let defaults = makeDefaults()

        try await LegacyAccountMigrator.migrate(from: source, into: target, defaults: defaults)

        let all = try await target.loadAllAccounts()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id, "fresh")
        XCTAssertNotNil(defaults.object(forKey: LegacyAccountMigrator.migratedAtKey))
    }

    func testDoesNotResurrectDeletedAccountsOnRerun() async throws {
        let source = TestTokenStore()
        try await source.save(account: makeAccount("1"))
        let target = TestTokenStore()
        let defaults = makeDefaults()

        // First run imports.
        try await LegacyAccountMigrator.migrate(from: source, into: target, defaults: defaults)
        let afterFirst = try await target.loadAllAccounts()
        XCTAssertEqual(afterFirst.count, 1)

        // User removes the account in-app; the legacy file still holds it.
        try await target.deleteAccount(twitchUserId: "1")
        let afterDelete = try await target.loadAllAccounts()
        XCTAssertTrue(afterDelete.isEmpty)

        // Re-running must NOT bring the deleted account back.
        try await LegacyAccountMigrator.migrate(from: source, into: target, defaults: defaults)
        let afterSecond = try await target.loadAllAccounts()
        XCTAssertTrue(afterSecond.isEmpty)
    }

    /// The reported failure: an undecryptable legacy file read as "no accounts", the migration
    /// recorded itself as complete, and the app then offered to delete the only surviving copy
    /// of the user's credentials. A failed read must stay a failure.
    func testUnreadableLegacySourceLeavesMigrationRetryable() async throws {
        let source = TestTokenStore()
        try await source.save(account: makeAccount("1"))
        await source.failLoads(with: LegacyTokenStoreError.undecryptable(
            underlying: NSError(domain: "test", code: 1)
        ))
        let target = TestTokenStore()
        let defaults = makeDefaults()

        do {
            try await LegacyAccountMigrator.migrate(from: source, into: target, defaults: defaults)
            XCTFail("A legacy store that cannot be read must not migrate silently")
        } catch {
            // Expected.
        }

        XCTAssertNil(
            defaults.object(forKey: LegacyAccountMigrator.migratedAtKey),
            "The flag must stay unset so the next launch retries instead of prompting to delete the backup"
        )

        // Once the read works again, the retry imports normally.
        await source.failLoads(with: nil)
        try await LegacyAccountMigrator.migrate(from: source, into: target, defaults: defaults)
        let imported = try await target.loadAllAccounts()
        XCTAssertEqual(imported.count, 1)
        XCTAssertNotNil(defaults.object(forKey: LegacyAccountMigrator.migratedAtKey))
    }
}
