import SwiftUI
import SwiftMinerCore
import AppKit

#if DEBUG
/// Reproducible, privacy-safe data for README and website captures.
///
/// The fixture deliberately starts from Twitch campaign records already cached
/// by the app, so names, reward metadata and artwork stay authentic. It only
/// changes the time window and progress to present those claimed/history
/// campaigns as a lively five-miner fleet. Nothing here exists in Release.
enum MarketingScreenshotFixture {
    static let environmentKey = "SWIFTMINER_MARKETING_SCREENSHOTS"
    static let fakeDiscordId = "100000000000000001"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment[environmentKey] == "1"
    }

    static func miners(from realMiners: [MinerManager.ManagedMiner]) -> [MinerManager.ManagedMiner] {
        guard isEnabled, !realMiners.isEmpty else { return realMiners }

        let targetCount = 5
        let campaignPool = selectedCampaigns(from: realMiners.flatMap(\.allCampaigns), count: targetCount)
        guard !campaignPool.isEmpty else { return realMiners }

        let names = ["pixelpanda", "nightowl", "emberfox", "quietcomet", "saltmarsh"]
        let progressFractions = [0.38, 0.62, 0.27, 0.74, 0.51]
        let now = Date()

        return (0..<targetCount).map { minerIndex in
            let campaigns = (0..<min(3, campaignPool.count)).map { queueIndex in
                makeLiveCampaign(
                    campaignPool[(minerIndex + queueIndex) % campaignPool.count],
                    minerIndex: minerIndex,
                    queueIndex: queueIndex,
                    progressFraction: queueIndex == 0 ? progressFractions[minerIndex] : 0
                )
            }
            let current = campaigns[0]

            return MinerManager.ManagedMiner(
                id: "marketing-\(minerIndex)-\(names[minerIndex])",
                accountId: "marketing-account-\(minerIndex)",
                username: names[minerIndex],
                ownerDiscordId: fakeDiscordId,
                status: .watching,
                needsAuth: false,
                currentCampaign: current.name,
                currentCampaignId: current.id,
                allCampaigns: campaigns,
                dropsClaimed: 4 + minerIndex * 3,
                isRunning: true,
                priorityGames: campaigns.map(\.game.name),
                lastEventAt: now.addingTimeInterval(-Double(8 + minerIndex * 3)),
                lastSuccessfulPollAt: now.addingTimeInterval(-Double(6 + minerIndex * 2)),
                lastCampaignRefreshAt: now.addingTimeInterval(-Double(42 + minerIndex * 7)),
                lastDropProgressAt: now.addingTimeInterval(-Double(25 + minerIndex * 4)),
                workerStartedAt: now.addingTimeInterval(-Double(6_600 + minerIndex * 840)),
                workerState: .running,
                isHealthy: true,
                isStalled: false,
                isOperator: minerIndex == 0
            )
        }
    }

    /// Prefer recognisable, real campaigns in a stable order so successive
    /// captures do not reshuffle. Extra slots draw from other cached campaigns
    /// with real reward data and one campaign per game.
    private static func selectedCampaigns(from campaigns: [Campaign], count: Int) -> [Campaign] {
        let preferredGames = [
            "THE FINALS",
            "ARC Raiders",
            "Battlefield 6",
            "Halo Infinite",
            "Call of Duty: Modern Warfare 4"
        ]
        var selected: [Campaign] = []
        var selectedGames = Set<String>()

        for gameName in preferredGames {
            guard let campaign = campaigns.first(where: {
                $0.game.name.localizedCaseInsensitiveCompare(gameName) == .orderedSame
                    && !$0.drops.isEmpty
            }) else { continue }
            selected.append(campaign)
            selectedGames.insert(campaign.game.name.lowercased())
        }

        for campaign in campaigns where selected.count < count && !campaign.drops.isEmpty {
            guard selectedGames.insert(campaign.game.name.lowercased()).inserted else { continue }
            selected.append(campaign)
        }

        return selected
    }

    private static func makeLiveCampaign(
        _ source: Campaign,
        minerIndex: Int,
        queueIndex: Int,
        progressFraction: Double
    ) -> Campaign {
        let campaignId = "marketing-\(minerIndex)-\(queueIndex)-\(source.id)"
        var drops = source.drops

        for index in drops.indices {
            let requiredMinutes = max(30, drops[index].requiredMinutes)
            let isCurrentDrop = queueIndex == 0 && index == 0
            let currentMinutes = isCurrentDrop
                ? max(1, min(requiredMinutes - 1, Int(Double(requiredMinutes) * progressFraction)))
                : 0
            drops[index].isClaimed = false
            drops[index].progress = Progress(
                id: "\(campaignId)-\(drops[index].id)",
                dropId: drops[index].id,
                dropName: drops[index].name,
                campaignId: campaignId,
                currentMinutes: currentMinutes,
                requiredMinutes: requiredMinutes,
                lastUpdated: Date()
            )
        }

        return Campaign(
            id: campaignId,
            name: source.name,
            game: source.game,
            status: .active,
            startDate: Date().addingTimeInterval(-2 * 24 * 60 * 60),
            endDate: Date().addingTimeInterval(Double(5 + queueIndex) * 24 * 60 * 60),
            drops: drops,
            channels: source.channels,
            isAccountConnected: true,
            allowIsEnabled: source.allowIsEnabled,
            isPrioritised: true
        )
    }
}
#endif

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
        if MarketingScreenshotFixture.isEnabled {
            return MarketingScreenshotFixture.miners(from: navigation.minerManager.miners)
        }
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
