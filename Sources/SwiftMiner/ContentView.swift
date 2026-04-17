import SwiftUI
import SwiftMinerCore
import AppKit

/// Root view — 2-column NavigationSplitView (Sidebar | Detail)
struct ContentView: View {
    @Environment(NavigationModel.self) private var navigation
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        @Bindable var nav = navigation
        NavigationSplitView {
            SidebarView()
        } detail: {
            detailView
        }
        .overlay {
            if nav.showOnboarding {
                ZStack {
                    Color.black.opacity(0.28)
                        .ignoresSafeArea()
                        .transition(.opacity)

                    OnboardingView()
                        .padding(24)
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                }
                .zIndex(100)
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .sheet(isPresented: $nav.showAddAccountSheet) {
            AuthRequiredSheet(isPresented: $nav.showAddAccountSheet)
                .environment(navigation)
        }
        .onAppear {
            navigation.refreshOnboardingPresentation()
        }
        .onChange(of: settings.gamePreferencesData) { _, _ in
            navigation.refreshOnboardingPresentation()
        }
        .onChange(of: navigation.minerManager.miners.count) { _, _ in
            navigation.handleAccountCountChange()
        }
    }

    // MARK: - Detail View

    @ViewBuilder
    private var detailView: some View {
        switch navigation.selectedItem {
        case .overview, .none:
            OverviewView()

        case .activity:
            ActivityOverviewView()

        case .drops:
            DropsListView()

        case .events:
            EventsView()
        }
    }
}

// MARK: - Events View

struct EventsView: View {
    @Environment(NavigationModel.self) private var navigation
    @State private var searchText = ""
    @State private var levelFilter: EventLevel? = nil
    @State private var showRawLogs = false

    private var filteredEvents: [EventEntry] {
        navigation.events.filter { event in
            let matchesSearch = searchText.isEmpty || event.message.localizedCaseInsensitiveContains(searchText) || (event.rawMessage?.localizedCaseInsensitiveContains(searchText) ?? false)
            let matchesLevel = levelFilter == nil || event.level == levelFilter
            return matchesSearch && matchesLevel
        }
    }

    var body: some View {
        ZStack {
            if filteredEvents.isEmpty {
                MaterialEmptyStatePanel(
                    "No Events",
                    systemImage: "bell.slash",
                    description: "Start a miner to see mining events here."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(28)
            } else {
                List(filteredEvents) { event in
                    EventRow(event: event, showRaw: showRawLogs)
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("Events")
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search events")
        .toolbar {
            ToolbarItemGroup {
                Picker("Level", selection: $levelFilter) {
                    Text("All Levels").tag(nil as EventLevel?)
                    Text("Info").tag(EventLevel.info as EventLevel?)
                    Text("Warning").tag(EventLevel.warning as EventLevel?)
                    Text("Error").tag(EventLevel.error as EventLevel?)
                }
                .pickerStyle(.menu)

                Toggle(isOn: $showRawLogs) {
                    Label("Raw Logs", systemImage: "text.alignleft")
                }
            }

            ToolbarItem(placement: .primaryAction) {
                Button("Clear") {
                    navigation.clearEvents()
                }
                .disabled(navigation.events.isEmpty)
            }
        }
    }
}

struct EventRow: View {
    let event: EventEntry
    let showRaw: Bool
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: iconName)
                    .foregroundStyle(iconColor)
                    .font(.system(size: 14, weight: .bold))
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(showRaw ? (event.rawMessage ?? event.message) : event.message)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                    
                    HStack(spacing: 8) {
                        Text(event.timestamp.formatted(.dateTime.hour().minute().second()))
                        if let minerId = event.minerId {
                            Text("•")
                            Text(minerName(for: minerId))
                                .fontWeight(.medium)
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
    
    /// Looks up the miner username from the minerId, fallback to shortened ID
    private func minerName(for minerId: String) -> String {
        if let miner = navigation.minerManager.miners.first(where: { $0.id == minerId }) {
            return miner.username
        }
        return "Account \(minerId.prefix(4))"
    }

    private var iconName: String {
        switch event.level {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.circle.fill"
        }
    }

    private var iconColor: Color {
        switch event.level {
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }
}

// MARK: - Overview View

struct OverviewView: View {
    @Environment(NavigationModel.self) private var navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var settings = Settings.shared
    @State private var progress: AggregateProgress?
    @State private var overviewCampaigns: [CampaignViewData] = []
    @State private var isRefreshing = false
    @State private var steamIdSheetPresentation: SteamIdSheetPresentation?

    private var campaigns: [CampaignViewData] {
        overviewCampaigns
            .filter { campaign in
                !settings.excludedGames.contains(where: { 
                    $0.localizedCaseInsensitiveCompare(campaign.gameName) == .orderedSame 
                })
            }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                let miners = navigation.minerManager.miners
                if !miners.isEmpty {
                    MinerHealthCard(miners: miners) { minerId in
                        navigation.selectedMinerId = minerId
                        navigation.selectedItem = .activity
                    }
                }
                metricsSection
                campaignFeedSection
                nextActionSection
                campaignSummarySection
            }
            .padding(24)
        }
        .navigationTitle("Overview")
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await refreshFromOverview() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isRefreshing)
            }
        }
        .task { await refreshSummary() }
        .onChange(of: settings.gamePreferencesData) { _, _ in
            Task { await enrichPreferredGameArtwork() }
        }
        .sheet(item: $steamIdSheetPresentation) { presentation in
            SetSteamIdSheet { appId in
                applySteamAppId(appId, for: presentation.gameName)
            }
            .presentationBackground(.clear)
        }
    }

    private func refreshSummary() async {
        isRefreshing = true
        progress = await navigation.minerManager.getAggregateProgress()
        if overviewCampaigns.isEmpty && !navigation.minerManager.dataCoordinator.lastKnownAllCampaigns.isEmpty {
            overviewCampaigns = navigation.minerManager.dataCoordinator.lastKnownAllCampaigns
        }
        overviewCampaigns = await navigation.minerManager.dataCoordinator.allCampaigns(
            preferSteamArtwork: Settings.shared.preferSteamArtwork
        )
        await enrichPreferredGameArtwork()
        isRefreshing = false
    }

    private func refreshFromOverview() async {
        isRefreshing = true
        defer { isRefreshing = false }

        if !navigation.minerManager.miners.isEmpty {
            if settings.preferSteamArtwork {
                await navigation.minerManager.dataCoordinator.clearSteamArtworkCache()
            }
            await navigation.minerManager.dataCoordinator.refreshAll()
        }

        progress = await navigation.minerManager.getAggregateProgress()
        overviewCampaigns = await navigation.minerManager.dataCoordinator.allCampaigns(
            preferSteamArtwork: Settings.shared.preferSteamArtwork
        )
        await enrichPreferredGameArtwork()
    }

    /// Enriches `steamArtworkOverrides` for preferred games that have no active campaign.
    /// No-op when `preferSteamArtwork` is off. Safe to call repeatedly (results are cached).
    private func enrichPreferredGameArtwork() async {
        guard settings.preferSteamArtwork else { return }
        let names = settings.gamePreferences.filter { $0.state == .preferred }.map(\.gameName)
        await navigation.minerManager.dataCoordinator.enrichGameNames(names)
    }

    private func presentSteamIdSheet(for gameName: String) {
        steamIdSheetPresentation = SteamIdSheetPresentation(gameName: gameName)
    }

    private func applySteamAppId(_ appId: String, for gameName: String) {
        guard SteamArtworkService.supportsSteamArtwork(forGameName: gameName) else {
            return
        }

        Task {
            await SteamArtworkService.shared.setManualAppId(for: gameName, appId: appId)
            await navigation.minerManager.dataCoordinator.enrichGameNames([gameName])
            await MainActor.run {
                Settings.shared.objectWillChange.send()
            }
        }
    }

    // MARK: - Metrics

    private var metricsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeading("Live Stats", subtitle: "Real-time summary of your mining activity.")

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3),
                spacing: 14
            ) {
                OverviewMetricCard(
                    title: "Active Miners",
                    value: "\(progress?.activeMiners ?? navigation.minerManager.miners.filter { $0.isRunning }.count)",
                    subtitle: "\(navigation.minerManager.miners.count) online accounts",
                    icon: "person.2.fill",
                    color: .blue
                )
                OverviewMetricCard(
                    title: "Eligible Campaigns",
                    value: "\(activeCampaignCount)",
                    subtitle: "ready to earn now",
                    icon: "play.fill",
                    color: .green
                )
                OverviewMetricCard(
                    title: "Claimed Today",
                    value: "\(progress?.claimedToday ?? 0)",
                    subtitle: "\(progress?.claimedDrops ?? 0) total claimed",
                    icon: "sparkles.tv.fill",
                    color: .orange
                )
            }
        }
    }

    private var activeCampaignCount: Int {
        campaigns
            .filter { campaign in
                campaign.isAccountConnected
                    && campaign.endDate > Date()
                    && campaign.overviewState != .completed
            }
            .count
    }

    // MARK: - Campaign Feed

    private var campaignFeedSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            if !displayedPrioritisedFeedItems.isEmpty {
                campaignRailSection(
                    title: "Prioritised",
                    items: displayedPrioritisedFeedItems,
                    prominence: .standard
                )
            }

            if !displayedMiningFeedItems.isEmpty {
                campaignRailSection(
                    title: "Mining / Queued",
                    items: displayedMiningFeedItems,
                    prominence: .feature,
                    displayStyle: effectiveQueueDisplayStyle
                )
            }
        }
        .padding(.vertical, 2)
    }

    private var displayedMiningFeedItems: [CampaignRailItem] {
#if DEBUG
        if settings.debugFakeQueueEnabled {
            return debugFakeQueueItems
        }
#endif
        let orderedCampaigns = orderedMiningQueueCampaigns
        guard !orderedCampaigns.isEmpty else {
            return [placeholderRailItem(for: .active)]
        }

        let firstIsActive = orderedCampaigns.first.map(isBeingWatched(_:)) ?? false

        return Array(orderedCampaigns.prefix(8).enumerated()).map { index, campaign in
            var item = makeRailItem(for: campaign, section: .active)
            item.queuePosition = index

            if index == 0 {
                item.queueLabel = firstIsActive ? "Now Mining" : "Next Up"
            } else if index == 1 && firstIsActive {
                item.queueLabel = "Next Up"
            } else {
                item.queueLabel = "Queue #\(index + 1)"
            }

            return item
        }
    }

    @ViewBuilder
    private func campaignRailSection(
        title: String,
        items: [CampaignRailItem],
        prominence: CampaignCardProminence,
        displayStyle: Settings.QueueDisplayStyle = .classic
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeading(title)

            ScrollView(.horizontal, showsIndicators: false) {
                if displayStyle == .classic {
                    LazyHStack(alignment: .top, spacing: prominence.spacing) {
                        ForEach(items) { item in
                            CampaignFeedCard(
                                item: item,
                                prominence: prominence,
                                onSetSteamId: presentSteamIdSheet(for:)
                            )
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 6)
                } else {
                    LazyHStack(
                        alignment: .top,
                        spacing: displayStyle == .stacked ? -prominence.size.width * 0.52 : prominence.spacing * 0.55
                    ) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            let clampedDepth = min(index, 4)
                            let scale = displayStyle == .stacked
                                ? max(0.62, 1.0 - (Double(clampedDepth) * 0.12))
                                : max(0.72, 1.0 - (Double(clampedDepth) * 0.10))
                            let opacity = displayStyle == .stacked
                                ? max(0.52, 1.0 - (Double(clampedDepth) * 0.16))
                                : max(0.58, 1.0 - (Double(clampedDepth) * 0.13))
                            let xOffset = displayStyle == .stacked
                                ? CGFloat(clampedDepth) * 16
                                : CGFloat(clampedDepth) * 6
                            let yOffset = displayStyle == .stacked
                                ? CGFloat(clampedDepth) * 4
                                : CGFloat(clampedDepth) * 1.5
                            let rotation = displayStyle == .coverFlow
                                ? min(Double(clampedDepth) * 14, 36)
                                : 0

                            CampaignFeedCard(
                                item: item,
                                prominence: prominence,
                                onSetSteamId: presentSteamIdSheet(for:)
                            )
                                .scaleEffect(scale)
                                .opacity(opacity)
                                .offset(x: xOffset, y: yOffset)
                                .rotation3DEffect(
                                    .degrees(rotation),
                                    axis: (x: 0, y: 1, z: 0),
                                    perspective: 0.7
                                )
                                .zIndex(Double(120 - index))
                                .animation(.spring(response: 0.34, dampingFraction: 0.82), value: items.map(\.id).joined(separator: ","))
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 10)
                }
            }
            .scrollClipDisabled()
        }
    }

    private var effectiveQueueDisplayStyle: Settings.QueueDisplayStyle {
        if reduceMotion && settings.queueDisplayStyle == .coverFlow {
            return .stacked
        }
        return settings.queueDisplayStyle
    }

