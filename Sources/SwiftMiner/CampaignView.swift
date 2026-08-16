import SwiftUI
import SwiftMinerCore
import CoreImage

// MARK: - Drops List View

struct DropsListView: View {
    @Environment(NavigationModel.self) private var navigation
    @State private var campaigns: [CampaignViewData] = []
    @State private var isRefreshing = false
    @State private var hasLoadedInitialCampaignFeed = false
    @State private var searchText: String = ""
    @State private var selectedMinerFilterId: String = DropsListView.allMinersFilterId
    @State private var visibleGroupLimit = 24
    @AppStorage("preferSteamArtwork", store: Settings.appStorageStore) private var preferSteamArtwork: Bool = false
    private var settings: Settings { .shared }

    fileprivate static let allMinersFilterId = "__all_miners__"

    private var selectedFilters: Set<DropFilter> {
        get { settings.selectedDropsFilters }
        nonmutating set { settings.selectedDropsFilters = newValue }
    }

    private var miners: [MinerManager.ManagedMiner] { navigation.minerManager.miners }
    private var hasAccounts: Bool { !miners.isEmpty }
    private var selectedMinerAccountId: String? {
        selectedMinerFilterId == Self.allMinersFilterId ? nil : selectedMinerFilterId
    }
    private var availableCampaigns: [CampaignViewData] {
        campaigns.isEmpty
            ? navigation.minerManager.dataCoordinator.lastKnownAllCampaigns
            : campaigns
    }
    private var accountSignature: String {
        miners
            .map { "\($0.id):\($0.accountId)" }
            .sorted()
            .joined(separator: "|")
    }

