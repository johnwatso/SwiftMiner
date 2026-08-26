import XCTest
@testable import SwiftMinerCore
@testable import SwiftMiner
import SwiftMinerService

@MainActor
final class MinerActivitySnapshotTests: XCTestCase {

    func testLiveActivityTimerFormatsShortAndLongSessions() {
        XCTAssertEqual(MinerLiveActivityTimerView.formatElapsed(0), "00:00")
        XCTAssertEqual(MinerLiveActivityTimerView.formatElapsed(65), "01:05")
        XCTAssertEqual(MinerLiveActivityTimerView.formatElapsed(3_661), "1:01:01")
    }

    func testGlobalPriorityToggleOnlyAppearsForMultipleMiners() {
        XCTAssertFalse(MinersOverviewView.shouldShowGlobalPriorityToggle(minerCount: 0))
        XCTAssertFalse(MinersOverviewView.shouldShowGlobalPriorityToggle(minerCount: 1))
        XCTAssertTrue(MinersOverviewView.shouldShowGlobalPriorityToggle(minerCount: 2))
    }

    func testOperatorProgressAddsMinutesAcrossEveryTimedDrop() {
        let firstProgress = Progress(
            dropId: "drop-1",
            campaignId: "campaign",
            currentMinutes: 60,
            requiredMinutes: 60,
            isClaimed: true
        )
        let secondProgress = Progress(
            dropId: "drop-2",
            campaignId: "campaign",
            currentMinutes: 30,
            requiredMinutes: 90
        )
        let campaign = makeCampaign(
            id: "campaign",
            isAccountConnected: true,
            drops: [
                Drop(id: "drop-1", name: "First", requiredMinutes: 60, progress: firstProgress, isClaimed: true),
                Drop(id: "drop-2", name: "Second", requiredMinutes: 90, progress: secondProgress),
            ]
        )
        let miner = makeMiner(
            status: .watching,
            campaigns: [campaign],
            currentCampaignId: campaign.id
        )

        let progress = MinerOperatorPresentation.aggregateProgress(for: campaign, miner: miner)

        XCTAssertEqual(progress?.currentMinutes, 90)
        XCTAssertEqual(progress?.requiredMinutes, 150)
        XCTAssertEqual(progress?.fraction ?? -1, 0.6, accuracy: 0.0001)
    }

    func testOperatorQueuePinsCurrentAndResolvedNextAheadOfRemainingCampaigns() {
        let current = makeCampaign(id: "current", gameId: "current-game", gameName: "Current", isAccountConnected: true)
        let next = makeCampaign(id: "next", gameId: "next-game", gameName: "Next", isAccountConnected: true)
        let later = makeCampaign(id: "later", gameId: "later-game", gameName: "Later", isAccountConnected: true)
        let miner = makeMiner(
            status: .watching,
            campaigns: [later, next, current],
            currentCampaignId: current.id,
            priorityGames: ["Current", "Next", "Later"]
        )

        let presentation = MinerOperatorPresentation.resolve(
            for: miner,
            priorityGames: ["Current", "Next", "Later"],
            excludedGames: [],
            strategy: .onlyPriority,
            includesBadgeAndEmoteCampaigns: false
        )

        XCTAssertEqual(presentation.snapshot.upNext?.campaignId, next.id)
        XCTAssertEqual(presentation.queue.map(\.campaign.id), [current.id, next.id, later.id])
        XCTAssertEqual(presentation.thenCampaigns.map(\.id), [later.id])
    }

    func testOperatorQueueIncludesPrioritisedUnlinkedCampaignsTheMinerCanSchedule() {
        let prioritised = makeCampaign(
            id: "priority",
            gameId: "priority-game",
            gameName: "Priority Game",
            isAccountConnected: false
        )
        let unrelatedUnlinked = makeCampaign(
            id: "unrelated-unlinked",
            gameId: "other-game",
            gameName: "Other Game",
            isAccountConnected: false
        )
        let linkedSmartCandidate = makeCampaign(
            id: "linked-candidate",
            gameId: "linked-game",
            gameName: "Linked Game",
            isAccountConnected: true
        )
        let miner = makeMiner(
            campaigns: [unrelatedUnlinked, linkedSmartCandidate, prioritised],
            priorityGames: ["Priority Game"]
        )

        let presentation = MinerOperatorPresentation.resolve(
            for: miner,
            priorityGames: ["Priority Game"],
            excludedGames: [],
            strategy: .mineAll,
            includesBadgeAndEmoteCampaigns: false
        )

        XCTAssertTrue(presentation.queue.contains { $0.campaign.id == prioritised.id })
        XCTAssertTrue(presentation.queue.contains { $0.campaign.id == linkedSmartCandidate.id })
        XCTAssertFalse(presentation.queue.contains { $0.campaign.id == unrelatedUnlinked.id })
        XCTAssertEqual(
            presentation.queue.first { $0.campaign.id == prioritised.id }?.status,
            .waitingForStream
        )
        XCTAssertEqual(presentation.snapshot.blockedPriority.map(\.campaignId), [prioritised.id])
    }

