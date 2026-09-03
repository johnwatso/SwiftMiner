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
        channels: [Channel] = [],
        allowIsEnabled: Bool? = nil,
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
            channels: channels,
            isAccountConnected: isAccountConnected,
            allowIsEnabled: allowIsEnabled
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

        _ = await client.reconcilingCampaign(campaign(drops: algsDrops))
        let stripped = await client.reconcilingCampaign(campaign(drops: []))

        XCTAssertEqual(stripped.drops.map(\.name), ["APEX Pack", "Sushi Nessie Gun Charm"])
    }

    func testRememberedCampaignFactsSurviveClaimInvalidationAndRestart() async {
        let acl = [Channel(id: "1", login: "algs", displayName: "ALGS")]
        let first = makeClient(persistsCampaignCaches: true)
        await first.setUserLogin(userLogin)
        _ = await first.reconcilingCampaign(campaign(
            drops: algsDrops,
            channels: acl,
            allowIsEnabled: true
        ))
        await first.persistCampaignCachesIfNeeded()
        await first.invalidateCampaignDetailsAfterClaim()

        let relaunched = makeClient(persistsCampaignCaches: true)
        await relaunched.setUserLogin(userLogin)
        await relaunched.loadPersistedCampaignCachesIfNeeded()
        let repaired = await relaunched.reconcilingCampaign(campaign(
            drops: [],
            channels: [],
            allowIsEnabled: nil
        ))

        XCTAssertEqual(repaired.drops.map(\.id), ["pack", "charm"])
        XCTAssertEqual(repaired.allowIsEnabled, true)
        XCTAssertEqual(repaired.channels.map(\.login), ["algs"])
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

        _ = await client.reconcilingCampaign(campaign(drops: algsDrops))
        let ended = await client.reconcilingCampaign(campaign(
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
        _ = await client.reconcilingCampaign(campaign(drops: claimable))
        let restored = await client.reconcilingCampaign(campaign(drops: []))

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
        let denied = await client.reconcilingCampaign(
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

        let denied = await client.reconcilingCampaign(
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

    func testAnActiveCampaignMissingFromTheNewResponseStillProducesAWarning() {
        let previous = campaign(drops: algsDrops)

        let summary = MinerEngine.abandonedCampaignSummary(
            previousCampaignId: previous.id,
            previousCampaign: previous,
            in: [],
            candidates: []
        )

        XCTAssertTrue(summary?.contains(previous.name) == true)
    }

    func testMissingActiveCampaignIsPreservedUntilItsWindowEnds() {
        let active = campaign(drops: algsDrops)
        let result = DropsService.preservingMissingActiveCampaigns(
            fetched: [],
            remembered: [active],
            inventory: nil
        )

        XCTAssertEqual(result.campaigns.map(\.id), [active.id])
        XCTAssertEqual(result.preservedIDs, Set([active.id]))
    }

    func testMissingCampaignIsNotPreservedAfterInventoryConfirmsCompletion() {
        let drops = [
            Drop(id: "pack", name: "APEX Pack", requiredMinutes: 15, benefitID: "benefit-pack"),
            Drop(id: "charm", name: "Sushi Nessie Gun Charm", requiredMinutes: 60, benefitID: "benefit-charm")
        ]
        let snapshot = InventorySnapshot(
            accountId: "1",
            benefitIDs: ["benefit-pack", "benefit-charm"],
            progress: []
        )

        let result = DropsService.preservingMissingActiveCampaigns(
            fetched: [],
            remembered: [campaign(drops: drops)],
            inventory: snapshot
        )

        XCTAssertTrue(result.campaigns.isEmpty)
        XCTAssertTrue(result.preservedIDs.isEmpty)
    }

    func testMalformedDashboardWindowIsRejectedInsteadOfExpiringAtNow() async {
        let client = makeClient()
        let malformed: [String: Any] = [
            "id": "algs-md6",
            "name": "ALGS Split 2 PL MD 6",
            "status": "ACTIVE",
            "startAt": "not-a-date",
            "game": ["id": "511224", "displayName": "Apex Legends"]
        ]

        let parsed = await client.parseBasicCampaign(from: malformed)

        XCTAssertNil(parsed)
    }

    // MARK: A reused benefit ID must not claim a reward in a campaign that never awarded it

    private let sharedCharmBenefit = "fa395b5e_CUSTOM_ID_algs_s29_weapon_charm_01"

    private func algsMatchDay(
        id: String,
        charmDropId: String,
        packBenefit: String,
        start: Date,
        end: Date
    ) -> Campaign {
        Campaign(
            id: id,
            name: "ALGS Split 2 PL \(id)",
            game: Game(id: "511224", name: "Apex Legends"),
            status: .active,
            startDate: start,
            endDate: end,
            drops: [
                Drop(id: "pack-\(id)", name: "APEX Pack", requiredMinutes: 15, benefitID: packBenefit),
                // The charm carries the SAME benefit ID on every match day. Only the drop id
                // differs, which is why its progress restarted from zero each day.
                Drop(id: charmDropId, name: "Sushi Nessie Gun Charm", requiredMinutes: 60, benefitID: sharedCharmBenefit)
            ],
            channels: [],
            isAccountConnected: true
        )
    }

    /// The failure that cost the charm three days running. Claiming it once in an earlier
    /// match day put its benefit ID in inventory; every later match day then read that as
    /// "already claimed", leaving the 15-minute pack as the only earnable reward. Claim the
    /// pack and the campaign has nothing left to earn, so it leaves the candidate set within
    /// one refresh — exactly when every miner stopped.
    func testAnEarlierMatchDayClaimDoesNotRetireTodaysCharm() {
        let day = 24.0 * 60 * 60
        let md4Start = Date().addingTimeInterval(-3 * day)
        let md4 = algsMatchDay(
            id: "md4",
            charmDropId: "charm-md4",
            packBenefit: "pack_4",
            start: md4Start,
            end: md4Start.addingTimeInterval(20 * 60 * 60)
        )
        let md6 = algsMatchDay(
            id: "md6",
            charmDropId: "charm-md6",
            packBenefit: "pack_6",
            start: Date().addingTimeInterval(-20 * 60),
            end: Date().addingTimeInterval(21 * 60 * 60)
        )

        let snapshot = InventorySnapshot(
            accountId: "1",
            benefitIDs: [sharedCharmBenefit],
            // Awarded three days ago, during MD4 — not during today's campaign.
            benefitAwardedAt: [sharedCharmBenefit: md4Start.addingTimeInterval(60 * 60)],
            progress: [],
            discoveredCampaigns: []
        )

        let merged = DropsService.mergeInventory(snapshot, into: [md4, md6])
        let today = merged.first { $0.id == "md6" }

        XCTAssertEqual(
            today?.drops.first { $0.id == "charm-md6" }?.isClaimed,
            false,
            "today's charm was never awarded and must stay earnable"
        )
        XCTAssertEqual(
            today?.earnableDrops.contains { $0.name == "Sushi Nessie Gun Charm" },
            true,
            "so the campaign survives its pack being claimed"
        )
        XCTAssertEqual(
            merged.first { $0.id == "md4" }?.drops.first { $0.id == "charm-md4" }?.isClaimed,
            true,
            "the match day that actually awarded it still reads as claimed"
        )
    }

    /// A benefit belonging to exactly one campaign needs no attribution and behaves as it
    /// always has — the overwhelmingly common case.
    func testAnUnsharedBenefitStillMarksItsDropClaimed() {
        let only = campaign(drops: [
            Drop(id: "only", name: "Stormlash", requiredMinutes: 60, benefitID: "unique-benefit")
        ])
        let snapshot = InventorySnapshot(
            accountId: "1",
            benefitIDs: ["unique-benefit"],
            progress: [],
            discoveredCampaigns: []
        )

        XCTAssertTrue(DropsService.mergeInventory(snapshot, into: [only])[0].drops[0].isClaimed)
    }

    /// Twitch dating an award poorly must not forfeit a reward. A redundant claim attempt is
    /// refused harmlessly; a wrong "claimed" loses the drop for good.
    func testAnUndatedSharedBenefitLeavesTheRewardEarnable() {
        let start = Date().addingTimeInterval(-60 * 60)
        let end = start.addingTimeInterval(20 * 60 * 60)
        let a = algsMatchDay(id: "a", charmDropId: "charm-a", packBenefit: "p_a", start: start, end: end)
        let b = algsMatchDay(id: "b", charmDropId: "charm-b", packBenefit: "p_b", start: start, end: end)

        let snapshot = InventorySnapshot(
            accountId: "1",
            benefitIDs: [sharedCharmBenefit],
            benefitAwardedAt: [:],
            progress: [],
            discoveredCampaigns: []
        )

        let merged = DropsService.mergeInventory(snapshot, into: [a, b])

        XCTAssertTrue(merged.allSatisfy { campaign in
            campaign.drops.contains { $0.name.contains("Nessie") && !$0.isClaimed }
        })
    }

    private func makeClient(persistsCampaignCaches: Bool = false) -> TwitchAPIClient {
        TwitchAPIClient(
            authService: TwitchAuthService(clientId: "test", tokenStore: InMemoryTokenStore()),
            clientId: "test",
            persistsCampaignCaches: persistsCampaignCaches
        )
    }
}
