import SwiftUI
import SwiftMinerCore
import AppKit
import UniformTypeIdentifiers

/// Root view — 2-column NavigationSplitView (Sidebar | Detail)
struct ContentView: View {
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        @Bindable var nav = navigation
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 168, ideal: 180, max: 240)
        } detail: {
            detailContainer
        }
        .background(WindowZoomConfigurator())
        .frame(minWidth: 800, minHeight: 600)
        .sheet(isPresented: $nav.showAddAccountSheet) {
            AuthRequiredSheet(isPresented: $nav.showAddAccountSheet)
                .environment(navigation)
        }
        .onAppear {
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

struct OverviewView: View {
    @Environment(NavigationModel.self) private var navigation
    @ObservedObject private var settings = Settings.shared
    @State private var overviewCampaigns: [CampaignViewData] = []
    @State private var isRefreshing = false
    @State private var steamIdSheetPresentation: SteamIdSheetPresentation?
    @State private var isShowingGameManagement = false
    @State private var customArtworkImportGame: Game?
    @State private var isShowingArtworkImporter = false

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
                systemStateBanner
                minerActivitySection
                campaignFeedSection
            }
            .padding(24)
        }
        .navigationTitle("Overview")
        .onReceive(NotificationCenter.default.publisher(for: .steamArtworkDidUpdate)) { _ in
            Task { @MainActor in
                // Trigger a re-render by updating local state
                overviewCampaigns = await navigation.minerManager.dataCoordinator.allCampaigns(
                    preferSteamArtwork: settings.preferSteamArtwork
                )
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
            onAction: handleSystemStateAction(_:)
        )
    }

    private var overviewSystemState: OverviewSystemState {
        let miners = navigation.minerManager.miners
        let miningMinerCount = miners.filter { $0.status == .watching }.count

        if miningMinerCount > 0 {
            return .mining(
                activeMinerCount: miningMinerCount,
                totalMinerCount: miners.count
            )
        }

        if miners.contains(where: { $0.needsAuth }) {
            return .blockedAuthenticationExpired
        }

        let accountLinkBlockedMiners = miners.filter { $0.status == .blockedAccountNotLinked }
        if !accountLinkBlockedMiners.isEmpty {
            return .blockedAccountNotLinked(
                minerName: accountLinkBlockedMiners.count == 1 ? accountLinkBlockedMiners[0].username : nil,
                blockedCount: accountLinkBlockedMiners.count
            )
        }

        if miners.contains(where: { $0.status == .error }) {
            return .blockedNeedsAttention
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

    private func refreshSummary() async {
        isRefreshing = true
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
            await navigation.minerManager.dataCoordinator.enrichGameNames([gameName])
            await MainActor.run {
                Settings.shared.objectWillChange.send()
            }
        }
    }

    // MARK: - Miner Activity

    private var minerActivitySection: some View {
        let miners = navigation.minerManager.miners

        return VStack(alignment: .leading, spacing: 14) {
            sectionHeading("Miner Activity")

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
                        }, onLinkAccount: {
                            startLinkAccountFlow(for: miner)
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
        VStack(alignment: .leading, spacing: 24) {
            if !displayedPrioritisedFeedItems.isEmpty {
                campaignRailSection(
                    title: "Prioritised",
                    items: displayedPrioritisedFeedItems,
                    prominence: .standard,
                    showsEditButton: true,
                    onMoveItem: movePrioritisedItem
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

    private var preferredGameFallbacks: [GamePreference] {
        preferredGames.filter { preference in
            !uniquePrioritisedCampaigns.contains(where: { matches($0, preference: preference) })
        }
    }

    private var uniquePrioritisedCampaigns: [CampaignViewData] {
        var seen = Set<String>()
        return prioritisedCampaigns.filter { campaign in
            let normalizedName = normalizedGameKey(campaign.gameName)
            let key = normalizedName.isEmpty ? normalizedGameKey(campaign.gameId ?? campaign.id) : normalizedName
            return seen.insert(key).inserted
        }
    }

    private var activeFeedCampaigns: [CampaignViewData] {
        campaigns
            .filter { campaign in
                let state = visualState(for: campaign)
                return state == .watching
                    || state == .claimable
                    || state == .inProgress
                    || isBeingWatched(campaign)
            }
            .sorted(by: campaignDisplaySort)
    }

    private func isPrioritisedRailEligible(_ campaign: CampaignViewData) -> Bool {
        campaign.isDisplayableInOverview
            || (campaign.relevance == .prioritised && !campaign.isCompleted)
    }

    private var recentCampaigns: [CampaignViewData] {
        campaigns
            .filter { campaign in
                campaign.isCompleted
            }
            .sorted { recentActivityDate(for: $0) > recentActivityDate(for: $1) }
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
        Task {
            try? await navigation.minerManager.startMiner(
                minerId: miner.id,
                priorityGames: [],
                excludedGames: [],
                strategy: .mineAll,
                avoidDuplicateStreams: Settings.shared.avoidDuplicateStreams,
                antiStallRecoveryEnabled: Settings.shared.antiStallRecoveryEnabled,
                prioritiseFollowedStreamers: Settings.shared.prioritiseFollowedStreamers
            )
        }
    }

    private func isGameExcluded(_ gameName: String) -> Bool {
        settings.excludedGames.contains(where: { $0.localizedCaseInsensitiveCompare(gameName) == .orderedSame })
    }

    private func makePreferredGameItem(_ preference: GamePreference) -> CampaignRailItem {
        let supportsSteamArtwork = SteamArtworkService.supportsSteamArtwork(
            forGameName: preference.gameName,
            gameId: preference.gameId
        )
        let artworkURL = preference.customArtworkURL
            ?? (
                supportsSteamArtwork
                    ? navigation.minerManager.dataCoordinator.steamArtworkOverrides[preference.gameName]
                        ?? preference.boxArtURL
                    : preference.boxArtURL
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
        navigation.minerManager.updatePriorityGames(settings.priorityGames)
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
                                ?? (settings.preferSteamArtwork ? nil : pref.boxArtURL)
                            : pref.boxArtURL
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
        let idMatches = campaign.gameId != nil && campaign.gameId == preference.gameId
        let nameMatches = campaign.gameName.localizedCaseInsensitiveCompare(preference.gameName) == .orderedSame
            || comparableGameName(campaign.gameName) == comparableGameName(preference.gameName)
        return idMatches || nameMatches
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

    // MARK: - Campaign Summary

    private var campaignSummarySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeading("Campaign Progress", subtitle: "Active and completed drop campaigns.")

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
        // Active campaigns are always shown — they don't need Twitch progress yet.
        // Only fall back to requiring real progress for recent (completed) campaigns.
        if !activeFeedCampaigns.isEmpty {
            return Array(activeFeedCampaigns.prefix(6))
        }
        if !prioritisedCampaigns.isEmpty {
            return Array(prioritisedCampaigns.prefix(6))
        }
        return recentCampaigns
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
            return "Idle — No eligible campaigns"
        case .authenticating:
            return "Waiting — Authenticating"
        case .fetchingCampaigns:
            return "Waiting — Refreshing campaigns"
        case .watching:
            return "Mining — \(miner.currentCampaign ?? "active campaign")"
        case .waitingForStream:
            return "Waiting — No live stream"
        case .claiming:
            return "Claiming completed rewards"
        case .paused:
            return "Paused — Mining is paused"
        case .idleNoEligibleCampaigns:
            return "Idle — No eligible campaigns"
        case .blockedAccountNotLinked:
            return "Blocked — Account not linked"
        case .error:
            return "Blocked — Needs attention"
        }
    }

    private func tintColor(for campaign: CampaignViewData) -> Color {
        return gameTintColor(forGameName: campaign.gameName)
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
    case blockedAccountNotLinked(minerName: String?, blockedCount: Int)
    case blockedAuthenticationExpired
    case blockedNeedsAttention
    case mining(activeMinerCount: Int, totalMinerCount: Int)

    var title: String {
        switch self {
        case .idleNoEligibleCampaigns, .idleAllCampaignsCompleted:
            return "Idle"
        case .waitingForLiveStream, .waitingRefreshingCampaigns, .waitingAuthenticating:
            return "Waiting"
        case .blockedAccountNotLinked(let minerName, let blockedCount):
            if let minerName {
                return "\(minerName) is blocked"
            }
            return "\(blockedCount) miners blocked"
        case .blockedAuthenticationExpired, .blockedNeedsAttention:
            return "Blocked"
        case .mining:
            return "Mining"
        }
    }

    var subtitle: String {
        switch self {
        case .idleNoEligibleCampaigns:
            return "No eligible campaigns are available right now."
        case .idleAllCampaignsCompleted:
            return "All campaigns have been earned and claimed."
        case .waitingForLiveStream:
            return "Campaigns exist but no eligible stream is live."
        case .waitingRefreshingCampaigns:
            return "Checking for new campaign opportunities..."
        case .waitingAuthenticating:
            return "Reconnecting account..."
        case .blockedAccountNotLinked(let minerName, let blockedCount):
            if let minerName {
                return "Account not linked. Link \(minerName)'s account to start mining drops."
            }
            return "\(blockedCount) miners need account linking before they can mine drops."
        case .blockedAuthenticationExpired:
            return "Account authentication expired. Please re-connect."
        case .blockedNeedsAttention:
            return "Check Events for the latest issue before mining can continue."
        case .mining(let activeMinerCount, let totalMinerCount):
            if totalMinerCount <= 1 {
                return "Miner is currently mining."
            }
            if activeMinerCount == totalMinerCount {
                return "All miners are currently mining."
            }
            return "\(activeMinerCount) of \(totalMinerCount) miners are currently mining."
        }
    }

    var symbol: String {
        switch self {
        case .idleNoEligibleCampaigns:
            return "pause.circle"
        case .idleAllCampaignsCompleted:
            return "checkmark.seal.fill"
        case .waitingForLiveStream:
            return "antenna.radiowaves.left.and.right"
        case .waitingRefreshingCampaigns:
            return "arrow.triangle.2.circlepath"
        case .waitingAuthenticating:
            return "key.fill"
        case .blockedAccountNotLinked:
            return "link.badge.plus"
        case .blockedAuthenticationExpired, .blockedNeedsAttention:
            return "exclamationmark.triangle.fill"
        case .mining:
            return "play.fill"
        }
    }

    var color: Color {
        switch self {
        case .idleNoEligibleCampaigns, .idleAllCampaignsCompleted:
            return .secondary
        case .waitingForLiveStream:
            return .cyan
        case .waitingRefreshingCampaigns:
            return .blue
        case .waitingAuthenticating:
            return .orange
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
        case .waitingForLiveStream, .waitingRefreshingCampaigns, .waitingAuthenticating:
            return .viewSchedule
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
    let onAction: (OverviewSystemAction) -> Void

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(state.color.opacity(0.14))

                Image(systemName: state.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(state.color)
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 4) {
                Text(state.title)
                    .font(.headline.weight(.semibold))

                Text(state.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: GlassRadius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: GlassRadius.medium, style: .continuous)
                .strokeBorder(state.color.opacity(0.2), lineWidth: 1)
        }
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
                    AnimatedLinearProgressView(value: progressFraction, tint: tint)
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
                Text("Idle — No eligible campaigns")
                    .font(.headline)

                Text("No active drop campaigns are available right now.")
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

private enum CampaignRailLayout {
    case horizontal
    case staggered
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
            return "Idle — No eligible campaigns"
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
    var usesCustomArtwork = false
    var game: Game? = nil
}


private struct CampaignFeedCard: View {
    let item: CampaignRailItem
    let prominence: CampaignCardProminence
    let onSetSteamId: (String) -> Void
    let onUploadCustomArtwork: (Game) -> Void
    @State private var isHovering = false

    private var settings: Settings {
        Settings.shared
    }

    private var usesStandbyMotionStyle: Bool {
        item.isPlaceholder && item.showsLiveMotion
    }

    private var artworkDimmingStops: [Color] {
        if item.usesCustomArtwork {
            return [
                .clear,
                Color.black.opacity(0),
                Color.black.opacity(0.06),
                Color.black.opacity(item.section == .recent ? 0.24 : 0.30)
            ]
        }

        return [
            .clear,
            Color.black.opacity(0.08),
            Color.black.opacity(0.36),
            Color.black.opacity(item.section == .recent ? 0.56 : 0.66)
        ]
    }

    private var cardOpacity: Double {
        if item.usesCustomArtwork {
            return item.section == .recent ? 0.94 : 1
        }
        return item.section == .recent ? 0.88 : (item.isDimmed ? 0.7 : 1)
    }

    private var cardSaturation: Double {
        item.usesCustomArtwork ? 1 : (item.isDimmed ? 0.82 : 1)
    }

    private var currentPreference: GamePreference? {
        guard let game = item.game else { return nil }
        let matches = settings.gamePreferences.filter { preference in
            let idMatches = !game.id.isEmpty && preference.gameId == game.id
            let nameMatches = preference.gameName.localizedCaseInsensitiveCompare(game.name) == .orderedSame
                || comparableGameName(preference.gameName) == comparableGameName(game.name)
            return idMatches || nameMatches
        }
        return matches.first(where: { $0.customArtworkURL != nil }) ?? matches.first
    }

    private func comparableGameName(_ value: String) -> String {
        value
            .lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private var hasCustomArtwork: Bool {
        currentPreference?.customArtworkURL != nil
    }

    private var canRemoveFromPrioritised: Bool {
        item.section == .prioritised && currentPreference?.state == .preferred
    }

    private var showsCampaignSubtitle: Bool {
        item.section == .active && !item.campaignName.isEmpty
    }

    private var accessibilityTitle: String {
        item.gameName
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CampaignArtworkBackground(
                url: item.artworkURL,
                title: item.gameName,
                tint: item.tint,
                useGhostArtworkPlaceholder: usesStandbyMotionStyle
            )
            .frame(width: prominence.size.width, height: prominence.size.height)
            .clipped()

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
                colors: artworkDimmingStops,
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
                                    item.tint.opacity(item.usesCustomArtwork ? 0 : 0.08),
                                    item.tint.opacity(item.usesCustomArtwork ? 0 : 0.18)
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

            VStack(alignment: .leading, spacing: 4) {
                Text(item.gameName)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
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
            .zIndex(2)
        }
        .frame(width: prominence.size.width, height: prominence.size.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: GlassRadius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: GlassRadius.medium, style: .continuous)
                .strokeBorder(.white.opacity(item.visualState == .watching ? 0.22 : 0.12), lineWidth: 1)
        }
        .opacity(cardOpacity)
        .saturation(cardSaturation)
        .brightness(item.visualState == .watching ? 0.04 : (isHovering ? 0.015 : 0))
        .scaleEffect(isHovering ? 1.03 : 1)
        .shadow(color: .black.opacity(item.visualState == .watching ? 0.16 : (isHovering ? 0.10 : 0.05)), 
                radius: item.visualState == .watching ? 10 : (isHovering ? 8 : 3), 
                y: item.visualState == .watching ? 5 : (isHovering ? 4 : 1))
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

                if canRemoveFromPrioritised, let preference = currentPreference {
                    Button(role: .destructive) {
                        Settings.shared.removeGamePreference(preference)
                    } label: {
                        GameActionMenuLabel(
                            title: "Remove Game",
                            subtitle: "Remove this game from the prioritised list.",
                            systemImage: "trash"
                        )
                    }
                }

                Button {
                    onUploadCustomArtwork(game)
                } label: {
                    GameActionMenuLabel(
                        title: "Upload Custom Artwork",
                        subtitle: "Cache a local image in Application Support for this game.",
                        systemImage: "square.and.arrow.up"
                    )
                }

                if hasCustomArtwork {
                    Button(role: .destructive) {
                        Settings.shared.removeCustomArtwork(for: game)
                    } label: {
                        GameActionMenuLabel(
                            title: "Remove Custom Artwork",
                            subtitle: "Return to Steam or Twitch artwork.",
                            systemImage: "photo.badge.minus"
                        )
                    }
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

private struct ReorderableCampaignFeedCard: View {
    let item: CampaignRailItem
    let index: Int
    let itemCount: Int
    let prominence: CampaignCardProminence
    let activeDragIndex: Int?
    let projectedDropIndex: Int?
    let activeDragProgress: CGFloat
    let onSetSteamId: (String) -> Void
    let onUploadCustomArtwork: (Game) -> Void
    let onDragProjectionChanged: (Int, Int, CGFloat) -> Void
    let onDragEnded: () -> Void
    let onMoveItem: ((CampaignRailItem, Int) -> Void)?
    @State private var dragOffset: CGFloat = 0

    private var travelDistance: CGFloat {
        prominence.size.width + prominence.spacing
    }

    private var reorderStep: CGFloat {
        max(travelDistance * 0.62, 1)
    }

    private var dragProgress: CGFloat {
        dragOffset / travelDistance
    }

    private var isActivelyDragged: Bool {
        activeDragIndex == index
    }

    private var neighborOffset: CGFloat {
        guard let activeDragIndex,
              let projectedDropIndex,
              activeDragIndex != index,
              projectedDropIndex != activeDragIndex else {
            return 0
        }

        let progress = activeDragProgress
        if progress > 0,
           index > activeDragIndex {
            let distanceFromActive = CGFloat(index - activeDragIndex)
            let influence = smoothstep(min(max(progress - (distanceFromActive - 1), 0), 1))
            return -travelDistance * influence
        }

        if progress < 0,
           index < activeDragIndex {
            let distanceFromActive = CGFloat(activeDragIndex - index)
            let influence = smoothstep(min(max(abs(progress) - (distanceFromActive - 1), 0), 1))
            return travelDistance * influence
        }

        return 0
    }

    private var liftAmount: CGFloat {
        min(abs(dragProgress), 1)
    }

    private func smoothstep(_ value: CGFloat) -> CGFloat {
        value * value * (3 - (2 * value))
    }

    private var card: some View {
        CampaignFeedCard(
            item: item,
            prominence: prominence,
            onSetSteamId: onSetSteamId,
            onUploadCustomArtwork: onUploadCustomArtwork
        )
    }

    var body: some View {
        if let onMoveItem {
            card
                .offset(x: dragOffset + neighborOffset, y: isActivelyDragged ? -6 * liftAmount : 0)
                .scaleEffect(isActivelyDragged ? 1 + (0.018 * liftAmount) : 1)
                .rotationEffect(.degrees(isActivelyDragged ? Double(dragProgress) * 0.35 : 0))
                .shadow(
                    color: .black.opacity(isActivelyDragged ? 0.14 : 0),
                    radius: isActivelyDragged ? 12 : 0,
                    y: isActivelyDragged ? 7 : 0
                )
                .zIndex(isActivelyDragged ? 1000 : Double(itemCount - index))
                .gesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { value in
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                dragOffset = value.translation.width
                            }

                            let rawProjectedIndex = index + Int((value.translation.width / reorderStep).rounded())
                            let projectedIndex = min(max(rawProjectedIndex, 0), itemCount - 1)
                            let progress = min(
                                max(value.translation.width / travelDistance, CGFloat(-index)),
                                CGFloat(itemCount - index - 1)
                            )
                            onDragProjectionChanged(index, projectedIndex, progress)
                        }
                        .onEnded { value in
                            let translation = abs(value.predictedEndTranslation.width) > abs(value.translation.width)
                                ? value.predictedEndTranslation.width
                                : value.translation.width
                            let rawDelta = translation / reorderStep
                            let delta = Int(rawDelta.rounded())
                            let targetIndex = min(max(index + delta, 0), itemCount - 1)

                            if targetIndex != index {
                                onMoveItem(item, targetIndex)
                            }

                            onDragEnded()
                            withAnimation(.interactiveSpring(response: 0.30, dampingFraction: 0.86, blendDuration: 0.08)) {
                                dragOffset = 0
                            }
                        }
                )
                .help("Drag left or right to reorder priority")
        } else {
            card
        }
    }
}

private struct StaggeredCampaignRail: View {
    let items: [CampaignRailItem]
    let prominence: CampaignCardProminence
    let onSetSteamId: (String) -> Void
    let onUploadCustomArtwork: (Game) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: -prominence.size.width * 0.52) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    let clampedDepth = min(index, 4)
                    let scale = max(0.62, 1.0 - (Double(clampedDepth) * 0.12))
                    let opacity = max(0.52, 1.0 - (Double(clampedDepth) * 0.16))
                    let xOffset = CGFloat(clampedDepth) * 16
                    let yOffset = CGFloat(clampedDepth) * 4

                    CampaignFeedCard(
                        item: item,
                        prominence: prominence,
                        onSetSteamId: onSetSteamId,
                        onUploadCustomArtwork: onUploadCustomArtwork
                    )
                    .scaleEffect(scale)
                    .opacity(opacity)
                    .offset(x: xOffset, y: yOffset)
                    .zIndex(Double(120 - index))
                    .animation(.spring(response: 0.34, dampingFraction: 0.82), value: item.id)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 10)
        }
        .scrollClipDisabled()
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
    let title: String
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
                        initialsOverlay
                    @unknown default:
                        Color.clear
                    }
                }
            } else {
                initialsOverlay
            }
        }
        .animation(.easeInOut(duration: 0.55), value: url)
    }

    private var initialsOverlay: some View {
        Text(initials(from: title))
            .font(.system(size: 44, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.18))
            .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
    }

    private func initials(from name: String) -> String {
        let parts = name.split(separator: " ")
        if parts.count >= 2 {
            return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
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
        guard let window = nsView.window, !context.coordinator.didConfigure else { return }
        configure(window, coordinator: context.coordinator)
    }

    private func configure(_ window: NSWindow, coordinator: Coordinator) {
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