    /// A missing game-account link never blocks mining — `canAttemptMining` leaves
    /// linkage out on purpose — so the queue keeps the campaign's real scheduling
    /// status and carries the link as a separate advisory flag.
    func testUnlinkedQueueEntryKeepsSchedulingStatusAndFlagsTheLinkSeparately() {
        let unlinked = makeCampaign(
            id: "unlinked-priority",
            gameId: "priority-game",
            gameName: "Priority Game",
            isAccountConnected: false
        )
        let linked = makeCampaign(
            id: "linked",
            gameId: "linked-game",
            gameName: "Linked Game",
            isAccountConnected: true
        )
        let miner = makeMiner(
            campaigns: [unlinked, linked],
            priorityGames: ["Priority Game"]
        )

        let presentation = MinerOperatorPresentation.resolve(
            for: miner,
            priorityGames: ["Priority Game"],
            excludedGames: [],
            strategy: .mineAll,
            includesBadgeAndEmoteCampaigns: false
        )

        let unlinkedEntry = presentation.queue.first { $0.campaign.id == unlinked.id }
        XCTAssertEqual(unlinkedEntry?.status, .waitingForStream)
        XCTAssertEqual(unlinkedEntry?.requiresAccountLink, true)

        let linkedEntry = presentation.queue.first { $0.campaign.id == linked.id }
        XCTAssertEqual(linkedEntry?.status, .waitingForStream)
        XCTAssertEqual(linkedEntry?.requiresAccountLink, false)
    }

    func testSummaryAndQueueShareTheResolvedCampaignDecisionOrder() {
        let halo = makeCampaign(
            id: "halo",
            gameId: "halo",
            gameName: "Halo Infinite",
            isAccountConnected: true
        )
        let battlefield = makeCampaign(
            id: "battlefield",
            gameId: "battlefield",
            gameName: "Battlefield 6",
            isAccountConnected: false
        )
        let finals = makeCampaign(
            id: "finals",
            gameId: "finals",
            gameName: "THE FINALS",
            isAccountConnected: true
        )
        let miner = makeMiner(
            status: .watching,
            campaigns: [finals, battlefield, halo],
            currentCampaignId: halo.id,
            priorityGames: ["Halo Infinite", "Battlefield 6", "THE FINALS"]
        )

        let presentation = MinerOperatorPresentation.resolve(
            for: miner,
            priorityGames: miner.priorityGames,
            excludedGames: [],
            strategy: .prioritiseSelected,
            includesBadgeAndEmoteCampaigns: false
        )

        XCTAssertEqual(presentation.snapshot.upNext?.campaignId, battlefield.id)
        XCTAssertEqual(presentation.thenCampaigns.map(\.id), [finals.id])
        XCTAssertEqual(presentation.queue.map(\.campaign.id), [halo.id, battlefield.id, finals.id])
        XCTAssertEqual(presentation.queue.map(\.status), [.watching, .waitingForStream, .waitingForStream])
    }

    func testUpNextAndQueueExcludeEndedOrClaimableCampaigns() {
        let now = Date()
        let ended = makeCampaign(
            id: "ended",
            gameId: "ended-game",
            gameName: "Ended Game",
            isAccountConnected: true,
            endDate: now.addingTimeInterval(-60)
        )
        let claimableProgress = Progress(
            dropId: "claimable-drop",
            campaignId: "claimable",
            currentMinutes: 60,
            requiredMinutes: 60
        )
        let claimable = makeCampaign(
            id: "claimable",
            gameId: "claimable-game",
            gameName: "Claimable Game",
            isAccountConnected: true,
            drops: [Drop(
                id: "claimable-drop",
                name: "Claimable Drop",
                requiredMinutes: 60,
                progress: claimableProgress
            )]
        )
        let miner = makeMiner(
            campaigns: [ended, claimable],
            priorityGames: ["Ended Game", "Claimable Game"]
        )

        let presentation = MinerOperatorPresentation.resolve(
            for: miner,
            priorityGames: miner.priorityGames,
            excludedGames: [],
            strategy: .onlyPriority,
            includesBadgeAndEmoteCampaigns: false
        )

        XCTAssertNil(presentation.snapshot.upNext)
        XCTAssertTrue(presentation.queue.isEmpty)
        XCTAssertTrue(presentation.thenCampaigns.isEmpty)
    }