#if DEBUG
    private var debugFakeQueueItems: [CampaignRailItem] {
        let maxCount = settings.clampedDebugFakeQueueLength
        let seedNames = debugQueueSeedGameNames

        guard !seedNames.isEmpty else {
            var placeholder = placeholderRailItem(for: .active)
            placeholder.queueLabel = "Now Mining"
            placeholder.isDebugPreview = true
            return [placeholder]
        }

        return Array((0..<maxCount)).map { index in
            let name = seedNames[index % seedNames.count]
            var item: CampaignRailItem

            if let existingCampaign = campaigns.first(where: { $0.gameName.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                item = makeRailItem(for: existingCampaign, section: .active)
            } else {
                item = makeSyntheticDebugQueueItem(gameName: name, index: index)
            }

            item.queuePosition = index
            if index == 0 {
                item.queueLabel = "Now Mining"
            } else if index == 1 {
                item.queueLabel = "Next Up"
            } else {
                item.queueLabel = "Queue #\(index + 1)"
            }
            item.isDebugPreview = true
            return item
        }
    }

    private var debugQueueSeedGameNames: [String] {
        let sourceNames: [String]
        switch settings.debugFakeQueueSource {
        case .prioritisedGames:
            sourceNames = settings.priorityGames
        case .customGames:
            sourceNames = settings.debugFakeQueueCustomGames
        }

        let normalized = sourceNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if !normalized.isEmpty {
            return deduplicatedGameNames(normalized)
        }

        let fallback = campaigns.map(\.gameName)
        return deduplicatedGameNames(fallback).prefix(8).map { $0 }
    }

    private func deduplicatedGameNames(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for name in names {
            let key = name.lowercased()
            if seen.insert(key).inserted {
                result.append(name)
            }
        }
        return result
    }

    private func makeSyntheticDebugQueueItem(gameName: String, index: Int) -> CampaignRailItem {
        let subtitle = index == 0 ? "Debug queue simulation" : "Queued in debug preview"
        let detail = index == 0 ? "Testing card hierarchy and screenshot layouts." : "Synthetic queue card for testing."
        let tint: Color = index == 0 ? .orange : .yellow

        return CampaignRailItem(
            id: "debug-queue-\(index)-\(gameName.lowercased())",
            section: .active,
            gameName: gameName,
            campaignName: subtitle,
            eyebrow: "Debug",
            progressText: detail,
            progressPercent: index == 0 ? 42 : 0,
            artworkURL: SteamArtworkService.supportsSteamArtwork(forGameName: gameName)
                ? navigation.minerManager.dataCoordinator.steamArtworkOverrides[gameName]
                : nil,
            tint: tint,
            hasOnlyBadgesOrEmotes: false,
            visualState: index == 0 ? .inProgress : .idle,
            watchers: [],
            isDimmed: false,
            isPlaceholder: false,
            showsLiveMotion: index == 0,
            game: Game(id: "debug-\(gameName.lowercased())", name: gameName, boxArtURL: nil)
        )
    }
#endif

    private var preferredGames: [GamePreference] {
        settings.gamePreferences.filter { $0.state == .preferred }
    }

    private var currentlyMiningCampaigns: [CampaignViewData] {
        campaigns.filter(isBeingWatched(_:))
    }

    private var orderedMiningQueueCampaigns: [CampaignViewData] {
        activeFeedCampaigns.sorted(by: campaignDisplaySort)
    }

    private var prioritisedCampaigns: [CampaignViewData] {
        campaigns
            .filter { campaign in
                (campaign.relevance == .prioritised || preferredGames.contains(where: { matches(campaign, preference: $0) }))
                    && campaign.isDisplayableInOverview
            }
            .sorted(by: campaignDisplaySort)
    }

    private var preferredGameFallbacks: [GamePreference] {
        preferredGames.filter { preference in
            !prioritisedCampaigns.contains(where: { matches($0, preference: preference) })
        }
    }

    private var activeFeedCampaigns: [CampaignViewData] {
        campaigns
            .filter { campaign in
                let state = visualState(for: campaign)
                return state == .watching
                    || state == .claimable
                    || state == .inProgress
            }
            .sorted(by: campaignDisplaySort)
    }

    private var recentCampaigns: [CampaignViewData] {
        campaigns
            .filter { campaign in
                campaign.isCompleted
            }
            .sorted { recentActivityDate(for: $0) > recentActivityDate(for: $1) }
    }

    private var prioritisedFeedItems: [CampaignRailItem] {
        var items = prioritisedCampaigns.prefix(8).map { makeRailItem(for: $0, section: .prioritised) }
        items.append(contentsOf: preferredGameFallbacks.prefix(4).map(makePreferredGameItem))
        return items
    }

    private var activeFeedItems: [CampaignRailItem] {
        activeFeedCampaigns.prefix(8).map { makeRailItem(for: $0, section: .active) }
    }

    private var recentFeedItems: [CampaignRailItem] {
        recentCampaigns.prefix(8).map { makeRailItem(for: $0, section: .recent) }
    }

    private var displayedPrioritisedFeedItems: [CampaignRailItem] {
        prioritisedFeedItems
    }

    private var displayedActiveFeedItems: [CampaignRailItem] {
        if !activeFeedItems.isEmpty {
            return activeFeedItems
        }
        if !recentFeedItems.isEmpty {
            return recentFeedItems
        }
        return Array(prioritisedFeedItems.prefix(6))
    }

    private func makeRailItem(for campaign: CampaignViewData, section: CampaignFeedSection) -> CampaignRailItem {
        let state = visualState(for: campaign)
        let hasPriorityLinkIssue = hasPriorityLinkIssue(for: campaign, section: section)
        let game = Game(id: campaign.gameId ?? campaign.id, name: campaign.gameName, boxArtURL: campaign.artworkURL)
        let artworkURL = SteamArtworkService.supportsSteamArtwork(forGameName: campaign.gameName, gameId: campaign.gameId)
            ? navigation.minerManager.dataCoordinator.steamArtworkOverrides[campaign.gameName] ?? campaign.artworkURL
            : campaign.artworkURL

        return CampaignRailItem(
            id: "\(section.rawValue)-\(campaign.id)",
            section: section,
            gameName: campaign.gameName,
            campaignName: campaign.campaignName,
            eyebrow: eyebrowText(for: campaign, section: section, state: state, hasPriorityLinkIssue: hasPriorityLinkIssue),
            progressText: campaignDetailText(for: campaign, state: state, hasPriorityLinkIssue: hasPriorityLinkIssue),
            progressPercent: campaignProgressPercent(for: campaign),
            artworkURL: artworkURL,
            tint: tintColor(for: campaign, hasPriorityLinkIssue: hasPriorityLinkIssue),
            hasOnlyBadgesOrEmotes: false,
            visualState: state,
            watchers: watchers(for: campaign),
            isDimmed: state == .claimed,
            isPlaceholder: false,
            showsLiveMotion: section == .active && (state == .watching || state == .inProgress || state == .claimable),
            issueBadge: hasPriorityLinkIssue ? .accountLinkRequired : nil,
            game: game
        )
    }

    private func currentCampaign(for miner: MinerManager.ManagedMiner) -> CampaignViewData? {
        if let campaignId = miner.currentCampaignId {
            return campaigns.first(where: { $0.id == campaignId })
        }

        guard let campaignName = miner.currentCampaign else {
            return nil
        }

        return campaigns.first(where: { $0.campaignName == campaignName })
    }

    private func priorityOrderIndex(for gameName: String) -> Int {
        settings.priorityGames.firstIndex(where: { $0.localizedCaseInsensitiveCompare(gameName) == .orderedSame }) ?? Int.max
    }

    private func isGameExcluded(_ gameName: String) -> Bool {
        settings.excludedGames.contains(where: { $0.localizedCaseInsensitiveCompare(gameName) == .orderedSame })
    }

    private func makePreferredGameItem(_ preference: GamePreference) -> CampaignRailItem {
        let supportsSteamArtwork = SteamArtworkService.supportsSteamArtwork(
            forGameName: preference.gameName,
            gameId: preference.gameId
        )
        let artworkURL = supportsSteamArtwork
            ? navigation.minerManager.dataCoordinator.steamArtworkOverrides[preference.gameName]
                ?? (settings.preferSteamArtwork ? nil : preference.boxArtURL)
            : preference.boxArtURL
        return CampaignRailItem(
            id: "preferred-\(preference.gameId.isEmpty ? preference.gameName : preference.gameId)",
            section: .prioritised,
            gameName: preference.gameName,
            campaignName: "",
            eyebrow: "",
            progressText: "",
            progressPercent: 0,
            artworkURL: artworkURL,
            tint: .orange,
            hasOnlyBadgesOrEmotes: false,
            visualState: .idle,
            watchers: [],
            isDimmed: false,
            isPlaceholder: false,
            showsLiveMotion: false,
            game: Game(id: preference.gameId, name: preference.gameName, boxArtURL: artworkURL)
        )
    }

    private func placeholderRailItem(for section: CampaignFeedSection) -> CampaignRailItem {
        switch section {
        case .prioritised:
            return CampaignRailItem(
                id: "placeholder-prioritised",
                section: .prioritised,
                gameName: settings.priorityGames.isEmpty ? "Pin favourites" : "Prioritised",
                campaignName: settings.priorityGames.isEmpty ? "Choose games to keep anchored here" : "Selected games stay surfaced first",
                eyebrow: "Pinned",
                progressText: settings.priorityGames.isEmpty
                    ? "Add preferred games in Settings."
                    : "Your preferred games are ready for the next campaign.",
                progressPercent: 0,
                artworkURL: preferredGames.first.flatMap { pref in
                    (SteamArtworkService.supportsSteamArtwork(
                        forGameName: pref.gameName,
                        gameId: pref.gameId
                    ))
                    ? navigation.minerManager.dataCoordinator.steamArtworkOverrides[pref.gameName]
                        ?? (settings.preferSteamArtwork ? nil : pref.boxArtURL)
                    : pref.boxArtURL
                },
                tint: .orange,
                hasOnlyBadgesOrEmotes: false,
                visualState: .idle,
                watchers: [],
                isDimmed: false,
                isPlaceholder: true,
                showsLiveMotion: false
            )
        case .active:
            let watchers = readyStateWatchers
            let anyMinersRunning = navigation.minerManager.miners.contains { $0.isRunning }
            let runningCount = navigation.minerManager.miners.filter { $0.isRunning }.count
            let detail = anyMinersRunning
                ? "\(runningCount) \(runningCount == 1 ? "miner is" : "miners are") online and ready."
                : "Accounts will start mining automatically when they are available."
            return CampaignRailItem(
                id: "placeholder-active",
                section: .active,
                gameName: anyMinersRunning ? "Ready" : "Standby",
                campaignName: anyMinersRunning ? "Waiting for the next live campaign" : "No miners are currently active",
                eyebrow: "Standby",
                progressText: detail,
                progressPercent: 0,
                artworkURL: nil,
                tint: anyMinersRunning ? .cyan : .gray,
                hasOnlyBadgesOrEmotes: false,
                visualState: .idle,
                watchers: anyMinersRunning ? watchers : [],
                isDimmed: !anyMinersRunning,
                isPlaceholder: true,
                showsLiveMotion: anyMinersRunning
            )
        case .recent:
            return CampaignRailItem(
                id: "placeholder-recent",
                section: .recent,
                gameName: "Recent",
                campaignName: "Freshly claimed campaigns land here",
                eyebrow: "History",
                progressText: "Completed campaigns stay visible for a while.",
                progressPercent: 0,
                artworkURL: nil,
                tint: .blue,
                hasOnlyBadgesOrEmotes: false,
                visualState: .claimed,
                watchers: [],
                isDimmed: true,
                isPlaceholder: true,
                showsLiveMotion: false
            )
        }
    }

    private func visualState(for campaign: CampaignViewData) -> CampaignVisualState {
        if campaign.isCompleted {
            return .claimed
        }

        if campaign.overviewState == .claimable {
            return .claimable
        }

        if campaign.hasValidProgress {
            return isBeingWatched(campaign) ? .watching : .inProgress
        }

        return .idle
    }

    private func watchers(for campaign: CampaignViewData) -> [CampaignWatcher] {
        return watchingMiners(for: campaign).map { miner in
            CampaignWatcher(
                id: miner.accountId,
                username: miner.username,
                initials: initials(for: miner.username)
            )
        }
    }

    private var readyStateWatchers: [CampaignWatcher] {
        let activeMiners = navigation.minerManager.miners.filter { miner in
            miner.isRunning || miner.status == .fetchingCampaigns || miner.status == .authenticating || miner.status == .paused
        }

        return activeMiners.map { miner in
            CampaignWatcher(
                id: miner.accountId,
                username: miner.username,
                initials: initials(for: miner.username)
            )
        }
    }

    private func watchingMiners(for campaign: CampaignViewData) -> [MinerManager.ManagedMiner] {
        navigation.minerManager.miners.filter { miner in
            // Must be actively running with watching/claiming status
            guard miner.status == .watching || miner.status == .claiming else {
                return false
            }

            // Verify currentCampaignId matches (defense against stale session state)
            if let id = miner.currentCampaignId {
                return id == campaign.id
            }

            return miner.currentCampaign == campaign.campaignName
        }
    }

    private func isBeingWatched(_ campaign: CampaignViewData) -> Bool {
        !watchingMiners(for: campaign).isEmpty
    }

    private func matches(_ campaign: CampaignViewData, preference: GamePreference) -> Bool {
        campaign.gameName.localizedCaseInsensitiveCompare(preference.gameName) == .orderedSame
    }

    private func eyebrowText(
        for campaign: CampaignViewData,
        section: CampaignFeedSection,
        state: CampaignVisualState,
        hasPriorityLinkIssue: Bool = false
    ) -> String {
        if hasPriorityLinkIssue {
            return "Link Required"
        }

        switch state {
        case .watching:
            return "In Progress"
        case .claimable:
            return "Claimable"
        case .inProgress:
            return "In Progress"
        case .claimed:
            return section == .recent ? "Recent" : "Claimed"
        case .idle:
            switch section {
            case .prioritised:
                return "Pinned"
            case .active:
                return "Available"
            case .recent:
                return "Recent"
            }
        }
    }

    private func campaignDetailText(
        for campaign: CampaignViewData,
        state: CampaignVisualState,
        hasPriorityLinkIssue: Bool = false
    ) -> String {
        if hasPriorityLinkIssue {
            return "Link the game publisher account in Twitch Drops to start mining."
        }

        let activeWatchers = watchers(for: campaign)
        let progressPercent = Int(campaignProgressPercent(for: campaign).rounded())

        switch state {
        case .watching:
            let watcherCount = activeWatchers.count
            let watcherCopy = "\(watcherCount) miner\(watcherCount == 1 ? "" : "s") watching"
            if progressPercent > 0 {
                return "\(watcherCopy) • \(progressPercent)% reward progress"
            }
            return watcherCopy
        case .claimable:
            return "Ready to claim"
        case .inProgress:
            return progressPercent > 0 ? "\(progressPercent)% reward progress" : "Progress synced from Drops"
        case .claimed:
            return "All campaign rewards claimed"
        case .idle:
            return "Available"
        }
    }

    private func hasPriorityLinkIssue(for campaign: CampaignViewData, section: CampaignFeedSection) -> Bool {
        guard section == .prioritised else { return false }
        guard campaign.startDate <= Date(), campaign.endDate > Date() else { return false }
        guard !campaign.isAccountConnected else { return false }
        guard campaign.drops.contains(where: { !$0.isClaimed }) else { return false }
        return campaign.relevance == .prioritised || preferredGames.contains(where: { matches(campaign, preference: $0) })
    }

    private func campaignDisplaySort(lhs: CampaignViewData, rhs: CampaignViewData) -> Bool {
        let lhsPriority = displayPriority(for: lhs)
        let rhsPriority = displayPriority(for: rhs)

        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }

        let lhsPinned = priorityOrderIndex(for: lhs.gameName)
        let rhsPinned = priorityOrderIndex(for: rhs.gameName)
        if lhsPinned != rhsPinned {
            return lhsPinned < rhsPinned
        }

        let lhsProgress = campaignProgressPercent(for: lhs)
        let rhsProgress = campaignProgressPercent(for: rhs)
        if lhsProgress != rhsProgress {
            return lhsProgress > rhsProgress
        }

        if lhs.endDate != rhs.endDate {
            return lhs.endDate < rhs.endDate
        }

        return lhs.gameName < rhs.gameName
    }

    private func displayPriority(for campaign: CampaignViewData) -> Int {
        switch visualState(for: campaign) {
        case .watching: return 0
        case .claimable: return 1
        case .inProgress: return 2
        case .idle: return 3
        case .claimed: return 4
        }
    }

    private func recentActivityDate(for campaign: CampaignViewData) -> Date {
        campaign.endDate
    }

    private func initials(for username: String) -> String {
        let tokens = username
            .split(whereSeparator: { $0 == " " || $0 == "_" || $0 == "-" })
            .prefix(2)

        let joined = tokens.map { String($0.prefix(1)).uppercased() }.joined()
        if !joined.isEmpty {
            return joined
        }

        return String(username.prefix(2)).uppercased()
    }

    // MARK: - Next Action

    private var nextActionSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeading("Next Action", subtitle: primaryStatusReason.detail)

            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(primaryStatusReason.title)
                        .font(.title3.weight(.semibold))

                    Text(primaryStatusReason.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Text(primaryStatusReason.badge)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .foregroundStyle(primaryStatusReason.color)
                    .background(
                        primaryStatusReason.color.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: GlassRadius.small, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: GlassRadius.small, style: .continuous)
                            .strokeBorder(primaryStatusReason.color.opacity(0.22), lineWidth: 1)
                    }
            }

            if !statusReasonRows.isEmpty {
                VStack(spacing: 10) {
                    ForEach(statusReasonRows) { row in
                        StatusReasonRow(row: row)
                    }
                }
            }
        }
        .padding(22)
        .glassCard()
    }

    private var primaryStatusReason: StatusReason {
        let miners = navigation.minerManager.miners
        if miners.isEmpty {
            return StatusReason(
                title: "Waiting for accounts",
                summary: "The dashboard is ready, but it needs a Twitch account before it can begin watching for drops.",
                detail: "Add an account to wake up the system and start populating campaign activity.",
                badge: "Standby",
                color: .secondary
            )
        }

        if let miner = miners.first(where: { $0.status == .claiming }) {
            return StatusReason(
                title: "Collecting completed drops",
                summary: "\(miner.username) is wrapping up rewards from \(miner.currentCampaign ?? "an active campaign").",
                detail: "Claiming is prioritized before returning the miner to watching.",
                badge: "Claiming",
                color: .purple
            )
        }

        if let miner = miners.first(where: { $0.status == .watching }) {
            let campaignName = miner.currentCampaign ?? "the current drop rotation"
            return StatusReason(
                title: "Watching live channels",
                summary: "\(miner.username) is actively mining \(campaignName).",
                detail: "The miner is staying on eligible streams and tracking progress in real time.",
                badge: "Watching",
                color: .green
            )
        }

        if miners.contains(where: { $0.status == .fetchingCampaigns }) {
            return StatusReason(
                title: "Refreshing campaign availability",
                summary: "The miner is scanning Twitch for new eligible campaigns and updated drop progress.",
                detail: "This is where upcoming or newly linked campaigns enter the feed.",
                badge: "Refreshing",
                color: .blue
            )
        }

        if miners.contains(where: { $0.status == .authenticating }) {
            return StatusReason(
                title: "Reconnecting account session",
                summary: "An account needs fresh authentication before mining can continue.",
                detail: "Once the session is valid, the miner resumes campaign selection automatically.",
                badge: "Authenticating",
                color: .orange
            )
        }

        if miners.contains(where: { $0.status == .paused }) {
            return StatusReason(
                title: "Standing by between campaigns",
                summary: "The miner is waiting for an eligible campaign or live channel to become available.",
                detail: "Upcoming and eligible cards above show the next opportunities in line.",
                badge: "Standby",
                color: .orange
            )
        }

        if miners.contains(where: { $0.status == .error }) {
            return StatusReason(
                title: "Needs attention",
                summary: "One or more miners hit an error and may need a refresh or reconnect.",
                detail: "Review the Events screen for the most recent issue details.",
                badge: "Error",
                color: .red
            )
        }

        return StatusReason(
            title: "Standing by",
            summary: "Miners are configured, but nothing is actively being watched right now.",
            detail: "Refreshing campaigns or starting miners will move the system back into motion.",
            badge: "Idle",
            color: .secondary
        )
    }

    private var statusReasonRows: [StatusReasonRowModel] {
        navigation.minerManager.miners.map { miner in
            StatusReasonRowModel(
                id: miner.id,
                title: miner.username,
                subtitle: miner.currentCampaign ?? fallbackSubtitle(for: miner),
                status: miner.statusLabel,
                color: statusColor(for: miner)
            )
        }
    }

    private func statusColor(for miner: MinerManager.ManagedMiner) -> Color {
        guard let resolved = miner.resolvedPrimaryState?.resolved else {
            return fallbackStatusColor(for: miner)
        }
        switch resolved.state {
        case .watching:                          return .green
        case .blocked:
            switch resolved.reason {
            case .notLinked:                        return .orange
            case .noLiveStreams:                    return .cyan
            default:                                return .secondary
            }
        case .idle:                              return .gray
        }
    }

    private func fallbackStatusColor(for miner: MinerManager.ManagedMiner) -> Color {
        switch miner.status {
        case .watching:                          return .green
        case .waitingForStream:                  return .yellow
        case .claiming:                          return .purple
        case .authenticating, .fetchingCampaigns, .paused: return .orange
        case .error:                             return .red
        case .idle:                              return .gray
        }
    }

    // MARK: - Campaign Summary

    private var campaignSummarySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeading("Campaign Progress", subtitle: "Drops-backed campaigns with real progress or completed rewards.")

            if summaryCampaigns.isEmpty {
                CampaignLibraryAmbientRow()
            } else {
                VStack(spacing: 10) {
                    ForEach(summaryCampaigns) { campaign in
                        OverviewCampaignSummaryRow(
                            campaign: campaign,
                            tint: gameTintColor(forGameName: campaign.gameName)
                        )
                    }
                }
            }
        }
    }

    private var summaryCampaigns: [CampaignViewData] {
        let sourceCampaigns: [CampaignViewData]
        if !activeFeedCampaigns.isEmpty {
            sourceCampaigns = activeFeedCampaigns
        } else if !prioritisedCampaigns.isEmpty {
            sourceCampaigns = prioritisedCampaigns
        } else {
            sourceCampaigns = recentCampaigns
        }

        return sourceCampaigns
            .filter { $0.isDisplayableInOverview }
            .prefix(6)
            .map { $0 }
    }

    private func campaignProgressPercent(for campaign: CampaignViewData) -> Double {
        let progressPercent = (campaign.overviewProgressFraction ?? 0) * 100
#if DEBUG
        if progressPercent > 0, !campaign.hasValidProgress {
            print("[Overview] ERROR: attempted to render progress for \(campaign.id) without Drops progress")
        }
#endif
        return progressPercent
    }

    private func fallbackSubtitle(for miner: MinerManager.ManagedMiner) -> String {
        switch miner.status {
        case .idle:
            return "Waiting for the next campaign"
        case .authenticating:
            return "Refreshing account access"
        case .fetchingCampaigns:
            return "Checking Twitch for live opportunities"
        case .watching:
            return "Watching eligible streams"
        case .waitingForStream:
            return "Waiting for a live stream"
        case .claiming:
            return "Claiming completed rewards"
        case .paused:
            return "Standing by for the next opportunity"
        case .error:
            return "Needs a refresh"
        }
    }

    private func tintColor(for campaign: CampaignViewData, hasPriorityLinkIssue: Bool = false) -> Color {
        if hasPriorityLinkIssue {
            return .orange
        }
        return gameTintColor(forGameName: campaign.gameName)
    }

    @ViewBuilder
    private func sectionHeading(_ title: String) -> some View {
        Text(title)
            .font(.title3.weight(.medium))
    }

    @ViewBuilder
    private func sectionHeading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title3.weight(.medium))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Supporting Types

