import SwiftUI
import SwiftTwitchMiner

/// Root view — 2-column NavigationSplitView (Sidebar | Detail)
struct ContentView: View {
    @Environment(NavigationModel.self) private var navigation

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
        .frame(minWidth: 800, minHeight: 600)
        .sheet(isPresented: $nav.showAddAccountSheet) {
            AuthRequiredSheet(isPresented: $nav.showAddAccountSheet)
                .environment(navigation)
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
                    description: "Activity will appear here as it happens."
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
                            Text("Miner \(minerId.prefix(4))")
                        }
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
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
    @State private var progress: AggregateProgress?
    @State private var isRefreshing = false

    private var campaigns: [Campaign] {
        navigation.minerManager.campaignStore.campaigns
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                campaignFeedSection
                nextActionSection
                metricsSection
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
            sectionHeading("Live Stats", subtitle: "A lighter snapshot of miner activity across the dashboard.")

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
        VStack(alignment: .leading, spacing: 16) {
            sectionHeading("Campaign Feed", subtitle: "Artwork-first view of what the miner is playing through right now.")

            if campaignFeedItems.isEmpty {
                MaterialEmptyStatePanel(
                    "No campaigns to show",
                    systemImage: "play.rectangle.on.rectangle",
                    description: "Add an account or refresh campaigns to populate the feed."
                )
                .frame(maxWidth: .infinity)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 18) {
                        ForEach(campaignFeedItems) { item in
                            CampaignFeedCard(item: item)
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 4)
                }
                .scrollClipDisabled()
            }
        }
        .padding(20)
        .glassContentSurface(cornerRadius: 30)
    }

    private var campaignFeedItems: [CampaignViewData] {
        var items: [CampaignViewData] = []
        var seen = Set<String>()

        for campaign in currentlyMiningCampaigns {
            let item = makeFeedItem(for: campaign, lane: .currentlyMining)
            if seen.insert(item.id).inserted {
                items.append(item)
            }
        }

        for campaign in eligibleCampaigns.prefix(6) {
            let item = makeFeedItem(for: campaign, lane: .eligible)
            if seen.insert(item.id).inserted {
                items.append(item)
            }
        }

        for campaign in upcomingCampaigns.prefix(6) {
            let item = makeFeedItem(for: campaign, lane: .upcoming)
            if seen.insert(item.id).inserted {
                items.append(item)
            }
        }

        return items
    }

    private var currentlyMiningCampaigns: [Campaign] {
        let miners = navigation.minerManager.miners
        return campaigns.filter { campaign in
            miners.contains { miner in
                if let id = miner.currentCampaignId {
                    return id == campaign.id
                }
                return miner.currentCampaign == campaign.name && miner.isRunning
            }
        }
    }

    private var eligibleCampaigns: [Campaign] {
        campaigns
            .filter { $0.isMiningEligible }
            .sorted { lhs, rhs in
                if lhs.hasClaimableDrops != rhs.hasClaimableDrops {
                    return lhs.hasClaimableDrops && !rhs.hasClaimableDrops
                }
                return lhs.endDate < rhs.endDate
            }
    }

    private var upcomingCampaigns: [Campaign] {
        campaigns
            .filter { $0.status == .upcoming || $0.startDate > Date() }
            .sorted { $0.startDate < $1.startDate }
    }

    private func makeFeedItem(for campaign: Campaign, lane: CampaignFeedLane) -> CampaignViewData {
        let progressPercent = campaignProgressPercent(for: campaign)
        let isClaimed = isCampaignClaimed(campaign)

        return CampaignViewData(
            id: "\(lane.rawValue)-\(campaign.id)",
            lane: lane,
            gameName: campaign.game.name,
            campaignName: campaign.name,
            progressText: feedProgressText(for: campaign, lane: lane),
            progressPercent: progressPercent,
            artworkURL: campaign.game.boxArtURL,
            isClaimed: isClaimed,
            tint: tintColor(for: campaign)
        )
    }

    private func feedStatusText(for campaign: Campaign, lane: CampaignFeedLane) -> String {
        switch lane {
        case .currentlyMining:
            return "Currently mining"
        case .eligible:
            return campaign.hasClaimableDrops ? "Ready to claim" : "Eligible now"
        case .upcoming:
            return "Starts \(campaign.startDate.formatted(date: .abbreviated, time: .omitted))"
        }
    }

    private func feedProgressText(for campaign: Campaign, lane: CampaignFeedLane) -> String {
        let progressPercent = campaignProgressPercent(for: campaign)
        let remainingMinutes = campaignRemainingMinutes(for: campaign)

        if isCampaignClaimed(campaign) {
            return "Completed"
        }

        switch lane {
        case .currentlyMining, .eligible:
            if progressPercent > 0 {
                return "\(Int(progressPercent))% complete • \(remainingMinutes)m remaining"
            }
            return lane == .currentlyMining ? "Mining now" : feedStatusText(for: campaign, lane: lane)
        case .upcoming:
            return feedStatusText(for: campaign, lane: lane)
        }
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
                    .glassControlSurface(cornerRadius: 999)
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
        .glassContentSurface(cornerRadius: 28)
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
        case .claiming:                          return .purple
        case .authenticating, .fetchingCampaigns, .paused: return .orange
        case .error:                             return .red
        case .idle:                              return .gray
        }
    }

    // MARK: - Campaign Summary

    private var campaignSummarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading("Active Campaigns", subtitle: "Content-first rows with artwork, progress, and what still needs attention.")

            let active = navigation.minerManager.campaignStore.campaigns.filter {
                $0.isTimeActive && $0.isAccountConnected
            }

            if active.isEmpty {
                Text("No active campaigns")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .glassControlSurface(cornerRadius: 16)
            } else {
                VStack(spacing: 8) {
                    ForEach(activeCampaignRows(from: active)) { campaign in
                        ActiveCampaignRow(item: campaign)
                    }
                }
            }
        }
        .padding(20)
        .glassContentSurface()
    }

    private func activeCampaignRows(from campaigns: [Campaign]) -> [CampaignViewData] {
        campaigns
            .map { campaign in
                CampaignViewData(
                    id: campaign.id,
                    lane: nil,
                    gameName: campaign.game.name,
                    campaignName: campaign.name,
                    progressText: activeRowProgressText(for: campaign),
                    progressPercent: campaignProgressPercent(for: campaign),
                    artworkURL: campaign.game.boxArtURL,
                    isClaimed: isCampaignClaimed(campaign),
                    tint: tintColor(for: campaign)
                )
            }
            .sorted { lhs, rhs in
                if lhs.isClaimed != rhs.isClaimed {
                    return !lhs.isClaimed && rhs.isClaimed
                }
                if lhs.progressPercent != rhs.progressPercent {
                    return lhs.progressPercent > rhs.progressPercent
                }
                return lhs.gameName < rhs.gameName
            }
    }

    private func activeRowProgressText(for campaign: Campaign) -> String {
        if isCampaignClaimed(campaign) {
            return "Completed"
        }

        let progressPercent = campaignProgressPercent(for: campaign)
        if progressPercent > 0 {
            return "\(Int(progressPercent))% • \(campaignRemainingMinutes(for: campaign))m remaining"
        }

        return "Not started"
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
    private func sectionHeading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title3.weight(.semibold))
            Text(subtitle)
                .font(.subheadline)
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
                .glassControlSurface(cornerRadius: 12)

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
        .glassPanel(cornerRadius: 20)
    }
}

