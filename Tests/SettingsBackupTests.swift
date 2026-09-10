import XCTest
@testable import SwiftMiner
import SwiftMinerCore

@MainActor
final class SettingsBackupTests: XCTestCase {
    private var settings: Settings!

    override func setUp() async throws {
        try await super.setUp()
        settings = Settings.shared
        settings.resetToDefaults()
    }

    override func tearDown() async throws {
        settings.resetToDefaults()
        settings = nil
        try await super.tearDown()
    }

    func testQuietHoursHandlesOvernightWindow() {
        settings.quietHoursEnabled = true
        settings.quietHoursStartMinute = 22 * 60
        settings.quietHoursEndMinute = 7 * 60

        XCTAssertFalse(settings.allowsOperatorNotifications(at: date(hour: 23)))
        XCTAssertFalse(settings.allowsOperatorNotifications(at: date(hour: 6)))
        XCTAssertTrue(settings.allowsOperatorNotifications(at: date(hour: 12)))
    }

    func testBackupRoundTripRestoresOperatorPreferences() throws {
        settings.appearanceStyle = .atomicPurple
        settings.quietHoursEnabled = true
        settings.quietHoursStartMinute = 21 * 60
        settings.quietHoursEndMinute = 8 * 60
        settings.swiftBotEndpoint = "http://127.0.0.1:9000"

        let data = try settings.exportBackupData()
        settings.resetToDefaults()
        try settings.importBackupData(data)

        XCTAssertEqual(settings.appearanceStyle, .atomicPurple)
        XCTAssertTrue(settings.quietHoursEnabled)
        XCTAssertEqual(settings.quietHoursStartMinute, 21 * 60)
        XCTAssertEqual(settings.quietHoursEndMinute, 8 * 60)
        XCTAssertEqual(settings.swiftBotEndpoint, "http://127.0.0.1:9000")
    }

    func testAppearanceChoicesPersistAndInvalidValuesUseDefaults() {
        settings.appearanceStyle = .atomicPurple

        XCTAssertEqual(
            Settings.appStorageStore.string(forKey: "appearanceStyle"),
            AppearanceStyle.atomicPurple.rawValue
        )

        Settings.appStorageStore.set("unknown-style", forKey: "appearanceStyle")
        XCTAssertEqual(settings.appearanceStyle, .standard)
    }

    /// Backups written while SwiftMiner still had its own light/dark switch must
    /// still import. The mode itself is gone — macOS owns it — so the only thing
    /// that has to survive the trip is the style.
    func testBackupCarryingALegacyModeStillImportsTheStyle() throws {
        settings.appearanceStyle = .standard
        let data = try settings.exportBackupData()
        var payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        payload["appearanceMode"] = "light"
        payload["appearanceStyle"] = AppearanceStyle.atomicPurple.rawValue
        let older = try JSONSerialization.data(withJSONObject: payload)

        try settings.importBackupData(older)

        XCTAssertEqual(settings.appearanceStyle, .atomicPurple)
    }

    func testCombinedAtomicPurpleBackupMigratesToTheAtomicPurpleStyle() throws {
        settings.appearanceStyle = .standard
        let data = try settings.exportBackupData()
        var payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertNotNil(payload.removeValue(forKey: "appearanceStyle"))
        payload["appearanceTheme"] = "atomicPurple"
        let older = try JSONSerialization.data(withJSONObject: payload)

        try settings.importBackupData(older)

        XCTAssertEqual(settings.appearanceStyle, .atomicPurple)
    }

    func testBackupRoundTripRestoresTheMinerArrangement() throws {
        settings.minerOrder = ["c", "a", "b"]

        let data = try settings.exportBackupData()
        settings.resetToDefaults()
        XCTAssertEqual(settings.minerOrder, [])

        try settings.importBackupData(data)
        XCTAssertEqual(settings.minerOrder, ["c", "a", "b"])
    }

    func testABackupWrittenBeforeArrangementsExistedImportsAsNoArrangement() throws {
        settings.minerOrder = ["c", "a", "b"]
        let data = try settings.exportBackupData()

        // An older export is exactly this file without the key, so drop it
        // rather than hand-writing a payload that would drift from the type.
        var payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertNotNil(payload.removeValue(forKey: "minerOrderData"))
        let older = try JSONSerialization.data(withJSONObject: payload)

        try settings.importBackupData(older)
        XCTAssertEqual(settings.minerOrder, [])
    }

    func testWebDashboardOAuthProviderSwitchesResetToEnabled() {
        settings.webDashboardTwitchOAuthEnabled = false
        settings.webDashboardDiscordOAuthEnabled = false

        settings.resetToDefaults()

        XCTAssertTrue(settings.webDashboardTwitchOAuthEnabled)
        XCTAssertTrue(settings.webDashboardDiscordOAuthEnabled)
    }

    func testWebDashboardLocalPasswordRoundTripsAndFollowsUsernameChanges() throws {
        try settings.saveWebDashboardLocalPassword("first-password", username: "admin")
        XCTAssertEqual(settings.webDashboardLocalPassword(), "first-password")

        try settings.saveWebDashboardLocalPassword("second-password", username: "operator")
        settings.webDashboardLocalUsername = "operator"

        XCTAssertEqual(settings.webDashboardLocalPassword(), "second-password")
        settings.webDashboardLocalUsername = "admin"
        XCTAssertNil(settings.webDashboardLocalPassword())
    }

    func testWebDashboardURLRequiresHTTPSOutsideTheLocalNetwork() {
        XCTAssertEqual(
            Settings.normalizedWebDashboardURL(from: "swiftminer.example.com"),
            URL(string: "https://swiftminer.example.com")
        )
        XCTAssertNil(Settings.normalizedWebDashboardURL(from: "http://swiftminer.example.com"))

        for local in [
            "http://localhost:8080",
            "http://127.0.0.1:8080",
            "http://192.168.1.20:8080",
            "http://swiftminer.local:8080",
            "http://mac-mini:8080"
        ] {
            XCTAssertEqual(
                Settings.normalizedWebDashboardURL(from: local),
                URL(string: local),
                "\(local) should remain available for local dashboard access"
            )
        }
    }

    func testIRLCampaignsResetToDisabled() {
        settings.mineIRLCampaigns = true

        settings.resetToDefaults()

        XCTAssertFalse(settings.mineIRLCampaigns)
    }

    func testDisablingIRLCampaignsAlsoExcludesSpecialEvents() {
        settings.mineIRLCampaigns = false

        XCTAssertTrue(settings.excludedGames.contains(Game.specialIRLCategoryId))
        XCTAssertTrue(settings.excludedGames.contains(Game.specialEventsCategoryId))

        settings.mineIRLCampaigns = true

        XCTAssertFalse(settings.excludedGames.contains(Game.specialIRLCategoryId))
        XCTAssertFalse(settings.excludedGames.contains(Game.specialEventsCategoryId))
    }

    private func date(hour: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 5, day: 24, hour: hour))!
    }
}
