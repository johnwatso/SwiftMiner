import SwiftUI
import SwiftMinerCore
import CoreImage
import TipKit

// MARK: - Drops List View

struct DropsListView: View {
    @Environment(NavigationModel.self) private var navigation
    @State private var campaigns: [CampaignViewData] = []
    @State private var isRefreshing = false
    @State private var searchText: String = ""
    @State private var selectedMinerFilterId: String = DropsListView.allMinersFilterId
    @AppStorage("preferSteamArtwork", store: Settings.appStorageStore) private var preferSteamArtwork: Bool = false
    @ObservedObject private var settings = Settings.shared

    fileprivate static let allMinersFilterId = "__all_miners__"

    private var selectedFilters: Set<DropFilter> {
        get { settings.selectedDropsFilters }
        nonmutating set { settings.selectedDropsFilters = newValue }
    }

    private var miners: [MinerManager.ManagedMiner] { navigation.minerManager.miners }
    private var hasAccounts: Bool { !miners.isEmpty }
    private var accountSignature: String {
        miners
            .map { "\($0.id):\($0.accountId)" }
            .sorted()
            .joined(separator: "|")
    }

    var body: some View {
        Group {
            if !hasAccounts {
                noAccountsState
            } else if campaigns.isEmpty && isRefreshing {
                initialLoadingState
            } else if campaigns.isEmpty {
                contextualStandbyState(
                    title: "No campaigns yet",
                    message: "No campaigns yet",
                    description: "SwiftMiner will show campaigns here once your miners sync their latest Twitch drops data."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        dashboardHeader
                        searchAndMinerControls
                        filterChipsRow

                        if let message = contextualBannerMessage {
                            fallbackBanner(message)
                        }

                        if renderedCampaigns.isEmpty {
                            fallbackBanner(emptyFilterMessage)
                        } else {
                            ForEach(groupedCampaigns) { group in
                                if let single = group.singleCampaign {
                                    let singleActivity = activity(for: single.campaign)
                                    CampaignDeckCard(
                                        campaign: single.campaign,
                                        activity: singleActivity,
                                        onSteamIdSet: { appId in
                                            await SteamArtworkService.shared.setManualAppId(for: single.campaign.gameName, appId: appId)
                                            await navigation.minerManager.dataCoordinator.clearSteamArtworkCache()
                                            await loadCampaignFeed()
                                        }
                                    )
                                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
                                } else {
                                    GameCampaignDeckCard(
                                        group: group,
                                        activityProvider: activity(for:)
                                    )
                                        .transition(.opacity.combined(with: .scale(scale: 0.985)))
                                }
                            }
                        }
                    }
                    .padding(24)
                }
                .animation(.easeInOut(duration: 0.28), value: renderSignature)
            }
        }
        .navigationTitle("Drops")
        .task(id: accountSignature) {
            applyRequestedDropsFilter()
            await loadCampaignFeed()
            await MinerFilterTip.viewedDropsList.donate()
            await DropFilterChipsTip.viewedDropsList.donate()
            if !preferSteamArtwork {
                await SteamArtworkTip.viewedCampaigns.donate()
            }
        }
        .onChange(of: navigation.requestedDropsFilter) { _, _ in
            applyRequestedDropsFilter()
        }
        .onChange(of: preferSteamArtwork) { _, _ in
            Task {
                await navigation.minerManager.dataCoordinator.clearSteamArtworkCache()
                await loadCampaignFeed()
            }
        }
        .onChange(of: miners.map(\.accountId)) { _, accountIds in
            guard selectedMinerFilterId != Self.allMinersFilterId,
                  !accountIds.contains(selectedMinerFilterId)
            else { return }
            selectedMinerFilterId = Self.allMinersFilterId
        }
    }

    private var searchAndMinerControls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)

                TextField("Search drops", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .frame(maxWidth: 320)
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.secondary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
            )

            if miners.count > 1 {
                Picker("Miner", selection: $selectedMinerFilterId) {
                    Text("All miners").tag(Self.allMinersFilterId)
                    ForEach(miners) { miner in
                        Text(miner.displayName).tag(miner.accountId)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(width: 180)
                .help("Show campaigns for a specific miner")
                .minerTip(MinerFilterTip())
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: - States

    private func applyRequestedDropsFilter() {
        guard let intent = navigation.consumeDropsFilterIntent() else { return }

        switch intent {
        case .upcoming:
            selectedFilters = [.upcoming]
        }
    }

    private var noAccountsState: some View {
        MaterialEmptyStatePanel(
            "Add an account to load drops",
            systemImage: "person.crop.circle.badge.plus",
            description: "SwiftMiner will render cached and live campaigns here as soon as an account is connected."
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var initialLoadingState: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)

            VStack(spacing: 6) {
                Text("Loading campaigns")
                    .font(.headline)

                Text("Your progress will be ready in a moment.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func contextualStandbyState(title: String = "Campaigns are syncing", message: String, description: String) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            fallbackBanner(message)

            Color.clear
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(title)
                            .font(.headline.weight(.semibold))

                        Text(description)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(24)
                }
                .frame(height: 220)
                .glassCard()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(24)
    }

    @ViewBuilder
    private func fallbackBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles.tv")
                .foregroundStyle(.secondary)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial.opacity(0.75), in: RoundedRectangle(cornerRadius: GlassRadius.medium, style: .continuous))
    }

    private var filterChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(DropFilter.allCases) { option in
                    let isSelected = selectedFilters.contains(option)
                    Button {
                        DropFilterChipsTip().invalidate(reason: .actionPerformed)
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            var current = selectedFilters
                            if isSelected {
                                current.remove(option)
                            } else {
                                current.insert(option)
                            }
                            selectedFilters = current
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: option.symbol)
                                .font(.caption.weight(.semibold))
                            Text(option.title)
                                .font(.subheadline.weight(.medium))
                        }
                        .foregroundStyle(isSelected ? .primary : .secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            Group {
                                if isSelected {
                                    Capsule().fill(.thinMaterial.opacity(0.95))
                                } else {
                                    Capsule().fill(Color.clear)
                                }
                            }
                        )
                        .overlay(
                            Capsule()
                                .stroke(isSelected ? Color.primary.opacity(0.20) : Color.secondary.opacity(0.18), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                    .help("Toggle \(option.title) campaigns")
                    .accessibilityLabel(option.title)
                    .accessibilityValue(isSelected ? "Selected" : "Not selected")
                }
            }
            .padding(.horizontal, 1)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Campaign filters")
        .minerTip(DropFilterChipsTip())
    }

    // MARK: - Data

    private var feedCampaigns: [CampaignViewData] {
        campaigns
            .map(applyingCustomArtwork)
            .sorted(by: campaignSort)
            .filter { !isExcludedCampaign($0) }
    }

    private var activeMiningCampaigns: [CampaignViewData] {
        feedCampaigns
            .filter { campaign in
                activity(for: campaign).state == .active
            }
    }

    private var claimableCampaigns: [CampaignViewData] {
        feedCampaigns
            .filter { activity(for: $0).claimableDropCount > 0 }
    }

    private var renderedCampaigns: [CampaignViewData] {
        feedCampaigns.filter { campaign in
            matchesSelectedFilters(campaign, activity: activity(for: campaign))
                && matchesSelectedMiner(campaign)
                && matchesSearch(campaign)
        }
    }

    private func matchesSelectedMiner(_ campaign: CampaignViewData) -> Bool {
        guard selectedMinerFilterId != Self.allMinersFilterId else { return true }
        return campaign.accountStates.contains { $0.accountId == selectedMinerFilterId }
    }

    private func matchesSearch(_ campaign: CampaignViewData) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let haystack = ([campaign.gameName, campaign.campaignName] + campaign.drops.map(\.name))
            .joined(separator: " ")
        return haystack.localizedCaseInsensitiveContains(query)
    }

    private var groupedCampaigns: [GameAggregate] {
        let activeCampaigns = renderedCampaigns.filter { !$0.isExpired() }
        let endedCampaigns = renderedCampaigns.filter { $0.isExpired() }

        let activeGroups = GameAggregateBuilder.buildDrops(from: activeCampaigns)
        let endedGroups = endedCampaigns.map(endedCampaignGroup)

        return (activeGroups + endedGroups).sorted { lhs, rhs in
            if lhs.aggregateState.priority != rhs.aggregateState.priority {
                return lhs.aggregateState.priority < rhs.aggregateState.priority
            }
            return lhs.gameName.localizedCaseInsensitiveCompare(rhs.gameName) == .orderedAscending
        }
    }

    private func endedCampaignGroup(for campaign: CampaignViewData) -> GameAggregate {
        GameAggregate(
            id: "\(campaign.aggregateGameGroupKey):ended:\(campaign.id)",
            gameName: campaign.gameName,
            artworkURL: campaign.artworkURL,
            totalDrops: campaign.totalDrops,
            earnedDrops: campaign.drops.filter { $0.isClaimed || $0.isClaimable || $0.progress >= 0.995 }.count,
            claimedDrops: campaign.overviewClaimedRewardCount,
            claimableDrops: campaign.drops.filter { $0.isClaimable && !$0.isClaimed }.count,
            campaigns: [
                GameAggregateCampaign(
                    campaign: campaign,
                    state: campaign.gameAggregateState()
                )
            ],
            aggregateState: campaign.gameAggregateState()
        )
    }

    private func applyingCustomArtwork(to campaign: CampaignViewData) -> CampaignViewData {
        let game = Game(id: campaign.gameId ?? "", name: campaign.gameName, boxArtURL: campaign.artworkURL)
        guard let customArtworkURL = preferredPreference(matching: game)?.customArtworkURL else {
            return campaign
        }
        return campaign.withArtworkURL(customArtworkURL)
    }

    private func preferredPreference(matching game: Game) -> GamePreference? {
        let matches = settings.gamePreferences.filter { preference in
            let idMatches = !game.id.isEmpty && preference.gameId == game.id
            let nameMatches = preference.gameName.localizedCaseInsensitiveCompare(game.name) == .orderedSame
            return idMatches || nameMatches
        }

        return matches.first(where: { $0.customArtworkURL != nil }) ?? matches.first
    }

    private var contextualBannerMessage: String? {
        guard isRefreshing else { return nil }

        if selectedFilters.isEmpty {
            return "Refreshing campaigns in the background"
        }

        if selectedFilters.count == 1, let only = selectedFilters.first {
            return "Refreshing \(only.title.lowercased()) campaigns in the background"
        }

        return "Refreshing selected campaign filters in the background"
    }

    private var emptyFilterMessage: String {
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "No campaigns match your search."
        }

        if selectedMinerFilterId != Self.allMinersFilterId,
           let miner = miners.first(where: { $0.accountId == selectedMinerFilterId }) {
            return "No campaigns for \(miner.displayName) match the selected filters."
        }

        if selectedFilters.isEmpty {
            return "Select at least one filter to refine campaigns."
        }

        if selectedFilters == [.active] {
            return "No campaigns are currently mining or in progress."
        }

        if selectedFilters == [.needsSetup] {
            return "No campaigns need account linking right now."
        }

        if selectedFilters == [.upcoming] {
            return "No upcoming campaigns are in your current feed."
        }

        if selectedFilters == [.completed] {
            return "No completed or ended campaigns yet."
        }

        return "No campaigns match the selected filters."
    }

    private var renderSignature: [String] {
        feedCampaigns.map { campaign in
            let snapshot = activity(for: campaign)
            return "\(campaign.id)-\(snapshot.state.rawValue)-\(snapshot.claimableDropCount)-\(snapshot.claimedRewardCount)"
        }
    }

    private var dashboardHeader: some View {
        HStack(spacing: 12) {
            DashboardMetricCard(
                title: "Active miners",
                value: "\(miners.filter { $0.status == .watching || $0.status == .claiming }.count)",
                detail: "\(activeMiningCampaigns.count) \(activeMiningCampaigns.count == 1 ? "campaign" : "campaigns") in motion",
                tint: .green,
                systemImage: "person.2.fill"
            )

            DashboardMetricCard(
                title: "Top game",
                value: topClaimedGame?.name ?? "None yet",
                detail: topClaimedGame.map { top in
                    "\(top.count) \(top.count == 1 ? "reward" : "rewards") claimed"
                } ?? "Claim a reward to crown a winner",
                tint: .orange,
                systemImage: "trophy.fill",
                isMuted: topClaimedGame == nil
            )

            DashboardMetricCard(
                title: "Rewards claimed",
                value: "\(feedCampaigns.reduce(0) { $0 + activity(for: $1).claimedRewardCount })",
                detail: "\(feedCampaigns.count) \(feedCampaigns.count == 1 ? "campaign" : "campaigns") tracked",
                tint: .blue,
                systemImage: "checkmark.circle.fill"
            )

            if miners.count > 1, let leader = mostActiveMiner {
                DashboardMetricCard(
                    title: "Most active miner",
                    value: leader.name,
                    detail: "\(leader.count) \(leader.count == 1 ? "reward" : "rewards") claimed",
                    tint: .purple,
                    systemImage: "star.fill",
                    isMuted: leader.count == 0
                )
            }
        }
    }

    private var mostActiveMiner: (name: String, count: Int)? {
        guard miners.count > 1 else { return nil }
        guard let leader = miners.max(by: { lhs, rhs in
            if lhs.dropsClaimed != rhs.dropsClaimed { return lhs.dropsClaimed < rhs.dropsClaimed }
            return lhs.displayName > rhs.displayName
        }) else { return nil }
        return (name: leader.displayName, count: leader.dropsClaimed)
    }

    private var claimableRewardCount: Int {
        feedCampaigns.reduce(0) { $0 + activity(for: $1).claimableDropCount }
    }

    private var topClaimedGame: (name: String, count: Int)? {
        var counts: [String: Int] = [:]
        for campaign in feedCampaigns {
            let claimed = activity(for: campaign).claimedRewardCount
            guard claimed > 0 else { continue }
            counts[campaign.gameName, default: 0] += claimed
        }
        guard let top = counts.max(by: { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value < rhs.value }
            return lhs.key > rhs.key
        }) else { return nil }
        return (name: top.key, count: top.value)
    }

    @MainActor
    private func loadCampaignFeed() async {
        guard hasAccounts else {
            campaigns = []
            isRefreshing = false
            return
        }

        isRefreshing = true
        defer { isRefreshing = false }

        // Seed from last-known cache immediately (synchronous) so the view
        // shows artwork-complete campaigns while the async refresh runs.
        let lastKnown = navigation.minerManager.dataCoordinator.lastKnownAllCampaigns
        if campaigns.isEmpty && !lastKnown.isEmpty {
            campaigns = lastKnown
        }

        // Load ALL campaigns (not filtered) for the "All" tab
        let cached = await navigation.minerManager.dataCoordinator.allCampaigns(
            preferSteamArtwork: Settings.shared.preferSteamArtwork
        )
        if !cached.isEmpty {
            withAnimation(.easeInOut(duration: 0.2)) {
                campaigns = cached
            }
        }

        let preferSteamArtwork = Settings.shared.preferSteamArtwork
        let refreshTask = Task {
            await navigation.minerManager.dataCoordinator.refreshAll()
        }
        let completedInTime = await waitForRefreshTask(
            refreshTask,
            timeout: .seconds(45)
        )

        // Don't leave the UI waiting forever when one account is slow.
        // Let refresh continue in the background and apply results when ready.
        if !completedInTime {
            Task { @MainActor in
                await refreshTask.value
                guard hasAccounts else { return }
                let eventual = await navigation.minerManager.dataCoordinator.allCampaigns(
                    preferSteamArtwork: preferSteamArtwork
                )
                if !eventual.isEmpty || campaigns.isEmpty {
                    withAnimation(.easeInOut(duration: 0.24)) {
                        campaigns = eventual
                    }
                }
            }
            return
        }

        // Load ALL campaigns after refresh (not filtered)
        let refreshed = await navigation.minerManager.dataCoordinator.allCampaigns(
            preferSteamArtwork: preferSteamArtwork
        )

        if !refreshed.isEmpty || campaigns.isEmpty {
            withAnimation(.easeInOut(duration: 0.24)) {
                campaigns = refreshed
            }
        }
    }

    private func activeMiners(for campaign: CampaignViewData) -> [MinerManager.ManagedMiner] {
        miners.filter { miner in
            guard miner.status == .watching || miner.status == .claiming else {
                return false
            }

            if let id = miner.currentCampaignId {
                return id == campaign.id
            }

            return miner.currentCampaign == campaign.campaignName
        }
    }

    private func waitForRefreshTask(_ task: Task<Void, Never>, timeout: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await task.value
                return true
            }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    return false
                } catch {
                    return true
                }
            }

            let first = await group.next() ?? true
            group.cancelAll()
            return first
        }
    }

    private func campaignSort(lhs: CampaignViewData, rhs: CampaignViewData) -> Bool {
        let lhsActivity = activity(for: lhs)
        let rhsActivity = activity(for: rhs)

        if lhsActivity.state.priority != rhsActivity.state.priority {
            return lhsActivity.state.priority < rhsActivity.state.priority
        }

        if lhsActivity.activeMiners.count != rhsActivity.activeMiners.count {
            return lhsActivity.activeMiners.count > rhsActivity.activeMiners.count
        }

        if lhsActivity.claimableDropCount != rhsActivity.claimableDropCount {
            return lhsActivity.claimableDropCount > rhsActivity.claimableDropCount
        }

        if lhsActivity.claimedRewardCount != rhsActivity.claimedRewardCount {
            return lhsActivity.claimedRewardCount > rhsActivity.claimedRewardCount
        }

        return lhs.gameName < rhs.gameName
    }

    private func isExcludedCampaign(_ campaign: CampaignViewData) -> Bool {
        let excluded = Settings.shared.excludedGames
        return excluded.contains { gameName in
            gameName.localizedCaseInsensitiveCompare(campaign.gameName) == .orderedSame
        }
    }

    private func matchesActiveFilter(_ campaign: CampaignViewData, activity: CampaignActivitySnapshot) -> Bool {
        guard !matchesCompletedFilter(campaign, activity: activity) else {
            return false
        }
        guard !isBlockedCampaign(campaign, activity: activity) else {
            return false
        }

        guard campaign.startDate <= Date(), campaign.endDate > Date() else {
            return false
        }

        switch activity.state {
        case .active, .inProgress, .claimable, .ready, .waiting, .idle:
            return true
        case .blocked, .claimed, .expired:
            return false
        }
    }

    private func matchesNeedsSetupFilter(_ campaign: CampaignViewData, activity: CampaignActivitySnapshot) -> Bool {
        return isBlockedCampaign(campaign, activity: activity)
    }

    private func matchesUpcomingFilter(_ campaign: CampaignViewData, activity: CampaignActivitySnapshot) -> Bool {
        guard !isBlockedCampaign(campaign, activity: activity) else {
            return false
        }
        guard campaign.startDate > Date() else {
            return false
        }
        return !matchesCompletedFilter(campaign, activity: activity)
    }

    private func matchesCompletedFilter(_ campaign: CampaignViewData, activity: CampaignActivitySnapshot) -> Bool {
        guard !isBlockedCampaign(campaign, activity: activity) else {
            return false
        }
        return campaign.isExpired() || activity.state == .claimed
    }

    private func isBlockedCampaign(_ campaign: CampaignViewData, activity: CampaignActivitySnapshot) -> Bool {
        !campaign.isAccountConnected || !activity.blockedAccounts.isEmpty
    }

    private func filters(for campaign: CampaignViewData, activity: CampaignActivitySnapshot) -> Set<DropFilter> {
        if matchesNeedsSetupFilter(campaign, activity: activity) {
            return [.needsSetup]
        }

        var filters: Set<DropFilter> = []
        if matchesActiveFilter(campaign, activity: activity) {
            filters.insert(.active)
        }
        if matchesUpcomingFilter(campaign, activity: activity) {
            filters.insert(.upcoming)
        }
        if matchesCompletedFilter(campaign, activity: activity) {
            filters.insert(.completed)
        }
        return filters
    }

    private func matchesSelectedFilters(_ campaign: CampaignViewData, activity: CampaignActivitySnapshot) -> Bool {
        guard !selectedFilters.isEmpty else {
            return false
        }
        return !filters(for: campaign, activity: activity).intersection(selectedFilters).isEmpty
    }

    private func activity(for campaign: CampaignViewData) -> CampaignActivitySnapshot {
        let activeMiners = activeMiners(for: campaign)
        let claimedAccounts = campaign.accountStates.filter { $0.miningStatus == .claimed }
        let needsAuthAccounts = campaign.accountStates.filter { $0.miningStatus == .needsAuth }
        let blockedAccounts = campaign.accountStates.filter { $0.miningStatus == .blocked || $0.miningStatus == .needsAuth }
        let claimableDropCount = campaign.drops.filter { $0.isClaimable && !$0.isClaimed }.count
        let claimedRewardCount = max(
            campaign.dropsClaimed,
            campaign.drops.filter(\.isClaimed).count
        )
        let remainingRewardCount = max(campaign.totalDrops - claimedRewardCount, 0)
        let isExpired = campaign.isExpired()
        let combinedProgress = campaign.combinedProgressFraction

        let state: CampaignCardState

        if !campaign.isAccountConnected || !blockedAccounts.isEmpty {
            state = .blocked
        } else if isExpired {
            state = .expired
        } else if combinedProgress >= 0.995 {
            state = .claimed
        } else if !activeMiners.isEmpty {
            state = .active
        } else if combinedProgress > 0 {
            state = .inProgress
        } else {
            state = .ready
        }

        return CampaignActivitySnapshot(
            state: state,
            activeMiners: activeMiners,
            claimedAccounts: claimedAccounts,
            needsAuthAccounts: needsAuthAccounts,
            blockedAccounts: blockedAccounts,
            claimableDropCount: claimableDropCount,
            claimedRewardCount: claimedRewardCount,
            remainingRewardCount: remainingRewardCount
        )
    }
}

