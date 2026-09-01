import XCTest
@testable import SwiftMiner
@testable import SwiftMinerCore

/// A link-blocked campaign whose drops are all claimed still needs the game
/// account linked — claiming on Twitch is not the publisher delivering the
/// reward in-game. The Pending list always listed those; the attention banner
/// and sidebar badge used to skip them, so the two disagreed.
@MainActor
final class AccountLinkDeliveryTests: XCTestCase {

    private let gameName = "Call of Duty: Modern Warfare 4"
    private let gameId = "cod-mw4"

    override func setUp() {
        super.setUp()
        // Both the banner and the Pending list only consider prioritised games.
        Settings.shared.gamePreferencesData = "[]"
        Settings.shared.addGamePreference(Game(id: gameId, name: gameName), state: .preferred)
    }

    override func tearDown() {
        Settings.shared.gamePreferencesData = "[]"
        super.tearDown()
    }

    // MARK: - Banner and badge

    func testFullyClaimedBlockerStillRaisesAttention() {
        let miner = makeMiner(campaigns: [campaign(claimed: true)])

        XCTAssertNotNil(
            MinerAttention.accountLinkReminderCampaign(for: miner, settings: .shared),
            "a claimed campaign still cannot deliver its rewards while unlinked"
        )
        XCTAssertTrue(MinerAttention.hasPendingAttention(for: miner, settings: .shared))
        XCTAssertNotNil(MinerAttentionIssue.resolve(miner: miner, events: []))
    }

    func testUnclaimedBlockerStillRaisesAttention() {
        let miner = makeMiner(campaigns: [campaign(claimed: false)])

        XCTAssertNotNil(MinerAttention.accountLinkReminderCampaign(for: miner, settings: .shared))
        XCTAssertTrue(MinerAttention.hasPendingAttention(for: miner, settings: .shared))
    }

    func testClaimedBlockerSaysDeliveryNotEarning() {
        let miner = makeMiner(campaigns: [campaign(claimed: true)])

        let attention = MinerAttentionIssue.resolve(miner: miner, events: [])

        XCTAssertEqual(attention?.title, "Link \(gameName) to Twitch")
        XCTAssertTrue(attention?.detail.contains("cannot be delivered") == true, attention?.detail ?? "")
        XCTAssertFalse(attention?.detail.contains("unclaimed drops") == true)
        XCTAssertEqual(attention?.action, .openTwitchDrops)
    }

    func testUnclaimedBlockerKeepsTheEarningWording() {
        let miner = makeMiner(campaigns: [campaign(claimed: false)])

        let attention = MinerAttentionIssue.resolve(miner: miner, events: [])

        XCTAssertTrue(attention?.detail.contains("unclaimed drops") == true, attention?.detail ?? "")
        XCTAssertFalse(attention?.detail.contains("cannot be delivered") == true)
    }

    /// Rewards still to earn are the more urgent of the two, so a miner with
    /// both must not be described by the weaker one.
    func testUnclaimedBlockerIsPreferredOverAClaimedOne() {
        let miner = makeMiner(campaigns: [
            campaign(id: "claimed", name: "Beta W1", claimed: true),
            campaign(id: "unclaimed", name: "Beta W2", claimed: false)
        ])

        XCTAssertEqual(
            MinerAttention.accountLinkReminderCampaign(for: miner, settings: .shared)?.id,
            "unclaimed"
        )
    }

    func testMutingStillSilencesAClaimedBlocker() {
        let miner = makeMiner(campaigns: [campaign(claimed: true)])
        Settings.shared.setIgnoreAccountLinkWarnings(true, for: miner.accountId, gameId: gameId)
        defer { Settings.shared.setIgnoreAccountLinkWarnings(false, for: miner.accountId, gameId: gameId) }

        XCTAssertNil(MinerAttention.accountLinkReminderCampaign(for: miner, settings: .shared))
        XCTAssertFalse(MinerAttention.hasPendingAttention(for: miner, settings: .shared))
    }

    /// A linked account has nothing to fix, claimed or not.
    func testConnectedAccountRaisesNothing() {
        let miner = makeMiner(campaigns: [campaign(claimed: true, connected: true)])

        XCTAssertNil(MinerAttention.accountLinkReminderCampaign(for: miner, settings: .shared))
    }

    // MARK: - Pending copy

    func testPendingRowSaysDeliveryWhenEverythingIsClaimed() {
        let item = PendingItem(kind: .accountLink(issue(awaitingDelivery: true)), isMuted: false)

        XCTAssertTrue(item.subtitle.contains("can’t reach the game"), item.subtitle)
        XCTAssertFalse(item.subtitle.contains("To earn"))
    }

    func testPendingRowSaysEarnWhenDropsRemain() {
        let item = PendingItem(kind: .accountLink(issue(awaitingDelivery: false)), isMuted: false)

        XCTAssertTrue(item.subtitle.contains("To earn"), item.subtitle)
        XCTAssertFalse(item.subtitle.contains("can’t reach the game"))
    }

    /// Mute wording wins over both — the row explains why it is silent.
    func testMutedPendingRowKeepsTheMutedWording() {
        for awaitingDelivery in [true, false] {
            let item = PendingItem(kind: .accountLink(issue(awaitingDelivery: awaitingDelivery)), isMuted: true)
            XCTAssertTrue(item.subtitle.hasPrefix("Reminder muted."), item.subtitle)
        }
    }

    // MARK: - Fixtures

    private func issue(awaitingDelivery: Bool) -> PrioritisedLinkIssue {
        PrioritisedLinkIssue(
            minerId: "miner-1",
            accountId: "account-1",
            minerName: "ruffcrumble",
            gameId: gameId,
            gameName: gameName,
            campaignNames: ["Modern Warfare 4 Beta W2"],
            isIgnored: false,
            awaitingDelivery: awaitingDelivery
        )
    }

    private func campaign(
        id: String = "campaign-1",
        name: String = "Modern Warfare 4 Beta W2",
        claimed: Bool,
        connected: Bool = false
    ) -> Campaign {
        Campaign(
            id: id,
            name: name,
            game: Game(id: gameId, name: gameName),
            status: .active,
            startDate: Date().addingTimeInterval(-3600),
            endDate: Date().addingTimeInterval(3600),
            drops: [Drop(id: "\(id)-drop", name: "Reward", requiredMinutes: 60, isClaimed: claimed)],
            isAccountConnected: connected
        )
    }

    private func makeMiner(campaigns: [Campaign]) -> MinerManager.ManagedMiner {
        MinerManager.ManagedMiner(
            id: "miner-1",
            accountId: "account-1",
            username: "ruffcrumble",
            status: .watching,
            allCampaigns: campaigns,
            isRunning: true
        )
    }
}
