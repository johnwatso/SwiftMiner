import SwiftUI
import SwiftTwitchMiner

/// Root view — 2-column NavigationSplitView (Sidebar | Detail)
struct ContentView: View {
    @Environment(NavigationModel.self) private var navigation
    @ObservedObject private var settings = Settings.shared

    var body: some View {
        @Bindable var nav = navigation
        ZStack {
            LiquidGlassBackdrop()

            NavigationSplitView {
                SidebarView()
            } detail: {
                detailView
            }
        }
        .overlay(alignment: .topTrailing) {
            if nav.showOnboarding {
                OnboardingView()
                    .padding(24)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
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
    @ObservedObject private var settings = Settings.shared
    @State private var progress: AggregateProgress?
    @State private var isRefreshing = false

    private var campaigns: [Campaign] {
        navigation.minerManager.campaignStore.campaigns
            .filter { campaign in
                !settings.excludedGames.contains(where: { 
                    $0.localizedCaseInsensitiveCompare(campaign.game.name) == .orderedSame 
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
                    Task { await refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isRefreshing)
            }
        }
        .task { await refresh() }
    }

    private func refresh() async {
        isRefreshing = true
        progress = await navigation.minerManager.getAggregateProgress()
        isRefreshing = false
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
        navigation.minerManager.campaignStore.campaigns
            .filter { $0.isMiningEligible }
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
                    prominence: .feature
                )
            }
        }
        .padding(.vertical, 2)
    }

    private var displayedMiningFeedItems: [CampaignRailItem] {
        // Mining items = those currently being watched by any miner
        let mining = currentlyMiningCampaigns.map { makeRailItem(for: $0, section: .active) }
        
        // Queued items = those next in line (we can approximate this by picking the top of the eligible list)
        // But John's requirement is "source of truth: MinerEngine active selection".
        // Since we already filter `currentlyMiningCampaigns` by `miner.currentCampaignId`, this is correct.
        
        return mining.isEmpty ? [placeholderRailItem(for: .active)] : mining
    }

    @ViewBuilder
    private func campaignRailSection(
        title: String,
        items: [CampaignRailItem],
        prominence: CampaignCardProminence
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeading(title)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: prominence.spacing) {
                    ForEach(items) { item in
                        CampaignFeedCard(item: item, prominence: prominence)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 6)
            }
            .scrollClipDisabled()
        }
    }

    private var preferredGames: [GamePreference] {
        settings.gamePreferences.filter { $0.state == .preferred }
    }

    private var currentlyMiningCampaigns: [Campaign] {
        campaigns.filter(isBeingWatched(_:))
    }

    private var prioritisedCampaigns: [Campaign] {
        campaigns
            .filter { campaign in
                campaign.relevance == .prioritised || preferredGames.contains(where: { matches(campaign, preference: $0) })
            }
            .sorted(by: campaignDisplaySort)
    }

    private var preferredGameFallbacks: [GamePreference] {
        preferredGames.filter { preference in
            !prioritisedCampaigns.contains(where: { matches($0, preference: preference) })
        }
    }

    private var activeFeedCampaigns: [Campaign] {
        campaigns
            .filter { campaign in
                isBeingWatched(campaign)
                    || campaign.relevance == .active
                    || campaign.miningStatus == .claimable
                    || campaign.miningStatus == .inProgress
                    || campaign.isMiningEligible
            }
            .sorted(by: campaignDisplaySort)
    }

    private var recentCampaigns: [Campaign] {
        campaigns
            .filter { $0.relevance == .recent || $0.miningStatus == .claimed }
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

    private func makeRailItem(for campaign: Campaign, section: CampaignFeedSection) -> CampaignRailItem {
        let state = visualState(for: campaign)

        return CampaignRailItem(
            id: "\(section.rawValue)-\(campaign.id)",
            section: section,
            gameName: campaign.game.name,
            campaignName: campaign.name,
            eyebrow: eyebrowText(for: campaign, section: section, state: state),
            progressText: campaignDetailText(for: campaign, section: section, state: state),
            progressPercent: campaignProgressPercent(for: campaign),
            artworkURL: navigation.minerManager.dataCoordinator.steamArtworkOverrides[campaign.game.name] ?? campaign.game.boxArtURL,
            tint: tintColor(for: campaign),
            hasOnlyBadgesOrEmotes: campaign.hasOnlyBadgesOrEmotes,
            visualState: state,
            watchers: watchers(for: campaign),
            isDimmed: state == .claimed,
            isPlaceholder: false,
            showsLiveMotion: section == .active && (state == .watching || state == .inProgress || state == .claimable),
            game: campaign.game
        )
    }

    private func makePreferredGameItem(_ preference: GamePreference) -> CampaignRailItem {
        CampaignRailItem(
            id: "preferred-\(preference.gameId.isEmpty ? preference.gameName : preference.gameId)",
            section: .prioritised,
            gameName: preference.gameName,
            campaignName: "",
            eyebrow: "",
            progressText: "",
            progressPercent: 0,
            artworkURL: preference.boxArtURL,
            tint: .orange,
            hasOnlyBadgesOrEmotes: false,
            visualState: .idle,
            watchers: [],
            isDimmed: false,
            isPlaceholder: false,
            showsLiveMotion: false,
            game: Game(id: preference.gameId, name: preference.gameName, boxArtURL: preference.boxArtURL)
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
                artworkURL: preferredGames.first?.boxArtURL,
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
            let runningCount = watchers.count
            let detail = runningCount > 0
                ? "\(runningCount) \(runningCount == 1 ? "miner is" : "miners are") online and ready."
                : "Accounts are ready to jump into the next campaign."
            return CampaignRailItem(
                id: "placeholder-active",
                section: .active,
                gameName: "Ready",
                campaignName: "Waiting for the next live campaign",
                eyebrow: "Standby",
                progressText: detail,
                progressPercent: 0,
                artworkURL: nil,
                tint: .cyan,
                hasOnlyBadgesOrEmotes: false,
                visualState: .idle,
                watchers: watchers,
                isDimmed: false,
                isPlaceholder: true,
                showsLiveMotion: true
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

    private func visualState(for campaign: Campaign) -> CampaignVisualState {
        if isBeingWatched(campaign) {
            return .watching
        }

        switch campaign.miningStatus {
        case .claimable:
            return .claimable
        case .inProgress:
            return .inProgress
        case .claimed, .expired:
            return .claimed
        case .available:
            return .idle
        }
    }

    private func watchers(for campaign: Campaign) -> [CampaignWatcher] {
        let palette: [Color] = [.green, .blue, .orange, .pink, .cyan, .teal]

        return watchingMiners(for: campaign).enumerated().map { index, miner in
            CampaignWatcher(
                id: miner.id,
                username: miner.username,
                initials: initials(for: miner.username),
                tint: palette[index % palette.count]
            )
        }
    }

    private var readyStateWatchers: [CampaignWatcher] {
        let palette: [Color] = [.green, .blue, .orange, .pink, .cyan, .teal]
        let activeMiners = navigation.minerManager.miners.filter { miner in
            miner.isRunning || miner.status == .fetchingCampaigns || miner.status == .authenticating || miner.status == .paused
        }

        return activeMiners.enumerated().map { index, miner in
            CampaignWatcher(
                id: miner.id,
                username: miner.username,
                initials: initials(for: miner.username),
                tint: palette[index % palette.count]
            )
        }
    }

    private func watchingMiners(for campaign: Campaign) -> [MinerManager.ManagedMiner] {
        navigation.minerManager.miners.filter { miner in
            // Must be actively running with watching/claiming status
            guard miner.status == .watching || miner.status == .claiming else {
                return false
            }

            // Verify currentCampaignId matches (defense against stale session state)
            if let id = miner.currentCampaignId {
                return id == campaign.id
            }

            return miner.currentCampaign == campaign.name
        }
    }

    private func isBeingWatched(_ campaign: Campaign) -> Bool {
        !watchingMiners(for: campaign).isEmpty
    }

    private func matches(_ campaign: Campaign, preference: GamePreference) -> Bool {
        if !preference.gameId.isEmpty, campaign.game.id == preference.gameId {
            return true
        }

        return campaign.game.name.localizedCaseInsensitiveCompare(preference.gameName) == .orderedSame
    }

    private func eyebrowText(
        for campaign: Campaign,
        section: CampaignFeedSection,
        state: CampaignVisualState
    ) -> String {
        switch state {
        case .watching:
            return "Watching"
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
        for campaign: Campaign,
        section: CampaignFeedSection,
        state: CampaignVisualState
    ) -> String {
        let progressPercent = campaignProgressPercent(for: campaign)
        let remainingMinutes = campaignRemainingMinutes(for: campaign)
        let activeWatchers = watchers(for: campaign)

        switch state {
        case .watching:
            if activeWatchers.count == 1, let watcher = activeWatchers.first {
                return "\(watcher.username) is watching now"
            }
            return "\(activeWatchers.count) accounts are watching"
        case .claimable:
            return "Reward ready to collect"
        case .inProgress:
            return "\(Int(progressPercent))% complete • \(remainingMinutes)m left"
        case .claimed:
            return section == .recent ? "Recently wrapped and safely claimed" : "Completed, still pinned"
        case .idle:
            if campaign.startDate > Date() {
                return "Starts \(campaign.startDate.formatted(date: .abbreviated, time: .omitted))"
            }
            if campaign.isMiningEligible {
                return "Available now"
            }
            if progressPercent > 0 {
                return "\(Int(progressPercent))% complete • \(remainingMinutes)m left"
            }
            return section == .recent ? "Completed recently" : "Waiting for the next viewing session"
        }
    }

    private func campaignDisplaySort(lhs: Campaign, rhs: Campaign) -> Bool {
        let lhsPriority = displayPriority(for: lhs)
        let rhsPriority = displayPriority(for: rhs)

        if lhsPriority != rhsPriority {
            return lhsPriority < rhsPriority
        }

        let lhsProgress = campaignProgressPercent(for: lhs)
        let rhsProgress = campaignProgressPercent(for: rhs)
        if lhsProgress != rhsProgress {
            return lhsProgress > rhsProgress
        }

        if lhs.endDate != rhs.endDate {
            return lhs.endDate < rhs.endDate
        }

        return lhs.game.name < rhs.game.name
    }

    private func displayPriority(for campaign: Campaign) -> Int {
        switch visualState(for: campaign) {
        case .watching: return 0
        case .claimable: return 1
        case .inProgress: return 2
        case .idle: return 3
        case .claimed: return 4
        }
    }

    private func recentActivityDate(for campaign: Campaign) -> Date {
        campaign.drops.compactMap(\.progress?.lastUpdated).max() ?? campaign.endDate
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
                    .glassControlSurface(cornerRadius: GlassRadius.pill)
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
        .glassContentSurface()
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
                title: "Paused between campaigns",
                summary: "The miner is waiting for an eligible campaign or live channel to become available.",
                detail: "Upcoming and eligible cards above show the next opportunities in line.",
                badge: "Paused",
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
                status: miner.status.displayName,
                color: statusColor(for: miner)
            )
        }
    }

    private func statusColor(for miner: MinerManager.ManagedMiner) -> Color {
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
            sectionHeading("Campaign Progress", subtitle: "Campaigns with drops still to earn.")

            if campaignLibraryItems.isEmpty {
                CampaignLibraryAmbientRow()
            } else {
                VStack(spacing: 10) {
                    ForEach(campaignLibraryItems) { campaign in
                        ActiveCampaignRow(item: campaign)
                    }
                }
            }
        }
    }

    private var campaignLibraryItems: [CampaignRailItem] {
        let sourceCampaigns: [Campaign]
        if !activeFeedCampaigns.isEmpty {
            sourceCampaigns = Array(activeFeedCampaigns.prefix(6))
        } else if !prioritisedCampaigns.isEmpty {
            sourceCampaigns = Array(prioritisedCampaigns.prefix(6))
        } else {
            sourceCampaigns = Array(recentCampaigns.prefix(6))
        }

        return sourceCampaigns.map { makeRailItem(for: $0, section: .active) }
    }

    private func campaignProgressPercent(for campaign: Campaign) -> Double {
        guard !campaign.drops.isEmpty else { return 0 }

        let totalRequiredMinutes = campaign.drops.reduce(0) { total, drop in
            total + max(drop.requiredMinutes, 0)
        }
        guard totalRequiredMinutes > 0 else {
            return isCampaignClaimed(campaign) ? 100 : 0
        }

        let accruedMinutes = campaign.drops.reduce(0) { total, drop in
            if drop.isClaimed {
                return total + drop.requiredMinutes
            }
            let currentMinutes = min(drop.progress?.currentMinutes ?? 0, drop.requiredMinutes)
            return total + max(currentMinutes, 0)
        }

        return min(100, max(0, (Double(accruedMinutes) / Double(totalRequiredMinutes)) * 100))
    }

    private func campaignRemainingMinutes(for campaign: Campaign) -> Int {
        campaign.drops.reduce(0) { total, drop in
            if drop.isClaimed {
                return total
            }
            let currentMinutes = min(drop.progress?.currentMinutes ?? 0, drop.requiredMinutes)
            return total + max(drop.requiredMinutes - currentMinutes, 0)
        }
    }

    private func isCampaignClaimed(_ campaign: Campaign) -> Bool {
        !campaign.drops.isEmpty && campaign.drops.allSatisfy(\.isClaimed)
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
            return "Paused until something new appears"
        case .error:
            return "Needs a refresh"
        }
    }

    private func tintColor(for campaign: Campaign) -> Color {
        let name = campaign.game.name.lowercased()
        if name.contains("rust") { return .orange }
        if name.contains("fortnite") { return .blue }
        if name.contains("valorant") { return .red }
        if name.contains("finals") { return .pink }
        return .purple
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
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.headline)
                .frame(width: 28, height: 28)
                .glassControlSurface(cornerRadius: GlassRadius.small)

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Text(value)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))

                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassPanel()
    }
}

