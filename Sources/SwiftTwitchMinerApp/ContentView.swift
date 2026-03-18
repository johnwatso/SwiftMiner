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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                metricsSection
                minerStatusSection
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
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 3),
            spacing: 16
        ) {
            OverviewMetricCard(
                title: "Active Miners",
                value: "\(progress?.activeMiners ?? navigation.minerManager.miners.filter { $0.isRunning }.count)",
                subtitle: "\(navigation.minerManager.miners.count) total",
                icon: "person.2.fill",
                color: .blue
            )
            OverviewMetricCard(
                title: "Active Campaigns",
                value: "\(activeCampaignCount)",
                subtitle: "across all games",
                icon: "play.fill",
                color: .green
            )
            OverviewMetricCard(
                title: "Total Claimed",
                value: "\(progress?.claimedDrops ?? 0)",
                subtitle: "+\(progress?.claimedToday ?? 0) today",
                icon: "gift.fill",
                color: .secondary
            )
        }
    }

    private var activeCampaignCount: Int {
        navigation.minerManager.campaignStore.campaigns
            .filter { $0.isMiningEligible }
            .count
    }

    // MARK: - Miner Status

    private var minerStatusSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Currently Mining")
                .font(.title3.weight(.semibold))

            let activeCampaigns = navigation.minerManager.campaignStore.campaigns.filter { $0.isMiningEligible }
            let activeGameNames = Array(Set(activeCampaigns.map { $0.gameName })).sorted()

            // Surface layer card: Miner list
            VStack(alignment: .leading, spacing: 8) {
                if navigation.minerManager.miners.isEmpty {
                    Text("No miners configured. Add an account to get started.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(navigation.minerManager.miners) { miner in
                        HStack(spacing: 12) {
                            Circle()
                                .fill(statusColor(for: miner))
                                .frame(width: 8, height: 8)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(miner.username)
                                    .font(.system(size: 13, weight: .medium))
                                if let campaign = miner.currentCampaign {
                                    Text(campaign)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }

                            Spacer()

                            Text(miner.status.displayName)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(statusColor(for: miner))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .glassControlSurface(cornerRadius: 14)
                    }
                }
            }
            .padding(16)
            .glassPanel(cornerRadius: 24)

            if !activeGameNames.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Active Games")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)

                    Text(activeGameNames.joined(separator: ", "))
                        .font(.subheadline)
                        .lineLimit(2)
                }
                .padding(16)
                .glassPanel(cornerRadius: 24)
            }
        }
        .padding(20)
        .glassContentSurface()
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
            Text("Active Campaigns")
                .font(.title3.weight(.semibold))

            // Show any campaign that is active, connected, and has unclaimed drops (even if they're already 100%)
            let active = navigation.minerManager.campaignStore.campaigns.filter { 
                $0.isTimeActive && $0.isAccountConnected && !$0.unclaimedDrops.isEmpty 
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
                    ForEach(gameSummaries(from: active), id: \.id) { game in
                        CampaignSummaryRow(game: game)
                    }
                }
            }
        }
        .padding(20)
        .glassContentSurface()
    }

    private func gameSummaries(from campaigns: [Campaign]) -> [GameSummary] {
        var map: [String: [Campaign]] = [:]
        for c in campaigns {
            let key = c.game.id.isEmpty ? c.game.name.lowercased() : c.game.id
            map[key, default: []].append(c)
        }
        return map.map { _, group in
            let first = group[0]
            // We count all unclaimed drops as 'active' for the UI summary
            let unclaimedDrops = group.flatMap { $0.unclaimedDrops }
            let allDrops = group.flatMap { $0.drops }
            return GameSummary(
                gameId: first.game.id,
                gameName: first.game.name,
                totalDrops: allDrops.count,
                claimedDrops: allDrops.filter { $0.isClaimed }.count,
                activeDrops: unclaimedDrops.count
            )
        }.sorted { $0.gameName < $1.gameName }
    }
}

// MARK: - Supporting Types

struct GameSummary {
    let gameId: String
    let gameName: String
    let totalDrops: Int
    let claimedDrops: Int
    let activeDrops: Int
    var id: String { gameId.isEmpty ? gameName : gameId }
    var progressPercent: Double {
        guard totalDrops > 0 else { return 0 }
        return Double(claimedDrops) / Double(totalDrops) * 100
    }
}

// MARK: - Overview Metric Card

struct OverviewMetricCard: View {
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .font(.title3)

            Text(value)
                .font(.system(size: 28, weight: .bold, design: .rounded))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.medium))
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassPanel(cornerRadius: 24)
    }
}

// MARK: - Campaign Summary Row

private struct CampaignSummaryRow: View {
    let game: GameSummary

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(game.gameName)
                    .font(.system(size: 13, weight: .medium))
                Text("\(game.activeDrops) active • \(game.claimedDrops)/\(game.totalDrops) claimed")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            ProgressView(value: game.progressPercent, total: 100)
                .progressViewStyle(.linear)
                .frame(width: 80)
                .tint(.purple)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .glassControlSurface(cornerRadius: 16)
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environment(NavigationModel(clientId: "preview"))
        .environment(AppModel(clientId: "preview"))
}