// MARK: - Campaign Deck Card

private struct CampaignDeckCard: View {
    let campaign: CampaignViewData
    let activity: CampaignActivitySnapshot
    var onSteamIdSet: ((String) async -> Void)?
    @State private var isHovered = false
    @State private var showingSteamIdPopover = false
    @State private var steamIdDraft = ""
    @State private var extractedArtworkTint: Color?

    private var shownDrops: [DropViewData] {
        campaign.drops
    }

    private var campaignGame: Game {
        Game(id: "", name: campaign.gameName, boxArtURL: campaign.artworkURL)
    }

    private var supportsSteamArtwork: Bool {
        SteamArtworkService.supportsSteamArtwork(forGameName: campaign.gameName, gameId: campaign.gameId)
    }

    private var hasAccountLinkIssue: Bool {
        activity.state == .blocked && activity.blockedAccounts.contains { $0.miningStatus == .blocked }
    }

    private var hasBlockedNeedsAuthIssue: Bool {
        activity.state == .blocked && !activity.needsAuthAccounts.isEmpty
    }

    private var isActive: Bool {
        activity.state == .active
    }

    private var rewardOutcomeText: String? {
        let totalRewards = max(campaign.totalDrops, campaign.drops.count)
        let claimedRewards = min(activity.claimedRewardCount, totalRewards)

        guard totalRewards > 0 else { return nil }

        if claimedRewards == totalRewards && allRelevantMinersComplete {
            return nil
        }

        return "\(claimedRewards) / \(totalRewards) rewards claimed"
    }