// MARK: - Campaign Summary Row

private struct ActiveCampaignRow: View {
    let item: CampaignRailItem

    var body: some View {
        HStack(spacing: 14) {
            CampaignThumbnail(url: item.artworkURL, tint: item.tint)
                .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 5) {
                Text(item.gameName)
                    .font(.headline)

                Text(item.campaignName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Text(item.progressText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    if !item.watchers.isEmpty {
                        CampaignWatcherStack(watchers: item.watchers, size: 18)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                CampaignStateBadge(state: item.visualState)

                if item.progressPercent > 0 {
                    VStack(alignment: .trailing, spacing: 6) {
                        Text(item.visualState == .claimed ? "Completed" : "\(Int(item.progressPercent))%")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(item.visualState.accent)

                        ProgressView(value: item.progressPercent, total: 100)
                            .progressViewStyle(.linear)
                            .frame(width: 118)
                            .tint(item.visualState.accent)
                    }
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
        .contextMenu {
            if let game = item.game, !item.isPlaceholder {
                Button {
                    Settings.shared.setGamePreference(game, state: .preferred)
                } label: {
                    Label("Prioritise Game", systemImage: "star.fill")
                }
                
                Button(role: .destructive) {
                    Settings.shared.setGamePreference(game, state: .excluded)
                } label: {
                    Label("Exclude Game", systemImage: "minus.circle")
                }
            }
        }
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

                Text("Start mining to see your active drop campaigns.")
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
    let tint: Color
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
    var game: Game? = nil
}

private struct CampaignFeedCard: View {
    let item: CampaignRailItem
    let prominence: CampaignCardProminence
    @State private var isHovering = false

    private var usesStandbyMotionStyle: Bool {
        item.isPlaceholder && item.showsLiveMotion
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

            VStack(alignment: .leading, spacing: 4) {
                Text(item.gameName)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                if !item.campaignName.isEmpty {
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
        .onHover { hovering in
            isHovering = hovering
        }
        .contextMenu {
            if let game = item.game, !item.isPlaceholder {
                Button {
                    Settings.shared.setGamePreference(game, state: .preferred)
                } label: {
                    Label("Prioritise Game", systemImage: "star.fill")
                }
                
                Button(role: .destructive) {
                    Settings.shared.setGamePreference(game, state: .excluded)
                } label: {
                    Label("Exclude Game", systemImage: "minus.circle")
                }
            }
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

    var body: some View {
        HStack(spacing: -size * 0.28) {
            ForEach(Array(watchers.prefix(3))) { watcher in
                Text(watcher.initials)
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(watcher.tint.opacity(0.9), in: Circle())
                    .overlay {
                        Circle()
                            .strokeBorder(.white.opacity(0.5), lineWidth: 1)
                    }
            }

            if watchers.count > 3 {
                Text("+\(watchers.count - 3)")
                    .font(.system(size: size * 0.34, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .frame(height: size)
                    .padding(.horizontal, size * 0.28)
                    .background(.ultraThinMaterial, in: Capsule())
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
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassControlSurface()
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environment(NavigationModel(clientId: "preview"))
        .environment(AppModel(clientId: "preview"))
}