// MARK: - Overview Metric Card

struct OverviewMetricCard: View {
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(color.opacity(0.12))

                    Image(systemName: icon)
                        .foregroundStyle(color)
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(width: 28, height: 28)

                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)
            }

            Text(value)
                .font(.system(size: 32, weight: .semibold, design: .rounded))

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .padding(16)
        .glassCard()
    }
}

// MARK: - Campaign Summary Row

private struct OverviewCampaignSummaryRow: View {
    let campaign: CampaignViewData
    let tint: Color

    private var progressFraction: Double? {
        campaign.overviewProgressFraction
    }

    @ViewBuilder
    private var statusText: some View {
        switch campaign.overviewState {
        case .completed:
            Text("All campaign rewards claimed")
                .font(.caption)
                .foregroundStyle(.green)
        case .claimable:
            Text("Reward ready to claim")
                .font(.caption)
                .foregroundStyle(.orange)
        case .inProgress:
            let claimedCopy = campaign.overviewClaimedRewardCount > 0
                ? " · \(campaign.overviewClaimedRewardCount) claimed"
                : ""
            Text("Progress synced from Drops" + claimedCopy)
                .font(.caption)
                .foregroundStyle(.secondary)
        case .available:
            Text("Available")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            CampaignThumbnail(url: campaign.artworkURL, tint: tint)
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 8) {
                Text(campaign.gameName)
                    .font(.headline)
                    .lineLimit(1)

                Text(campaign.campaignName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if let progressFraction {
                    ProgressView(value: progressFraction)
                        .progressViewStyle(.linear)
                        .tint(tint)
                        .frame(maxWidth: 220)
                }

                statusText
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                if let progressFraction {
                    Text("\(Int((progressFraction * 100).rounded()))%")
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(campaign.overviewState == .claimable ? .orange : .primary)
                } else if campaign.isCompleted {
                    Text("Done")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(16)
        .background(.thinMaterial.opacity(0.54), in: RoundedRectangle(cornerRadius: GlassRadius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: GlassRadius.medium, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.06), radius: 4, y: 1)
    }
}

private struct CampaignLibraryAmbientRow: View {
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: GlassRadius.small, style: .continuous)
                    .fill(.thinMaterial.opacity(0.6))

                Image(systemName: "sparkles.tv")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text("No active campaigns yet")
                    .font(.headline)

                Text("Active drop campaigns will appear here automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(16)
        .background(.ultraThinMaterial.opacity(0.72), in: RoundedRectangle(cornerRadius: GlassRadius.medium, style: .continuous))
    }
}

private enum CampaignFeedSection: String {
    case prioritised
    case active
    case recent
}

private enum CampaignCardProminence {
    case feature
    case standard
    case compact

    var size: CGSize {
        CGSize(width: 186, height: 286)
    }

    var artworkHeight: CGFloat {
        202
    }

    var spacing: CGFloat {
        switch self {
        case .feature:
            return 18
        case .standard:
            return 18
        case .compact:
            return 16
        }
    }
}

private enum CampaignVisualState {
    case watching
    case inProgress
    case claimable
    case claimed
    case idle

    var accent: Color {
        switch self {
        case .watching:
            return .green
        case .inProgress:
            return .blue
        case .claimable:
            return .cyan
        case .claimed:
            return .green
        case .idle:
            return .secondary
        }
    }

    var label: String {
        switch self {
        case .watching:
            return "Watching"
        case .inProgress:
            return "In Progress"
        case .claimable:
            return "Claimable"
        case .claimed:
            return "Claimed"
        case .idle:
            return "Idle"
        }
    }

    var symbol: String {
        switch self {
        case .watching:
            return "play.fill"
        case .inProgress:
            return "chart.line.uptrend.xyaxis"
        case .claimable:
            return "sparkles"
        case .claimed:
            return "checkmark.circle.fill"
        case .idle:
            return "circle.fill"
        }
    }
}

private struct CampaignWatcher: Identifiable {
    let id: String
    let username: String
    let initials: String
}

struct AvatarColorSwatch {
    let top: Color
    let bottom: Color
    let text: Color

    var gradient: LinearGradient {
        LinearGradient(
            colors: [top, bottom],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

enum AvatarColorPalette {
    private static let palette: [NSColor] = [
        .systemBlue,
        .systemIndigo,
        .systemPurple,
        .systemPink,
        .systemOrange,
        .systemTeal,
        .systemGreen
    ]

    static func swatch(for userID: String?, username: String) -> AvatarColorSwatch {
        let base = softenedBaseColor(
            for: normalizedKey(userID: userID, username: username)
        )
        let top = base
            .mixed(with: .white, amount: 0.20)
            .adjusted(saturationFactor: 0.96, brightnessFactor: 1.03)
        let bottom = base
            .mixed(with: .black, amount: 0.08)
            .adjusted(saturationFactor: 0.97, brightnessFactor: 0.93)

        let text: Color = base.relativeLuminance > 0.64
            ? Color.black.opacity(0.72)
            : Color.white.opacity(0.93)

        return AvatarColorSwatch(
            top: Color(nsColor: top),
            bottom: Color(nsColor: bottom),
            text: text
        )
    }

    private static func softenedBaseColor(for userKey: String) -> NSColor {
        let hash = stableHash(for: userKey)
        let index = Int(hash % UInt64(palette.count))
        let variantA = CGFloat((hash >> 24) & 0xFF) / 255
        let variantB = CGFloat((hash >> 32) & 0xFF) / 255
        let variantC = CGFloat((hash >> 40) & 0xFF) / 255

        let saturationFactor = 0.70 + (variantA * 0.11)
        let brightnessFactor = 0.87 + (variantB * 0.09)
        let whiteMix = 0.08 + (variantC * 0.05)

        return palette[index]
            .adjusted(
                saturationFactor: saturationFactor,
                brightnessFactor: brightnessFactor
            )
            .mixed(with: .white, amount: whiteMix)
    }

    private static func stableHash(for value: String) -> UInt64 {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in value.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }

        // Finalize for stronger low-bit distribution before modulo palette size.
        hash ^= hash >> 30
        hash &*= 0xBF58_476D_1CE4_E5B9
        hash ^= hash >> 27
        hash &*= 0x94D0_49BB_1331_11EB
        hash ^= hash >> 31
        return hash
    }

    private static func normalizedKey(userID: String?, username: String) -> String {
        let normalizedID = (userID ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !normalizedID.isEmpty {
            return normalizedID
        }
        return username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

private extension NSColor {
    func adjusted(saturationFactor: CGFloat, brightnessFactor: CGFloat) -> NSColor {
        let color = (usingColorSpace(.deviceRGB) ?? self)
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)

        return NSColor(
            hue: hue,
            saturation: max(0, min(1, saturation * saturationFactor)),
            brightness: max(0, min(1, brightness * brightnessFactor)),
            alpha: alpha
        )
    }

    func mixed(with color: NSColor, amount: CGFloat) -> NSColor {
        let start = usingColorSpace(.deviceRGB) ?? self
        let end = color.usingColorSpace(.deviceRGB) ?? color
        let t = max(0, min(1, amount))

        var sr: CGFloat = 0
        var sg: CGFloat = 0
        var sb: CGFloat = 0
        var sa: CGFloat = 0
        var er: CGFloat = 0
        var eg: CGFloat = 0
        var eb: CGFloat = 0
        var ea: CGFloat = 0
        start.getRed(&sr, green: &sg, blue: &sb, alpha: &sa)
        end.getRed(&er, green: &eg, blue: &eb, alpha: &ea)

        return NSColor(
            red: sr + ((er - sr) * t),
            green: sg + ((eg - sg) * t),
            blue: sb + ((eb - sb) * t),
            alpha: sa + ((ea - sa) * t)
        )
    }

    var relativeLuminance: CGFloat {
        let color = usingColorSpace(.deviceRGB) ?? self
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)

        func linearize(_ channel: CGFloat) -> CGFloat {
            if channel <= 0.04045 {
                return channel / 12.92
            }
            return pow((channel + 0.055) / 1.055, 2.4)
        }

        let lr = linearize(r)
        let lg = linearize(g)
        let lb = linearize(b)
        return (0.2126 * lr) + (0.7152 * lg) + (0.0722 * lb)
    }
}

private func gameTintColor(forGameName gameName: String) -> Color {
    let name = gameName.lowercased()
    if name.contains("rust") { return .orange }
    if name.contains("fortnite") { return .blue }
    if name.contains("valorant") { return .red }
    if name.contains("finals") { return .pink }
    return .purple
}

private struct CampaignRailItem: Identifiable {
    let id: String
    let section: CampaignFeedSection
    let gameName: String
    let campaignName: String
    let eyebrow: String
    let progressText: String
    let progressPercent: Double
    let artworkURL: URL?
    let tint: Color
    let hasOnlyBadgesOrEmotes: Bool
    let visualState: CampaignVisualState
    let watchers: [CampaignWatcher]
    let isDimmed: Bool
    let isPlaceholder: Bool
    let showsLiveMotion: Bool
    var issueBadge: CampaignIssueBadge? = nil
    var game: Game? = nil
    var queuePosition: Int? = nil
    var queueLabel: String? = nil
    var isDebugPreview: Bool = false
}

private enum CampaignIssueBadge {
    case accountLinkRequired

    var title: String {
        switch self {
        case .accountLinkRequired:
            return "Link Required"
        }
    }

    var symbol: String {
        switch self {
        case .accountLinkRequired:
            return "exclamationmark.triangle.fill"
        }
    }
}

private struct CampaignFeedCard: View {
    let item: CampaignRailItem
    let prominence: CampaignCardProminence
    let onSetSteamId: (String) -> Void
    @ObservedObject private var settings = Settings.shared
    @State private var isHovering = false

    private var usesStandbyMotionStyle: Bool {
        item.isPlaceholder && item.showsLiveMotion
    }

    private var showsCampaignSubtitle: Bool {
        item.section == .active && !item.campaignName.isEmpty
    }

    private var showsQueueBadge: Bool {
        item.section == .active && !item.isPlaceholder && item.queueLabel != nil
    }

    private var showsDebugPreviewBadge: Bool {
#if DEBUG
        item.isDebugPreview && item.section == .active && settings.debugShowPreviewBadge
#else
        item.isDebugPreview && item.section == .active
#endif
    }

    private var showsIssueBadge: Bool {
        !item.isPlaceholder && item.issueBadge != nil
    }

    private var accessibilityTitle: String {
        if let issue = item.issueBadge {
            return "\(issue.title). \(item.gameName)"
        }
        if let queueLabel = item.queueLabel {
            return "\(queueLabel). \(item.gameName)"
        }
        return item.gameName
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CampaignArtworkBackground(
                url: item.artworkURL,
                tint: item.tint,
                useGhostArtworkPlaceholder: usesStandbyMotionStyle
            )

            if item.showsLiveMotion {
                if usesStandbyMotionStyle {
                    CampaignStandbyMotionOverlay(tint: item.tint)
                        .opacity(0.68)
                } else {
                    CampaignCardMotionOverlay(tint: item.tint)
                        .opacity(0.5)
                }
            }

            LinearGradient(
                colors: [
                    .clear,
                    Color.black.opacity(0.12),
                    Color.black.opacity(0.36),
                    Color.black.opacity(item.section == .recent ? 0.56 : 0.66)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            Rectangle()
                .fill(
                    usesStandbyMotionStyle
                        ? AnyShapeStyle(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0),
                                    Color.white.opacity(0.012),
                                    Color.black.opacity(0.08)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        : AnyShapeStyle(
                            LinearGradient(
                                colors: [
                                    item.tint.opacity(0),
                                    item.tint.opacity(0.08),
                                    item.tint.opacity(0.18)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
                .mask(alignment: .bottom) {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.24), .black],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }

            if let queueLabel = item.queueLabel, showsQueueBadge {
                VStack {
                    HStack {
                        Label(queueLabel, systemImage: "line.3.horizontal.decrease.circle.fill")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.95))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                        Spacer()
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
            }

            if showsDebugPreviewBadge || showsIssueBadge {
                VStack {
                    HStack {
                        Spacer()
                        VStack(alignment: .trailing, spacing: 6) {
                            if showsDebugPreviewBadge {
                                Label("Debug Preview", systemImage: "wrench.and.screwdriver.fill")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.white.opacity(0.95))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(.orange.opacity(0.8), in: Capsule())
                            }
                            if let issue = item.issueBadge, showsIssueBadge {
                                Label(issue.title, systemImage: issue.symbol)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.white.opacity(0.95))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(.orange.opacity(0.88), in: Capsule())
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.gameName)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                if showsCampaignSubtitle {
                    Text(item.campaignName)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(usesStandbyMotionStyle ? 0.44 : 0.78))
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .bottomLeading) {
                // Material slab treatment for all cards
                if usesStandbyMotionStyle {
                    Rectangle()
                        .fill(.ultraThinMaterial.opacity(0.6))
                        .overlay(alignment: .top) {
                            Color.white.opacity(0.1)
                                .frame(height: 1)
                        }
                } else {
                    Rectangle()
                        .fill(.thinMaterial.opacity(0.35))
                        .overlay(alignment: .top) {
                            Color.white.opacity(0.08)
                                .frame(height: 1)
                        }
                }
            }
        }
        .frame(width: prominence.size.width, height: prominence.size.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: GlassRadius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: GlassRadius.medium, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
        .opacity(item.section == .recent ? 0.88 : (item.isDimmed ? 0.7 : 1))
        .saturation(item.isDimmed ? 0.82 : 1)
        .brightness(isHovering ? 0.015 : 0)
        .scaleEffect(isHovering ? 1.03 : 1)
        .shadow(color: .black.opacity(isHovering ? 0.10 : 0.05), radius: isHovering ? 8 : 3, y: isHovering ? 4 : 1)
        .animation(.easeInOut(duration: 0.2), value: isHovering)
        .animation(.easeInOut(duration: 0.7), value: usesStandbyMotionStyle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(item.campaignName.isEmpty ? item.progressText : item.campaignName)
        .onHover { hovering in
            isHovering = hovering
        }
        .contextMenu {
            if let game = item.game, !item.isPlaceholder {
                Button {
                    Settings.shared.setGamePreference(game, state: .preferred)
                } label: {
                    GameActionMenuLabel(
                        title: "Prioritise Game",
                        systemImage: "star"
                    )
                }

                Button {
                    Settings.shared.setGamePreference(game, state: .excluded)
                } label: {
                    GameActionMenuLabel(
                        title: "Exclude Game",
                        systemImage: "minus.circle"
                    )
                }

                Divider()

                if SteamArtworkService.supportsSteamArtwork(forGameName: game.name, gameId: game.id) {
                    Button {
                        onSetSteamId(game.name)
                    } label: {
                        GameActionMenuLabel(
                            title: "Set Steam ID",
                            subtitle: "Set a Steam ID to enable high-resolution artwork for this game.",
                            systemImage: "photo.artframe"
                        )
                    }
                }
            }
        }
    }
}

private struct SteamIdSheetPresentation: Identifiable {
    let id = UUID()
    let gameName: String
}

private struct SetSteamIdSheet: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isInputFocused: Bool
    @State private var steamId = ""
    let onSet: (String) -> Void
    private let modalCornerRadius: CGFloat = 20

    private var normalizedSteamId: String {
        steamId.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValidSteamId: Bool {
        !normalizedSteamId.isEmpty && normalizedSteamId.allSatisfy(\.isNumber)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Set Steam ID")
                .font(.title3.weight(.semibold))

            Text("""
            SwiftMiner uses Steam IDs to fetch high-resolution artwork for games.
            Without this, some games may appear with low-quality or missing images.
            """)
            .font(.body)
            .foregroundStyle(Color.secondary.opacity(0.82))
            .lineLimit(nil)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 10)

            TextField("e.g. 2073850", text: $steamId)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .focused($isInputFocused)
                .onSubmit {
                    submitIfValid()
                }
                .opacity(0.82)
                .padding(.top, 16)

            Text("You can find this on SteamDB or the game's store page.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .opacity(0.76)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)

            HStack(spacing: 14) {
                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(SteamSecondaryGlassButtonStyle())
                .keyboardShortcut(.cancelAction)

                Button("Set") {
                    submitIfValid()
                }
                .buttonStyle(SteamPrimaryGlassButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!isValidSteamId)
            }
            .padding(.top, 18)
        }
        .frame(maxWidth: 420, alignment: .leading)
        .padding(24)
        .background {
            RoundedRectangle(cornerRadius: modalCornerRadius, style: .continuous)
                .fill(.thinMaterial.opacity(0.50))
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.12),
                            Color.white.opacity(0.03),
                            .clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(height: 1)
                .padding(.horizontal, 16)
                .blendMode(.screen)
        }
        .shadow(color: .black.opacity(0.055), radius: 46, y: 14)
        .scaleEffect(1.001)
        .padding(20)
        .onAppear {
            isInputFocused = true
        }
    }

    private func submitIfValid() {
        guard isValidSteamId else { return }
        onSet(normalizedSteamId)
        dismiss()
    }
}

private struct SteamPrimaryGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryBody(configuration: configuration)
    }

    private struct PrimaryBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(isEnabled ? 0.96 : 0.72))
                .padding(.horizontal, 15)
                .padding(.vertical, 8)
                .background {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(.ultraThinMaterial.opacity(0.58))
                        .overlay {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(Color.accentColor.opacity(isHovering ? 0.34 : 0.30))
                        }
                        .overlay(alignment: .top) {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color.white.opacity(0.20),
                                            .clear
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .padding(0.5)
                                .blendMode(.screen)
                        }
                }
                .brightness(isHovering ? 0.028 : 0)
                .brightness(configuration.isPressed ? -0.06 : 0)
                .opacity(isEnabled ? 1 : 0.65)
                .onHover { hovering in
                    isHovering = hovering
                }
                .animation(.easeInOut(duration: 0.16), value: isHovering)
                .animation(.easeInOut(duration: 0.10), value: configuration.isPressed)
        }
    }
}

private struct SteamSecondaryGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SecondaryBody(configuration: configuration)
    }

    private struct SecondaryBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(isHovering ? 0.08 : 0.01))
                }
                .opacity(configuration.isPressed ? 0.78 : (isEnabled ? 0.58 : 0.42))
                .onHover { hovering in
                    isHovering = hovering
                }
                .animation(.easeInOut(duration: 0.16), value: isHovering)
                .animation(.easeInOut(duration: 0.10), value: configuration.isPressed)
        }
    }
}

