import XCTest
@testable import SwiftMiner

final class LogRedactorTests: XCTestCase {

    func testRedactsTwitchOAuthToken() {
        let input = "Authorizing miner with oauth:abcd1234efgh5678ijkl9012mnop3456 for stream"
        let output = LogRedactor.redact(input)
        XCTAssertFalse(output.contains("abcd1234"))
        XCTAssertTrue(output.contains("oauth:<redacted>"))
    }

    func testRedactsBearerHeader() {
        let input = "Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.payloadhere.signature"
        let output = LogRedactor.redact(input)
        XCTAssertFalse(output.contains("eyJhbGciOiJIUzI1NiJ9"))
        XCTAssertTrue(output.contains("Bearer <redacted>") || output.contains("<jwt-redacted>"))
    }

    func testRedactsCookieValues() {
        let input = "Cookie: auth-token=xy12abc34; persistent=98zzz76; login=user_name"
        let output = LogRedactor.redact(input)
        XCTAssertFalse(output.contains("xy12abc34"))
        XCTAssertFalse(output.contains("98zzz76"))
        XCTAssertTrue(output.contains("auth-token=<redacted>"))
        XCTAssertTrue(output.contains("persistent=<redacted>"))
    }

    func testRedactsCookieJsonForm() {
        let input = #"{"auth-token":"sekrit-value","other":"ok"}"#
        let output = LogRedactor.redact(input)
        XCTAssertFalse(output.contains("sekrit-value"))
        XCTAssertTrue(output.contains(#""auth-token":"<redacted>""#))
    }

    func testRedactsEmailAddresses() {
        let input = "User johnhendersonnet@icloud.com signed in"
        let output = LogRedactor.redact(input)
        XCTAssertFalse(output.contains("johnhendersonnet"))
        XCTAssertFalse(output.contains("icloud.com"))
        XCTAssertTrue(output.contains("<email>"))
    }

    func testRedactsDiscordIdHinted() {
        let input = "discord_id=123456789012345678 reported in"
        let output = LogRedactor.redact(input)
        XCTAssertFalse(output.contains("123456789012345678"))
        XCTAssertTrue(output.contains("<discord-id>"))
    }

    func testLeavesShortIdentifiersAlone() {
        // Short ids and ordinary words must not be redacted by the generic rule.
        let input = "campaign id=loh-launch-week-2 status=watching"
        let output = LogRedactor.redact(input)
        XCTAssertEqual(output, input)
    }
}

final class LogExporterTests: XCTestCase {

    private func event(
        _ message: String,
        level: String = "info",
        miner: String? = nil,
        offset: TimeInterval = 0
    ) -> LogExporter.Snapshot.Event {
        LogExporter.Snapshot.Event(
            timestamp: Date(timeIntervalSince1970: 1_730_000_000 + offset),
            level: level,
            minerId: miner,
            message: message
        )
    }

    private func snapshot(
        miners: [LogExporter.Snapshot.Miner] = [],
        events: [LogExporter.Snapshot.Event] = [],
        settings: [(String, String)] = [("logLevel", "info")]
    ) -> LogExporter.Snapshot {
        LogExporter.Snapshot(
            generatedAt: Date(timeIntervalSince1970: 1_730_000_500),
            appVersion: "1.21",
            appBuild: "2026050414",
            osVersion: "macOS 15.0",
            arch: "arm64",
            miners: miners,
            settings: settings,
            events: events
        )
    }

    func testReportRendersWithEmptyInputs() {
        let report = LogExporter.buildReport(snapshot())
        XCTAssertTrue(report.contains("=== SwiftMiner Diagnostic Report ==="))
        XCTAssertTrue(report.contains("App: 1.21 (build 2026050414)"))
        XCTAssertTrue(report.contains("=== Miners (0) ==="))
        XCTAssertTrue(report.contains("=== Events (oldest → newest, 0) ==="))
    }

    func testReportRedactsSecretsInsideEvents() {
        let snap = snapshot(events: [
            event("connecting with oauth:abcd1234efgh5678ijkl9012mnop3456", miner: "gabe")
        ])
        let report = LogExporter.buildReport(snap)
        XCTAssertFalse(report.contains("abcd1234"))
        XCTAssertTrue(report.contains("oauth:<redacted>"))
        XCTAssertTrue(report.contains("gabe"))
    }

    func testReportIncludesMinerStuckDuration() {
        let now = Date(timeIntervalSince1970: 1_730_000_500)
        let miner = LogExporter.Snapshot.Miner(
            id: "gabe",
            username: "gabe",
            nickname: "Gabe",
            status: "watching",
            needsAuth: false,
            isRunning: true,
            dropsClaimed: 12,
            currentCampaign: "LoH Launch Drops Week 2",
            currentCampaignId: "abc-123",
            priorityGames: ["Skull and Bones"],
            statusChangedAt: now.addingTimeInterval(-2_820) // 47m ago
        )
        let report = LogExporter.buildReport(snapshot(miners: [miner]), now: now)
        XCTAssertTrue(report.contains("[Gabe]"))
        XCTAssertTrue(report.contains("status=watching"))
        XCTAssertTrue(report.contains("inStatusFor=47m0s"))
        XCTAssertTrue(report.contains("LoH Launch Drops Week 2"))
    }

    func testDefaultFilenameUsesUTCTimestamp() {
        let date = Date(timeIntervalSince1970: 1_730_000_000)
        let name = LogExporter.defaultFilename(for: date)
        XCTAssertTrue(name.hasPrefix("SwiftMiner-logs-"))
        XCTAssertTrue(name.hasSuffix(".txt"))
    }
}