    private var endedOutcomeText: String? {
        let totalRewards = max(campaign.totalDrops, campaign.drops.count)
        let claimedRewards = min(activity.claimedRewardCount, totalRewards)
        let unclaimedRewards = max(totalRewards - claimedRewards, activity.remainingRewardCount)

        guard totalRewards > 0 else { return "Ended" }
        guard unclaimedRewards > 0 else {
            return allRelevantMinersComplete ? nil : "\(claimedRewards) / \(totalRewards) rewards claimed"
        }

        return "Ended · \(unclaimedRewards) unclaimed"
    }

    private var outcomeText: String? {
        if activity.state == .expired {
            return endedOutcomeText
        }

        if let minerConsistencyText {
            return minerConsistencyText
        }

        return rewardOutcomeText
    }

    private var minerConsistencyText: String? {
        let totalMiners = totalMinerCount
        guard totalMiners > 0 else { return nil }

        let completedMiners = completedMinerCount
        guard completedMiners < totalMiners else { return nil }

        return "\(completedMiners) / \(totalMiners) miners complete"
    }

    private var totalMinerCount: Int {
        campaign.accountStates.count
    }

    private var completedMinerCount: Int {
        campaign.accountStates.filter { $0.miningStatus == .claimed }.count
    }

    private var allRelevantMinersComplete: Bool {
        totalMinerCount == 0 || completedMinerCount == totalMinerCount
    }