    func testOperatorQueueCarriesRealChannelProbeInsteadOfAssumingNoLiveChannels() throws {
        let campaign = makeCampaign(id: "checked", isAccountConnected: true)
        let sameGameCampaign = makeCampaign(id: "unchecked", isAccountConnected: true)
        let checkedAt = Date().addingTimeInterval(-60)
        let availability = GameChannelAvailability(
            gameKey: "test game",
            hasEligibleChannel: true,
            campaignId: campaign.id,
            channelName: "DropStreamer",
            checkedAt: checkedAt
        )
        let miner = makeMiner(
            campaigns: [campaign, sameGameCampaign],
            gameChannelAvailability: ["test game": availability]
        )

        let presentation = MinerOperatorPresentation.resolve(
            for: miner,
            priorityGames: ["Test Game"],
            excludedGames: [],
            strategy: .prioritiseSelected,
            includesBadgeAndEmoteCampaigns: false
        )

        let entry = try XCTUnwrap(presentation.queue.first { $0.campaign.id == campaign.id })
        XCTAssertEqual(entry.channelAvailability, availability)
        XCTAssertTrue(entry.channelAvailability?.isFresh(at: checkedAt) ?? false)
        XCTAssertNil(
            presentation.queue.first { $0.campaign.id == sameGameCampaign.id }?.channelAvailability,
            "A channel verified for one campaign must not be reported as eligible for every campaign in the game"
        )
    }

    func testSmartUpNextExplainsWhyEarlierCampaignPrecedesPrioritisedGame() {
        let now = Date()
        let brawlhalla = makeCampaign(
            id: "brawlhalla",
            gameId: "brawlhalla-id",
            gameName: "Brawlhalla",
            isAccountConnected: true,
            endDate: now.addingTimeInterval(60 * 60)
        )
        let battlefield = makeCampaign(
            id: "battlefield",
            gameId: "battlefield-id",
            gameName: "Battlefield 6",
            isAccountConnected: true,
            endDate: now.addingTimeInterval(2 * 60 * 60)
        )
        let miner = makeMiner(
            campaigns: [battlefield, brawlhalla],
            priorityGames: ["Battlefield 6"]
        )

        let snapshot = MinerActivitySnapshot.resolve(
            for: miner,
            priorityGames: ["Battlefield 6"],
            excludedGames: [],
            strategy: .mineAll,
            includesBadgeAndEmoteCampaigns: false
        )

        XCTAssertEqual(snapshot.upNext?.campaignId, brawlhalla.id)
        XCTAssertEqual(
            snapshot.upNext?.detail,
            "Ends before prioritised Battlefield 6 · Smart strategy"
        )
    }

    private func makeMiner(
        status: MinerManager.MinerStatus = .idle,
        campaigns: [Campaign],
        currentCampaignId: String? = nil,
        priorityGames: [String] = ["Test Game"],
        gameChannelAvailability: [String: GameChannelAvailability] = [:],
        workerState: MinerWorkerState = .running,
        isRunning: Bool = true,
        isHealthy: Bool = true,
        isStalled: Bool = false
    ) -> MinerManager.ManagedMiner {
        MinerManager.ManagedMiner(
            id: "miner-1",
            accountId: "account-1",
            username: "tester",
            status: status,
            currentCampaignId: currentCampaignId,
            allCampaigns: campaigns,
            gameChannelAvailability: gameChannelAvailability,
            isRunning: isRunning,
            priorityGames: priorityGames,
            workerState: workerState,
            isHealthy: isHealthy,
            isStalled: isStalled
        )
    }

    private func makeCampaign(
        id: String,
        gameId: String = "game-1",
        gameName: String = "Test Game",
        isAccountConnected: Bool,
        drops: [Drop] = [Drop(id: "drop-1", name: "Drop 1", requiredMinutes: 60)],
        endDate: Date? = nil,
        boxArtURL: URL? = nil
    ) -> Campaign {
        let now = Date()
        return Campaign(
            id: id,
            name: "Campaign \(id)",
            game: Game(id: gameId, name: gameName, boxArtURL: boxArtURL),
            startDate: now.addingTimeInterval(-3600),
            endDate: endDate ?? now.addingTimeInterval(3600),
            drops: drops,
            isAccountConnected: isAccountConnected
        )
    }

    private func resolveSnapshot(for miner: MinerManager.ManagedMiner) -> MinerActivitySnapshot {
        MinerActivitySnapshot.resolve(
            for: miner,
            priorityGames: ["Test Game"],
            excludedGames: [],
            strategy: .prioritiseSelected,
            includesBadgeAndEmoteCampaigns: false
        )
    }

