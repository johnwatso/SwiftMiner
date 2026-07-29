import Testing
import Foundation
@testable import SwiftMinerCore
@testable import SwiftMiner

/// Characterises how a miner describes itself across every state surface, and pins the one
/// property that has broken repeatedly: **they must never contradict each other.**
///
/// A miner's state is currently derived four different ways — `MinerStatus` on the manager,
/// `MinerGameState` per prioritised game, `PrimaryState` resolved from those, and
/// `MinerActivitySnapshot` recomputed independently in the UI. Nothing forced them to agree, and
/// they didn't: a miner waiting for a stream showed "Looking for Streams" on its card while
/// `statusLabel` simultaneously reported "Drops complete". That bug was fixed twice at two
/// different layers before it held.
///
/// This suite exists so the state model can be consolidated without changing behaviour. It
/// asserts agreement rather than exact strings wherever possible, so a refactor that renames a
/// label stays green while a refactor that reintroduces a contradiction fails.
@Suite("Miner state consistency")
@MainActor
struct MinerStateConsistencyTests {

    // MARK: - Fixtures

    private static func drop(id: String, isClaimed: Bool = false, requiredSubs: Int = 0) -> Drop {
        Drop(id: id, name: "Drop \(id)", requiredMinutes: 60, isClaimed: isClaimed, requiredSubs: requiredSubs)
    }

    private static func campaign(
        id: String,
        gameId: String = "game-1",
        gameName: String = "Test Game",
        isAccountConnected: Bool = true,
        drops: [Drop]
    ) -> Campaign {
        let now = Date()
        return Campaign(
            id: id,
            name: "Campaign \(id)",
            game: Game(id: gameId, name: gameName),
            startDate: now.addingTimeInterval(-3600),
            endDate: now.addingTimeInterval(3600),
            drops: drops,
            isAccountConnected: isAccountConnected
        )
    }

    private static func miner(
        status: MinerManager.MinerStatus,
        campaigns: [Campaign],
        currentCampaignId: String?,
        priorityGames: [String],
        availability: [String: GameChannelAvailability] = [:]
    ) -> MinerManager.ManagedMiner {
        MinerManager.ManagedMiner(
            id: "miner-1",
            accountId: "account-1",
            username: "tester",
            status: status,
            currentCampaignId: currentCampaignId,
            allCampaigns: campaigns,
            gameChannelAvailability: availability,
            isRunning: true,
            priorityGames: priorityGames
        )
    }

    private static func snapshot(for miner: MinerManager.ManagedMiner) -> MinerActivitySnapshot {
        MinerActivitySnapshot.resolve(
            for: miner,
            priorityGames: miner.priorityGames,
            excludedGames: [],
            strategy: .prioritiseSelected,
            includesBadgeAndEmoteCampaigns: false
        )
    }

    /// Phrases that assert the miner has nothing left to do.
    private static let completionPhrases = ["Drops complete", "Up to Date", "No eligible campaigns"]

    private static func claimsCompletion(_ label: String) -> Bool {
        completionPhrases.contains { label.localizedCaseInsensitiveContains($0) }
    }

    private static func claimsActiveWork(_ label: String) -> Bool {
        ["Looking for Streams", "Waiting", "Watching", "Currently mining"]
            .contains { label.localizedCaseInsensitiveContains($0) }
    }

    // MARK: - The invariant