    private var requirementBannerCopy: (title: String, message: String, systemImage: String, tint: Color)? {
        if hasAccountLinkIssue {
            let accountCount = activity.blockedAccounts.filter { $0.miningStatus == .blocked }.count
            return (
                title: "Link required",
                message: "Link the game account on Twitch for the affected miner\(accountCount == 1 ? "" : "s") before mining can continue.",
                systemImage: "link.badge.plus",
                tint: .orange
            )
        }

        if hasBlockedNeedsAuthIssue {
            let accountCount = activity.needsAuthAccounts.count
            return (
                title: "Needs setup",
                message: "Reconnect the affected Twitch account\(accountCount == 1 ? "" : "s") before mining can continue.",
                systemImage: "exclamationmark.triangle.fill",
                tint: .orange
            )
        }

        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                CampaignArtworkIcon(url: campaign.artworkURL, tint: activity.state.tint)

                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(campaign.gameName)
                                .font(.title3.weight(.bold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)

                            Text(campaign.campaignName)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        Spacer(minLength: 0)

                        HStack(spacing: 6) {
                            if isActive {
                                LivePulseDot(color: activity.state.tint)
                            } else {
                                Image(systemName: activity.state.symbol)
                                    .font(.caption2.weight(.bold))
                            }

                            Text(activity.state.title)
                                .lineLimit(1)
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(activity.state.tint)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.regularMaterial.opacity(0.92), in: Capsule())
                    }

                    HStack(spacing: 8) {
                        CampaignMetricPill(
                            title: "\(activity.claimedRewardCount) claimed",
                            systemImage: "checkmark.circle.fill",
                            tint: .blue
                        )
                        CampaignMetricPill(
                            title: "\(activity.remainingRewardCount) remaining",
                            systemImage: "gift.fill",
                            tint: .secondary
                        )

                        if activity.claimableDropCount > 0 && activity.state != .blocked {
                            CampaignMetricPill(
                                title: "\(activity.claimableDropCount) queued",
                                systemImage: "tray.and.arrow.down.fill",
                                tint: .orange
                            )
                        }
                    }

                    if let outcomeText {
                        Text(outcomeText)
                            .font(.caption)
                            .foregroundStyle(activity.state == .expired ? .orange : .secondary)
                    }

                    if !campaign.accountStates.isEmpty {
                        CampaignMinerAttributionRow(accountStates: campaign.accountStates)
                    }

                    if isActive && campaign.progress > 0 {
                        ProgressView(value: campaign.progress, total: 1.0)
                            .progressViewStyle(.linear)
                            .tint(activity.state.tint)
                            .padding(.top, 2)
                    } else if isActive {
                        ProgressView()
                            .controlSize(.small)
                            .tint(activity.state.tint)
                            .padding(.top, 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            if let requirementBannerCopy {
                CampaignRequirementBanner(
                    title: requirementBannerCopy.title,
                    message: requirementBannerCopy.message,
                    systemImage: requirementBannerCopy.systemImage,
                    tint: requirementBannerCopy.tint
                )
            }

            if shownDrops.isEmpty {
                Text("No rewards available for this campaign.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(shownDrops) { drop in
                        CampaignDropPreviewRow(
                            drop: drop,
                            activity: activity,
                            fallbackURL: campaign.artworkURL
                        )
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    activity.state.borderTint,
                    lineWidth: isActive ? 1.2 : 1
                )
        }
        .shadow(
            color: isActive
                ? activity.state.tint.opacity(isHovered ? 0.18 : 0.10)
                : .black.opacity(isHovered ? 0.10 : 0.06),
            radius: isHovered ? 10 : (isActive ? 8 : 4),
            y: isHovered ? 5 : (isActive ? 4 : 2)
        )
        .opacity(activity.state == .expired ? 0.62 : 1)
        .saturation(1)
        .brightness(isHovered ? 0.008 : 0)
        .animation(.easeInOut(duration: 0.18), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .task(id: campaign.artworkURL?.absoluteString ?? campaign.id) {
            extractedArtworkTint = await CampaignArtworkTintSampler.shared.tintColor(from: campaign.artworkURL)
        }
        .contextMenu {
            Button {
                Settings.shared.setGamePreference(campaignGame, state: .preferred)
            } label: {
                Label("Prioritise Game", systemImage: "star")
            }

            Button {
                Settings.shared.setGamePreference(campaignGame, state: .excluded)
            } label: {
                Label("Exclude Game", systemImage: "minus.circle")
            }

            Divider()

            if supportsSteamArtwork {
                Button {
                    steamIdDraft = ""
                    showingSteamIdPopover = true
                } label: {
                    Label("Set Steam ID", systemImage: "photo.artframe")
                }
            }
        }
        .popover(isPresented: $showingSteamIdPopover, arrowEdge: .bottom) {
            SteamIdInputPopover(
                gameName: campaign.gameName,
                appId: $steamIdDraft,
                onConfirm: {
                    showingSteamIdPopover = false
                    let id = steamIdDraft.trimmingCharacters(in: .whitespaces)
                    guard !id.isEmpty else { return }
                    Task { await onSteamIdSet?(id) }
                },
                onCancel: { showingSteamIdPopover = false }
            )
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(.thinMaterial.opacity(isActive ? 0.98 : 0.95))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                materialTint.opacity(isActive ? 0.10 : 0.05),
                                materialTint.opacity(isActive ? 0.05 : 0.025),
                                Color.white.opacity(isActive ? 0.045 : 0.02)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isActive ? 0.12 : 0.08),
                                activity.state.tint.opacity(activity.state == .claimed ? 0.02 : (isActive ? 0.06 : 0.03)),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: UnitPoint(x: 0.75, y: 0.65)
                        )
                    )
            }
    }

