import SwiftUI
import SwiftMinerCore
import AppKit
import UniformTypeIdentifiers

/// Root view — 2-column NavigationSplitView (Sidebar | Detail)
struct ContentView: View {
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        @Bindable var nav = navigation
        NavigationSplitView(columnVisibility: $nav.columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 180, max: 180)
        } detail: {
            detailContainer
        }
        .background(WindowZoomConfigurator())
        .frame(minWidth: 800, minHeight: 600)
        .sheet(isPresented: $nav.showAddAccountSheet) {
            AuthRequiredSheet(
                isPresented: $nav.showAddAccountSheet,
                reconnectingMinerId: nav.reconnectingMinerId
            )
                .environment(navigation)
                .onDisappear {
                    navigation.reconnectingMinerId = nil
                }
        }
        .onAppear {
            navigation.columnVisibility = .all
            navigation.preloadDropsTab()
        }
        .onChange(of: navigation.minerManager.miners.count) { _, _ in
            navigation.handleAccountCountChange()
            navigation.preloadDropsTab(force: true)
        }
    }

    // MARK: - Detail View

    private var detailContainer: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            detailView
                .id(navigation.selectedItem ?? .overview)
        }
        .animation(nil, value: navigation.selectedItem)
    }

    @ViewBuilder
    private var detailView: some View {
        switch navigation.selectedItem {
        case .overview, .none:
            OverviewView()

        case .miners:
            MinersOverviewView()

        case .drops:
            DropsListView()

        case .events:
            EventLogView()

        case .admin:
            if Settings.shared.swiftBotEnabled {
                AdminView()
            } else {
                OverviewView()
            }
        }
    }
}

// MARK: - Overview View

enum OverviewArtworkResolver {
    static func artworkURL(
        for preference: GamePreference,
        campaigns: [CampaignViewData]
    ) -> URL? {
        campaigns.lazy.compactMap { campaign in
            guard matches(
                gameId: campaign.gameId,
                gameName: campaign.gameName,
                preference: preference
            ) else { return nil }
            return usable(campaign.artworkURL)
        }.first
    }

    static func artworkURL(
        for preference: GamePreference,
        campaigns: [Campaign]
    ) -> URL? {
        campaigns.lazy.compactMap { campaign in
            guard matches(
                gameId: campaign.game.id,
                gameName: campaign.game.name,
                preference: preference
            ) else { return nil }
            return usable(campaign.game.boxArtURL)
        }.first
    }

    static func matches(
        gameId: String?,
        gameName: String,
        preference: GamePreference
    ) -> Bool {
        let idMatches = gameId.map { !$0.isEmpty && $0 == preference.gameId } ?? false
        let nameMatches = gameName.localizedCaseInsensitiveCompare(preference.gameName) == .orderedSame
            || comparableName(gameName) == comparableName(preference.gameName)
        return idMatches || nameMatches
    }

    private static func usable(_ url: URL?) -> URL? {
        guard let url else { return nil }
        guard url.isFileURL else { return url }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func comparableName(_ value: String) -> String {
        value
            .lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }
}

struct OverviewView: View {
    @Environment(NavigationModel.self) private var navigation
    private var settings: Settings { .shared }
    @State private var overviewCampaigns: [CampaignViewData] = []
    @State private var isRefreshing = false
    @State private var steamIdSheetPresentation: SteamIdSheetPresentation?
    @State private var isShowingGameManagement = false
    @State private var customArtworkImportGame: Game?
    @State private var isShowingArtworkImporter = false
    @State private var isMinerStatusLegendPresented = false

