import XCTest
@testable import SwiftMinerCore

/// Covers failover-streamer rule matching and the no-candidate backoff bound —
/// pure scheduling helpers that gate which streamer a stalled session falls
/// over to and how long an idle miner waits between empty scans.
final class MinerFailoverTests: XCTestCase {

    private func rule(
        gameId: String = "",
        gameName: String = "",
        streamer: String = "streamer",
        enabled: Bool = true
    ) -> GameFailoverStreamer {
        GameFailoverStreamer(gameId: gameId, gameName: gameName, streamerLogin: streamer, enabled: enabled)
    }

    // MARK: - matchingFailoverRule

    func testFailoverMatch_ByGameId() {
        let rules = [rule(gameId: "ow", gameName: "Overwatch 2", streamer: "shroud")]
        let match = MinerEngine.matchingFailoverRule(
            in: rules, campaignGameId: "ow", campaignGameName: "Something Else"
        )
        XCTAssertEqual(match?.streamerLogin, "shroud")
    }

    func testFailoverMatch_ByGameNameWhenIdEmpty() {
        let rules = [rule(gameId: "", gameName: "Overwatch 2", streamer: "shroud")]
        let match = MinerEngine.matchingFailoverRule(
            in: rules, campaignGameId: "ow", campaignGameName: "Overwatch 2"
        )
        XCTAssertEqual(match?.streamerLogin, "shroud")
    }

    func testFailoverMatch_IsCaseAndWhitespaceInsensitive() {
        let rules = [rule(gameName: "  Overwatch 2  ", streamer: "shroud")]
        let match = MinerEngine.matchingFailoverRule(
            in: rules, campaignGameId: "", campaignGameName: "overwatch 2"
        )
        XCTAssertEqual(match?.streamerLogin, "shroud")
    }

    func testFailoverMatch_SkipsDisabledRule() {
        let rules = [rule(gameId: "ow", streamer: "shroud", enabled: false)]
        XCTAssertNil(MinerEngine.matchingFailoverRule(
            in: rules, campaignGameId: "ow", campaignGameName: "Overwatch 2"
        ))
    }

    func testFailoverMatch_SkipsRuleWithNoStreamerLogin() {
        // An empty login is normalized to "" by GameFailoverStreamer and must not match.
        let rules = [rule(gameId: "ow", streamer: "")]
        XCTAssertNil(MinerEngine.matchingFailoverRule(
            in: rules, campaignGameId: "ow", campaignGameName: "Overwatch 2"
        ))
    }

    func testFailoverMatch_ReturnsFirstMatchingRule() {
        let rules = [
            rule(gameId: "ow", streamer: "first"),
            rule(gameId: "ow", streamer: "second"),
        ]
        let match = MinerEngine.matchingFailoverRule(
            in: rules, campaignGameId: "ow", campaignGameName: "Overwatch 2"
        )
        XCTAssertEqual(match?.streamerLogin, "first")
    }

    func testFailoverMatch_NoMatchReturnsNil() {
        let rules = [rule(gameId: "ow", gameName: "Overwatch 2", streamer: "shroud")]
        XCTAssertNil(MinerEngine.matchingFailoverRule(
            in: rules, campaignGameId: "valorant", campaignGameName: "VALORANT"
        ))
    }

    // MARK: - noCandidateBackoffInterval

    func testBackoff_FirstScansUseBaseInterval() {
        XCTAssertEqual(MinerEngine.noCandidateBackoffInterval(for: 0), MinerEngine.noCandidateBackoffBaseInterval)
        XCTAssertEqual(MinerEngine.noCandidateBackoffInterval(for: 1), MinerEngine.noCandidateBackoffBaseInterval)
    }

    /// The core reliability guarantee: no matter how many consecutive empty
    /// scans have happened, a newly-started short campaign is never left waiting
    /// longer than the capped interval before the next scan.
    func testBackoff_NeverExceedsMaxInterval() {
        for cycles in 0...20 {
            let interval = MinerEngine.noCandidateBackoffInterval(for: cycles)
            XCTAssertLessThanOrEqual(interval, MinerEngine.noCandidateBackoffMaxInterval)
            XCTAssertGreaterThanOrEqual(interval, MinerEngine.noCandidateBackoffBaseInterval)
        }
    }

    /// Documents the stated intent that the cap stays at 5 minutes — so an empty
    /// streak can't quietly grow into a 10–15 minute discovery delay.
    func testBackoff_CapIsFiveMinutes() {
        XCTAssertLessThanOrEqual(MinerEngine.noCandidateBackoffMaxInterval, 5 * 60 * 1_000_000_000)
    }
}