    /// Pins the trap that hid the link warning for the campaign being mined.
    /// `activityStatus` is single-valued and resolves the miner's current campaign
    /// to `.watching` before it reaches the link check, so `== .requiresLink` is not
    /// a safe test for "this game needs linking" — Pending and the sidebar/Dock badge
    /// must ask `isAccountConnected` directly.
    func testActivityStatusHidesTheLinkRequirementForTheCampaignBeingWatched() {
        let campaign = makeCampaign(id: "unlinked", isAccountConnected: false)
        let watching = makeMiner(
            status: .watching,
            campaigns: [campaign],
            currentCampaignId: campaign.id
        )
        let queued = makeMiner(status: .waitingForStream, campaigns: [campaign])

        XCTAssertEqual(campaign.activityStatus(for: watching), .watching)
        XCTAssertEqual(campaign.activityStatus(for: queued), .requiresLink)

        // The underlying fact is unchanged in both cases, which is why the warning
        // surfaces filter on this instead.
        XCTAssertFalse(campaign.isAccountConnected)
    }

    func testCurrentUnlinkedPrioritisedCampaignIsNotRepeatedAsUpNext() {
        let campaign = makeCampaign(id: "unlinked", isAccountConnected: false)
        let miner = makeMiner(campaigns: [campaign], currentCampaignId: campaign.id)

        let snapshot = resolveSnapshot(for: miner)

        XCTAssertEqual(campaign.activityStatus(for: miner), .requiresLink)
        XCTAssertNil(snapshot.upNext)
        XCTAssertEqual(snapshot.blockedPriority.map(\.campaignId), ["unlinked"])
        XCTAssertTrue(snapshot.blockedPriority.first?.requiresAccountLink ?? false)
        XCTAssertFalse(snapshot.isActivelyWatching)
        XCTAssertEqual(snapshot.currentSectionTitle, "Current status")
        XCTAssertEqual(snapshot.sourceListActivityLabel, "Up to Date")
    }

    func testUpNextShowsUnlinkedPrioritisedCampaignWithLinkRequirement() {
        let campaign = makeCampaign(id: "unlinked", isAccountConnected: false)
        let miner = makeMiner(campaigns: [campaign])

        let snapshot = resolveSnapshot(for: miner)

        XCTAssertEqual(snapshot.upNext?.campaignId, campaign.id)
        XCTAssertTrue(snapshot.upNext?.requiresAccountLink ?? false)
        XCTAssertEqual(snapshot.blockedPriority.map(\.campaignId), [campaign.id])
    }

    func testUpNextRetainsArtworkForUnlinkedPrioritisedCampaign() {
        let artworkURL = URL(string: "https://example.com/black-ops-7-600x800.jpg")!
        let campaign = makeCampaign(
            id: "unlinked",
            isAccountConnected: false,
            boxArtURL: artworkURL
        )
        let miner = makeMiner(campaigns: [campaign])

        let presentation = MinerOperatorPresentation.resolve(
            for: miner,
            priorityGames: ["Test Game"],
            excludedGames: [],
            strategy: .prioritiseSelected,
            includesBadgeAndEmoteCampaigns: false
        )

        XCTAssertEqual(presentation.queue.map(\.campaign.id), [campaign.id])
        XCTAssertEqual(presentation.snapshot.upNext?.campaignId, campaign.id)
        XCTAssertEqual(presentation.nextCampaign?.game.boxArtURL, artworkURL)
    }

    func testHealthyStatusPresentationIsCompactAndKeepsAllSignals() {
        let campaign = makeCampaign(id: "active", isAccountConnected: true)
        var miner = makeMiner(
            status: .watching,
            campaigns: [campaign],
            currentCampaignId: campaign.id
        )
        miner.lastEventAt = Date().addingTimeInterval(-14)
        miner.lastCampaignRefreshAt = Date().addingTimeInterval(-29)
        miner.lastSuccessfulPollAt = Date().addingTimeInterval(-32)
        let snapshot = MinerHealthSnapshot.make(miner: miner)

        let presentation = MinerRecoveryDiagnosticsPresentation.make(
            miner: miner,
            snapshot: snapshot
        )

        XCTAssertTrue(presentation.isCompact)
        XCTAssertEqual(presentation.title, "Healthy")
        XCTAssertEqual(presentation.badge, "Healthy")
        XCTAssertEqual(presentation.signals.map(\.title), ["Twitch", "Campaigns", "Drop progress"])
        XCTAssertEqual(presentation.signals.map(\.value), ["Connected", "Current", "Tracking"])
        XCTAssertEqual(presentation.signals.map(\.symbol), ["network", "shippingbox.fill", "chart.line.uptrend.xyaxis"])
        XCTAssertEqual(presentation.signals.map(\.dateLabel), ["Last activity", "Updated", "Last checked"])
        XCTAssertTrue(presentation.signals.allSatisfy { $0.tone == .healthy })
    }

    func testActionRequiredStatusPresentationRemainsExpanded() {
        let miner = makeMiner(
            status: .error,
            campaigns: [],
            priorityGames: []
        )
        let snapshot = MinerHealthSnapshot.make(miner: miner)

        let presentation = MinerRecoveryDiagnosticsPresentation.make(
            miner: miner,
            snapshot: snapshot
        )

        XCTAssertFalse(presentation.isCompact)
        XCTAssertEqual(presentation.badge, "Blocked")
        XCTAssertEqual(presentation.tone, .critical)
    }