private struct CampaignCardMotionOverlay: View {
    let tint: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: false)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let x = 0.2 + 0.6 * ((sin(t * 0.45) + 1) / 2)
            let y = 0.28 + 0.28 * ((cos(t * 0.32) + 1) / 2)

            ZStack {
                RadialGradient(
                    colors: [tint.opacity(0.28), tint.opacity(0.10), .clear],
                    center: UnitPoint(x: x, y: y),
                    startRadius: 12,
                    endRadius: 180
                )

                LinearGradient(
                    colors: [.clear, tint.opacity(0.12), .clear],
                    startPoint: UnitPoint(x: x - 0.2, y: 0),
                    endPoint: UnitPoint(x: x + 0.2, y: 1)
                )
            }
        }
        .blendMode(.screen)
    }
}

private struct CampaignStandbyMotionOverlay: View {
    let tint: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: false)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            
            // Hue cycling (full cycle every 30s)
            let hueBase = (t * 0.033).truncatingRemainder(dividingBy: 1.0)
            
            // Noticeable but smooth multi-sinusoidal drift
            let driftX = 70 * sin(t * 0.12) + 30 * cos(t * 0.18)
            let driftY = 30 * cos(t * 0.08) + 15 * sin(t * 0.15)
            
            // Dynamic colors cycling through hues - boosted saturation and brightness for "fun" look
            let color1 = Color(hue: hueBase, saturation: 0.85, brightness: 0.95)
            let color2 = Color(hue: (hueBase + 0.33).truncatingRemainder(dividingBy: 1.0), saturation: 0.80, brightness: 0.90)
            let color3 = Color(hue: (hueBase + 0.66).truncatingRemainder(dividingBy: 1.0), saturation: 0.75, brightness: 0.85)
            let highlight = Color(hue: (hueBase + 0.15).truncatingRemainder(dividingBy: 1.0), saturation: 0.50, brightness: 1.0)

            ZStack {
                // Background base - deeper version of the primary cycling color
                Color(hue: hueBase, saturation: 0.90, brightness: 0.30)

                // 3 Overlapping vibrant soft shapes cycling colors
                GhostArtworkShape(color: color1.opacity(0.7), size: CGSize(width: 280, height: 240))
                    .offset(
                        x: -80 + driftX * 0.7,
                        y: -40 + driftY * 0.9
                    )
                    .scaleEffect(1.0 + 0.06 * sin(t * 0.14))

                GhostArtworkShape(color: color2.opacity(0.6), size: CGSize(width: 220, height: 260))
                    .offset(
                        x: 20 + driftX,
                        y: 30 + driftY * 1.1
                    )
                    .scaleEffect(1.0 - 0.04 * cos(t * 0.11))

                GhostArtworkShape(color: color3.opacity(0.55), size: CGSize(width: 240, height: 200))
                    .offset(
                        x: 90 + driftX * 1.3,
                        y: 70 + driftY * 1.4
                    )
                    .scaleEffect(1.0 + 0.03 * sin(t * 0.09))
                
                // Extra warm "light leak" highlight
                GhostArtworkShape(color: highlight.opacity(0.22), size: CGSize(width: 200, height: 160))
                    .offset(
                        x: 40 + 50 * sin(t * 0.08),
                        y: -60 + 40 * cos(t * 0.06)
                    )
                    .blur(radius: 60)

                // Depth & Polish
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.18), // Glass top highlight
                        .clear,
                        Color.black.opacity(0.25)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .blendMode(.overlay)

                // Subtle vignette
                RadialGradient(
                    colors: [.clear, Color.black.opacity(0.15)],
                    center: .center,
                    startRadius: 90,
                    endRadius: 320
                )
                .blendMode(.multiply)
            }
        }
        .mask {
            RoundedRectangle(cornerRadius: GlassRadius.artwork, style: .continuous)
        }
        .blendMode(.screen)
    }
}

