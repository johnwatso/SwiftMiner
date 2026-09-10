import XCTest
@testable import SwiftMinerCore

/// `candidateCampaigns` is both the scheduler's decision point and a convenient way to refresh
/// the UI's campaign list, and it logged its filter tally either way. Call sites of the second
/// kind re-derive the list from a *different* snapshot moments later, so a live 16-hour log
/// carried 1,144 duplicate `[CampaignSelect]` lines — neighbouring lines in the same second
/// disagreeing about how many campaigns were eligible.
final class CampaignSelectLoggingTests: XCTestCase {

    private func campaign(id: String, game: String) -> Campaign {
        Campaign(
            id: id,
            name: "\(game) Drops",
            game: Game(id: "g-\(id)", name: game),
            status: .active,
            startDate: Date().addingTimeInterval(-3600),
            endDate: Date().addingTimeInterval(3600),
            drops: [Drop(id: "d-\(id)", name: "Drop \(id)", requiredMinutes: 60)],
            isAccountConnected: true
        )
    }

    private func captureLogs(
        logSummary: Bool
    ) async -> (candidates: [Campaign], lines: [String]) {
        let engine = MinerEngine(clientId: "test")
        let recorder = LogRecorder()
        await engine.setLogMessageHandler { message in recorder.append(message) }

        let campaigns = [campaign(id: "c1", game: "Rust"), campaign(id: "c2", game: "For Honor")]
        let candidates = await engine.candidateCampaigns(
            from: campaigns,
            priorityGames: ["Rust"],
            excludedGames: [],
            strategy: .prioritiseSelected,
            logSummary: logSummary
        )
        return (candidates, recorder.lines())
    }

    func testSchedulerCallStillLogsTheFilterTally() async {
        let (candidates, lines) = await captureLogs(logSummary: true)

        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(lines.filter { $0.contains("[CampaignSelect]") }.count, 1)
    }

    func testIncidentalCallIsSilent() async {
        let (candidates, lines) = await captureLogs(logSummary: false)

        XCTAssertEqual(candidates.count, 2, "silencing the log must not change the ranking")
        XCTAssertTrue(lines.filter { $0.contains("[CampaignSelect]") }.isEmpty)
    }

    /// Logging defaults on, so a new call site announces itself rather than going quiet by
    /// accident — silence is the decision that has to be made deliberately.
    func testLoggingIsOnByDefault() async {
        let engine = MinerEngine(clientId: "test")
        let recorder = LogRecorder()
        await engine.setLogMessageHandler { message in recorder.append(message) }

        _ = await engine.candidateCampaigns(
            from: [campaign(id: "c1", game: "Rust")],
            priorityGames: [],
            excludedGames: [],
            strategy: .mineAll
        )

        XCTAssertEqual(recorder.lines().filter { $0.contains("[CampaignSelect]") }.count, 1)
    }
}

/// The engine's log handler is `@Sendable` and called from the actor, so collected lines need
/// their own synchronisation.
private final class LogRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    func append(_ line: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(line)
    }

    func lines() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