    func testDegradedSignalKeepsStatusPresentationExpanded() {
        let campaign = makeCampaign(id: "active", isAccountConnected: true)
        let miner = makeMiner(
            status: .watching,
            campaigns: [campaign],
            currentCampaignId: campaign.id
        )
        let snapshot = MinerHealthSnapshot.make(miner: miner)

        let presentation = MinerRecoveryDiagnosticsPresentation.make(
            miner: miner,
            snapshot: snapshot
        )

        XCTAssertFalse(presentation.isCompact)
        XCTAssertEqual(
            presentation.signals.first { $0.id == "inventory" }?.tone,
            .warning
        )
    }

    func testPrioritisedUnlinkedCampaignOnlyAppearsAsMiningAfterActualWatchStarts() {
        let campaign = makeCampaign(id: "unlinked", isAccountConnected: false)
        let miner = makeMiner(
            status: .watching,
            campaigns: [campaign],
            currentCampaignId: campaign.id
        )

        let presentation = MinerOperatorPresentation.resolve(
            for: miner,
            priorityGames: ["Test Game"],
            excludedGames: [],
            strategy: .prioritiseSelected,
            includesBadgeAndEmoteCampaigns: false
        )

        XCTAssertEqual(presentation.snapshot.now.id, "now-unlinked")
        XCTAssertTrue(presentation.snapshot.isActivelyWatching)
        XCTAssertEqual(presentation.snapshot.currentSectionTitle, "Currently mining")
        XCTAssertEqual(presentation.snapshot.sourceListActivityLabel, "Watching Test Game")
        XCTAssertNil(presentation.snapshot.upNext)
        XCTAssertEqual(presentation.snapshot.blockedPriority.map(\.campaignId), [campaign.id])
        XCTAssertEqual(presentation.queue.map(\.campaign.id), [campaign.id])
        XCTAssertEqual(presentation.queue.first?.status, .watching)
    }

    func testUpNextHidesUnlinkedNonPrioritisedCampaign() {
        // An unlinked campaign whose game is NOT prioritised for this miner must not
        // surface — otherwise another miner's prioritised game leaks in here.
        let campaign = makeCampaign(id: "unlinked-other", gameId: "game-2", gameName: "Other Game", isAccountConnected: false)
        let miner = makeMiner(campaigns: [campaign], priorityGames: ["Test Game"])

        let snapshot = resolveSnapshot(for: miner)

        XCTAssertNil(snapshot.upNext)
    }

    func testUpNextShowsLinkedEligibleCampaign() {
        let campaign = makeCampaign(id: "linked", isAccountConnected: true)
        let miner = makeMiner(campaigns: [campaign])

        let snapshot = resolveSnapshot(for: miner)

        XCTAssertEqual(snapshot.upNext?.campaignId, "linked")
        XCTAssertFalse(snapshot.upNext?.requiresAccountLink ?? true)
    }

    func testNewIdleAndBlockedStatusesSurfaceInSnapshot() {
        let idleMiner = makeMiner(
            status: .idleNoEligibleCampaigns,
            campaigns: [],
            priorityGames: []
        )
        let blockedMiner = makeMiner(
            status: .blockedAccountNotLinked,
            campaigns: [],
            priorityGames: []
        )

        let idleSnapshot = resolveSnapshot(for: idleMiner)
        let blockedSnapshot = resolveSnapshot(for: blockedMiner)

        XCTAssertEqual(idleSnapshot.statusText, "Up to Date")
        XCTAssertEqual(idleSnapshot.now.title, "Up to Date")
        XCTAssertNil(idleSnapshot.upNext)

        XCTAssertEqual(blockedSnapshot.statusText, "Up to Date")
        XCTAssertEqual(blockedSnapshot.now.title, "Priority game ready")
        XCTAssertNil(blockedSnapshot.upNext)
    }

    func testStoppedMinerIsNeverPresentedAsUpToDate() {
        let miner = makeMiner(
            status: .idleNoEligibleCampaigns,
            campaigns: [],
            priorityGames: [],
            workerState: .idle,
            isRunning: false
        )

        let snapshot = resolveSnapshot(for: miner)

        XCTAssertEqual(miner.statusLabel, "Stopped")
        XCTAssertEqual(snapshot.statusText, "Stopped")
        XCTAssertEqual(snapshot.now.title, "Stopped")
        XCTAssertEqual(snapshot.now.subtitle, "Start this miner to check for and earn drops.")
    }