private struct GhostArtworkShape: View {
    let color: Color
    let size: CGSize

    var body: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: size.width * 0.34,
            bottomLeadingRadius: size.width * 0.18,
            bottomTrailingRadius: size.width * 0.32,
            topTrailingRadius: size.width * 0.12,
            style: .continuous
        )
        .fill(color)
        .frame(width: size.width, height: size.height)
        .rotationEffect(.degrees(-18))
        .blur(radius: 42)
        .blendMode(.screen)
    }
}

private struct GameActionMenuLabel: View {
    let title: String
    var subtitle: String? = nil
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .center)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct CampaignAmbientRailCard: View {
    let title: String
    let subtitle: String
    let prominence: CampaignCardProminence
    let tint: Color

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [tint.opacity(0.5), tint.opacity(0.14), Color.white.opacity(0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(tint.opacity(0.22))
                .frame(width: prominence.size.width * 0.55)
                .blur(radius: 24)
                .offset(x: prominence.size.width * 0.22, y: -prominence.size.height * 0.18)

            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(prominence == .feature ? .title3.weight(.semibold) : .headline.weight(.semibold))

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            .padding(prominence == .compact ? 16 : 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial.opacity(0.5), in: RoundedRectangle(cornerRadius: GlassRadius.medium, style: .continuous))
            .padding(14)
        }
        .frame(width: prominence.size.width, height: prominence.size.height)
        .background(.thinMaterial.opacity(0.5), in: RoundedRectangle(cornerRadius: GlassRadius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: GlassRadius.medium, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.06), radius: 4, y: 1)
    }
}

