import SwiftUI
import SwiftMinerCore
import AppKit

/// Overview's system-state banner and the campaign data behind it.
extension OverviewView {
    // MARK: - System State

    var systemStateBanner: some View {
        OverviewSystemStateBanner(
            state: overviewSystemState,
            fleet: MinerFleetStatus.make(miners: displayedMiners),
            onAction: handleSystemStateAction(_:)
        )
    }

    /// Miners the Overview renders. Normally exactly the real ones; in DEBUG it
    /// can be padded for marketing screenshots — see `demoExpanded(_:)`.
    var displayedMiners: [MinerManager.ManagedMiner] {
        #if DEBUG
        return Self.demoExpanded(navigation.minerManager.miners)
        #else
        return navigation.minerManager.miners
        #endif
    }

    #if DEBUG
    /// Pads the miner list with copies of the real ones under demo names, so a
    /// larger fleet can be captured for the website without inventing pixels —
    /// the cards are the real UI rendered over real campaign data.
    ///
    /// Set `SWIFTMINER_DEMO_MINERS=5` in the scheme's environment. Compiled out
    /// of Release entirely, and a no-op unless the variable asks for more
    /// miners than actually exist.
    private static func demoExpanded(_ miners: [MinerManager.ManagedMiner]) -> [MinerManager.ManagedMiner] {
        guard let raw = ProcessInfo.processInfo.environment["SWIFTMINER_DEMO_MINERS"],
              let target = Int(raw),
              target > miners.count,
              !miners.isEmpty else {
            return miners
        }

        let demoNames = ["pixelpanda", "nightowl", "emberfox", "quietcomet", "saltmarsh"]
        var result = miners
        for index in 0..<(target - miners.count) {
            // Cycle the real miners as templates so the extra cards differ from
            // one another rather than repeating a single campaign.
            let template = miners[index % miners.count]
            let name = demoNames[index % demoNames.count]
            result.append(
                MinerManager.ManagedMiner(
                    id: "demo-\(index)-\(name)",
                    accountId: "demo-\(index)",
                    username: name,
                    status: template.status,
                    needsAuth: false,
                    currentCampaign: template.currentCampaign,
                    currentCampaignId: template.currentCampaignId,
                    allCampaigns: template.allCampaigns,
                    dropsClaimed: template.dropsClaimed,
                    isRunning: template.isRunning,
                    priorityGames: template.priorityGames,
                    lastEventAt: template.lastEventAt,
                    lastSuccessfulPollAt: template.lastSuccessfulPollAt,
                    lastCampaignRefreshAt: template.lastCampaignRefreshAt,
                    lastDropProgressAt: template.lastDropProgressAt,
                    workerStartedAt: template.workerStartedAt,
                    workerState: template.workerState,
                    isHealthy: true,
                    isStalled: false
                )
            )
        }
        return result
    }
    #endif

    private var overviewSystemState: OverviewSystemState {
        let miners = displayedMiners
        let miningMinerCount = miners.filter { $0.status == .watching }.count

        if miners.contains(where: { $0.needsAuth }) {
            return .blockedAuthenticationExpired
        }

        if miners.contains(where: \.isStalled) {
            return .minerUnresponsive
        }

        if miners.contains(where: { $0.workerState.isRecovering }) {
            return .recovering
        }

        let accountLinkBlockedMiners = miners.filter { $0.status == .blockedAccountNotLinked }
        if !accountLinkBlockedMiners.isEmpty {
            return .blockedAccountNotLinked(
                minerName: accountLinkBlockedMiners.count == 1 ? accountLinkBlockedMiners[0].displayName : nil,
                blockedCount: accountLinkBlockedMiners.count
            )
        }

        if miners.contains(where: { $0.status == .error }) {
            return .blockedNeedsAttention
        }

        if miners.contains(where: { $0.showsNoRecentActivityAttention }) {
            return .noRecentActivity
        }

        if miningMinerCount > 0 {
            return .mining(
                activeMinerCount: miningMinerCount,
                totalMinerCount: miners.count
            )
        }

        if miners.contains(where: { $0.status == .waitingForStream }) {
            return .waitingForLiveStream
        }

        if miners.contains(where: { $0.status == .fetchingCampaigns }) {
            return .waitingRefreshingCampaigns
        }

        if miners.contains(where: { $0.status == .authenticating }) {
            return .waitingAuthenticating
        }

        if !campaigns.isEmpty && campaigns.allSatisfy(\.isCompleted) {
            return .idleAllCampaignsCompleted
        }

        if activeCampaignCount == 0 {
            return .idleNoEligibleCampaigns
        }

        return .idleNoEligibleCampaigns
    }

    private func handleSystemStateAction(_ action: OverviewSystemAction) {
        switch action {
        case .viewDrops:
            navigation.selectedItem = .drops
        case .viewSchedule:
            navigation.requestDropsFilter(.upcoming)
            navigation.selectedItem = .drops
        case .linkAccount:
            if let miner = firstMinerForAccountLinkAction {
                startLinkAccountFlow(for: miner)
            } else {
                navigation.showAddAccountSheet = true
            }
        }
    }

    private var firstMinerForAccountLinkAction: MinerManager.ManagedMiner? {
        let miners = navigation.minerManager.miners
        return miners.first { $0.needsAuth }
            ?? miners.first { $0.status == .blockedAccountNotLinked }
            ?? miners.first { $0.status == .error }
    }

    /// Assigns only when the data actually changed, so refresh storms that
    /// produce an identical campaign array don't invalidate the whole overview.
    func applyOverviewCampaigns(_ fresh: [CampaignViewData]) {
        guard fresh != overviewCampaigns else { return }
        setOverviewCampaigns(fresh)
    }

    private func setOverviewCampaigns(_ fresh: [CampaignViewData]) {
        overviewCampaigns = fresh
        visibleCampaigns = Self.campaignsExcludingHiddenGames(in: fresh, excludedGames: settings.excludedGames)
    }

    static func campaignsExcludingHiddenGames(
        in campaigns: [CampaignViewData],
        excludedGames: [String]
    ) -> [CampaignViewData] {
        guard !excludedGames.isEmpty else { return campaigns }
        let index = GameMatchIndex(
            gamePreferences: [],
            priorityGames: [],
            excludedGames: excludedGames
        )
        return campaigns.filter { !index.isExcluded(gameName: $0.gameName) }
    }

    func refreshSummary() async {
        isRefreshing = true
        if overviewCampaigns.isEmpty && !navigation.minerManager.dataCoordinator.lastKnownAllCampaigns.isEmpty {
            setOverviewCampaigns(navigation.minerManager.dataCoordinator.lastKnownAllCampaigns)
        }
        applyOverviewCampaigns(await navigation.minerManager.dataCoordinator.allCampaigns())
        isRefreshing = false
    }

    func refreshFromOverview() async {
        isRefreshing = true
        defer { isRefreshing = false }

        await navigation.restartMinersAndRefreshOverviewData()

        applyOverviewCampaigns(await navigation.minerManager.dataCoordinator.allCampaigns())
    }

    func presentCustomArtworkImporter(for game: Game) {
        customArtworkImportGame = game
        DispatchQueue.main.async {
            isShowingArtworkImporter = true
        }
    }
}