    func testPendingMinerStartupIsPresentedAsStarting() {
        let miner = makeMiner(
            status: .authenticating,
            campaigns: [],
            priorityGames: [],
            workerState: .idle,
            isRunning: false
        )

        let snapshot = resolveSnapshot(for: miner)

        XCTAssertEqual(miner.statusLabel, "Starting...")
        XCTAssertEqual(snapshot.statusText, "Starting...")
        XCTAssertEqual(snapshot.now.title, "Starting...")
    }

    func testDismissedLinkReminderStillShowsPrioritisedCampaignUpNext() {
        let campaign = makeCampaign(id: "unlinked", isAccountConnected: false)
        let miner = makeMiner(status: .blockedAccountNotLinked, campaigns: [campaign])

        let snapshot = MinerActivitySnapshot.resolve(
            for: miner,
            priorityGames: ["Test Game"],
            excludedGames: [],
            strategy: .prioritiseSelected,
            includesBadgeAndEmoteCampaigns: false,
            ignoredAccountLinkGameIds: ["game-1"]
        )

        XCTAssertEqual(snapshot.statusText, "Up to Date")
        XCTAssertEqual(snapshot.now.title, "Priority game ready")
        XCTAssertEqual(snapshot.upNext?.campaignId, campaign.id)
        XCTAssertTrue(snapshot.blockedPriority.isEmpty)
    }

    func testClaimedPriorityGameWaitsForDropsInsteadOfSayingComplete() {
        let claimedProgress = Progress(
            dropId: "drop-1",
            campaignId: "claimed",
            currentMinutes: 60,
            requiredMinutes: 60,
            isClaimed: true
        )
        let claimedDrop = Drop(
            id: "drop-1",
            name: "Buoy",
            requiredMinutes: 60,
            progress: claimedProgress,
            isClaimed: true
        )
        let campaign = makeCampaign(
            id: "claimed",
            gameName: "ARC Raiders",
            isAccountConnected: true,
            drops: [claimedDrop]
        )
        let miner = makeMiner(
            campaigns: [campaign],
            priorityGames: ["ARC Raiders"]
        )

        let snapshot = MinerActivitySnapshot.resolve(
            for: miner,
            priorityGames: ["ARC Raiders"],
            excludedGames: [],
            strategy: .prioritiseSelected,
            includesBadgeAndEmoteCampaigns: false
        )

        XCTAssertEqual(snapshot.statusText, "Up to Date")
        XCTAssertEqual(snapshot.now.title, "Up to Date")
        XCTAssertEqual(snapshot.now.subtitle, "No active drops are available for this account.")
    }

    func testWatchingClaimedCurrentCampaignDoesNotShowAsMining() {
        let claimedProgress = Progress(
            dropId: "drop-1",
            campaignId: "claimed",
            currentMinutes: 60,
            requiredMinutes: 60,
            isClaimed: true
        )
        let claimedDrop = Drop(
            id: "drop-1",
            name: "Buoy",
            requiredMinutes: 60,
            progress: claimedProgress,
            isClaimed: true
        )
        let campaign = makeCampaign(
            id: "claimed",
            gameName: "ARC Raiders",
            isAccountConnected: true,
            drops: [claimedDrop]
        )
        let miner = makeMiner(
            status: .watching,
            campaigns: [campaign],
            currentCampaignId: "claimed",
            priorityGames: ["ARC Raiders"]
        )

        let snapshot = MinerActivitySnapshot.resolve(
            for: miner,
            priorityGames: ["ARC Raiders"],
            excludedGames: [],
            strategy: .prioritiseSelected,
            includesBadgeAndEmoteCampaigns: false
        )

        XCTAssertEqual(snapshot.statusText, "Up to Date")
        XCTAssertEqual(snapshot.now.title, "Up to Date")
        XCTAssertEqual(snapshot.now.subtitle, "No active drops are available for this account.")
        XCTAssertNotEqual(snapshot.now.campaignId, "claimed")
    }

    func testWatchingNewDropShowsKnownDurationInsteadOfGenericProgressCheck() {
        let progress = Progress(
            dropId: "drop-1",
            campaignId: "active",
            currentMinutes: 0,
            requiredMinutes: 60
        )
        let drop = Drop(
            id: "drop-1",
            name: "Drop 1",
            requiredMinutes: 60,
            progress: progress
        )
        let campaign = makeCampaign(
            id: "active",
            isAccountConnected: true,
            drops: [drop]
        )
        let miner = makeMiner(
            status: .watching,
            campaigns: [campaign],
            currentCampaignId: "active"
        )

        let snapshot = resolveSnapshot(for: miner)

        XCTAssertEqual(snapshot.now.detail, "Drop 1 · 0 / 60 min watched")
        XCTAssertEqual(snapshot.now.progressFraction, 0)
        XCTAssertTrue(snapshot.isActivelyWatching)
        XCTAssertEqual(snapshot.currentSectionTitle, "Currently mining")
        XCTAssertEqual(snapshot.sourceListActivityLabel, "Watching Test Game")
    }