private struct CampaignWatcherStack: View {
    let watchers: [CampaignWatcher]
    let size: CGFloat
    private var avatarDiameter: CGFloat { size * 0.88 }

    var body: some View {
        HStack(spacing: -avatarDiameter * 0.24) {
            ForEach(Array(watchers.prefix(3).enumerated()), id: \.element.id) { index, watcher in
                let swatch = AvatarColorPalette.swatch(for: watcher.id, username: watcher.username)

                Text(watcher.initials)
                    .font(.system(size: avatarDiameter * 0.34, weight: .semibold, design: .rounded))
                    .tracking(0.16)
                    .foregroundStyle(swatch.text)
                    .frame(width: avatarDiameter, height: avatarDiameter)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay {
                        Circle()
                            .fill(swatch.gradient)
                            .opacity(0.9)
                    }
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
                        Circle()
                            .strokeBorder(.white.opacity(0.68), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.045), radius: 2, y: 1)
                    .zIndex(Double(watchers.count - index))
            }

            if watchers.count > 3 {
                Text("+\(watchers.count - 3)")
                    .font(.system(size: avatarDiameter * 0.32, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.75))
                    .frame(height: avatarDiameter)
                    .padding(.horizontal, avatarDiameter * 0.3)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay {
                        Capsule()
                            .strokeBorder(.white.opacity(0.56), lineWidth: 1)
                    }
                    .padding(.leading, 4)
            }
        }
    }
}