    /// The core property. Whatever the surfaces say, they may not simultaneously claim the miner
    /// is finished and that it is actively working. This is the exact contradiction that shipped.
    @Test(
        "Status label and activity card never contradict",
        arguments: [
            MinerManager.MinerStatus.idle,
            .watching,
            .claiming,
            .waitingForStream,
            .fetchingCampaigns,
            .idleNoEligibleCampaigns,
            .blockedAccountNotLinked
        ]
    )
    func labelAndCardAgree(status: MinerManager.MinerStatus) {
        let work = Self.campaign(id: "work", drops: [Self.drop(id: "d1")])
        let miner = Self.miner(
            status: status,
            campaigns: [work],
            currentCampaignId: "work",
            priorityGames: ["Test Game"]
        )

        let label = miner.statusLabel
        let card = Self.snapshot(for: miner).statusText

        #expect(
            !(Self.claimsCompletion(label) && Self.claimsActiveWork(card)),
            "statusLabel '\(label)' says finished while the card '\(card)' says working (status: \(status.rawValue))"
        )
        #expect(
            !(Self.claimsActiveWork(label) && Self.claimsCompletion(card)),
            "statusLabel '\(label)' says working while the card '\(card)' says finished (status: \(status.rawValue))"
        )
    }

    /// The regression that took three attempts to fix. The no-channel path clears the watch
    /// target before waiting, so every surface has to describe the wait without one.
    @Test("Waiting for a stream is never reported as finished", arguments: [true, false])
    func waitingIsNeverReportedFinished(targetCleared: Bool) {
        // Prioritised game is finished; the scheduler is waiting on a different game.
        let gated = Self.campaign(
            id: "gated",
            gameId: "finals",
            gameName: "THE FINALS",
            drops: [Self.drop(id: "sub", requiredSubs: 1)]
        )
        let waitingOn = Self.campaign(
            id: "esports",
            gameId: "brawlhalla",
            gameName: "Brawlhalla",
            drops: [Self.drop(id: "d1")]
        )
        let miner = Self.miner(
            status: .waitingForStream,
            campaigns: [gated, waitingOn],
            currentCampaignId: targetCleared ? nil : "esports",
            priorityGames: ["THE FINALS"],
            availability: [
                "brawlhalla": GameChannelAvailability(
                    gameKey: "brawlhalla",
                    hasEligibleChannel: false,
                    campaignId: "esports",
                    checkedAt: Date()
                )
            ]
        )

        #expect(
            !Self.claimsCompletion(miner.statusLabel),
            "A miner waiting on Brawlhalla reported '\(miner.statusLabel)' (targetCleared: \(targetCleared))"
        )
        #expect(miner.resolvedPrimaryState?.resolved?.gameName == "Brawlhalla")
    }

    /// A miner with genuinely nothing left must say so consistently — the inverse failure,
    /// where a finished miner claims to be working, is equally wrong.
    @Test("A fully claimed miner reports completion on every surface")
    func finishedMinerAgrees() {
        let done = Self.campaign(id: "done", drops: [Self.drop(id: "d1", isClaimed: true)])
        let miner = Self.miner(
            status: .idle,
            campaigns: [done],
            currentCampaignId: nil,
            priorityGames: ["Test Game"]
        )

        #expect(PrimaryStateResolver.resolve(for: miner) == .completed)
        #expect(Self.claimsCompletion(miner.statusLabel))
        #expect(Self.claimsCompletion(Self.snapshot(for: miner).statusText))
    }

    /// Operational states outrank campaign bookkeeping everywhere. A stalled or stopped miner
    /// that reports "Up to Date" hides a real fault.
    @Test(
        "Operational faults outrank campaign state",
        arguments: [
            (stalled: true, running: true),
            (stalled: false, running: false)
        ]
    )
    func operationalFaultsWin(stalled: Bool, running: Bool) {
        let done = Self.campaign(id: "done", drops: [Self.drop(id: "d1", isClaimed: true)])
        let miner = MinerManager.ManagedMiner(
            id: "miner-1",
            accountId: "account-1",
            username: "tester",
            status: .idle,
            currentCampaignId: nil,
            allCampaigns: [done],
            isRunning: running,
            priorityGames: ["Test Game"],
            workerState: .running,
            isStalled: stalled
        )

        #expect(
            !Self.claimsCompletion(miner.statusLabel),
            "An unhealthy miner reported '\(miner.statusLabel)', hiding the fault"
        )
    }

    /// Subscription-gated campaigns count as finished work and must never present as the
    /// miner's current activity — they are surfaced separately as a mutable Pending item.
    @Test("Subscription-gated campaigns are never the current activity")
    func gatedCampaignsAreNotCurrentActivity() {
        let gated = Self.campaign(
            id: "gated",
            gameId: "finals",
            gameName: "THE FINALS",
            drops: [Self.drop(id: "sub", requiredSubs: 1)]
        )
        let miner = Self.miner(
            status: .waitingForStream,
            campaigns: [gated],
            currentCampaignId: nil,
            priorityGames: ["THE FINALS"]
        )

        let card = Self.snapshot(for: miner)
        #expect(!card.now.id.hasPrefix("subscription-"))
        #expect(!card.statusText.localizedCaseInsensitiveContains("Subscription Required"))
    }
}