    private var materialTint: Color {
        extractedArtworkTint ?? Color.gray
    }

}

// MARK: - Grouped Game Card

private struct GameCampaignDeckCard: View {
    let group: GameAggregate
    let activityProvider: (CampaignViewData) -> CampaignActivitySnapshot

    private var cardState: CampaignCardState {
        group.aggregateState.asCampaignCardState
    }

    private var isActive: Bool {
        group.aggregateState == .inProgress
    }

    private var minerAccountStates: [AccountState] {
        var mergedStates: [String: AccountState] = [:]

        for account in group.campaigns.flatMap(\.campaign.accountStates) {
            if let existing = mergedStates[account.accountId] {
                mergedStates[account.accountId] = preferredAccountState(existing, account)
            } else {
                mergedStates[account.accountId] = account
            }
        }

        let statusOrder: [AccountMiningStatus: Int] = [
            .needsAuth: 0,
            .blocked: 1,
            .mining: 2,
            .ready: 3,
            .claimed: 4,
            .idle: 5
        ]

        return mergedStates.values.sorted {
            let lhsOrder = statusOrder[$0.miningStatus] ?? Int.max
            let rhsOrder = statusOrder[$1.miningStatus] ?? Int.max
            if lhsOrder != rhsOrder {
                return lhsOrder < rhsOrder
            }
            return $0.username.localizedCaseInsensitiveCompare($1.username) == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                CampaignArtworkIcon(url: group.artworkURL, tint: group.aggregateState.tint)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 10) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.gameName)
                                .font(.title3.weight(.bold))
                                .lineLimit(1)

                            Text("\(group.campaigns.count) campaigns")
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 0)

                        HStack(spacing: 6) {
                            Image(systemName: group.aggregateState.symbol)
                                .font(.caption2.weight(.bold))

                            Text(group.aggregateState.title)
                                .lineLimit(1)
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(group.aggregateState.tint)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.regularMaterial.opacity(0.92), in: Capsule())
                    }

                    HStack(spacing: 8) {
                        CampaignMetricPill(
                            title: "\(group.claimedRewardCount) claimed",
                            systemImage: "checkmark.circle.fill",
                            tint: .blue
                        )
                        CampaignMetricPill(
                            title: "\(group.remainingRewardCount) remaining",
                            systemImage: "gift.fill",
                            tint: .secondary
                        )
                        if group.claimableRewardCount > 0 && group.aggregateState != .actionRequired {
                            CampaignMetricPill(
                                title: "\(group.claimableRewardCount) queued",
                                systemImage: "tray.and.arrow.down.fill",
                                tint: .orange
                            )
                        }
                    }

                    if !minerAccountStates.isEmpty {
                        CampaignMinerAttributionRow(accountStates: minerAccountStates)
                    }
                }
            }

            Divider()
                .overlay(.white.opacity(0.08))

            VStack(spacing: 8) {
                ForEach(group.campaigns) { item in
                    GroupedCampaignSubItem(
                        item: item,
                        activity: activityProvider(item.campaign)
                    )
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.thinMaterial.opacity(isActive ? 0.98 : 0.95))
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(cardState.borderTint, lineWidth: isActive ? 1.2 : 1)
        }
        .shadow(
            color: isActive
                ? group.aggregateState.tint.opacity(0.10)
                : .black.opacity(0.06),
            radius: isActive ? 8 : 4,
            y: isActive ? 4 : 2
        )
    }

    private func preferredAccountState(_ lhs: AccountState, _ rhs: AccountState) -> AccountState {
        let statusOrder: [AccountMiningStatus: Int] = [
            .needsAuth: 0,
            .blocked: 1,
            .mining: 2,
            .ready: 3,
            .claimed: 4,
            .idle: 5
        ]

        let lhsOrder = statusOrder[lhs.miningStatus] ?? Int.max
        let rhsOrder = statusOrder[rhs.miningStatus] ?? Int.max

        if lhsOrder != rhsOrder {
            return lhsOrder < rhsOrder ? lhs : rhs
        }

        let lhsProgress = lhs.progressFraction ?? 0
        let rhsProgress = rhs.progressFraction ?? 0
        if lhsProgress != rhsProgress {
            return lhsProgress > rhsProgress ? lhs : rhs
        }

        return lhs.claimedDropCount >= rhs.claimedDropCount ? lhs : rhs
    }
}

private struct GroupedCampaignSubItem: View {
    let item: GameAggregateCampaign
    let activity: CampaignActivitySnapshot

    private var representativeDrop: DropViewData? {
        item.campaign.drops.first { $0.isClaimable && !$0.isClaimed }
            ?? item.campaign.drops.first { $0.progress > 0 && !$0.isClaimed }
            ?? item.campaign.drops.first { !$0.isClaimed }
            ?? item.campaign.drops.first
    }

