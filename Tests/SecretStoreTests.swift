import XCTest
@testable import SwiftMinerCore

/// The SwiftBot pairing secret, the local API key and the dashboard's Twitch client secret are
/// bearer credentials. They used to sit in the defaults plist, readable by anything running as
/// the user; they belong in the Keychain, and the move must not lose a working configuration.
///
/// Under XCTest `SecretStore` uses a process-local store, so these never touch the real
/// login Keychain.
final class SecretStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "com.swiftminer.tests.secrets.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        for key in SecretStore.Key.allCases { SecretStore.delete(key) }
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        for key in SecretStore.Key.allCases { SecretStore.delete(key) }
        super.tearDown()
    }

    func testMigrationMovesPlaintextSecretsOutOfDefaults() throws {
        defaults.set("hmac-secret", forKey: SecretStore.Key.swiftBotHmacSecret.rawValue)
        defaults.set("api-key", forKey: SecretStore.Key.swiftMinerAPIKey.rawValue)

        XCTAssertEqual(SecretStore.migrateIfNeeded(defaults: defaults), 2)

        XCTAssertEqual(SecretStore.read(.swiftBotHmacSecret), "hmac-secret")
        XCTAssertEqual(SecretStore.read(.swiftMinerAPIKey), "api-key")
        XCTAssertNil(
            defaults.string(forKey: SecretStore.Key.swiftBotHmacSecret.rawValue),
            "The plaintext copy must be removed once the secret is safely stored"
        )
        XCTAssertNil(defaults.string(forKey: SecretStore.Key.swiftMinerAPIKey.rawValue))

        // Idempotent: a second launch has nothing left to move.
        XCTAssertEqual(SecretStore.migrateIfNeeded(defaults: defaults), 0)
        XCTAssertEqual(SecretStore.read(.swiftBotHmacSecret), "hmac-secret")
    }

    /// A build that hasn't run the migration yet must still find its configuration.
    func testReadFallsBackToLegacyDefaults() throws {
        defaults.set("legacy-key", forKey: SecretStore.Key.swiftMinerAPIKey.rawValue)

        XCTAssertNil(SecretStore.read(.swiftMinerAPIKey), "No fallback unless one is offered")
        XCTAssertEqual(SecretStore.read(.swiftMinerAPIKey, legacyDefaults: defaults), "legacy-key")

        // Once stored, the Keychain wins over any stale plaintext copy.
        try SecretStore.write(.swiftMinerAPIKey, "current-key")
        XCTAssertEqual(SecretStore.read(.swiftMinerAPIKey, legacyDefaults: defaults), "current-key")
    }

    func testWritingAnEmptyValueRemovesTheSecret() throws {
        try SecretStore.write(.webDashboardTwitchClientSecret, "twitch-secret")
        XCTAssertEqual(SecretStore.read(.webDashboardTwitchClientSecret), "twitch-secret")

        try SecretStore.write(.webDashboardTwitchClientSecret, "")
        XCTAssertNil(SecretStore.read(.webDashboardTwitchClientSecret))
    }

    /// A stale plaintext copy alongside a stored secret is dropped, not promoted.
    func testMigrationPrefersTheStoredSecretOverAStalePlaintextCopy() throws {
        try SecretStore.write(.swiftBotHmacSecret, "current")
        defaults.set("stale", forKey: SecretStore.Key.swiftBotHmacSecret.rawValue)

        XCTAssertEqual(SecretStore.migrateIfNeeded(defaults: defaults), 0)
        XCTAssertEqual(SecretStore.read(.swiftBotHmacSecret), "current")
        XCTAssertNil(defaults.string(forKey: SecretStore.Key.swiftBotHmacSecret.rawValue))
    }
}
