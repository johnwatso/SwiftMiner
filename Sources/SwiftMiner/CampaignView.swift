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
    @State private var gameExpansionOverrides: [String: Bool] = [:]
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
                                GameCampaignDeckCard(
                                    group: group,
                                    activityProvider: activity(for:),
                                    isExpanded: gameExpansionOverrides[group.id] ?? shouldExpandByDefault(group),
                                    onExpansionChange: { isExpanded in
                                        gameExpansionOverrides[group.id] = isExpanded
                                    },
                                    onSteamIdSet: { appId in
                                        await SteamArtworkService.shared.setManualAppId(for: group.gameName, appId: appId)
                                        await navigation.minerManager.dataCoordinator.clearSteamArtworkCache()
                                        await loadCampaignFeed()
                                    }
                                )
                                .transition(.opacity.combined(with: .scale(scale: 0.985)))
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

        return (activeGroups + endedGroups)
            .filter { group in
                if group.aggregateState == .unavailable {
                    return selectedFilters.contains(.ended)
                }
                if group.aggregateState == .actionRequired {
                    return selectedFilters.contains(.needsSetup)
                }
                return true
            }
            .sorted { lhs, rhs in
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
            return "No completed campaigns yet."
        }

        if selectedFilters == [.ended] {
            return "No ended campaigns yet."
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
        let claimedCountsByAccount = claimedRewardCountsByAccount()
        guard let leader = miners.max(by: { lhs, rhs in
            let lhsCount = claimedCountsByAccount[lhs.accountId] ?? lhs.dropsClaimed
            let rhsCount = claimedCountsByAccount[rhs.accountId] ?? rhs.dropsClaimed
            if lhsCount != rhsCount { return lhsCount < rhsCount }
            return lhs.displayName > rhs.displayName
        }) else { return nil }

        let leaderCount = claimedCountsByAccount[leader.accountId] ?? leader.dropsClaimed
        return (name: leader.displayName, count: leaderCount)
    }

    private func claimedRewardCountsByAccount() -> [String: Int] {
        var counts: [String: Int] = [:]
        for campaign in feedCampaigns {
            for account in campaign.accountStates {
                counts[account.accountId, default: 0] += account.claimedDropCount
            }
        }
        return counts
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
        // Needs setup must only contain active, live, and mineable/actionable campaigns
        guard campaign.startDate <= Date() else {
            return false
        }
        // It must NOT contain ended/expired campaigns
        guard !campaign.isExpired() && campaign.endDate > Date() else {
            return false
        }
        // It must NOT contain completed/fully claimed campaigns
        guard !campaign.isCompleted else {
            return false
        }
        // It must have obtainable rewards remaining
        guard campaign.hasObtainableRewards else {
            return false
        }
        // It must require account linking or setup
        return isBlockedCampaign(campaign, activity: activity)
    }

    private func matchesUpcomingFilter(_ campaign: CampaignViewData, activity: CampaignActivitySnapshot) -> Bool {
        guard campaign.startDate > Date() else {
            return false
        }
        return !matchesCompletedFilter(campaign, activity: activity) && !matchesEndedFilter(campaign, activity: activity)
    }

    private func matchesCompletedFilter(_ campaign: CampaignViewData, activity: CampaignActivitySnapshot) -> Bool {
        return !campaign.isExpired() && (activity.state == .claimed || campaign.isCompleted)
    }

    private func matchesEndedFilter(_ campaign: CampaignViewData, activity: CampaignActivitySnapshot) -> Bool {
        return campaign.isExpired()
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
        if matchesEndedFilter(campaign, activity: activity) {
            filters.insert(.ended)
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

        if isExpired {
            state = .expired
        } else if campaign.startDate > Date() {
            state = .ready
        } else if combinedProgress >= 0.995 || campaign.isCompleted {
            state = .claimed
        } else if (!campaign.isAccountConnected || !blockedAccounts.isEmpty) && campaign.hasObtainableRewards {
            state = .blocked
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

    private func shouldExpandByDefault(_ group: GameAggregate) -> Bool {
        guard group.aggregateState == .inProgress || group.aggregateState == .actionRequired else {
            return false
        }

        if group.claimableRewardCount > 0 {
            return true
        }

        for item in group.campaigns {
            let snapshot = activity(for: item.campaign)
            if !snapshot.blockedAccounts.isEmpty || !snapshot.needsAuthAccounts.isEmpty {
                return true
            }
            if minerSyncIssueCount(for: item.campaign, activity: snapshot) > 0 {
                return true
            }
        }

        return false
    }

    private func minerSyncIssueCount(for campaign: CampaignViewData, activity: CampaignActivitySnapshot) -> Int {
        let activeAccounts = Set(activity.activeMiners.map(\.accountId))
        return campaign.accountStates.filter { account in
            switch account.miningStatus {
            case .blocked, .needsAuth:
                return true
            case .mining:
                return !activeAccounts.isEmpty && !activeAccounts.contains(account.accountId)
            case .ready, .idle:
                return activity.state == .active || activity.state == .inProgress
            case .claimed:
                return false
            }
        }.count
    }
}



// MARK: - Grouped Game Card
private struct GameCampaignDeckCard: View {
    let group: GameAggregate
    let activityProvider: (CampaignViewData) -> CampaignActivitySnapshot
    let isExpanded: Bool // Kept for compatibility, but not used since we have clean popover inspector
    let onExpansionChange: (Bool) -> Void // Kept for compatibility
    var onSteamIdSet: ((String) async -> Void)?

    @State private var isHovered = false
    @State private var showingSteamIdPopover = false
    @State private var showingInspectorPopover = false
    @State private var steamIdDraft = ""
    @State private var extractedArtworkTint: Color?

    private var cardState: CampaignCardState {
        group.aggregateState.asCampaignCardState
    }

    private var isActive: Bool {
        group.aggregateState == .inProgress
    }

    private var isFinishedOrEnded: Bool {
        group.aggregateState == .completed || group.aggregateState == .unavailable
    }

    private var campaignGame: Game {
        let firstCampaign = group.campaigns.first?.campaign
        return Game(id: firstCampaign?.gameId ?? "", name: group.gameName, boxArtURL: group.artworkURL)
    }

    private var supportsSteamArtwork: Bool {
        let firstCampaign = group.campaigns.first?.campaign
        return SteamArtworkService.supportsSteamArtwork(forGameName: group.gameName, gameId: firstCampaign?.gameId)
    }

    private var totalRewardCount: Int {
        group.campaigns.reduce(0) { $0 + max($1.campaign.totalDrops, $1.campaign.drops.count) }
    }

    private var claimedRewardCount: Int {
        group.campaigns.reduce(0) { $0 + min(activityProvider($1.campaign).claimedRewardCount, max($1.campaign.totalDrops, $1.campaign.drops.count)) }
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

    private var activeMinerCount: Int {
        Set(group.campaigns.flatMap { activityProvider($0.campaign).activeMiners.map(\.accountId) }).count
    }

    private var completedCurrentRewardMinerCount: Int {
        let activeCampaigns = group.campaigns.filter { !$0.campaign.isExpired() }
        guard let currentCampaign = activeCampaigns.first(where: { activityProvider($0.campaign).state == .active || activityProvider($0.campaign).state == .inProgress })?.campaign
            ?? activeCampaigns.first?.campaign
        else { return 0 }

        return currentCampaign.accountStates.filter { account in
            account.miningStatus == .claimed
                || account.claimedDropCount > 0
                || (account.progressFraction ?? 0) >= 0.995
        }.count
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

    private var eligibleMiners: [AccountState] {
        minerAccountStates.filter { account in
            if Settings.shared.excludedGames.contains(where: { $0.localizedCaseInsensitiveCompare(group.gameName) == .orderedSame }) {
                return false
            }
            let gameId = group.campaigns.first?.campaign.gameId ?? ""
            if Settings.shared.isIgnoringAccountLinkWarnings(for: account.accountId, gameId: gameId) ||
               Settings.shared.isIgnoringAccountLinkWarnings(for: account.accountId, gameId: "all") {
                return false
            }
            let campaignId = group.campaigns.first?.campaign.id ?? ""
            if Settings.shared.isIgnoringSubscriptionRequiredWarnings(for: account.accountId, campaignId: campaignId) {
                return false
            }
            return true
        }
    }

    private var eligibleMinerCount: Int {
        eligibleMiners.count
    }

    private var campaignExpiryText: String {
        guard let firstCampaign = group.campaigns.first?.campaign else { return "" }
        if firstCampaign.endDate <= Date() {
            return "Ended"
        }
        let remaining = firstCampaign.endDate.timeIntervalSince(Date())
        return remaining.formattedRemaining
    }

    private var aggregateStatusSummary: CardStatusSummary {
        let activeCount = activeMinerCount
        let claimedCount = completedCurrentRewardMinerCount
        let totalCount = minerAccountStates.count

        if activeCount > 0 {
            let title = activeCount == 1 ? "1 Miner Active" : "\(activeCount) Miners Active"
            return CardStatusSummary(title: title, icon: "dot.radiowaves.left.and.right")
        }
        if claimedCount == totalCount && totalCount > 0 {
            return CardStatusSummary(title: "Completed", icon: "checkmark.circle.fill")
        }
        if claimedCount > 0 {
            let title = claimedCount == 1 ? "1 Miner Completed" : "\(claimedCount) Miners Completed"
            return CardStatusSummary(title: title, icon: "checkmark.circle.fill")
        }
        if group.aggregateState == .actionRequired {
            return CardStatusSummary(title: "Needs Setup", icon: "exclamationmark.triangle.fill")
        }
        if group.aggregateState == .unavailable {
            return CardStatusSummary(title: "Campaign Ended", icon: "clock.badge.exclamationmark")
        }
        return CardStatusSummary(title: "Looking for Streams", icon: "antenna.radiowaves.left.and.right")
    }

    private var aggregateStatusColor: Color {
        switch group.aggregateState {
        case .inProgress:
            return .green
        case .actionRequired:
            return .orange
        case .completed:
            return .green
        case .unavailable:
            return .secondary
        case .ready:
            return .secondary
        }
    }

    private var displayDrops: [DropViewData] {
        group.campaigns.flatMap { $0.campaign.drops }
    }

    var body: some View {
        let drops = displayDrops
        let status = aggregateStatusSummary

        HStack(alignment: .center, spacing: 16) {
            // LEFT ARTWORK (Anchors the cluster, prominent 120x160 size)
            GameArtworkCard(url: group.artworkURL, tint: group.aggregateState.tint)

            // CONTENT CLUSTER (titles, metadata, and reward shelf sit together)
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(group.gameName)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if let firstCampaign = group.campaigns.first?.campaign {
                        Text(firstCampaign.campaignName)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    // Compact Metadata Row
                    HStack(spacing: 12) {
                        HStack(spacing: 4) {
                            Image(systemName: "gift.fill")
                            Text("\(totalRewardCount) \(totalRewardCount == 1 ? "reward" : "rewards")")
                        }
                        
                        if !campaignExpiryText.isEmpty {
                            HStack(spacing: 4) {
                                Image(systemName: "calendar")
                                Text(campaignExpiryText)
                            }
                        }
                        
                        let count = eligibleMinerCount
                        if count > 0 {
                            HStack(spacing: 4) {
                                Image(systemName: "person.2.fill")
                                Text("\(count) eligible")
                            }
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                // Reward Shelf directly beneath metadata
                if !drops.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 8) {
                            ForEach(drops) { drop in
                                BeautifulRewardCard(drop: drop)
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 2)
                    }
                    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
                } else {
                    Text("No rewards available")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 64)
        }
        .padding(.leading, 16)
        .padding(.trailing, 16)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 8) {
                // Compact Semantic Status Pill
                HStack(spacing: 4) {
                    AnimatedStatusIcon(symbol: status.icon, color: aggregateStatusColor, size: 10, weight: .semibold)
                    Text(status.title)
                        .font(.system(size: 10, weight: status.title == "Completed" ? .medium : .semibold))
                }
                .foregroundStyle(aggregateStatusColor.opacity(0.85))
                .padding(.horizontal, 8)
                .padding(.vertical, 4.5)
                .background(aggregateStatusColor.opacity(0.06), in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(aggregateStatusColor.opacity(0.15), lineWidth: 1)
                }
                .saturation(status.title == "Completed" ? 0.65 : 1.0)
                .opacity(status.title == "Completed" ? 0.85 : 1.0)

                Button {
                    showingInspectorPopover = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(.regularMaterial.opacity(0.65), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Show miner operational details")
                .popover(isPresented: $showingInspectorPopover, arrowEdge: .bottom) {
                    CampaignMinerInspectorPopover(gameName: group.gameName, miners: eligibleMiners)
                }
            }
            .padding(.top, 14)
            .padding(.trailing, 14)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(cardState.borderTint.opacity(isActive ? 0.75 : 0.40), lineWidth: isActive ? 1.0 : 0.6)
        }
        .shadow(
            color: isActive
                ? group.aggregateState.tint.opacity(isHovered ? 0.12 : 0.08)
                : .black.opacity(isHovered ? 0.08 : 0.04),
            radius: isHovered ? 8 : (isActive ? 6 : 3),
            y: isHovered ? 4 : (isActive ? 3 : 1)
        )
        .animation(.easeInOut(duration: 0.18), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
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
                gameName: group.gameName,
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
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(.thinMaterial.opacity(isActive ? 0.98 : 0.94))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                cardState.tint.opacity(isActive ? 0.11 : (isFinishedOrEnded ? 0.025 : 0.055)),
                                Color.white.opacity(isActive ? 0.055 : 0.025),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
    }
}

private struct GameArtworkCard: View {
    let url: URL?
    let tint: Color

    var body: some View {
        CampaignCardArtwork(url: url, tint: tint)
            .frame(width: 120, height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
    }
}

private struct BeautifulRewardCard: View {
    let drop: DropViewData
    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .center) {
            // Main image thumbnail
            Group {
                if let url = drop.imageURL?.highResolutionArtworkURL {
                    AsyncImage(url: url) { image in
                        image
                            .resizable()
                            .interpolation(.high)
                            .scaledToFill()
                    } placeholder: {
                        placeholderArtwork
                    }
                } else {
                    placeholderArtwork
                }
            }
            .frame(width: 76, height: 76)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .shadow(color: .black.opacity(isHovered ? 0.15 : 0.10), radius: isHovered ? 6 : 4, y: isHovered ? 3 : 2)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isHovered ? .white.opacity(0.20) : .white.opacity(0.08), lineWidth: 1)
            }

            // Completion checkmark (Frosted Glass Outer Circle, Apple Photos selection style)
            if drop.isClaimed {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 18, height: 18)
                        .shadow(color: .black.opacity(0.12), radius: 2)
                    
                    Circle()
                        .fill(Color.green)
                        .frame(width: 13, height: 13)
                    
                    Image(systemName: "checkmark")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 76, height: 76, alignment: .topTrailing)
                .padding(4)
            } else if drop.isClaimable {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 18, height: 18)
                        .shadow(color: .black.opacity(0.12), radius: 2)
                    
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 13, height: 13)
                    
                    Image(systemName: "sparkles")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 76, height: 76, alignment: .topTrailing)
                .padding(4)
            }

            // Progress bar
            if drop.progress > 0 && drop.progress < 1.0 {
                GeometryReader { geo in
                    VStack {
                        Spacer()
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(.black.opacity(0.45))
                                .frame(height: 3)
                            
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.blue)
                                .frame(width: geo.size.width * drop.progress, height: 3)
                        }
                    }
                }
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            // Duration Overlay Badge (Bottom Right)
            Text("\(drop.requiredMinutes)m")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 4.5)
                .padding(.vertical, 2.5)
                .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 4.5, style: .continuous))
                .frame(width: 76, height: 76, alignment: .bottomTrailing)
                .padding(4)
        }
        .scaleEffect(isHovered ? 1.03 : 1.0)
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .popover(isPresented: $isHovered, arrowEdge: .top) {
            BeautifulRewardHoverCard(drop: drop)
        }
    }

    private var statusTitle: String {
        if drop.isClaimed { return "Claimed" }
        if drop.isClaimable { return "Ready to Claim" }
        if drop.progress > 0 { return "Mining (\(Int(drop.progress * 100))%)" }
        return "Locked"
    }

    private var placeholderArtwork: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.thinMaterial)
            .overlay {
                Image(systemName: rewardIcon)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.secondary)
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