    func testWatchingDropShowsCumulativeMinutesOutOfRequiredMinutes() {
        let progress = Progress(
            dropId: "drop-1",
            campaignId: "active",
            currentMinutes: 10,
            requiredMinutes: 60
        )
        let drop = Drop(
            id: "drop-1",
            name: "Drop 1",
            requiredMinutes: 60,
            progress: progress
        )
        let campaign = makeCampaign(
            id: "active",
            isAccountConnected: true,
            drops: [drop]
        )
        let miner = makeMiner(
            status: .watching,
            campaigns: [campaign],
            currentCampaignId: "active"
        )

        let snapshot = resolveSnapshot(for: miner)

        XCTAssertEqual(snapshot.now.detail, "Drop 1 · 10 / 60 min watched")
        XCTAssertEqual(snapshot.now.progressFraction ?? -1, 1.0 / 6.0, accuracy: 0.0001)
    }

    func testWaitingForStreamIgnoresSubscriptionRequiredPriorityCampaign() {
        let creators = makeCampaign(
            id: "creators",
            gameId: "g007",
            gameName: "007 First Light",
            isAccountConnected: true,
            drops: [Drop(id: "creator-drop", name: "Creator Drop", requiredMinutes: 60)]
        )
        let launchBadge = makeCampaign(
            id: "launch-sub",
            gameId: "g007",
            gameName: "007 First Light",
            isAccountConnected: true,
            drops: [
                Drop(
                    id: "badge",
                    name: "007 Gun Barrel Badge",
                    requiredMinutes: 0,
                    requiredSubs: 1
                )
            ]
        )
        let miner = makeMiner(
            status: .waitingForStream,
            campaigns: [creators, launchBadge],
            priorityGames: ["007 First Light"]
        )

        let snapshot = MinerActivitySnapshot.resolve(
            for: miner,
            priorityGames: ["007 First Light"],
            excludedGames: [],
            strategy: .prioritiseSelected,
            includesBadgeAndEmoteCampaigns: false
        )

        XCTAssertEqual(snapshot.statusText, "Looking for Streams")
        XCTAssertEqual(snapshot.now.title, "No eligible stream live")
        XCTAssertEqual(snapshot.now.campaignId, creators.id)
        XCTAssertFalse(snapshot.now.id.hasPrefix("subscription-"))
    }

    func testWaitingForStreamExplainsTheSpecificCampaignOnTheMinerCard() {
        let campaign = makeCampaign(
            id: "skull-and-bones",
            gameId: "skull-and-bones",
            gameName: "Skull and Bones",
            isAccountConnected: true
        )
        let availability = GameChannelAvailability(
            gameKey: "skull and bones",
            hasEligibleChannel: false,
            campaignId: campaign.id,
            checkedAt: Date()
        )
        let miner = makeMiner(
            status: .waitingForStream,
            campaigns: [campaign],
            priorityGames: ["Skull and Bones"],
            gameChannelAvailability: ["skull and bones": availability]
        )

        let snapshot = MinerActivitySnapshot.resolve(
            for: miner,
            priorityGames: ["Skull and Bones"],
            excludedGames: [],
            strategy: .prioritiseSelected,
            includesBadgeAndEmoteCampaigns: false
        )

        XCTAssertEqual(snapshot.now.title, "No eligible stream live")
        XCTAssertEqual(snapshot.now.subtitle, campaign.name)
        XCTAssertEqual(
            snapshot.now.detail,
            "SwiftMiner will automatically start earning when an eligible Skull and Bones stream goes live."
        )
        XCTAssertEqual(snapshot.now.campaignId, campaign.id)
    }

    func testSubscriptionRequiredCampaignDoesNotSuppressSameGameUpNext() {
        let creators = makeCampaign(
            id: "creators",
            gameId: "g007",
            gameName: "007 First Light",
            isAccountConnected: true,
            drops: [Drop(id: "creator-drop", name: "Creator Drop", requiredMinutes: 60)]
        )
        let launchBadge = makeCampaign(
            id: "launch-sub",
            gameId: "g007",
            gameName: "007 First Light",
            isAccountConnected: true,
            drops: [
                Drop(
                    id: "badge",
                    name: "007 Gun Barrel Badge",
                    requiredMinutes: 0,
                    requiredSubs: 1
                )
            ]
        )
        let miner = makeMiner(
            status: .waitingForStream,
            campaigns: [creators, launchBadge],
            priorityGames: ["007 First Light"]
        )

        let snapshot = MinerActivitySnapshot.resolve(
            for: miner,
            priorityGames: ["007 First Light"],
            excludedGames: [],
            strategy: .prioritiseSelected,
            includesBadgeAndEmoteCampaigns: false
        )

        XCTAssertEqual(snapshot.upNext?.campaignId, "creators")
    }