    var body: some View {
        let context = makeRenderContext()

        Group {
            if !hasAccounts {
                noAccountsState
            } else if availableCampaigns.isEmpty && (!hasLoadedInitialCampaignFeed || isRefreshing) {
                loadingSplashState
            } else if availableCampaigns.isEmpty {
                contextualStandbyState(
                    title: "No campaigns yet",
                    message: "No campaigns yet",
                    description: "SwiftMiner will show campaigns here once your miners sync their latest Twitch drops data."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        dashboardHeader(context)
                        searchAndMinerControls
                        filterChipsRow

                        if !waitingForStreamTargets.isEmpty {
                            waitingForStreamBanner(waitingForStreamTargets)
                        }

                        if let message = contextualBannerMessage {
                            fallbackBanner(message)
                        }

                        if context.renderedCampaigns.isEmpty {
                            fallbackBanner(emptyFilterMessage)
                        } else {
                            ForEach(context.visibleGroupedCampaigns) { group in
                                GameCampaignDeckCard(
                                    group: group,
                                    selectedAccountId: selectedMinerAccountId,
                                    activityProvider: { campaign in
                                        context.activityByCampaignId[campaign.id] ?? activity(for: campaign)
                                    },
                                    onSteamIdSet: { appId in
                                        await SteamArtworkService.shared.setManualAppId(for: group.gameName, appId: appId)
                                        await navigation.minerManager.dataCoordinator.clearSteamArtworkCache()
                                        await loadCampaignFeed()
                                    }
                                )
                                .transition(.opacity.combined(with: .scale(scale: 0.985)))
                            }

                            if context.groupedCampaigns.count > visibleGroupLimit {
                                Color.clear
                                    .frame(height: 1)
                                    .onAppear {
                                        visibleGroupLimit += 24
                                    }
                            }
                        }
                    }
                    .padding(24)
                }
                .animation(.easeInOut(duration: 0.28), value: context.renderSignature)
            }
        }
        .navigationTitle("Drops")
        .task(id: accountSignature) {
            applyRequestedDropsFilter()
            if campaigns.isEmpty {
                campaigns = navigation.minerManager.dataCoordinator.lastKnownAllCampaigns
            }
            hasLoadedInitialCampaignFeed = !availableCampaigns.isEmpty
            await loadCampaignFeed()
            hasLoadedInitialCampaignFeed = true
            isRefreshing = navigation.refreshDropsInBackground()
        }
        .onReceive(NotificationCenter.default.publisher(for: .dropsCampaignsDidUpdate)) { _ in
            Task { @MainActor in
                await loadCampaignFeed(recomposeCachedFeed: true)
                isRefreshing = navigation.isDropsBackgroundRefreshRunning
            }
        }
        .onChange(of: navigation.isDropsBackgroundRefreshRunning) { _, running in
            isRefreshing = running
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
        .onChange(of: selectedFilters) { _, _ in resetVisibleGroups() }
        .onChange(of: selectedMinerFilterId) { _, _ in resetVisibleGroups() }
        .onChange(of: searchText) { _, _ in resetVisibleGroups() }
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

    private var loadingSplashState: some View {
        DropsLoadingSplash()
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

    private struct WaitingForStreamTarget: Identifiable {
        let minerID: String
        let minerName: String
        let campaignID: String
        let campaignName: String
        let gameName: String
        let checkedAt: Date

        var id: String { "\(minerID):\(campaignID)" }
    }

    /// The engine deliberately clears its watch session while it waits for a suitable channel.
    /// Keep the last verified no-channel probe visible here so a completed campaign for the
    /// same game cannot conceal the campaign the miner is actually trying to resume.
    private var waitingForStreamTargets: [WaitingForStreamTarget] {
        let now = Date()

        return miners.compactMap { miner in
            guard miner.isRunning,
                  miner.status == .waitingForStream,
                  selectedMinerAccountId == nil || miner.accountId == selectedMinerAccountId,
                  let availability = miner.gameChannelAvailability.values
                    .filter({ !$0.hasEligibleChannel && $0.isFresh(at: now) && $0.campaignId != nil })
                    .max(by: { $0.checkedAt < $1.checkedAt }),
                  let campaignID = availability.campaignId,
                  let campaign = miner.allCampaigns.first(where: { $0.id == campaignID })
            else {
                return nil
            }

            return WaitingForStreamTarget(
                minerID: miner.id,
                minerName: miner.displayName,
                campaignID: campaignID,
                campaignName: campaign.name,
                gameName: campaign.game.name,
                checkedAt: availability.checkedAt
            )
        }
        .sorted { $0.checkedAt > $1.checkedAt }
    }

    @ViewBuilder
    private func waitingForStreamBanner(_ targets: [WaitingForStreamTarget]) -> some View {
        let primary = targets[0]

        HStack(alignment: .center, spacing: 11) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 3) {
                Text("Waiting on \(primary.campaignName)")
                    .font(.subheadline.weight(.semibold))

                Text(waitingForStreamDetail(for: targets))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: GlassRadius.medium, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: GlassRadius.medium, style: .continuous)
                .stroke(Color.orange.opacity(0.20), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    private func waitingForStreamDetail(for targets: [WaitingForStreamTarget]) -> String {
        guard let primary = targets.first else { return "" }

        if targets.count == 1 {
            return "\(primary.minerName) is checking live \(primary.gameName) streams for this campaign."
        }

        return "\(primary.minerName) and \(targets.count - 1) other \(targets.count == 2 ? "miner" : "miners") are checking live streams for their current campaigns."
    }

    private var filterChipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(DropFilter.allCases) { option in
                    let isSelected = selectedFilters.contains(option)
                    Button {
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
    }

    // MARK: - Data

    private func makeRenderContext() -> DropsListRenderContext {
        let now = Date()
        let activeMinerCandidates = miners.filter { $0.status == .watching || $0.status == .claiming }
        let customizedCampaigns = availableCampaigns.map(applyingCustomArtwork)
        let activityByCampaignId = activitySnapshots(
            for: customizedCampaigns,
            activeMinerCandidates: activeMinerCandidates,
            now: now
        )

        let feedCampaigns = customizedCampaigns
            .filter { shouldIncludeInDropsFeed($0, now: now) }
            .sorted {
                campaignSort(lhs: $0, rhs: $1, activityByCampaignId: activityByCampaignId)
            }

        let renderedCampaigns = feedCampaigns.filter { campaign in
            guard let activity = activityByCampaignId[campaign.id] else { return false }
            return matchesSelectedFilters(campaign, activity: activity, now: now)
                && matchesSelectedMiner(campaign)
                && matchesSearch(campaign)
        }

        let groupedCampaigns = groupedCampaigns(from: renderedCampaigns, now: now)
        let visibleGroupedCampaigns = Array(groupedCampaigns.prefix(visibleGroupLimit))
        let rewardsClaimedCount = feedCampaigns.reduce(0) { total, campaign in
            total + (activityByCampaignId[campaign.id]?.claimedRewardCount ?? 0)
        }

        let renderSignature = feedCampaigns.map { campaign in
            let snapshot = activityByCampaignId[campaign.id]
            return "\(campaign.id)-\(snapshot?.state.rawValue ?? "unknown")-\(snapshot?.claimableDropCount ?? 0)-\(snapshot?.claimedRewardCount ?? 0)"
        }

        return DropsListRenderContext(
            feedCampaigns: feedCampaigns,
            renderedCampaigns: renderedCampaigns,
            groupedCampaigns: groupedCampaigns,
            visibleGroupedCampaigns: visibleGroupedCampaigns,
            activityByCampaignId: activityByCampaignId,
            renderSignature: renderSignature,
            // "In motion" means a miner is watching it right now, which is not
            // the same as the card state being `.active` — the state ladder
            // resolves `.claimed`/`.blocked` first, so a campaign one account
            // has finished reads as claimed even while another account mines
            // it. Counting active miners directly keeps this honest.
            activeMiningCampaignCount: feedCampaigns.filter {
                !(activityByCampaignId[$0.id]?.activeMiners.isEmpty ?? true)
            }.count,
            rewardsClaimedCount: rewardsClaimedCount,
            topClaimedGame: topClaimedGame(in: feedCampaigns, activityByCampaignId: activityByCampaignId),
            mostActiveMiner: mostActiveMiner(in: feedCampaigns)
        )
    }

    private func shouldIncludeInDropsFeed(_ campaign: CampaignViewData, now: Date) -> Bool {
        guard !isExcludedCampaign(campaign) else { return false }
        if campaign.relevance != .irrelevant {
            return true
        }

        // Completed is a history view. Once a campaign has completed during
        // its current window, retain it here even when it has fallen outside
        // the curated mining feed. This keeps the native and web dashboards
        // consistent and lets people see every campaign their account has
        // completed, not only games currently selected for mining.
        if selectedFilters.contains(.completed),
           !campaign.isExpired(now: now),
           (campaign.combinedProgressFraction >= 0.995 || campaign.isCompleted) {
            return true
        }

        if DropsCampaignFilterRules.preservesCampaignOutsideCuratedFeed(
            campaign,
            selectedFilters: selectedFilters,
            now: now
        ) {
            return true
        }

        // A game the user prioritised stays in the feed for its whole run, even
        // once every reward is claimed. Previously the obtainable-rewards gate
        // made a prioritised campaign vanish the moment it completed, which
        // reads as data loss rather than as "finished" — the filter chips are
        // what should decide where it lands, not whether it appears at all.
        guard isPrioritisedCampaign(campaign) else { return false }
        return campaign.startDate <= now && campaign.endDate > now
    }

    private func isPrioritisedCampaign(_ campaign: CampaignViewData) -> Bool {
        let gameId = campaign.gameId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let gameName = campaign.gameName.trimmingCharacters(in: .whitespacesAndNewlines)
        let comparableName = comparableGameName(gameName)

        if settings.gamePreferences.contains(where: { preference in
            guard preference.state == .preferred else { return false }
            let idMatches = !gameId.isEmpty && preference.gameId == gameId
            let nameMatches = comparableGameName(preference.gameName) == comparableName
            return idMatches || nameMatches
        }) {
            return true
        }

        let priorityNames = settings.priorityGames + miners.flatMap(\.priorityGames)
        return priorityNames.contains { comparableGameName($0) == comparableName }
    }

    private func comparableGameName(_ value: String) -> String {
        value
            .lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private func activitySnapshots(
        for campaigns: [CampaignViewData],
        activeMinerCandidates: [MinerManager.ManagedMiner],
        now: Date
    ) -> [String: CampaignActivitySnapshot] {
        var snapshots: [String: CampaignActivitySnapshot] = [:]
        snapshots.reserveCapacity(campaigns.count)

        for campaign in campaigns {
            snapshots[campaign.id] = activity(
                for: campaign,
                activeMinerCandidates: activeMinerCandidates,
                now: now
            )
        }

        return snapshots
    }

    private func matchesSelectedMiner(_ campaign: CampaignViewData) -> Bool {
        guard let selectedMinerAccountId else { return true }
        guard let miner = miners.first(where: { $0.accountId == selectedMinerAccountId }) else {
            return false
        }

        return DropsMinerCampaignFilter.matches(
            campaign,
            selectedAccountId: selectedMinerAccountId,
            currentCampaignId: miner.currentCampaignId,
            priorityGames: navigation.priorityGames(for: miner)
        )
    }

    private func matchesSearch(_ campaign: CampaignViewData) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let haystack = ([campaign.gameName, campaign.campaignName] + campaign.drops.map(\.name))
            .joined(separator: " ")
        return haystack.localizedCaseInsensitiveContains(query)
    }

    private func groupedCampaigns(from renderedCampaigns: [CampaignViewData], now: Date) -> [GameAggregate] {
        let activeCampaigns = renderedCampaigns.filter { !$0.isExpired(now: now) }
        let endedCampaigns = renderedCampaigns.filter { $0.isExpired(now: now) }

        let activeGroups = GameAggregateBuilder.buildDrops(from: activeCampaigns, now: now)
            .map { normalizedDisplayGroup($0, now: now) }
        let endedGroups = endedCampaigns.map { endedCampaignGroup(for: $0, now: now) }

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

    private func resetVisibleGroups() {
        visibleGroupLimit = 24
    }

    private func endedCampaignGroup(for campaign: CampaignViewData, now: Date) -> GameAggregate {
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
                    state: campaign.gameAggregateState(now: now)
                )
            ],
            aggregateState: campaign.gameAggregateState(now: now)
        )
    }

    private func normalizedDisplayGroup(_ group: GameAggregate, now: Date) -> GameAggregate {
        let campaigns = group.campaigns.map { item in
            GameAggregateCampaign(
                campaign: item.campaign,
                state: displayAggregateState(for: item.campaign, now: now)
            )
        }

        return GameAggregate(
            id: group.id,
            gameName: group.gameName,
            artworkURL: group.artworkURL,
            totalDrops: group.totalDrops,
            earnedDrops: group.earnedDrops,
            claimedDrops: group.claimedDrops,
            claimableDrops: group.claimableDrops,
            campaigns: campaigns,
            aggregateState: resolveDisplayAggregateState(from: campaigns.map(\.state))
        )
    }

    private func displayAggregateState(for campaign: CampaignViewData, now: Date) -> GameAggregateState {
        if campaign.isExpired(now: now) {
            return .unavailable
        }
        if campaign.isCompleted {
            return .completed
        }
        if campaign.startDate > now {
            return .ready
        }
        if campaign.accountStates.contains(where: { $0.miningStatus == .needsAuth || $0.miningStatus == .blocked }) && campaign.hasObtainableRewards {
            return .actionRequired
        }
        if campaign.combinedProgressFraction > 0 {
            return .inProgress
        }
        return .ready
    }

    private func resolveDisplayAggregateState(from states: [GameAggregateState]) -> GameAggregateState {
        if states.contains(.actionRequired) { return .actionRequired }
        if states.contains(.inProgress) { return .inProgress }
        if states.contains(.ready) { return .ready }
        if states.contains(.completed) { return .completed }
        return .unavailable
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
            return "No campaigns need setup right now."
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

    private func dashboardHeader(_ context: DropsListRenderContext) -> some View {
        HStack(spacing: 12) {
            DashboardMetricCard(
                title: "Active miners",
                value: "\(miners.filter { $0.status == .watching || $0.status == .claiming }.count)",
                detail: "\(context.activeMiningCampaignCount) \(context.activeMiningCampaignCount == 1 ? "campaign" : "campaigns") in motion",
                tint: .green,
                systemImage: "person.2.fill"
            )

            DashboardMetricCard(
                title: "Top game",
                value: context.topClaimedGame?.name ?? "None yet",
                detail: context.topClaimedGame.map { top in
                    "\(top.count) \(top.count == 1 ? "reward" : "rewards") claimed"
                } ?? "Claim a reward to crown a winner",
                tint: .orange,
                systemImage: "trophy.fill",
                isMuted: context.topClaimedGame == nil
            )

            DashboardMetricCard(
                title: "Rewards claimed",
                value: "\(context.rewardsClaimedCount)",
                detail: "\(context.feedCampaigns.count) \(context.feedCampaigns.count == 1 ? "campaign" : "campaigns") tracked",
                tint: .blue,
                systemImage: "checkmark.circle.fill"
            )

            if miners.count > 1, let leader = context.mostActiveMiner {
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

    private func mostActiveMiner(in feedCampaigns: [CampaignViewData]) -> (name: String, count: Int)? {
        guard miners.count > 1 else { return nil }
        let claimedCountsByAccount = claimedRewardCountsByAccount(in: feedCampaigns)
        guard let leader = miners.max(by: { lhs, rhs in
            let lhsCount = claimedCountsByAccount[lhs.accountId] ?? lhs.dropsClaimed
            let rhsCount = claimedCountsByAccount[rhs.accountId] ?? rhs.dropsClaimed
            if lhsCount != rhsCount { return lhsCount < rhsCount }
            return lhs.displayName > rhs.displayName
        }) else { return nil }

        let leaderCount = claimedCountsByAccount[leader.accountId] ?? leader.dropsClaimed
        return (name: leader.displayName, count: leaderCount)
    }

    private func claimedRewardCountsByAccount(in feedCampaigns: [CampaignViewData]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for campaign in feedCampaigns {
            for account in campaign.accountStates {
                counts[account.accountId, default: 0] += account.claimedDropCount
            }
        }
        return counts
    }

    private func topClaimedGame(
        in feedCampaigns: [CampaignViewData],
        activityByCampaignId: [String: CampaignActivitySnapshot]
    ) -> (name: String, count: Int)? {
        var counts: [String: Int] = [:]
        for campaign in feedCampaigns {
            let claimed = activityByCampaignId[campaign.id]?.claimedRewardCount ?? 0
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
    private func loadCampaignFeed(recomposeCachedFeed: Bool = false) async {
        guard hasAccounts else {
            campaigns = []
            isRefreshing = false
            resetVisibleGroups()
            return
        }

        // Seed from last-known cache immediately (synchronous) so the view
        // shows artwork-complete campaigns while any async refresh runs.
        let lastKnown = navigation.minerManager.dataCoordinator.lastKnownAllCampaigns
        if campaigns.isEmpty && !lastKnown.isEmpty {
            campaigns = lastKnown
        }

        guard recomposeCachedFeed || campaigns.isEmpty else {
            return
        }

        // Load ALL campaigns (not filtered) for the "All" tab
        let cached = await navigation.minerManager.dataCoordinator.allCampaigns(
            preferSteamArtwork: Settings.shared.preferSteamArtwork
        )
        if !cached.isEmpty {
            withAnimation(.easeInOut(duration: 0.2)) {
                campaigns = cached
                resetVisibleGroups()
            }
        }
    }

    private func activeMiners(
        for campaign: CampaignViewData,
        in activeMinerCandidates: [MinerManager.ManagedMiner]? = nil
    ) -> [MinerManager.ManagedMiner] {
        let candidates = activeMinerCandidates ?? miners.filter { $0.status == .watching || $0.status == .claiming }
        return candidates.filter { miner in
            if let id = miner.currentCampaignId {
                return id == campaign.id
            }

            return miner.currentCampaign == campaign.campaignName
        }
    }

    private func campaignSort(
        lhs: CampaignViewData,
        rhs: CampaignViewData,
        activityByCampaignId: [String: CampaignActivitySnapshot]
    ) -> Bool {
        let lhsActivity = activityByCampaignId[lhs.id] ?? activity(for: lhs)
        let rhsActivity = activityByCampaignId[rhs.id] ?? activity(for: rhs)

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

    private func matchesActiveFilter(_ campaign: CampaignViewData, activity: CampaignActivitySnapshot, now: Date) -> Bool {
        guard !matchesCompletedFilter(campaign, activity: activity, now: now) else {
            return false
        }
        guard !isBlockedCampaign(campaign, activity: activity) else {
            return false
        }

        guard campaign.startDate <= now, campaign.endDate > now else {
            return false
        }

        switch activity.state {
        case .active, .inProgress, .claimable, .ready, .waiting, .idle:
            return true
        case .blocked, .claimed, .expired:
            return false
        }
    }

    private func matchesNeedsSetupFilter(_ campaign: CampaignViewData, now: Date) -> Bool {
        DropsCampaignFilterRules.matchesNeedsSetup(campaign, now: now)
    }

    private func matchesUpcomingFilter(_ campaign: CampaignViewData, activity: CampaignActivitySnapshot, now: Date) -> Bool {
        guard campaign.startDate > now else {
            return false
        }
        return !matchesCompletedFilter(campaign, activity: activity, now: now) && !matchesEndedFilter(campaign, activity: activity, now: now)
    }

    private func matchesCompletedFilter(_ campaign: CampaignViewData, activity: CampaignActivitySnapshot, now: Date) -> Bool {
        return !campaign.isExpired(now: now) && (activity.state == .claimed || campaign.isCompleted)
    }

    private func matchesEndedFilter(_ campaign: CampaignViewData, activity: CampaignActivitySnapshot, now: Date) -> Bool {
        return campaign.isExpired(now: now)
    }

    private func isBlockedCampaign(_ campaign: CampaignViewData, activity: CampaignActivitySnapshot) -> Bool {
        !activity.needsAuthAccounts.isEmpty || !activity.blockedAccounts.isEmpty
    }

    private func filters(for campaign: CampaignViewData, activity: CampaignActivitySnapshot, now: Date) -> Set<DropFilter> {
        if matchesNeedsSetupFilter(campaign, now: now) {
            return [.needsSetup]
        }

        var filters: Set<DropFilter> = []
        if matchesActiveFilter(campaign, activity: activity, now: now) {
            filters.insert(.active)
        }
        if matchesUpcomingFilter(campaign, activity: activity, now: now) {
            filters.insert(.upcoming)
        }
        if matchesCompletedFilter(campaign, activity: activity, now: now) {
            filters.insert(.completed)
        }
        if matchesEndedFilter(campaign, activity: activity, now: now) {
            filters.insert(.ended)
        }
        return filters
    }

    private func matchesSelectedFilters(_ campaign: CampaignViewData, activity: CampaignActivitySnapshot, now: Date) -> Bool {
        guard !selectedFilters.isEmpty else {
            return false
        }
        return !filters(for: campaign, activity: activity, now: now).intersection(selectedFilters).isEmpty
    }

    private func activity(
        for campaign: CampaignViewData,
        activeMinerCandidates: [MinerManager.ManagedMiner]? = nil,
        now: Date = Date()
    ) -> CampaignActivitySnapshot {
        let activeMiners = activeMiners(for: campaign, in: activeMinerCandidates)
        let claimedAccounts = campaign.accountStates.filter { $0.miningStatus == .claimed }
        let needsAuthAccounts = campaign.accountStates.filter { $0.miningStatus == .needsAuth }
        let blockedAccounts = campaign.accountStates.filter { $0.miningStatus == .blocked }
        let hasBlockedAccount = !needsAuthAccounts.isEmpty || !blockedAccounts.isEmpty
        let claimableDropCount = campaign.drops.filter { $0.isClaimable && !$0.isClaimed }.count
        let claimedRewardCount = max(
            campaign.dropsClaimed,
            campaign.drops.filter(\.isClaimed).count
        )
        let remainingRewardCount = max(campaign.totalDrops - claimedRewardCount, 0)
        let isExpired = campaign.isExpired(now: now)
        let combinedProgress = campaign.combinedProgressFraction

        let state: CampaignCardState

        if isExpired {
            state = .expired
        } else if campaign.startDate > now {
            state = .ready
        } else if combinedProgress >= 0.995 || campaign.isCompleted {
            state = .claimed
        } else if hasBlockedAccount && campaign.hasObtainableRewards {
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

struct DropsListRenderContext {
    let feedCampaigns: [CampaignViewData]
    let renderedCampaigns: [CampaignViewData]
    let groupedCampaigns: [GameAggregate]
    let visibleGroupedCampaigns: [GameAggregate]
    let activityByCampaignId: [String: CampaignActivitySnapshot]
    let renderSignature: [String]
    let activeMiningCampaignCount: Int
    let rewardsClaimedCount: Int
    let topClaimedGame: (name: String, count: Int)?
    let mostActiveMiner: (name: String, count: Int)?
}

struct DropsLoadingSplash: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.10))
                    .frame(width: 84, height: 84)

                Circle()
                    .strokeBorder(Color.green.opacity(0.18), lineWidth: 1)
                    .frame(width: 84, height: 84)

                if reduceMotion {
                    loadingSymbol
                } else {
                    loadingSymbol
                        .symbolEffect(.variableColor.cumulative, options: .repeating.speed(0.45))
                        .symbolEffect(.pulse, options: .repeating.speed(0.7))
                }
            }

            VStack(spacing: 6) {
                Text("Loading drops")
                    .font(.headline.weight(.semibold))

                Text("Syncing Twitch campaign data.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 30)
        .frame(maxWidth: 420)
        .glassCard()
    }

    private var loadingSymbol: some View {
        Image(systemName: "sparkles.tv")
            .font(.system(size: 34, weight: .semibold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.green)
            .accessibilityHidden(true)
    }
}


// MARK: - Preview

#Preview("Drops List") {
    DropsListView()
        .environment(NavigationModel(clientId: "preview"))
        .frame(width: 700, height: 680)
}
