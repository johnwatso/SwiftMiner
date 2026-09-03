import XCTest
@testable import SwiftMinerCore

/// The guard against this bug class recurring.
///
/// A degraded Twitch response erasing one field of a campaign has taken SwiftMiner out of a
/// drop window four separate times — the campaign window, the approved-channel list, the
/// drop list, and the account link — each discovered only after a missed campaign, each
/// patched on its own. TDM never had the problem because it holds no campaign state between
/// cycles; SwiftMiner caches details for up to four hours to survive five accounts at
/// launch, which turns a transient bad answer into a durable one.
///
/// So the rule is declared once in `CampaignMiningGate`, and these tests make it impossible
/// to add a field that can stop mining without deciding what happens when Twitch omits it.
final class CampaignRefreshPolicyTests: XCTestCase {
    private func campaign(
        drops: [Drop] = [Drop(id: "d", name: "Charm", requiredMinutes: 60)],
        channels: [Channel] = [],
        isAccountConnected: Bool = true,
        allowIsEnabled: Bool? = nil,
        endDate: Date = Date().addingTimeInterval(20 * 60 * 60)
    ) -> Campaign {
        Campaign(
            id: "c1",
            name: "ALGS Split 2 PL MD 6",
            game: Game(id: "511224", name: "Apex Legends"),
            status: .active,
            startDate: Date().addingTimeInterval(-3600),
            endDate: endDate,
            drops: drops,
            channels: channels,
            isAccountConnected: isAccountConnected,
            allowIsEnabled: allowIsEnabled
        )
    }

    private let acl = [Channel(id: "1", login: "algs1_team1", displayName: "ALGS")]

    // MARK: The enforcement

    /// Every stored property of `Campaign` must be classified: either it can stop the miner
    /// — in which case it is a `CampaignMiningGate` with a declared refresh policy — or it
    /// is explicitly listed as non-gating. Adding a property fails this test until someone
    /// decides which it is, which is the whole point.
    func testEveryCampaignPropertyIsClassified() {
        let properties = Set(
            Mirror(reflecting: campaign()).children.compactMap(\.label)
        )
        let gates = Set(CampaignMiningGate.allCases.map(\.rawValue))
        let classified = gates.union(CampaignMiningGate.nonGatingCampaignProperties)

        XCTAssertEqual(
            properties.subtracting(classified),
            [],
            """
            A new Campaign property is neither a CampaignMiningGate nor listed as non-gating. \
            If a degraded refresh of this field could stop the miner working the campaign, \
            add it to CampaignMiningGate and declare its refreshPolicy. If it cannot, add it \
            to nonGatingCampaignProperties.
            """
        )
        XCTAssertEqual(
            classified.subtracting(properties),
            [],
            "A classified name no longer exists on Campaign — the classification is stale."
        )
    }

    /// Fields carried by a source refetched every cycle must not be pinned to a remembered
    /// answer, or a campaign extension could never land.
    func testTheCampaignWindowAndStatusAlwaysTakeTheNewestAnswer() {
        for gate in [CampaignMiningGate.status, .startDate, .endDate] {
            XCTAssertEqual(gate.refreshPolicy, .trustNewest, "\(gate.rawValue) must not be pinned")
        }
    }

    /// Everything else that gates mining must survive an omission.
    func testEveryOtherGateRefusesToRegress() {
        for gate in [CampaignMiningGate.drops, .isAccountConnected, .channels, .allowIsEnabled] {
            XCTAssertEqual(gate.refreshPolicy, .neverRegress, "\(gate.rawValue) must survive an omission")
        }
    }

    // MARK: The rule itself

    func testAFetchThatLosesEverythingIsFullyRepaired() {
        let stripped = campaign(drops: [], channels: [], isAccountConnected: false)

        let result = CampaignRefreshPolicy.reconcile(
            fetched: stripped,
            remembered: RememberedCampaignFacts(
                drops: [Drop(id: "d", name: "Charm", requiredMinutes: 60)],
                channels: acl,
                isAccountConnected: true,
                allowIsEnabled: true
            )
        )

        XCTAssertEqual(result.campaign.drops.map(\.name), ["Charm"])
        XCTAssertEqual(result.campaign.channels.map(\.login), ["algs1_team1"])
        XCTAssertTrue(result.campaign.isAccountConnected)
        XCTAssertEqual(result.campaign.allowIsEnabled, true)
        XCTAssertEqual(
            Set(result.repaired),
            [.drops, .channels, .isAccountConnected, .allowIsEnabled]
        )
    }