    private var imageURLToUse: URL? {
        (representativeDrop?.imageURL ?? item.campaign.artworkURL)?.highResolutionArtworkURL
    }

    private var progressPercent: Int {
        Int((item.campaign.progress * 100).rounded())
    }

    private var detailText: String {
        if item.state == .actionRequired {
            return "Action required"
        }
        if activity.claimableDropCount > 0 {
            let count = activity.claimableDropCount
            return count == 1 ? "1 claim queued" : "\(count) claims queued"
        }
        if item.state == .inProgress && item.campaign.progress > 0 {
            return "\(progressPercent)% progress • \(activity.claimedRewardCount) claimed"
        }
        if item.campaign.overviewRemainingRewardCount > 0 {
            let remaining = item.campaign.overviewRemainingRewardCount
            return remaining == 1 ? "1 reward remaining" : "\(remaining) rewards remaining"
        }
        if item.state == .completed {
            return "Completed"
        }
        return "Ended"
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            thumbnail

            VStack(alignment: .leading, spacing: 5) {
                Text(item.campaign.campaignName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if !item.campaign.accountStates.isEmpty {
                    CampaignAccountAttribution(accountStates: item.campaign.accountStates)
                }
            }

            Spacer(minLength: 0)

            if item.state != .actionRequired && item.campaign.progress > 0 && item.state != .completed {
                Text("\(progressPercent)%")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Text(item.state.title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(item.state.tint)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.thinMaterial.opacity(0.85), in: Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var thumbnail: some View {
        Group {
            if let imageURLToUse {
                AsyncImage(url: imageURLToUse) { phase in
                    switch phase {
                    case .empty:
                        thumbnailPlaceholder
                    case .success(let image):
                        image
                            .resizable()
                            .interpolation(.high)
                            .scaledToFill()
                    case .failure:
                        thumbnailPlaceholder
                    @unknown default:
                        thumbnailPlaceholder
                    }
                }
            } else {
                thumbnailPlaceholder
            }
        }
        .frame(width: 34, height: 34)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        }
    }

    private var thumbnailPlaceholder: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(item.state.tint.opacity(0.12))
            .overlay {
                Image(systemName: rewardIcon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(item.state.tint)
            }
    }

    private var rewardIcon: String {
        switch representativeDrop?.rewardType ?? .inGame {
        case .badge: return "person.badge.shield.check.fill"
        case .emote: return "face.smiling.fill"
        case .inGame: return "gift.fill"
        }
    }
}

// MARK: - Activity Support

private struct CampaignActivitySnapshot {
    let state: CampaignCardState
    let activeMiners: [MinerManager.ManagedMiner]
    let claimedAccounts: [AccountState]
    let needsAuthAccounts: [AccountState]
    let blockedAccounts: [AccountState]
    let claimableDropCount: Int
    let claimedRewardCount: Int
    let remainingRewardCount: Int
}

private struct DashboardMetricCard: View {
    let title: String
    let value: String
    let detail: String
    let tint: Color
    let systemImage: String
    var isMuted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(isMuted ? .tertiary : .secondary)

            Text(value)
                .font(.title3.weight(.semibold))
                .foregroundStyle(isMuted ? .secondary : .primary)

            Text(detail)
                .font(.caption)
                .foregroundStyle(isMuted ? .tertiary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.thinMaterial.opacity(isMuted ? 0.78 : 0.88), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(tint.opacity(isMuted ? 0.08 : 0.14), lineWidth: 1)
        }
        .opacity(isMuted ? 0.82 : 1)
    }
}

private struct CampaignMetricPill: View {
    let title: String
    let systemImage: String
    let tint: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.regularMaterial.opacity(0.72), in: Capsule())
    }
}

private struct CampaignRequirementBanner: View {
    let title: String
    let message: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(tint.opacity(0.22), lineWidth: 1)
        }
    }
}

// MARK: - Drop Preview Row

private struct CampaignDropPreviewRow: View {
    let drop: DropViewData
    let activity: CampaignActivitySnapshot
    let fallbackURL: URL?

    private var imageURLToUse: URL? {
        (drop.imageURL ?? fallbackURL)?.highResolutionArtworkURL
    }

    private var status: DropPreviewState {
        if activity.state == .blocked {
            return drop.isClaimed ? .claimed : .locked
        }
        if drop.isClaimed { return .claimed }
        if drop.isClaimable { return .claimable }
        if drop.progress > 0 || !activity.activeMiners.isEmpty {
            return .inProgress
        }
        return .locked
    }

    private var showsProgressBar: Bool {
        activity.state == .active && drop.progress > 0 && !drop.isClaimed && !drop.isClaimable
    }

    private var progressPercent: Int {
        Int((drop.progress * 100).rounded())
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            thumbnail

            VStack(alignment: .leading, spacing: 3) {
                Text(drop.name)
                    .font(.subheadline.weight(activity.state == .active ? .semibold : .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Text("Watch \(drop.requiredMinutes) minutes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Group {
                if showsProgressBar {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("\(progressPercent)%")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)

                        ProgressView(value: drop.progress, total: 1.0)
                            .progressViewStyle(.linear)
                            .tint(status.tint)
                            .frame(width: 44)
                    }
                } else {
                    Image(systemName: status.symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(status.tint)
                        .frame(width: 20, height: 20)
                }
            }
            .help(status.title)
        }
        .padding(.vertical, 8)
        .help(status.helpText)
    }

    private var thumbnail: some View {
        Group {
            if let url = imageURLToUse {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        thumbnailPlaceholder
                    case .success(let image):
                        image
                            .resizable()
                            .interpolation(.high)
                            .scaledToFill()
                    case .failure:
                        thumbnailPlaceholder
                    @unknown default:
                        thumbnailPlaceholder
                    }
                }
            } else {
                thumbnailPlaceholder
            }
        }
        .frame(width: 36, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        }
    }

    private var thumbnailPlaceholder: some View {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(status.tint.opacity(0.12))
            .overlay {
                Image(systemName: rewardIcon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(status.tint)
            }
    }

    private var rewardIcon: String {
        switch drop.rewardType {
        case .badge: return "person.badge.shield.check.fill"
        case .emote: return "face.smiling.fill"
        case .inGame: return "gift.fill"
        }
    }
}

// MARK: - Card Chrome

private struct CampaignStatePill: View {
    let state: CampaignCardState

    var body: some View {
        Label(state.title, systemImage: state.symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(state.tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.regularMaterial.opacity(0.9), in: Capsule())
    }
}

private struct CampaignMinerAttributionRow: View {
    let accountStates: [AccountState]