private struct CardStatusSummary {
    let title: String
    let icon: String
}

// MARK: - Premium Frosted Hover Card Popover
private struct BeautifulRewardHoverCard: View {
    let drop: DropViewData

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                // Tiny reward artwork preview!
                if let url = drop.imageURL?.highResolutionArtworkURL {
                    AsyncImage(url: url) { image in
                        image
                            .resizable()
                            .scaledToFill()
                    } placeholder: {
                        RoundedRectangle(cornerRadius: 6).fill(.secondary.opacity(0.2))
                    }
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(drop.name)
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    
                    Text(statusText)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(statusColor)
                }
            }
            
            if let desc = drop.description, !desc.isEmpty {
                Text(desc)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            HStack(spacing: 4) {
                Image(systemName: "clock")
                    .font(.system(size: 9))
                Text("Required: \(drop.requiredMinutes) min")
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundStyle(.secondary.opacity(0.8))
        }
        .padding(12)
        .frame(width: 200)
    }

    private var statusText: String {
        if drop.isClaimed { return "Claimed" }
        if drop.isClaimable { return "Ready to Claim" }
        if drop.progress > 0 { return "Mining (\(Int(drop.progress * 100))%)" }
        return "Locked"
    }

    private var statusColor: Color {
        if drop.isClaimed { return .green }
        if drop.isClaimable { return .orange }
        if drop.progress > 0 { return .blue }
        return .secondary
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
        let totalSeconds = max(self, 0)
        let totalDays = Int(totalSeconds / 86400)
        
        if totalDays == 0 {
            let hours = Int(totalSeconds / 3600)
            let minutes = Int((totalSeconds.truncatingRemainder(dividingBy: 3600)) / 60)
            if hours > 0 {
                return minutes > 0 ? "\(hours)h \(minutes)m left" : "\(hours)h left"
            }
            return "\(max(minutes, 1))m left"
        }
        
        let weeks = totalDays / 7
        let days = totalDays % 7
        
        if weeks > 0 {
            if days > 0 {
                return "\(weeks) \(weeks == 1 ? "week" : "weeks") and \(days) \(days == 1 ? "day" : "days") left"
            } else {
                return "\(weeks) \(weeks == 1 ? "week" : "weeks") left"
            }
        } else {
            return "\(days) \(days == 1 ? "day" : "days") left"
        }
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

struct CampaignActivitySnapshot {
    let state: CampaignCardState
    let activeMiners: [MinerManager.ManagedMiner]
    let claimedAccounts: [AccountState]
    let needsAuthAccounts: [AccountState]
    let blockedAccounts: [AccountState]
    let claimableDropCount: Int
    let claimedRewardCount: Int
    let remainingRewardCount: Int
}

enum CampaignCardState: String {
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
        case .blocked: return "Needs Setup"
        case .active: return "Mining Active"
        case .inProgress: return "Mining Active"
        case .claimable: return "Claiming Rewards"
        case .ready: return "Up to Date"
        case .waiting: return "Looking for Streams"
        case .claimed: return "Completed"
        case .expired: return "Ended"
        case .idle: return "Ready to Mine"
        }
    }

    var symbol: String {
        switch self {
        case .blocked: return "exclamationmark.triangle.fill"
        case .active: return "dot.radiowaves.left.and.right"
        case .inProgress: return "dot.radiowaves.left.and.right"
        case .claimable: return "gift.fill"
        case .ready: return "checkmark.circle.fill"
        case .waiting: return "antenna.radiowaves.left.and.right"
        case .claimed: return "checkmark.circle.fill"
        case .expired: return "clock.badge.exclamationmark"
        case .idle: return "checkmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .blocked: return .orange
        case .active: return .green
        case .inProgress: return .blue
        case .claimable: return .secondary
        case .ready: return .green
        case .waiting: return .secondary
        case .claimed: return .green
        case .expired: return .orange
        case .idle: return .green
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

struct DashboardMetricCard: View {
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

struct CampaignMinerInspectorPopover: View {
    let gameName: String
    let miners: [AccountState]
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "personalhotspot")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text(gameName)
                    .font(.headline.weight(.semibold))
            }
            .padding(.bottom, 2)

            if miners.isEmpty {
                Text("No actionable miners")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                VStack(spacing: 6) {
                    ForEach(miners) { account in
                        HStack(spacing: 8) {
                            Image(systemName: statusIcon(for: account.miningStatus))
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(statusColor(for: account.miningStatus))
                                .frame(width: 18)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(navigation.minerManager.displayName(forAccountId: account.accountId, fallback: account.username))
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.primary)
                                
                                Text(statusLabel(for: account.miningStatus))
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 8)

                            if let progress = account.progressFraction, progress > 0 && progress < 0.995 {
                                Text("\(Int(progress * 100))%")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundStyle(.blue)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 8)
                        .background(.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 220)
    }

    private func statusIcon(for status: AccountMiningStatus) -> String {
        switch status {
        case .mining: return "play.circle.fill"
        case .claimed: return "checkmark.circle.fill"
        case .ready, .idle: return "pause.circle.fill"
        case .blocked: return "link.badge.plus"
        case .needsAuth: return "exclamationmark.triangle.fill"
        }
    }

    private func statusColor(for status: AccountMiningStatus) -> Color {
        switch status {
        case .mining:
            return .green
        case .claimed:
            return .green
        case .ready, .idle:
            return .secondary
        case .blocked:
            return .orange
        case .needsAuth:
            return .red
        }
    }

    private func statusLabel(for status: AccountMiningStatus) -> String {
        switch status {
        case .mining:
            return "Watching"
        case .claimed:
            return "Claimed"
        case .ready, .idle:
            return "Waiting"
        case .blocked:
            return "Needs Link"
        case .needsAuth:
            return "Error"
        }
    }
}

struct CampaignCardArtwork: View {
    let url: URL?
    let tint: Color

    private var resolvedURL: URL? {
        url?.highResolutionArtworkURL
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .top) {
                if let resolvedURL {
                    AsyncImage(url: resolvedURL) { image in
                        image
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                    } placeholder: {
                        placeholder
                    }
                } else {
                    placeholder
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
    }

    private var placeholder: some View {
        LinearGradient(
            colors: [tint.opacity(0.82), tint.opacity(0.38), Color.black.opacity(0.52)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

struct CampaignArtworkIcon: View {
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

actor CampaignArtworkTintSampler {
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

@inline(__always) private func clamp01(_ val: Double) -> Double {
    min(max(val, 0.0), 1.0)
}

struct ArtworkRGB: Sendable, Hashable {
    let red: Double
    let green: Double
    let blue: Double

    var color: Color {
        Color(red: clamp01(red), green: clamp01(green), blue: clamp01(blue))
    }

    var softenedForGlass: ArtworkRGB {
        let rWeight = red * 0.299
        let gWeight = green * 0.587
        let bWeight = blue * 0.114
        let luminance = clamp01(rWeight + gWeight + bWeight)
        
        let desaturation: Double = 0.38
        let whiteMix: Double = 0.22

        let rSoft = red * (1.0 - desaturation)
        let gSoft = green * (1.0 - desaturation)
        let bSoft = blue * (1.0 - desaturation)
        
        let lumSoft = luminance * desaturation

        let softenedRed = clamp01(rSoft + lumSoft)
        let softenedGreen = clamp01(gSoft + lumSoft)
        let softenedBlue = clamp01(bSoft + lumSoft)

        let finalRed = (softenedRed * (1.0 - whiteMix)) + whiteMix
        let finalGreen = (softenedGreen * (1.0 - whiteMix)) + whiteMix
        let finalBlue = (softenedBlue * (1.0 - whiteMix)) + whiteMix

        return ArtworkRGB(
            red: clamp01(finalRed),
            green: clamp01(finalGreen),
            blue: clamp01(finalBlue)
        )
    }
}

extension GameAggregateState {
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
    
    var tint: Color {
        switch self {
        case .actionRequired: return .orange
        case .inProgress: return .green
        case .ready: return .secondary
        case .completed: return .green
        case .unavailable: return .orange
        }
    }
}

extension URL {
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

// MARK: - Preview

#Preview("Drops List") {
    DropsListView()
        .environment(NavigationModel(clientId: "preview"))
        .frame(width: 700, height: 680)
}
