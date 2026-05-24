import XCTest
@testable import SwiftMiner

@MainActor
final class SettingsBackupTests: XCTestCase {
    private var settings: Settings!

    override func setUp() {
        super.setUp()
        settings = Settings.shared
        settings.resetToDefaults()
    }

    override func tearDown() {
        settings.resetToDefaults()
        settings = nil
        super.tearDown()
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
        settings.preferSteamArtwork = false
        settings.swiftBotEndpoint = "http://127.0.0.1:9000"

        let data = try settings.exportBackupData()
        settings.resetToDefaults()
        try settings.importBackupData(data)

        XCTAssertTrue(settings.quietHoursEnabled)
        XCTAssertEqual(settings.quietHoursStartMinute, 21 * 60)
        XCTAssertEqual(settings.quietHoursEndMinute, 8 * 60)
        XCTAssertFalse(settings.preferSteamArtwork)
        XCTAssertEqual(settings.swiftBotEndpoint, "http://127.0.0.1:9000")
    }

    private func date(hour: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 5, day: 24, hour: hour))!
    }
}