    private var campaigns: [CampaignViewData] {
        // Resolve the exclusion list once, not once per campaign inside the filter.
        let excluded = settings.excludedGames
        return overviewCampaigns
            .filter { campaign in
                !excluded.contains(where: {
                    $0.localizedCaseInsensitiveCompare(campaign.gameName) == .orderedSame
                })
            }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !navigation.minerManager.miners.isEmpty {
                    systemStateBanner
                }
                minerActivitySection
                campaignFeedSection
            }
            .padding(24)
        }
        .navigationTitle("Overview")
        .onReceive(NotificationCenter.default.publisher(for: .steamArtworkDidUpdate)) { _ in
            Task { @MainActor in
                applyOverviewCampaigns(await navigation.minerManager.dataCoordinator.allCampaigns(
                    preferSteamArtwork: settings.preferSteamArtwork
                ))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .dropsCampaignsDidUpdate)) { _ in
            // Miner registration makes the per-account disk caches available after
            // Overview's first task may already have returned empty. Drops listens to
            // this same event; keep Overview on the same source-of-truth timeline.
            Task { @MainActor in
                applyOverviewCampaigns(await navigation.minerManager.dataCoordinator.allCampaigns(
                    preferSteamArtwork: settings.preferSteamArtwork
                ))
                await enrichPreferredGameArtwork()
            }
        }
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
        .sheet(isPresented: $isShowingGameManagement) {
            GamePreferenceManagementView(
                settings: settings,
                minerManager: navigation.minerManager
            )
        }
        .fileImporter(
            isPresented: $isShowingArtworkImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            guard let game = customArtworkImportGame else { return }
            defer { customArtworkImportGame = nil }

            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    try settings.setCustomArtwork(from: url, for: game)
                } catch {
                    print("[Overview] Custom artwork import failed: \(error.localizedDescription)")
                }
            case .failure(let error):
                print("[Overview] Custom artwork selection failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - System State

    private var systemStateBanner: some View {
        OverviewSystemStateBanner(
            state: overviewSystemState,
            fleet: MinerFleetStatus.make(miners: displayedMiners),
            onAction: handleSystemStateAction(_:)
        )
    }

    /// Miners the Overview renders. Normally exactly the real ones; in DEBUG it
    /// can be padded for marketing screenshots — see `demoExpanded(_:)`.
    private var displayedMiners: [MinerManager.ManagedMiner] {
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
    static func demoExpanded(_ miners: [MinerManager.ManagedMiner]) -> [MinerManager.ManagedMiner] {
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
    private func applyOverviewCampaigns(_ fresh: [CampaignViewData]) {
        if fresh != overviewCampaigns {
            overviewCampaigns = fresh
        }
    }

    private func refreshSummary() async {
        isRefreshing = true
        if overviewCampaigns.isEmpty && !navigation.minerManager.dataCoordinator.lastKnownAllCampaigns.isEmpty {
            overviewCampaigns = navigation.minerManager.dataCoordinator.lastKnownAllCampaigns
        }
        applyOverviewCampaigns(await navigation.minerManager.dataCoordinator.allCampaigns(
            preferSteamArtwork: Settings.shared.preferSteamArtwork
        ))
        await enrichPreferredGameArtwork()
        isRefreshing = false
    }

    private func refreshFromOverview() async {
        isRefreshing = true
        defer { isRefreshing = false }

        await navigation.restartMinersAndRefreshOverviewData()

        applyOverviewCampaigns(await navigation.minerManager.dataCoordinator.allCampaigns(
            preferSteamArtwork: Settings.shared.preferSteamArtwork
        ))
        await enrichPreferredGameArtwork()
    }

    /// Enriches `steamArtworkOverrides` for preferred games that have no active campaign.
    /// Already-resolved and custom-artwork games are skipped so returning to Overview does
    /// not repeat Steam lookups that cannot change the visible cards.
    private func enrichPreferredGameArtwork() async {
        guard settings.preferSteamArtwork else { return }
        let existingArtwork = navigation.minerManager.dataCoordinator.steamArtworkOverrides
        let names = settings.gamePreferences
            .filter {
                $0.state == .preferred
                    && $0.customArtworkURL == nil
                    && existingArtwork[$0.gameName] == nil
            }
            .map(\.gameName)
        guard !names.isEmpty else { return }
        await navigation.minerManager.dataCoordinator.enrichGameNames(names)
    }

    private func presentSteamIdSheet(for gameName: String) {
        steamIdSheetPresentation = SteamIdSheetPresentation(gameName: gameName)
    }

    private func presentCustomArtworkImporter(for game: Game) {
        customArtworkImportGame = game
        DispatchQueue.main.async {
            isShowingArtworkImporter = true
        }
    }

    private func applySteamAppId(_ appId: String, for gameName: String) {
        guard SteamArtworkService.supportsSteamArtwork(forGameName: gameName) else {
            return
        }

        Task {
            await SteamArtworkService.shared.setManualAppId(for: gameName, appId: appId)
            // enrichGameNames posts .steamArtworkDidUpdate, which refreshes
            // overviewCampaigns above — no manual invalidation needed.
            await navigation.minerManager.dataCoordinator.enrichGameNames([gameName])
        }
    }

    // MARK: - Miner Activity

    private var minerActivitySection: some View {
        let miners = displayedMiners

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                sectionHeading("Miner Activity")

                Button {
                    isMinerStatusLegendPresented.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Explain miner card statuses")
                .popover(isPresented: $isMinerStatusLegendPresented, arrowEdge: .top) {
                    MinerStatusLegendPopover()
                }

                Spacer()

                Button {
                    navigation.showAddAccountSheet = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Add a Twitch account")
            }

            if miners.isEmpty {
                MaterialEmptyStatePanel(
                    "No Twitch accounts connected",
                    systemImage: "person.badge.plus",
                    description: "Add an account to see what each miner is mining now."
                ) {
                    Button {
                        navigation.showAddAccountSheet = true
                    } label: {
                        Label("Add Account", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                LazyVGrid(columns: minerActivityColumns, spacing: 14) {
                    ForEach(miners) { miner in
                        MinerActivityCard(miner: miner, prominence: .compact, onSelect: {
                            navigation.selectedMinerId = miner.id
                            navigation.selectedItem = .miners
                        })
                    }
                }
            }
        }
    }

    private var minerActivityColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 300), spacing: 14, alignment: .top)]
    }

    private var activeCampaignCount: Int {
        let now = Date()
        return campaigns
            .filter { campaign in
                campaign.isAccountConnected
                    && campaign.startDate <= now
                    && campaign.endDate > now
                    && !campaign.isCompleted
                    && campaign.overviewRemainingRewardCount > 0
            }
            .count
    }

    // MARK: - Campaign Feed

    private var campaignFeedSection: some View {
        // Build the (expensive) prioritised feed once per render. Previously this
        // chain was re-derived 3-4× per render — for `.isEmpty`, the `items:`
        // argument, and the `.onChange(of: …count)` keypath, which SwiftUI
        // re-evaluates on every render.
        let items = displayedPrioritisedFeedItems
        return VStack(alignment: .leading, spacing: 24) {
            if !items.isEmpty {
                campaignRailSection(
                    title: "Prioritised",
                    items: items,
                    prominence: .standard,
                    showsEditButton: true,
                    layout: .grid
                )
            } else {
                addPrioritisedGameSection
            }
        }
        .padding(.vertical, 2)
    }

    private var addPrioritisedGameSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeading("Prioritised")

            MaterialEmptyStatePanel(
                "No prioritised games",
                systemImage: "star",
                description: "Add a game to keep it surfaced here and mine it first when drops are available."
            ) {
                Button {
                    isShowingGameManagement = true
                } label: {
                    Label("Add Prioritised Game", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, minHeight: 180)
        }
    }

    @ViewBuilder
    private func campaignRailSection(
        title: String,
        items: [CampaignRailItem],
        prominence: CampaignCardProminence,
        showsEditButton: Bool = false,
        layout: CampaignRailLayout = .horizontal,
        onMoveItem: ((CampaignRailItem, Int) -> Void)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                sectionHeading(title)

                Spacer()

                if showsEditButton {
                    Button {
                        isShowingGameManagement = true
                    } label: {
                        Label("Edit", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            switch layout {
            case .horizontal:
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: prominence.spacing) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            ReorderableCampaignFeedCard(
                                item: item,
                                index: index,
                                itemCount: items.count,
                                prominence: prominence,
                                activeDragIndex: activePriorityDragIndex,
                                projectedDropIndex: projectedPriorityDropIndex,
                                activeDragProgress: activePriorityDragProgress,
                                onSetSteamId: presentSteamIdSheet(for:),
                                onUploadCustomArtwork: presentCustomArtworkImporter(for:),
                                onDragProjectionChanged: updatePriorityDragProjection,
                                onDragEnded: clearPriorityDragProjection,
                                onMoveItem: onMoveItem
                            )
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 6)
                }
                .scrollClipDisabled()
            case .staggered:
                StaggeredCampaignRail(
                    items: items,
                    prominence: prominence,
                    onSetSteamId: presentSteamIdSheet(for:),
                    onUploadCustomArtwork: presentCustomArtworkImporter(for:)
                )
                .padding(.horizontal, 2)
                .padding(.vertical, 6)
            case .grid:
                LazyVGrid(
                    columns: [
                        GridItem(
                            .adaptive(
                                minimum: prominence.size.width,
                                maximum: prominence.size.width
                            ),
                            spacing: prominence.spacing,
                            alignment: .top
                        )
                    ],
                    alignment: .leading,
                    spacing: prominence.spacing
                ) {
                    ForEach(items) { item in
                        CampaignFeedCard(
                            item: item,
                            prominence: prominence,
                            onSetSteamId: presentSteamIdSheet(for:),
                            onUploadCustomArtwork: presentCustomArtworkImporter(for:)
                        )
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 6)
            }
        }
    }

    private var preferredGames: [GamePreference] {
        settings.gamePreferences.filter { $0.state == .preferred }
    }

    private var prioritisedCampaigns: [CampaignViewData] {
        campaigns
            .filter { campaign in
                (campaign.relevance == .prioritised || preferredGames.contains(where: { matches(campaign, preference: $0) }))
                    && isPrioritisedRailEligible(campaign)
            }
            .sorted(by: campaignDisplaySort)
    }


    private var uniquePrioritisedCampaigns: [CampaignViewData] {
        var seen = Set<String>()
        return prioritisedCampaigns.filter { campaign in
            let normalizedName = normalizedGameKey(campaign.gameName)
            let key = normalizedName.isEmpty ? normalizedGameKey(campaign.gameId ?? campaign.id) : normalizedName
            return seen.insert(key).inserted
        }
    }


    private func isPrioritisedRailEligible(_ campaign: CampaignViewData) -> Bool {
        campaign.isDisplayableInOverview
            || (campaign.relevance == .prioritised && !campaign.isCompleted)
    }


    private var prioritisedFeedItems: [CampaignRailItem] {
        let campaignPool = uniquePrioritisedCampaigns
        var usedCampaignIds = Set<String>()
        var items: [CampaignRailItem] = []

        for preference in preferredGames {
            if let campaign = campaignPool.first(where: { campaign in
                !usedCampaignIds.contains(campaign.id) && matches(campaign, preference: preference)
            }) {
                usedCampaignIds.insert(campaign.id)
                items.append(makeRailItem(for: campaign, section: .prioritised))
            } else {
                items.append(makePreferredGameItem(preference))
            }
        }

        let unpinnedCampaigns = campaignPool
            .filter { !usedCampaignIds.contains($0.id) }
            .map { makeRailItem(for: $0, section: .prioritised) }

        items.append(contentsOf: unpinnedCampaigns)
        return Array(deduplicatedPrioritisedItems(items).prefix(12))
    }

    private var displayedPrioritisedFeedItems: [CampaignRailItem] {
        prioritisedFeedItems
    }

    private func makeRailItem(for campaign: CampaignViewData, section: CampaignFeedSection) -> CampaignRailItem {
        var state = visualState(for: campaign)
        if state == .idle && isBeingWatched(campaign) {
            state = .watching
        }
        let game = Game(id: campaign.gameId ?? campaign.id, name: campaign.gameName, boxArtURL: campaign.artworkURL)
        let preference = preferredPreference(matching: game)
        let artworkURL = preference?.customArtworkURL
            ?? (
                SteamArtworkService.supportsSteamArtwork(forGameName: campaign.gameName, gameId: campaign.gameId)
                    ? navigation.minerManager.dataCoordinator.steamArtworkOverrides[campaign.gameName] ?? campaign.artworkURL
                    : campaign.artworkURL
            )
        return CampaignRailItem(
            id: "\(section.rawValue)-\(campaign.id)",
            section: section,
            gameName: campaign.gameName,
            campaignName: campaign.campaignName,
            progressText: campaignDetailText(for: campaign, state: state),
            progressPercent: campaignProgressPercent(for: campaign),
            artworkURL: artworkURL,
            tint: tintColor(for: campaign),
            hasOnlyBadgesOrEmotes: false,
            visualState: state,
            watchers: watchers(for: campaign),
            isDimmed: state == .claimed,
            isPlaceholder: false,
            showsLiveMotion: section == .active && (state == .watching || state == .inProgress || state == .claimable),
            usesCustomArtwork: preference?.customArtworkURL != nil,
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

    private func normalizedGameKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func comparableGameName(_ value: String) -> String {
        value
            .lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private func startLinkAccountFlow(for miner: MinerManager.ManagedMiner) {
        navigation.reconnectTwitchAccount(for: miner.id)
    }

    private func isGameExcluded(_ gameName: String) -> Bool {
        settings.excludedGames.contains(where: { $0.localizedCaseInsensitiveCompare(gameName) == .orderedSame })
    }

    private func makePreferredGameItem(_ preference: GamePreference) -> CampaignRailItem {
        let supportsSteamArtwork = SteamArtworkService.supportsSteamArtwork(
            forGameName: preference.gameName,
            gameId: preference.gameId
        )
        // This item is built precisely because the game has no *eligible* campaign,
        // but an ineligible one (completed, unlinked) usually still exists and
        // carries live Twitch art. Preferences hold no remote URL of their own once
        // a dead cache path is discarded, so without this the tile drops to initials.
        let campaignArtwork = OverviewArtworkResolver.artworkURL(
            for: preference,
            campaigns: campaigns
        ) ?? OverviewArtworkResolver.artworkURL(
            for: preference,
            campaigns: navigation.minerManager.miners.flatMap(\.allCampaigns)
        )

        let artworkURL = preference.customArtworkURL
            ?? (
                supportsSteamArtwork
                    ? navigation.minerManager.dataCoordinator.steamArtworkOverrides[preference.gameName]
                        ?? preference.resolvedBoxArtURL
                        ?? campaignArtwork
                    : preference.resolvedBoxArtURL ?? campaignArtwork
            )
        return CampaignRailItem(
            id: "preferred-\(preference.gameId.isEmpty ? preference.gameName : preference.gameId)",
            section: .prioritised,
            gameName: preference.gameName,
            campaignName: "",
            progressText: "Your preferred games are ready for the next campaign.",
            progressPercent: 0,
            artworkURL: artworkURL,
            tint: .secondary,
            hasOnlyBadgesOrEmotes: false,
            visualState: .idle,
            watchers: [],
            isDimmed: false,
            isPlaceholder: false,
            showsLiveMotion: false,
            usesCustomArtwork: preference.customArtworkURL != nil,
            game: Game(id: preference.gameId, name: preference.gameName, boxArtURL: artworkURL)
        )
    }

    private func movePrioritisedItem(_ item: CampaignRailItem, to targetIndex: Int) {
        guard let game = item.game else { return }
        let preferred = preferredGames
        guard preferred.count > 1,
              let sourceIndex = preferred.firstIndex(where: { preferenceMatches($0, game: game) }) else {
            return
        }

        let destinationIndex = min(max(targetIndex, 0), preferred.count - 1)
        guard sourceIndex != destinationIndex else { return }

        let toOffset = sourceIndex < destinationIndex ? destinationIndex + 1 : destinationIndex
        withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
            settings.moveGamePreferences(
                fromOffsets: IndexSet(integer: sourceIndex),
                toOffset: toOffset,
                inState: .preferred
            )
        }
        navigation.minerManager.updatePriorityGames(resolving: { settings.priorityGames(forAccountId: $0.accountId) })
    }

    @State private var activePriorityDragIndex: Int?
    @State private var projectedPriorityDropIndex: Int?
    @State private var activePriorityDragProgress: CGFloat = 0

    private func updatePriorityDragProjection(activeIndex: Int, projectedIndex: Int, progress: CGFloat) {
        guard activePriorityDragIndex != activeIndex
                || projectedPriorityDropIndex != projectedIndex
                || activePriorityDragProgress != progress else {
            return
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            activePriorityDragIndex = activeIndex
            projectedPriorityDropIndex = projectedIndex
            activePriorityDragProgress = progress
        }
    }

    private func clearPriorityDragProjection() {
        withAnimation(.interactiveSpring(response: 0.24, dampingFraction: 0.88, blendDuration: 0.08)) {
            activePriorityDragIndex = nil
            projectedPriorityDropIndex = nil
            activePriorityDragProgress = 0
        }
    }

    private func preferredPreference(matching game: Game) -> GamePreference? {
        let matches = settings.gamePreferences.filter { preference in
            preferenceMatches(preference, game: game)
        }

        return matches.first(where: { $0.customArtworkURL != nil }) ?? matches.first
    }

    private func preferenceMatches(_ preference: GamePreference, game: Game) -> Bool {
        let idMatches = !game.id.isEmpty && preference.gameId == game.id
        let nameMatches = preference.gameName.localizedCaseInsensitiveCompare(game.name) == .orderedSame
            || comparableGameName(preference.gameName) == comparableGameName(game.name)
        return idMatches || nameMatches
    }

    private func deduplicatedPrioritisedItems(_ items: [CampaignRailItem]) -> [CampaignRailItem] {
        var seenIds = Set<String>()
        var seenNames = Set<String>()
        return items.filter { item in
            let id = item.game?.id.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let name = comparableGameName(item.gameName)

            if (!id.isEmpty && seenIds.contains(id)) || (!name.isEmpty && seenNames.contains(name)) {
                return false
            }

            if !id.isEmpty {
                seenIds.insert(id)
            }
            if !name.isEmpty {
                seenNames.insert(name)
            }

            return true
        }
    }

    private func placeholderRailItem(for section: CampaignFeedSection) -> CampaignRailItem {
        switch section {
        case .prioritised:
            return CampaignRailItem(
                id: "placeholder-prioritised",
                section: .prioritised,
                gameName: settings.priorityGames.isEmpty ? "Pin favourites" : "Prioritised",
                campaignName: settings.priorityGames.isEmpty ? "Choose games to keep anchored here" : "Selected games stay surfaced first",
                progressText: settings.priorityGames.isEmpty
                    ? "Add preferred games in Settings."
                    : "Your preferred games are ready for the next campaign.",
                progressPercent: 0,
                artworkURL: preferredGames.first.flatMap { pref in
                    pref.customArtworkURL
                        ?? (
                            SteamArtworkService.supportsSteamArtwork(
                                forGameName: pref.gameName,
                                gameId: pref.gameId
                            )
                            ? navigation.minerManager.dataCoordinator.steamArtworkOverrides[pref.gameName]
                                ?? (settings.preferSteamArtwork ? nil : pref.resolvedBoxArtURL)
                            : pref.resolvedBoxArtURL
                        )
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
            return CampaignRailItem(
                id: "placeholder-active",
                section: .active,
                gameName: "No eligible campaigns",
                campaignName: "No campaign is mineable right now",
                progressText: "No eligible campaigns are available right now.",
                progressPercent: 0,
                artworkURL: nil,
                tint: .secondary,
                hasOnlyBadgesOrEmotes: false,
                visualState: .idle,
                watchers: [],
                isDimmed: false,
                isPlaceholder: true,
                showsLiveMotion: false
            )
        case .recent:
            return CampaignRailItem(
                id: "placeholder-recent",
                section: .recent,
                gameName: "Recent",
                campaignName: "Freshly claimed campaigns land here",
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
        OverviewArtworkResolver.matches(
            gameId: campaign.gameId,
            gameName: campaign.gameName,
            preference: preference
        )
    }

    private func campaignDetailText(
        for campaign: CampaignViewData,
        state: CampaignVisualState
    ) -> String {
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
        if !miner.isRunning {
            switch miner.status {
            case .authenticating:
                return "Starting..."
            case .paused:
                return "Paused"
            case .error:
                return "Blocked — Needs attention"
            case .idle,
                 .fetchingCampaigns,
                 .watching,
                 .claiming,
                 .waitingForStream,
                 .idleNoEligibleCampaigns,
                 .blockedAccountNotLinked:
                return "Stopped"
            }
        }
        switch miner.status {
        case .idle:
            return "Up to Date"
        case .authenticating:
            return "Reconnecting"
        case .fetchingCampaigns:
            return "Updating…"
        case .watching:
            return "Watching — \(miner.currentCampaign ?? "active campaign")"
        case .waitingForStream:
            return "Looking for Streams"
        case .claiming:
            return "Claiming Rewards"
        case .paused:
            return "Paused — Mining is paused"
        case .idleNoEligibleCampaigns:
            return "Up to Date"
        case .blockedAccountNotLinked:
            return "Blocked — Account not linked"
        case .error:
            return "Blocked — Needs attention"
        }
    }

    private func tintColor(for campaign: CampaignViewData) -> Color {
        return gameTintColor(forGameName: campaign.gameName)
    }

// MARK: - Miner Status Legend Popover

private struct MinerStatusLegendPopover: View {
    private var settings: Settings { .shared }

    private struct StatusEntry {
        let symbol: String
        let paletteColors: (Color, Color)?
        let monoColor: Color
        let title: String
        let description: String
    }

    private var entries: [StatusEntry] {
        [
            StatusEntry(
                symbol: "dot.radiowaves.left.and.right",
                paletteColors: nil,
                monoColor: .green,
                title: "Watching",
                description: "Actively watching a live stream and earning drops."
            ),
            StatusEntry(
                symbol: "gift.fill",
                paletteColors: nil,
                monoColor: .purple,
                title: "Claiming Reward",
                description: "A completed drop is being claimed from Twitch."
            ),
            StatusEntry(
                symbol: "arrow.clockwise",
                paletteColors: nil,
                monoColor: .blue,
                title: "Updating",
                description: "Refreshing campaigns and verified drop progress from Twitch."
            ),
            StatusEntry(
                symbol: "antenna.radiowaves.left.and.right",
                paletteColors: nil,
                monoColor: .cyan,
                title: "Looking for Streams",
                description: "Eligible campaigns found — waiting for a live channel to become available."
            ),
            StatusEntry(
                symbol: "calendar.badge.checkmark",
                paletteColors: (.green, .red),
                monoColor: .green,
                title: "Up to Date",
                description: "No drops left to earn right now. The miner is standing by."
            ),
            StatusEntry(
                symbol: "clock.badge.exclamationmark",
                paletteColors: (.red, Color(nsColor: .labelColor)),
                monoColor: .yellow,
                title: "No Recent Activity",
                description: "Worker is running but hasn't reported a liveness signal yet."
            ),
            StatusEntry(
                symbol: "wrench.and.screwdriver.fill",
                paletteColors: nil,
                monoColor: .orange,
                title: "Recovering",
                description: "Restarting the miner and rebuilding Twitch subscriptions after a stall."
            ),
            StatusEntry(
                symbol: "bolt.horizontal.circle.fill",
                paletteColors: nil,
                monoColor: .red,
                title: "Miner Unresponsive",
                description: "This miner stopped receiving Twitch activity while others are still active."
            ),
            StatusEntry(
                symbol: "personalhotspot.slash",
                paletteColors: nil,
                monoColor: .orange,
                title: "Account Not Linked",
                description: "The game account must be connected on Twitch before drops can be earned."
            ),
            StatusEntry(
                symbol: "person.crop.circle.badge.exclamationmark",
                paletteColors: nil,
                monoColor: .orange,
                title: "Authentication Expired",
                description: "Twitch credentials have expired. Re-link the account to resume."
            ),
            StatusEntry(
                symbol: "arrow.triangle.2.circlepath",
                paletteColors: nil,
                monoColor: .orange,
                title: "Reconnecting",
                description: "Refreshing the Twitch session after a token or network interruption."
            ),
            StatusEntry(
                symbol: "exclamationmark.triangle.fill",
                paletteColors: nil,
                monoColor: .red,
                title: "Error",
                description: "Something went wrong. Check the Activity Log for details."
            ),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Miner Card Statuses")
                .font(.headline)

            VStack(alignment: .leading, spacing: 11) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    HStack(alignment: .top, spacing: 10) {
                        Group {
                            if let (primary, secondary) = entry.paletteColors {
                                Image(systemName: entry.symbol)
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(primary, secondary)
                            } else {
                                Image(systemName: entry.symbol)
                                    .foregroundStyle(entry.monoColor)
                            }
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 20, alignment: .center)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title)
                                .font(.system(size: 13, weight: .semibold))

                            Text(entry.description)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineSpacing(1.5)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
    }
}

    @ViewBuilder
    private func sectionHeading(_ title: String) -> some View {
        Text(title)
            .font(.title3.weight(.medium))
            .padding(.top, 10)
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
        .padding(.top, 10)
    }
}

// MARK: - Supporting Types

private enum OverviewSystemState: Equatable {
    case idleNoEligibleCampaigns
    case idleAllCampaignsCompleted
    case waitingForLiveStream
    case waitingRefreshingCampaigns
    case waitingAuthenticating
    case minerUnresponsive
    case recovering
    case noRecentActivity
    case blockedAccountNotLinked(minerName: String?, blockedCount: Int)
    case blockedAuthenticationExpired
    case blockedNeedsAttention
    case mining(activeMinerCount: Int, totalMinerCount: Int)

    var title: String {
        switch self {
        case .idleNoEligibleCampaigns, .idleAllCampaignsCompleted:
            return "Up to Date"
        case .waitingForLiveStream:
            return "Looking for Streams"
        case .waitingRefreshingCampaigns:
            return "Updating…"
        case .waitingAuthenticating:
            return "Reconnecting"
        case .recovering:
            return "Waiting"
        case .minerUnresponsive, .noRecentActivity:
            return "Attention"
        case .blockedAccountNotLinked(let minerName, let blockedCount):
            if let minerName {
                return "\(minerName) is blocked"
            }
            return "\(blockedCount) miners blocked"
        case .blockedAuthenticationExpired, .blockedNeedsAttention:
            return "Blocked"
        case .mining:
            return "Mining Active"
        }
    }

    var subtitle: String {
        switch self {
        case .idleNoEligibleCampaigns:
            return "No active campaigns are available right now."
        case .idleAllCampaignsCompleted:
            return "All campaigns have been earned and completed."
        case .waitingForLiveStream:
            return "Checking channels for active streams."
        case .waitingRefreshingCampaigns:
            return "Checking campaigns and drop progress."
        case .waitingAuthenticating:
            return "Reconnecting and restoring Twitch subscriptions."
        case .minerUnresponsive:
            return "One or more miners stopped receiving Twitch activity while other miners are still active."
        case .recovering:
            return "A miner is being restarted and refreshed automatically."
        case .noRecentActivity:
            return "A miner is running but has not reported recent activity yet."
        case .blockedAccountNotLinked(let minerName, let blockedCount):
            if let minerName {
                return "Account not linked. Link \(minerName)'s account to start mining drops."
            }
            return "\(blockedCount) miners need account linking before they can mine drops."
        case .blockedAuthenticationExpired:
            return "Account authentication expired. Please re-connect."
        case .blockedNeedsAttention:
            return "Check Activity Log for the latest issue before mining can continue."
        case .mining(let activeMinerCount, let totalMinerCount):
            if totalMinerCount <= 1 {
                return "Miner is currently active."
            }
            if activeMinerCount == totalMinerCount {
                return "All miners are currently active."
            }
            return "\(activeMinerCount) of \(totalMinerCount) miners are currently active."
        }
    }

    var symbol: String {
        switch self {
        case .idleNoEligibleCampaigns:
            return "calendar.badge.checkmark"
        case .idleAllCampaignsCompleted:
            return "calendar.badge.checkmark"
        case .waitingForLiveStream:
            return "antenna.radiowaves.left.and.right"
        case .waitingRefreshingCampaigns:
            return "arrow.clockwise"
        case .waitingAuthenticating:
            return "arrow.triangle.2.circlepath"
        case .minerUnresponsive:
            return "bolt.horizontal.circle.fill"
        case .recovering:
            return "wrench.and.screwdriver.fill"
        case .noRecentActivity:
            return "checkmark.circle.trianglebadge.exclamationmark.fill"
        case .blockedAccountNotLinked:
            return "personalhotspot.slash"
        case .blockedAuthenticationExpired, .blockedNeedsAttention:
            return "exclamationmark.triangle.fill"
        case .mining:
            return "dot.radiowaves.left.and.right"
        }
    }

    var color: Color {
        switch self {
        case .idleNoEligibleCampaigns, .idleAllCampaignsCompleted:
            return .green
        case .waitingForLiveStream:
            return .cyan
        case .waitingRefreshingCampaigns:
            return .blue
        case .waitingAuthenticating:
            return .orange
        case .minerUnresponsive:
            return .red
        case .recovering:
            return .orange
        case .noRecentActivity:
            return .yellow
        case .blockedAccountNotLinked, .blockedAuthenticationExpired, .blockedNeedsAttention:
            return .orange
        case .mining:
            return .green
        }
    }

    var action: OverviewSystemAction? {
        switch self {
        case .idleNoEligibleCampaigns, .idleAllCampaignsCompleted:
            return .viewDrops
        case .waitingForLiveStream, .waitingAuthenticating, .recovering:
            return .viewSchedule
        case .waitingRefreshingCampaigns:
            return nil
        case .minerUnresponsive, .noRecentActivity:
            return nil
        case .blockedAccountNotLinked, .blockedAuthenticationExpired, .blockedNeedsAttention:
            return .linkAccount
        case .mining:
            return nil
        }
    }
}

private enum OverviewSystemAction {
    case viewDrops
    case viewSchedule
    case linkAccount

    var title: String {
        switch self {
        case .viewDrops:
            return "View Drops"
        case .viewSchedule:
            return "View Schedule"
        case .linkAccount:
            return "Link Account"
        }
    }
}

private struct OverviewSystemStateBanner: View {
    let state: OverviewSystemState
    let fleet: MinerFleetStatus
    let onAction: (OverviewSystemAction) -> Void

    var body: some View {
        HStack(spacing: 14) {
            AnimatedStatusIcon(symbol: state.symbol, color: state.color, size: 16, weight: .semibold)
                .frame(width: 38, height: 38, alignment: .center)

            VStack(alignment: .leading, spacing: 4) {
                Text(state.title)
                    .font(.headline.weight(.semibold))

                Text(state.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 18)

            // Same cluster the Miners tab shows per miner, carrying fleet-wide
            // values. Drops its labels before it drops cells when space is
            // tight, so the grouping survives at every width.
            ViewThatFits(in: .horizontal) {
                fleetCluster(showsLabels: true)
                fleetCluster(showsLabels: false)
            }

            if let action = state.action {
                Button {
                    onAction(action)
                } label: {
                    Text(action.title)
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(state.color)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Match the corner radius of the Miner Activity cards below, which use
        // `.glassCard()` (default radius 18).
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        }
    }

    private func fleetCluster(showsLabels: Bool) -> some View {
        MinerStatusCluster(
            uptimeStart: fleet.uptimeStart,
            lastPollAt: fleet.lastPollAt,
            healthTitle: fleet.healthTitle,
            healthSymbol: fleet.healthSymbol,
            healthTint: fleet.healthTint,
            uptimeLabel: "Avg Uptime",
            lastPollLabel: "Avg Last Poll",
            healthLabel: "Fleet Health",
            showsLabels: showsLabels,
            // Wider than the per-miner cluster: these labels carry the "Avg" and
            // "Fleet" qualifiers and must stay on one line.
            cellWidth: 136
        )
    }
}

// MARK: - Campaign Summary Row



// MARK: - Window Configuration

private struct WindowZoomConfigurator: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            configure(window, coordinator: context.coordinator)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        configure(window, coordinator: context.coordinator)
    }

    private func configure(_ window: NSWindow, coordinator: Coordinator) {
        if !coordinator.didConfigure {
            coordinator.didConfigure = true
            window.styleMask.insert(.resizable)
            window.collectionBehavior.remove([
                .fullScreenPrimary,
                .fullScreenAuxiliary,
                .fullScreenAllowsTiling
            ])
            window.collectionBehavior.insert([
                .fullScreenNone,
                .fullScreenDisallowsTiling
            ])
        }
    }

    final class Coordinator: NSObject {
        var didConfigure = false
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environment(NavigationModel(clientId: "preview"))
        .environment(AppModel(clientId: "preview"))
}