    func testStalledMinerSurfacesOperationalStateInsteadOfNoCampaigns() {
        let miner = makeMiner(
            status: .idleNoEligibleCampaigns,
            campaigns: [],
            priorityGames: [],
            workerState: .running,
            isHealthy: false,
            isStalled: true
        )

        let snapshot = resolveSnapshot(for: miner)

        XCTAssertEqual(snapshot.statusText, "Miner Unresponsive")
        XCTAssertEqual(snapshot.now.title, "Miner Unresponsive")
    }

    func testRecoveringMinerSurfacesRecoveringState() {
        let miner = makeMiner(
            status: .idleNoEligibleCampaigns,
            campaigns: [],
            priorityGames: [],
            workerState: .recovering,
            isHealthy: false,
            isStalled: false
        )

        let snapshot = resolveSnapshot(for: miner)

        XCTAssertEqual(snapshot.statusText, "Recovering...")
        XCTAssertEqual(snapshot.now.title, "Recovering...")
    }

    func testUnhealthyRefreshAndBlockedStatesDoNotCollapseToNoRecentActivity() {
        let refreshingMiner = makeMiner(
            status: .fetchingCampaigns,
            campaigns: [],
            priorityGames: [],
            workerState: .running,
            isHealthy: false
        )
        let errorMiner = makeMiner(
            status: .error,
            campaigns: [],
            priorityGames: [],
            workerState: .running,
            isHealthy: false
        )
        let idleMiner = makeMiner(
            status: .idleNoEligibleCampaigns,
            campaigns: [],
            priorityGames: [],
            workerState: .running,
            isHealthy: false
        )

        let refreshingSnapshot = resolveSnapshot(for: refreshingMiner)
        let errorSnapshot = resolveSnapshot(for: errorMiner)
        let idleSnapshot = resolveSnapshot(for: idleMiner)

        XCTAssertEqual(refreshingSnapshot.statusText, "Updating…")
        XCTAssertEqual(refreshingSnapshot.now.title, "Updating…")
        XCTAssertEqual(refreshingSnapshot.now.subtitle, "Checking campaigns and drop progress.")
        XCTAssertEqual(refreshingSnapshot.now.symbol, "arrow.clockwise")

        XCTAssertEqual(errorSnapshot.statusText, "Blocked — Needs attention")
        XCTAssertEqual(errorSnapshot.now.title, "Blocked — Needs attention")

        XCTAssertEqual(idleSnapshot.statusText, "Up to Date")
        XCTAssertEqual(idleSnapshot.now.title, "Up to Date")
    }

    func testCampaignRefreshTakesPriorityOverCachedUpToDateState() {
        let claimedProgress = Progress(
            dropId: "drop-1",
            campaignId: "cached",
            currentMinutes: 60,
            requiredMinutes: 60,
            isClaimed: true
        )
        let claimedDrop = Drop(
            id: "drop-1",
            name: "Cached Drop",
            requiredMinutes: 60,
            progress: claimedProgress,
            isClaimed: true
        )
        let campaign = makeCampaign(
            id: "cached",
            isAccountConnected: true,
            drops: [claimedDrop]
        )
        let miner = makeMiner(
            status: .fetchingCampaigns,
            campaigns: [campaign],
            currentCampaignId: "cached"
        )

        let snapshot = resolveSnapshot(for: miner)

        XCTAssertEqual(snapshot.statusText, "Updating…")
        XCTAssertEqual(snapshot.now.title, "Updating…")
        XCTAssertEqual(snapshot.now.symbol, "arrow.clockwise")
    }

    func testUnhealthyWatchingMinerStillSurfacesNoRecentActivity() {
        let miner = makeMiner(
            status: .watching,
            campaigns: [],
            priorityGames: [],
            workerState: .running,
            isHealthy: false
        )

        let snapshot = resolveSnapshot(for: miner)

        XCTAssertEqual(snapshot.statusText, "No Recent Activity")
        XCTAssertEqual(snapshot.now.title, "No Recent Activity")
    }

    func testWebCampaignSummaryMarksSubscriptionOnlyCampaignAsGated() {
        let now = Date()
        let campaign = Campaign(
            id: "subscription-only",
            name: "Subscription Campaign",
            game: Game(id: "game", name: "Test Game"),
            status: .active,
            startDate: now.addingTimeInterval(-60),
            endDate: now.addingTimeInterval(3_600),
            drops: [
                Drop(id: "sub-drop", name: "Subscriber Reward", requiredMinutes: 0, requiredSubs: 1)
            ],
            isAccountConnected: true
        )

        let summary = NavigationModel.webCampaignSummary(from: campaign)

        XCTAssertTrue(summary.requiresSubscription)
        XCTAssertEqual(summary.subscriptionRequiredDropCount, 1)
    }
}
