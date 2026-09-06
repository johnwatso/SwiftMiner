import XCTest
@testable import SwiftMiner
@testable import SwiftMinerCore

@MainActor
final class AccountPriorityGamesTests: XCTestCase {
    private var settings: Settings!
    private let account = "account-1"

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

    func testSetPersonalPriorityGamesTrimsAndDeduplicates() {
        let result = settings.setPersonalPriorityGames(accountId: account, games: ["  Marvel Rivals ", "Delta Force", "marvel rivals", ""])
        XCTAssertEqual(result, ["Marvel Rivals", "Delta Force"])
        XCTAssertEqual(settings.personalPriorityGames(forAccountId: account), ["Marvel Rivals", "Delta Force"])
    }

    func testPersonalGamesRankAboveGlobalAndExcludeGlobalFromPersonalList() {
        settings.addGamePreference(Game(id: "g-global", name: "Global Game"), state: .preferred)
        XCTAssertEqual(settings.priorityGames, ["Global Game"])

        let effective = settings.setPersonalPriorityGames(accountId: account, games: ["Personal Game"])
        // Personal first, global retained at lower priority.
        XCTAssertEqual(effective, ["Personal Game", "Global Game"])
        // Personal-only view excludes the global game.
        XCTAssertEqual(settings.personalPriorityGames(forAccountId: account), ["Personal Game"])
    }

    func testCanOptOutOfGlobalPriorityGames() {
        settings.addGamePreference(Game(id: "g-global", name: "Global Game"), state: .preferred)
        settings.setPersonalPriorityGames(accountId: account, games: ["Personal Game"])

        settings.setIncludesGlobalPriorityGames(false, forAccountId: account)

        XCTAssertFalse(settings.includesGlobalPriorityGames(forAccountId: account))
        XCTAssertEqual(settings.priorityGames(forAccountId: account), ["Personal Game"])
        XCTAssertEqual(settings.personalPriorityGames(forAccountId: account), ["Personal Game"])
    }

    func testOptingOutWithEmptyPersonalListUsesNoPriorities() {
        settings.addGamePreference(Game(id: "g-global", name: "Global Game"), state: .preferred)

        settings.setIncludesGlobalPriorityGames(false, forAccountId: account)

        XCTAssertEqual(settings.priorityGames(forAccountId: account), [])
    }

    func testClearingPersonalGamesFallsBackToGlobal() {
        settings.addGamePreference(Game(id: "g-global", name: "Global Game"), state: .preferred)
        settings.setPersonalPriorityGames(accountId: account, games: ["Personal Game"])

        let cleared = settings.setPersonalPriorityGames(accountId: account, games: [])
        XCTAssertEqual(cleared, ["Global Game"])
        XCTAssertTrue(settings.personalPriorityGames(forAccountId: account).isEmpty)
    }

    func testGlobalSourcePreservesPersonalPrioritiesForLaterUse() {
        settings.addGamePreference(Game(id: "g-global", name: "Global Game"), state: .preferred)
        settings.setPersonalPriorityGames(accountId: account, games: ["Personal Game"])

        settings.setPrioritySource(.global, forAccountId: account)
        XCTAssertEqual(settings.prioritySource(forAccountId: account), .global)
        XCTAssertEqual(settings.priorityGames(forAccountId: account), ["Global Game"])
        XCTAssertEqual(settings.personalPriorityGames(forAccountId: account), ["Personal Game"])

        settings.setPrioritySource(.globalAndPersonal, forAccountId: account)
        XCTAssertEqual(settings.priorityGames(forAccountId: account), ["Personal Game", "Global Game"])
        XCTAssertEqual(settings.personalPriorityGames(forAccountId: account), ["Personal Game"])
    }

    func testResettingCustomPrioritiesRestoresGlobalPriorities() {
        settings.addGamePreference(Game(id: "g-global", name: "Global Game"), state: .preferred)
        settings.setPersonalPriorityGames(accountId: account, games: ["Personal Game"])
        settings.setPrioritySource(.personal, forAccountId: account)
        XCTAssertTrue(settings.hasCustomPriorityGames(forAccountId: account))

        let reset = settings.resetPriorityGamesToGlobal(forAccountId: account)

        XCTAssertEqual(reset, ["Global Game"])
        XCTAssertEqual(settings.prioritySource(forAccountId: account), .global)
        XCTAssertFalse(settings.hasCustomPriorityGames(forAccountId: account))
        XCTAssertTrue(settings.personalPriorityGames(forAccountId: account).isEmpty)
    }

    func testPriorityAuditIncludesModeChanges() {
        let messages = NavigationModel.priorityAuditMessages(
            actor: "sorbertman",
            old: ["Old Game"],
            new: ["New Game"],
            oldSource: .global,
            newSource: .globalAndPersonal
        )

        XCTAssertEqual(messages, [
            "sorbertman changed priority mode from Shared to Hybrid",
            "sorbertman added New Game to their priority list",
            "sorbertman removed Old Game from their priority list"
        ])
    }

    func testGameFailoverStreamerPersistsByGame() {
        let game = Game(id: "g-finals", name: "THE FINALS")
        settings.addGamePreference(game, state: .preferred)

        let preference = try! XCTUnwrap(settings.gamePreferences.first)
        settings.setFailoverStreamer("https://www.twitch.tv/Ronin", for: preference)

        let failover = settings.failoverStreamer(for: preference)
        XCTAssertEqual(failover?.gameId, "g-finals")
        XCTAssertEqual(failover?.gameName, "THE FINALS")
        XCTAssertEqual(failover?.streamerLogin, "ronin")

        settings.clearFailoverStreamer(for: preference)
        XCTAssertNil(settings.failoverStreamer(for: preference))
    }
}
