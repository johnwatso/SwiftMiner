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
        settings.quietHoursEnabled = true
        settings.quietHoursStartMinute = 21 * 60
        settings.quietHoursEndMinute = 8 * 60
        settings.swiftBotEndpoint = "http://127.0.0.1:9000"

        let data = try settings.exportBackupData()
        settings.resetToDefaults()
        try settings.importBackupData(data)

        XCTAssertTrue(settings.quietHoursEnabled)
        XCTAssertEqual(settings.quietHoursStartMinute, 21 * 60)
        XCTAssertEqual(settings.quietHoursEndMinute, 8 * 60)
        XCTAssertEqual(settings.swiftBotEndpoint, "http://127.0.0.1:9000")
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