    var body: some View {
        HStack(spacing: 7) {
            Text("Miners")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            CampaignAccountAttribution(accountStates: accountStates)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct CampaignAccountAttribution: View {
    let accountStates: [AccountState]

    var body: some View {
        if let onlyAccount = accountStates.first, accountStates.count == 1 {
            CampaignAccountStatusItem(account: onlyAccount)
        } else {
            HStack(spacing: 8) {
                ForEach(Array(accountStates.prefix(3))) { account in
                    CampaignAccountStatusItem(account: account)
                }

                let overflowCount = max(accountStates.count - 3, 0)
                if overflowCount > 0 {
                    Text("+\(overflowCount)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .help("\(overflowCount) more miner\(overflowCount == 1 ? "" : "s")")
                }
            }
        }
    }
}

private struct CampaignAccountStatusItem: View {
    let account: AccountState
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        HStack(spacing: 5) {
            CampaignAccountAvatar(account: account)

            Text(navigation.minerManager.displayName(forAccountId: account.accountId, fallback: account.username))
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(statusLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(statusTint)
                .lineLimit(1)
        }
    }

    private var statusLabel: String {
        switch account.miningStatus {
        case .mining: return "mining"
        case .claimed: return "claimed"
        case .needsAuth: return "needs setup"
        case .blocked: return "link required"
        case .ready: return "ready"
        case .idle: return "waiting"
        }
    }

    private var statusTint: Color {
        switch account.miningStatus {
        case .mining: return .green
        case .claimed: return .blue
        case .needsAuth, .blocked: return .orange
        case .ready, .idle: return .secondary
        }
    }
}

private struct CampaignAccountStrip: View {
    let accountStates: [AccountState]
    var maxVisibleCount: Int? = nil
    var showsOverflow = false
    private let avatarDiameter: CGFloat = 21

    private var visibleAccounts: [AccountState] {
        guard let maxVisibleCount else { return accountStates }
        return Array(accountStates.prefix(maxVisibleCount))
    }

    private var overflowCount: Int {
        guard let maxVisibleCount else { return 0 }
        return max(accountStates.count - maxVisibleCount, 0)
    }

    var body: some View {
        HStack(spacing: -avatarDiameter * 0.24) {
            ForEach(Array(visibleAccounts.enumerated()), id: \.element.id) { index, account in
                CampaignAccountAvatar(account: account)
                    .zIndex(Double(visibleAccounts.count - index))
            }

            if showsOverflow && overflowCount > 0 {
                Text("+\(overflowCount)")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: avatarDiameter, height: avatarDiameter)
                    .background(.regularMaterial, in: Circle())
                    .overlay {
                        Circle()
                            .strokeBorder(.white.opacity(0.58), lineWidth: 1)
                    }
                    .help("\(overflowCount) more miner\(overflowCount == 1 ? "" : "s")")
                    .zIndex(0)
            }
        }
        .frame(height: avatarDiameter + 4)
    }
}

private struct CampaignAccountAvatar: View {
    let account: AccountState
    @Environment(NavigationModel.self) private var navigation
    private let avatarDiameter: CGFloat = 21

    var body: some View {
        let swatch = AvatarColorPalette.swatch(for: account.accountId, username: account.username)
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(swatch.gradient)
                .overlay {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.24), .clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .opacity(0.72)
                }
                .overlay {
                    Text(account.initials)
                        .font(.system(size: avatarDiameter * 0.34, weight: .semibold, design: .rounded))
                        .tracking(0.16)
                        .foregroundStyle(swatch.text)
                }
                .overlay {
                    Circle()
                        .strokeBorder(.white.opacity(0.68), lineWidth: 1)
                }
                .frame(width: avatarDiameter, height: avatarDiameter)
                .shadow(color: .black.opacity(0.045), radius: 2, y: 1)

            if account.miningStatus == .mining {
                LivePulseDot(color: .green)
                    .offset(x: 1.5, y: 1.5)
            } else if account.miningStatus == .needsAuth {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(.orange)
                    .padding(1.5)
                    .background(.regularMaterial, in: Circle())
                    .offset(x: 1.5, y: 1.5)
            } else if account.miningStatus == .blocked {
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 7))
                    .foregroundStyle(.orange)
                    .padding(1.5)
                    .background(.regularMaterial, in: Circle())
                    .offset(x: 1.5, y: 1.5)
            } else if account.miningStatus == .claimed {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 7))
                    .foregroundStyle(.blue)
                    .padding(1.5)
                    .background(.regularMaterial, in: Circle())
                    .offset(x: 1.5, y: 1.5)
            }
        }
        .help("\(navigation.minerManager.displayName(forAccountId: account.accountId, fallback: account.username)) — \(statusTitle(for: account.miningStatus))")
    }

    private func statusTitle(for status: AccountMiningStatus) -> String {
        switch status {
        case .mining: return "Watching"
        case .claimed: return "Claimed"
        case .needsAuth: return "Needs Re-auth"
        case .blocked: return "Link required"
        case .ready: return "Ready"
        case .idle: return "Idle"
        }
    }
}

private struct LivePulseDot: View {
    let color: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: false)) { context in
            let scale = 0.92 + 0.16 * ((sin(context.date.timeIntervalSinceReferenceDate * 2.4) + 1) / 2)

            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .scaleEffect(scale)
                .shadow(color: color.opacity(0.28), radius: 3, y: 0.5)
        }
    }
}

private struct CampaignCardArtwork: View {
    let url: URL?
    let tint: Color

    private var resolvedURL: URL? {
        url?.highResolutionArtworkURL
    }