// MARK: - Campaign Summary Row

private struct ActiveCampaignRow: View {
    let item: CampaignViewData

    var body: some View {
        HStack(spacing: 14) {
            CampaignThumbnail(url: item.artworkURL, tint: item.tint)
                .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.gameName)
                    .font(.headline)

                Text(item.campaignName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(item.progressText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 6) {
                    if item.isClaimed {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }

                    Text(item.isClaimed ? "Completed" : "\(Int(item.progressPercent))%")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(item.isClaimed ? .green : .primary)
                }

                ProgressView(value: item.progressPercent, total: 100)
                    .progressViewStyle(.linear)
                    .frame(width: 120)
                    .tint(item.isClaimed ? .green : .accentColor)
            }
        }
        .padding(14)
        .glassPanel(cornerRadius: 20)
    }
}

private enum CampaignFeedLane: String {
    case currentlyMining
    case eligible
    case upcoming

    var label: String {
        switch self {
        case .currentlyMining: return "Now Mining"
        case .eligible: return "Eligible"
        case .upcoming: return "Upcoming"
        }
    }
}

private struct CampaignViewData: Identifiable {
    let id: String
    let lane: CampaignFeedLane?
    let gameName: String
    let campaignName: String
    let progressText: String
    let progressPercent: Double
    let artworkURL: URL?
    let isClaimed: Bool
    let tint: Color
}

private struct CampaignFeedCard: View {
    let item: CampaignViewData
    @State private var isHovering = false

    var body: some View {
        ZStack {
            CampaignArtworkBackground(url: item.artworkURL, tint: item.tint)

            LinearGradient(
                colors: [.black.opacity(0.78), .black.opacity(0.28), .clear],
                startPoint: .bottom,
                endPoint: .top
            )

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    if let lane = item.lane {
                        Text(lane.label)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.92))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(.ultraThinMaterial, in: Capsule())
                    }

                    Spacer(minLength: 0)

                    if item.isClaimed {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.white, .green.opacity(0.92))
                            .padding(8)
                            .background(.regularMaterial, in: Circle())
                    }
                }

                Spacer(minLength: 0)

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.gameName)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    Text(item.campaignName)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.84))
                        .lineLimit(2)

                    Text(item.progressText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                }
            }
            .padding(16)

            if item.progressPercent > 0 {
                VStack {
                    Spacer()

                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(.white.opacity(0.18))

                        Capsule()
                            .fill(.white.opacity(0.92))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .mask(alignment: .leading) {
                                GeometryReader { proxy in
                                    Capsule()
                                        .frame(width: proxy.size.width * (item.progressPercent / 100))
                                }
                            }
                    }
                    .frame(height: 4)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
            }
        }
        .frame(width: 240, height: 135)
        .background(.thinMaterial.opacity(0.16))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
        }
        .scaleEffect(isHovering ? 1.03 : 1)
        .shadow(color: .black.opacity(isHovering ? 0.24 : 0.16), radius: isHovering ? 22 : 14, y: isHovering ? 12 : 8)
        .animation(.easeInOut(duration: 0.2), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
    }
}

private struct CampaignArtworkBackground: View {
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
    }

    private var placeholder: some View {
        LinearGradient(
            colors: [tint.opacity(0.85), tint.opacity(0.45), Color.black.opacity(0.45)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
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
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var placeholder: some View {
        LinearGradient(
            colors: [tint.opacity(0.65), tint.opacity(0.35), Color.white.opacity(0.14)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
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
        .glassControlSurface(cornerRadius: 16)
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environment(NavigationModel(clientId: "preview"))
        .environment(AppModel(clientId: "preview"))
}
