import XCTest
@testable import SwiftMinerCore

/// The cross-miner campaign metadata cache lets one account's fetch serve the rest, which is
/// most of SwiftMiner's Twitch traffic. It is only safe while the shared copy carries no
/// account-specific state and reconstruction never downgrades an account's link state — a
/// campaign wrongly marked unlinked drops out of mining entirely.
final class CampaignMetadataSharingTests: XCTestCase {
    private func drop(id: String, claimed: Bool, minutes: Int?) -> Drop {
        Drop(
            id: id,
            name: "Drop \(id)",
            requiredMinutes: 60,
            benefitID: "benefit-\(id)",
            progress: minutes.map {
                Progress(
                    id: "progress-\(id)",
                    dropId: id,
                    dropName: "Drop \(id)",
                    campaignId: "campaign",
                    currentMinutes: $0,
                    requiredMinutes: 60
                )
            },
            isClaimed: claimed
        )
    }

    private func campaign(
        connected: Bool,
        prioritised: Bool = false,
        claimed: Bool = false,
        minutes: Int? = nil
    ) -> Campaign {
        Campaign(
            id: "campaign",
            name: "Season 4 Launch",
            game: Game(id: "1", name: "Battlefield 6"),
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_600_000),
            drops: [drop(id: "a", claimed: claimed, minutes: minutes)],
            channels: [Channel(id: "c1", login: "streamer", displayName: "Streamer")],
            isAccountConnected: connected,
            allowIsEnabled: true,
            isPrioritised: prioritised
        )
    }

    /// Nothing account-specific may be published to a cache other accounts read from.
    func testSharedMetadataStripsAccountSpecificState() {
        let source = campaign(connected: true, prioritised: true, claimed: true, minutes: 42)

        let shared = TwitchAPIClient.sharedCampaignMetadata(from: source)

        XCTAssertFalse(shared.isAccountConnected)
        XCTAssertEqual(shared.drops.count, 1)
        XCTAssertFalse(shared.drops[0].isClaimed)
        XCTAssertNil(shared.drops[0].progress)

        // Campaign-global facts must survive, or the cache would be useless.
        XCTAssertEqual(shared.name, "Season 4 Launch")
        XCTAssertEqual(shared.game.name, "Battlefield 6")
        XCTAssertEqual(shared.startDate, source.startDate)
        XCTAssertEqual(shared.endDate, source.endDate)
        XCTAssertEqual(shared.channels.map(\.id), ["c1"])
        XCTAssertEqual(shared.drops[0].requiredMinutes, 60)
        XCTAssertEqual(shared.allowIsEnabled, true)
    }

    /// The reason the shared path was previously restricted to already-linked campaigns:
    /// a linked account whose dashboard entry does not say so must not be served a copy
    /// that reports it unlinked.
    func testReconstructionDoesNotDowngradeKnownLinkState() {
        let shared = TwitchAPIClient.sharedCampaignMetadata(from: campaign(connected: true))
        let dashboardSaysUnlinked = campaign(connected: false, prioritised: true)

        let rebuilt = TwitchAPIClient.campaign(
            fromSharedMetadata: shared,
            accountContext: dashboardSaysUnlinked,
            // What a real fetch previously established for this account.
            isAccountConnected: true
        )

        XCTAssertTrue(rebuilt.isAccountConnected)
        XCTAssertTrue(rebuilt.isPrioritised, "user preference comes from the account context")
    }

    func testReconstructionKeepsUnlinkedWhenNeitherSourceKnowsBetter() {
        let shared = TwitchAPIClient.sharedCampaignMetadata(from: campaign(connected: true))
        let context = campaign(connected: false)

        let rebuilt = TwitchAPIClient.campaign(
            fromSharedMetadata: shared,
            accountContext: context,
            isAccountConnected: false
        )

        XCTAssertFalse(rebuilt.isAccountConnected)
    }

    /// A shared copy must never leak one account's claim or progress state into another's.
    func testReconstructionDoesNotInheritAnotherAccountsProgress() {
        let shared = TwitchAPIClient.sharedCampaignMetadata(
            from: campaign(connected: true, claimed: true, minutes: 59)
        )

        let rebuilt = TwitchAPIClient.campaign(
            fromSharedMetadata: shared,
            accountContext: campaign(connected: false),
            isAccountConnected: true
        )

        XCTAssertFalse(rebuilt.drops[0].isClaimed)
        XCTAssertNil(rebuilt.drops[0].progress)
    }

    /// The details cache exists to spare a refetch on the next cycle. At exactly the
    /// campaign check interval every entry expired just before it was needed, so the cache
    /// never hit and each cycle refetched every active campaign.
    func testDetailsCacheOutlivesTheCampaignRefreshInterval() async {
        let client = TwitchAPIClient(
            authService: TwitchAuthService(clientId: "test", tokenStore: InMemoryTokenStore()),
            clientId: "test"
        )
        let campaignCheckInterval: TimeInterval = 5 * 60

        let detailsTTL = await client.campaignDetailsCacheTTL
        let linkStateTTL = await client.campaignLinkStateTTL
        XCTAssertGreaterThan(detailsTTL, campaignCheckInterval)
        XCTAssertGreaterThan(linkStateTTL, campaignCheckInterval)
    }
}