private struct CampaignStateBadge: View {
    let state: CampaignVisualState
    var titleOverride: String? = nil
    var useDarkForeground = true

    var body: some View {
        Label(titleOverride ?? state.label, systemImage: state.symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(useDarkForeground ? state.accent : .white.opacity(0.95))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                useDarkForeground
                    ? AnyShapeStyle(.thinMaterial)
                    : AnyShapeStyle(.ultraThinMaterial),
                in: Capsule()
            )
    }
}

private struct CampaignArtworkBackground: View {
    let url: URL?
    let tint: Color
    var useGhostArtworkPlaceholder = false

    var body: some View {
        ZStack {
            placeholder

            if let url {
                AsyncImage(
                    url: url.overviewHighResolutionArtworkURL,
                    transaction: Transaction(animation: .easeInOut(duration: 0.55))
                ) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .interpolation(.high)
                            .scaledToFill()
                            .transition(.opacity.combined(with: .scale(scale: 1.02)))
                    case .empty:
                        Color.clear
                    case .failure:
                        Color.clear
                    @unknown default:
                        Color.clear
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.55), value: url)
    }

    private var placeholder: some View {
        Group {
            if useGhostArtworkPlaceholder {
                ZStack {
                    // Match the deeper base
                    Color(red: 0.12, green: 0.11, blue: 0.28)

                    GhostArtworkShape(color: Color(hue: 0.0, saturation: 0.85, brightness: 0.95).opacity(0.5), size: CGSize(width: 250, height: 210))
                        .offset(x: -70, y: 8)

                    GhostArtworkShape(color: Color(hue: 0.33, saturation: 0.80, brightness: 0.90).opacity(0.45), size: CGSize(width: 184, height: 244))
                        .offset(x: 8, y: 48)

                    GhostArtworkShape(color: Color(hue: 0.66, saturation: 0.75, brightness: 0.85).opacity(0.4), size: CGSize(width: 208, height: 154))
                        .offset(x: 102, y: 94)

                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.15),
                            Color.clear,
                            Color.black.opacity(0.18)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .blendMode(.overlay)

                    RadialGradient(
                        colors: [.clear, Color.black.opacity(0.12)],
                        center: .center,
                        startRadius: 60,
                        endRadius: 280
                    )
                    .blendMode(.multiply)
                }
            } else {
                LinearGradient(
                    colors: [tint.opacity(0.85), tint.opacity(0.45), Color.black.opacity(0.45)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
    }
}

private struct CampaignThumbnail: View {
    let url: URL?
    let tint: Color

    var body: some View {
        ZStack {
            if let url {
                AsyncImage(url: url) { image in
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
        .clipShape(RoundedRectangle(cornerRadius: GlassRadius.artwork, style: .continuous))
    }

    private var placeholder: some View {
        LinearGradient(
            colors: [tint.opacity(0.65), tint.opacity(0.35), Color.white.opacity(0.14)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private extension URL {
    var overviewHighResolutionArtworkURL: URL {
        let replacements: [(String, String)] = [
            ("{width}", "600"),
            ("{height}", "800"),
            ("%7Bwidth%7D", "600"),
            ("%7Bheight%7D", "800")
        ]

        let resolved = replacements.reduce(absoluteString) { partial, pair in
            partial.replacingOccurrences(of: pair.0, with: pair.1)
        }

        return URL(string: resolved) ?? self
    }
}

private struct StatusReason {
    let title: String
    let summary: String
    let detail: String
    let badge: String
    let color: Color
}

private struct StatusReasonRowModel: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let status: String
    let color: Color
}

private struct StatusReasonRow: View {
    let row: StatusReasonRowModel

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(row.color)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.subheadline.weight(.semibold))
                Text(row.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(row.status)
                .font(.caption.weight(.medium))
                .foregroundStyle(row.color)
        }
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassCard()
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environment(NavigationModel(clientId: "preview"))
        .environment(AppModel(clientId: "preview"))
}