    /// A healthy refresh must pass through untouched and report no repair, or the log fills
    /// with noise and the real event stops standing out.
    func testAHealthyRefreshIsNotTouched() {
        let healthy = campaign(channels: acl, allowIsEnabled: true)

        let result = CampaignRefreshPolicy.reconcile(
            fetched: healthy,
            remembered: RememberedCampaignFacts(
                drops: healthy.drops,
                channels: healthy.channels,
                isAccountConnected: true,
                allowIsEnabled: true
            )
        )

        XCTAssertFalse(result.describesRepair)
        XCTAssertEqual(result.campaign.drops.map(\.name), ["Charm"])
        XCTAssertEqual(result.campaign.channels.map(\.login), ["algs1_team1"])
    }

    /// Restoring the restriction flag is what buys an esports campaign the short
    /// `restrictedCampaignDetailsCacheTTL` instead of the four-hour one — and it has to
    /// happen before the ACL rule, which reads that flag.
    func testARestoredRestrictionFlagLetsTheACLComeBackToo() {
        let stripped = campaign(channels: [], allowIsEnabled: nil)

        let result = CampaignRefreshPolicy.reconcile(
            fetched: stripped,
            remembered: RememberedCampaignFacts(channels: acl, allowIsEnabled: true)
        )

        XCTAssertTrue(result.campaign.hasChannelRestrictions)
        XCTAssertEqual(result.campaign.channels.map(\.login), ["algs1_team1"])
    }

    func testAPartialDropResponseKeepsEveryRememberedTier() {
        let pack = Drop(id: "pack", name: "APEX Pack", requiredMinutes: 15)
        let charm = Drop(id: "charm", name: "Sushi Nessie Gun Charm", requiredMinutes: 60)

        let result = CampaignRefreshPolicy.reconcile(
            fetched: campaign(drops: [pack]),
            remembered: RememberedCampaignFacts(drops: [pack, charm])
        )

        XCTAssertEqual(result.campaign.drops.map(\.id), ["pack", "charm"])
        XCTAssertEqual(result.repaired, [.drops])
    }

    func testAPartialACLKeepsEveryRememberedChannel() {
        let second = Channel(id: "2", login: "algs1_team2", displayName: "ALGS 2")

        let result = CampaignRefreshPolicy.reconcile(
            fetched: campaign(channels: [acl[0]], allowIsEnabled: true),
            remembered: RememberedCampaignFacts(channels: [acl[0], second], allowIsEnabled: true)
        )

        XCTAssertEqual(result.campaign.channels.map(\.login), ["algs1_team1", "algs1_team2"])
        XCTAssertEqual(result.repaired, [.channels])
    }

    /// A campaign that genuinely opened up must not be re-restricted to channels it no
    /// longer needs.
    func testAnUnrestrictedCampaignDoesNotGetAnOldACLBack() {
        let open = campaign(channels: [], allowIsEnabled: false)

        let result = CampaignRefreshPolicy.reconcile(
            fetched: open,
            remembered: RememberedCampaignFacts(channels: acl)
        )

        XCTAssertTrue(result.campaign.channels.isEmpty)
    }

    func testAnExplicitOpenAnswerDiscardsAContradictoryACL() {
        let contradictory = campaign(channels: acl, allowIsEnabled: false)

        let result = CampaignRefreshPolicy.reconcile(
            fetched: contradictory,
            remembered: RememberedCampaignFacts(channels: acl, allowIsEnabled: true)
        )

        XCTAssertTrue(result.campaign.channels.isEmpty)
        XCTAssertEqual(result.repaired, [.channels])
    }

    func testAMissingRestrictionFlagKeepsTheLastExplicitFalse() {
        let silent = campaign(channels: [], allowIsEnabled: nil)

        let result = CampaignRefreshPolicy.reconcile(
            fetched: silent,
            remembered: RememberedCampaignFacts(channels: acl, allowIsEnabled: false)
        )

        XCTAssertEqual(result.campaign.allowIsEnabled, false)
        XCTAssertTrue(result.campaign.channels.isEmpty)
        XCTAssertEqual(result.repaired, [.allowIsEnabled])
    }

    /// Nothing remembered means nothing to restore — a genuinely empty campaign stays empty.
    func testNothingRememberedChangesNothing() {
        let stripped = campaign(drops: [], isAccountConnected: false)

        let result = CampaignRefreshPolicy.reconcile(
            fetched: stripped,
            remembered: RememberedCampaignFacts()
        )

        XCTAssertFalse(result.describesRepair)
        XCTAssertTrue(result.campaign.drops.isEmpty)
        XCTAssertFalse(result.campaign.isAccountConnected)
    }

    /// A campaign whose window has closed has nothing left to defend.
    func testAnEndedCampaignIsLeftAlone() {
        let ended = campaign(drops: [], endDate: Date().addingTimeInterval(-60))

        let result = CampaignRefreshPolicy.reconcile(
            fetched: ended,
            remembered: RememberedCampaignFacts(drops: [Drop(id: "d", name: "Charm", requiredMinutes: 60)])
        )

        XCTAssertTrue(result.campaign.drops.isEmpty)
    }
}
