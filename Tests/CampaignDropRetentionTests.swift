import XCTest
@testable import SwiftMinerCore

/// Guards the way a campaign we are actively earning in can disappear mid-window.
///
/// `ViewerDropsDashboard` never carries drops, so `DropCampaignDetails` is the only source
/// of them. A response that omits `timeBasedDrops`, or that answers `isAccountConnected:
/// false` for an account that is in fact linked, leaves a campaign that `candidateCampaigns`
/// filters out — and `cacheCampaignDetailsForAccount` then pins that answer for up to four
/// hours for a campaign with no ACL of its own.
///
/// That is what took the ALGS Split 2 PL charm on three consecutive match days: each miner
/// claimed the 15-minute APEX Pack, the claim forced a details refetch, and Apex Legends was
/// out of the candidate set within one cycle with the 60-minute drop stranded at 18/60 and
/// roughly 21 hours of campaign window unused.
final class CampaignDropRetentionTests: XCTestCase {
    private let userLogin = "drop-retention-tests"

    private let algsDrops = [
        Drop(id: "pack", name: "APEX Pack", requiredMinutes: 15),
        Drop(id: "charm", name: "Sushi Nessie Gun Charm", requiredMinutes: 60)
    ]

    private func campaign(
        drops: [Drop],
        isAccountConnected: Bool = true,
        endDate: Date = Date().addingTimeInterval(21 * 60 * 60)
    ) -> Campaign {
        Campaign(
            id: "algs-md6",
            name: "ALGS Split 2 PL MD 6",
            game: Game(id: "511224", name: "Apex Legends"),
            status: .active,
            startDate: Date().addingTimeInterval(-20 * 60),
            endDate: endDate,
            drops: drops,
            channels: [],
            isAccountConnected: isAccountConnected
        )
    }

    override func tearDown() {
        CampaignDetailsDiskCache.clear(userLogin: userLogin)
        super.tearDown()
    }

    /// The core regression: drops seen once come back when a later fetch omits them.
    func testDropsAreReinstatedWhenAFetchReturnsNone() async {
        let client = makeClient()
        await client.setUserLogin(userLogin)

        _ = await client.reinstatingKnownDrops(campaign(drops: algsDrops))
        let stripped = await client.reinstatingKnownDrops(campaign(drops: []))

        XCTAssertEqual(stripped.drops.map(\.name), ["APEX Pack", "Sushi Nessie Gun Charm"])
    }

    /// Without the drops the campaign is not mineable at all — this is the filter that
    /// removed Apex Legends from the candidate set.
    func testACampaignWithNoDropsCannotBeMined() {
        XCTAssertFalse(campaign(drops: []).canAttemptMining)
        XCTAssertTrue(campaign(drops: algsDrops).canAttemptMining)
    }

    /// A campaign that has genuinely ended must not have drops put back — reinstating there
    /// would keep dead campaigns alive in the candidate set.
    func testAnEndedCampaignDoesNotGetItsDropsBack() async {
        let client = makeClient()
        await client.setUserLogin(userLogin)

        _ = await client.reinstatingKnownDrops(campaign(drops: algsDrops))
        let ended = await client.reinstatingKnownDrops(campaign(
            drops: [],
            endDate: Date().addingTimeInterval(-60)
        ))

        XCTAssertTrue(ended.drops.isEmpty)
    }

    /// Reinstating a remembered list must not resurrect a claimed drop: `mergeInventory`
    /// assigns `isClaimed` from inventory benefit IDs and ignores what the drop carried.
    func testReinstatedDropsTakeTheirClaimedStateFromInventory() async {
        let client = makeClient()
        await client.setUserLogin(userLogin)

        let claimable = [
            Drop(id: "pack", name: "APEX Pack", requiredMinutes: 15, benefitID: "benefit-pack"),
            Drop(id: "charm", name: "Sushi Nessie Gun Charm", requiredMinutes: 60, benefitID: "benefit-charm")
        ]
        _ = await client.reinstatingKnownDrops(campaign(drops: claimable))
        let restored = await client.reinstatingKnownDrops(campaign(drops: []))

        let snapshot = InventorySnapshot(
            accountId: "1",
            benefitIDs: ["benefit-pack"],
            progress: [],
            discoveredCampaigns: [],
            lastUpdated: Date()
        )
        let merged = DropsService.mergeInventory(snapshot, into: [restored])

        let claimedNames = merged[0].drops.filter(\.isClaimed).map(\.name)
        XCTAssertEqual(claimedNames, ["APEX Pack"], "only the benefit inventory reports is claimed")
        XCTAssertEqual(merged[0].earnableDrops.map(\.name), ["Sushi Nessie Gun Charm"])
    }

    /// A single `isAccountConnected: false` must not unlink a campaign this account was
    /// confirmed linked to — an unlinked, non-prioritised campaign is never attempted.
    func testAConfirmedLinkSurvivesOneUnlinkedResponse() async {
        let client = makeClient()
        await client.setUserLogin(userLogin)
        let cacheKey = TwitchAPIClient.cacheKey("campaign-details", userLogin, "algs-md6")

        await client.rememberLinkState(isAccountConnected: true, cacheKey: cacheKey)
        let denied = await client.reinstatingKnownLinkState(
            campaign(drops: algsDrops, isAccountConnected: false),
            cacheKey: cacheKey
        )

        XCTAssertTrue(denied.isAccountConnected)
    }

    /// With nothing remembered there is nothing to reinstate: an unlinked answer stands.
    func testAnUnlinkedResponseStandsWithoutARememberedLink() async {
        let client = makeClient()
        await client.setUserLogin(userLogin)
        let cacheKey = TwitchAPIClient.cacheKey("campaign-details", userLogin, "algs-md6")

        let denied = await client.reinstatingKnownLinkState(
            campaign(drops: algsDrops, isAccountConnected: false),
            cacheKey: cacheKey
        )

        XCTAssertFalse(denied.isAccountConnected)
    }

    /// The diagnostic that was missing: name the campaign that left, and what it lost.
    func testAnAbandonedCampaignIsNamedWithWhatItLost() {
        let stranded = campaign(drops: [])

        let summary = MinerEngine.abandonedCampaignSummary(
            previousCampaignId: "algs-md6",
            in: [stranded],
            candidates: []
        )

        let reported = try? XCTUnwrap(summary)
        XCTAssertTrue(reported?.contains("ALGS Split 2 PL MD 6") == true)
        XCTAssertTrue(reported?.contains("drops=0") == true)
    }

    /// A campaign that finished, or whose window closed, was not abandoned — reporting those
    /// would bury the real case in noise.
    func testAFinishedCampaignIsNotReportedAsAbandoned() {
        let claimed = [
            Drop(id: "pack", name: "APEX Pack", requiredMinutes: 15, isClaimed: true),
            Drop(id: "charm", name: "Sushi Nessie Gun Charm", requiredMinutes: 60, isClaimed: true)
        ]

        XCTAssertNil(MinerEngine.abandonedCampaignSummary(
            previousCampaignId: "algs-md6",
            in: [campaign(drops: claimed)],
            candidates: []
        ))
        XCTAssertNil(MinerEngine.abandonedCampaignSummary(
            previousCampaignId: "algs-md6",
            in: [campaign(drops: algsDrops, endDate: Date().addingTimeInterval(-60))],
            candidates: []
        ))
    }

    private func makeClient() -> TwitchAPIClient {
        TwitchAPIClient(
            authService: TwitchAuthService(clientId: "test", tokenStore: InMemoryTokenStore()),
            clientId: "test",
            persistsCampaignCaches: false
        )
    }
}
