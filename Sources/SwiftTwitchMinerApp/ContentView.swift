import SwiftUI
import SwiftTwitchMiner

/// Root view — 2-column NavigationSplitView (Sidebar | Detail)
struct ContentView: View {
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        @Bindable var nav = navigation
        NavigationSplitView {
            SidebarView()
        } detail: {
            detailView
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
        VStack(spacing: 0) {
            // Header / Toolbar
            HStack {
                Picker("Level", selection: $levelFilter) {
                    Text("All Levels").tag(nil as EventLevel?)
                    Text("Info").tag(EventLevel.info as EventLevel?)
                    Text("Warning").tag(EventLevel.warning as EventLevel?)
                    Text("Error").tag(EventLevel.error as EventLevel?)
                }
                .frame(width: 150)
                
                TextField("Search events...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 300)
                
                Spacer()
                
                Toggle("Show raw logs", isOn: $showRawLogs)
                    .toggleStyle(.checkbox)
                
                Button("Clear") {
                    navigation.clearEvents()
                }
            }
            .padding(12)
            .background(.bar)

            Divider()

            if filteredEvents.isEmpty {
                ContentUnavailableView(
                    "No Events",
                    systemImage: "bell.slash",
                    description: Text("Activity will appear here as it happens.")
                )
            } else {
                List(filteredEvents) { event in
                    EventRow(event: event, showRaw: showRawLogs)
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("Events")
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
                Divider()
                minerStatusSection
                Divider()
                campaignSummarySection
            }
            .padding()
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
            columns: Array(repeating: GridItem(.flexible(), spacing: 16), count: 4),
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
                title: "Active Drops",
                value: "\(activeDropCount)",
                subtitle: "across all games",
                icon: "play.fill",
                color: .purple
            )
            OverviewMetricCard(
                title: "Total Claimed",
                value: "\(progress?.claimedDrops ?? 0)",
                subtitle: "+\(progress?.claimedToday ?? 0) today",
                icon: "gift.fill",
                color: .green
            )
            OverviewMetricCard(
                title: "Pending Claims",
                value: "\(pendingClaimCount)",
                subtitle: "ready to claim",
                icon: "clock.badge.fill",
                color: .orange
            )
        }
    }

    private var activeDropCount: Int {
        navigation.minerManager.campaignStore.campaigns
            .filter { $0.isActive }
            .reduce(0) { $0 + $1.drops.filter { !$0.isClaimed }.count }
    }

    private var pendingClaimCount: Int {
        navigation.minerManager.campaignStore.campaigns
            .reduce(0) { $0 + $1.drops.filter { $0.isClaimable }.count }
    }

    // MARK: - Miner Status

    private var minerStatusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Miners")
                .font(.title3.weight(.semibold))

            if navigation.minerManager.miners.isEmpty {
                Text("No miners configured. Add an account to get started.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(navigation.minerManager.miners) { miner in
                        MinerStatusRow(miner: miner)
                    }
                }
            }
        }
    }

    // MARK: - Campaign Summary

    private var campaignSummarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Active Campaigns")
                .font(.title3.weight(.semibold))

            let active = navigation.minerManager.campaignStore.campaigns.filter { $0.isActive }

            if active.isEmpty {
                Text("No active campaigns")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 6) {
                    ForEach(gameSummaries(from: active), id: \.id) { game in
                        CampaignSummaryRow(game: game)
                    }
                }
            }
        }
    }

    private func gameSummaries(from campaigns: [Campaign]) -> [GameSummary] {
        var map: [String: [Campaign]] = [:]
        for c in campaigns {
            let key = c.game.id.isEmpty ? c.game.name.lowercased() : c.game.id
            map[key, default: []].append(c)
        }
        return map.map { _, group in
            let first = group[0]
            let drops = group.flatMap { $0.drops }
            return GameSummary(
                gameId: first.game.id,
                gameName: first.game.name,
                totalDrops: drops.count,
                claimedDrops: drops.filter { $0.isClaimed }.count,
                activeDrops: drops.filter { !$0.isClaimed }.count
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
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(color.opacity(0.15), lineWidth: 1)
        )
    }
}

// MARK: - Miner Status Row

private struct MinerStatusRow: View {
    let miner: MinerManager.ManagedMiner

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(statusColor)
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
                .foregroundStyle(statusColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var statusColor: Color {
        switch miner.status {
        case .watching:                          return .green
        case .claiming:                          return .purple
        case .authenticating, .fetchingCampaigns, .paused: return .orange
        case .error:                             return .red
        case .idle:                              return .gray
        }
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
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environment(NavigationModel(clientId: "preview"))
        .environment(AppModel(clientId: "preview"))
}