    var body: some View {
        ZStack {
            if let resolvedURL {
                AsyncImage(url: resolvedURL) { image in
                    image
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                } placeholder: {
                    placeholder
                }
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    private var placeholder: some View {
        LinearGradient(
            colors: [tint.opacity(0.82), tint.opacity(0.38), Color.black.opacity(0.52)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private struct CampaignArtworkIcon: View {
    let url: URL?
    let tint: Color

    var body: some View {
        CampaignCardArtwork(url: url, tint: tint)
            .frame(width: 48, height: 64)
            .clipShape(RoundedRectangle(cornerRadius: GlassRadius.artwork, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: GlassRadius.artwork, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 1)
            }
    }
}

private extension URL {
    var highResolutionArtworkURL: URL {
        let replacements: [(String, String)] = [
            ("{width}", "1200"),
            ("{height}", "1600"),
            ("%7Bwidth%7D", "1200"),
            ("%7Bheight%7D", "1600")
        ]

        let resolved = replacements.reduce(absoluteString) { partial, pair in
            partial.replacingOccurrences(of: pair.0, with: pair.1)
        }

        return URL(string: resolved) ?? self
    }
}

private actor CampaignArtworkTintSampler {
    static let shared = CampaignArtworkTintSampler()

    private var cache: [URL: ArtworkRGB] = [:]
    private var inFlight: [URL: Task<ArtworkRGB?, Never>] = [:]

    func tintColor(from artworkURL: URL?) async -> Color? {
        guard let artworkURL else { return nil }

        if let cached = cache[artworkURL] {
            return cached.color
        }

        if let existingTask = inFlight[artworkURL] {
            return await existingTask.value?.color
        }

        let task = Task<ArtworkRGB?, Never> {
            await Self.fetchAndExtractTint(from: artworkURL.highResolutionArtworkURL)
        }
        inFlight[artworkURL] = task

        let extracted = await task.value
        inFlight[artworkURL] = nil

        if let extracted {
            cache[artworkURL] = extracted
        }

        return extracted?.color
    }

    private static func fetchAndExtractTint(from url: URL) async -> ArtworkRGB? {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                return nil
            }

            return extractDominantColor(from: data)?.softenedForGlass
        } catch {
            return nil
        }
    }

    private static func extractDominantColor(from data: Data) -> ArtworkRGB? {
        guard let ciImage = CIImage(data: data) else { return nil }
        let extent = ciImage.extent
        guard !extent.isEmpty else { return nil }

        guard let filter = CIFilter(name: "CIAreaAverage") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgRect: extent), forKey: kCIInputExtentKey)
        guard let outputImage = filter.outputImage else { return nil }

        let context = CIContext()
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            outputImage,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: nil
        )

        return ArtworkRGB(
            red: Double(pixel[0]) / 255.0,
            green: Double(pixel[1]) / 255.0,
            blue: Double(pixel[2]) / 255.0
        )
    }
}

private struct ArtworkRGB: Sendable, Hashable {
    let red: Double
    let green: Double
    let blue: Double

    var color: Color {
        Color(red: red.clamped01, green: green.clamped01, blue: blue.clamped01)
    }

    var softenedForGlass: ArtworkRGB {
        let luminance = ((red * 0.299) + (green * 0.587) + (blue * 0.114)).clamped01
        let desaturation: Double = 0.38
        let whiteMix: Double = 0.22

        let softenedRed = ((red * (1 - desaturation)) + (luminance * desaturation)).clamped01
        let softenedGreen = ((green * (1 - desaturation)) + (luminance * desaturation)).clamped01
        let softenedBlue = ((blue * (1 - desaturation)) + (luminance * desaturation)).clamped01

        return ArtworkRGB(
            red: ((softenedRed * (1 - whiteMix)) + whiteMix).clamped01,
            green: ((softenedGreen * (1 - whiteMix)) + whiteMix).clamped01,
            blue: ((softenedBlue * (1 - whiteMix)) + whiteMix).clamped01
        )
    }
}

private extension Double {
    var clamped01: Double {
        min(max(self, 0), 1)
    }
}

private extension GameAggregateState {
    var title: String {
        switch self {
        case .actionRequired: return "Link required"
        case .inProgress: return "In Progress"
        case .ready: return "Ready"
        case .completed: return "Completed"
        case .unavailable: return "Ended"
        }
    }

    var symbol: String {
        switch self {
        case .actionRequired: return "exclamationmark.triangle.fill"
        case .inProgress: return "chart.bar.fill"
        case .ready: return "clock.badge.checkmark.fill"
        case .completed: return "checkmark.circle.fill"
        case .unavailable: return "clock.badge.exclamationmark"
        }
    }

    var tint: Color {
        switch self {
        case .actionRequired: return .orange
        case .inProgress: return .green
        case .ready: return .secondary
        case .completed: return .green
        case .unavailable: return .orange
        }
    }

    var asCampaignCardState: CampaignCardState {
        switch self {
        case .actionRequired:
            return .blocked
        case .inProgress:
            return .inProgress
        case .ready:
            return .ready
        case .completed:
            return .claimed
        case .unavailable:
            return .expired
        }
    }
}

private enum CampaignCardState: String {
    case blocked
    case active
    case inProgress
    case claimable
    case ready
    case waiting
    case claimed
    case expired
    case idle

    var priority: Int {
        switch self {
        case .blocked: return 0
        case .active: return 1
        case .claimable: return 2
        case .inProgress: return 3
        case .ready: return 4
        case .waiting: return 5
        case .idle: return 6
        case .claimed: return 7
        case .expired: return 8
        }
    }

    var title: String {
        switch self {
        case .blocked: return "Link required"
        case .active: return "Watching now"
        case .inProgress: return "In progress"
        case .claimable: return "Reward ready"
        case .ready: return "Ready"
        case .waiting: return "Waiting"
        case .claimed: return "Completed"
        case .expired: return "Ended"
        case .idle: return "Available"
        }
    }

    var symbol: String {
        switch self {
        case .blocked: return "exclamationmark.triangle.fill"
        case .active: return "dot.radiowaves.left.and.right"
        case .inProgress: return "chart.bar.fill"
        case .claimable: return "sparkles"
        case .ready: return "clock.badge.checkmark.fill"
        case .waiting: return "antenna.radiowaves.left.and.right.slash"
        case .claimed: return "checkmark.circle.fill"
        case .expired: return "clock.badge.exclamationmark"
        case .idle: return "clock.badge.checkmark.fill"
        }
    }

    var tint: Color {
        switch self {
        case .blocked: return .orange
        case .active: return .green
        case .inProgress: return .blue
        case .claimable: return .secondary
        case .ready: return .secondary
        case .waiting: return .secondary
        case .claimed: return .green
        case .expired: return .orange
        case .idle: return .secondary
        }
    }

    var borderTint: Color {
        switch self {
        case .blocked:
            return .orange.opacity(0.36)
        case .active:
            return .green.opacity(0.28)
        case .claimable:
            return .white.opacity(0.12)
        case .inProgress:
            return .blue.opacity(0.20)
        case .ready, .waiting:
            return .white.opacity(0.12)
        case .claimed:
            return .green.opacity(0.14)
        case .expired:
            return .orange.opacity(0.22)
        case .idle:
            return .white.opacity(0.12)
        }
    }
}

private enum DropPreviewState {
    case claimed
    case claimable
    case inProgress
    case locked

    var title: String {
        switch self {
        case .claimed: return "Claimed"
        case .claimable: return "Claimable"
        case .inProgress: return "In progress"
        case .locked: return "Locked"
        }
    }

    var symbol: String {
        switch self {
        case .claimed: return "checkmark.circle.fill"
        case .claimable: return "sparkles"
        case .inProgress: return "chart.bar.fill"
        case .locked: return "lock.fill"
        }
    }

    var tint: Color {
        switch self {
        case .claimed: return .green
        case .claimable: return .orange
        case .inProgress: return .blue
        case .locked: return .secondary
        }
    }

    var helpText: String {
        switch self {
        case .claimed: return "Reward already claimed"
        case .claimable: return "Reward ready to claim"
        case .inProgress: return "Reward currently being mined"
        case .locked: return "Reward not available yet"
        }
    }
}

private extension TimeInterval {
    var formattedHoursMinutes: String {
        let totalMinutes = max(Int(self / 60), 0)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m left"
        }

        return "\(minutes)m left"
    }

    var formattedRemaining: String {
        let totalMinutes = max(Int(self / 60), 0)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            return minutes > 0
                ? "\(hours)h \(minutes)m remaining"
                : "\(hours)h remaining"
        }

        return "\(minutes)m remaining"
    }
}

// MARK: - Steam ID Input Popover

private struct SteamIdInputPopover: View {
    let gameName: String
    @Binding var appId: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Set Steam App ID")
                .font(.headline)
            Text("Override artwork lookup for \"\(gameName)\"")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("App ID (e.g. 2073850)", text: $appId)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
            HStack {
                Button("Cancel", action: onCancel)
                Spacer()
                Button("Set") { onConfirm() }
                    .keyboardShortcut(.return)
                    .disabled(appId.trimmingCharacters(in: .whitespaces).isEmpty)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 300)
    }
}

// MARK: - Preview

#Preview("Drops List") {
    DropsListView()
        .environment(NavigationModel(clientId: "preview"))
        .frame(width: 700, height: 680)
}
