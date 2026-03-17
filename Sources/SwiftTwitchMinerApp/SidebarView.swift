import SwiftUI
import SwiftTwitchMiner

/// Sidebar navigation for the multi-miner dashboard.
///
/// Sections:
///   ACCOUNTS — one row per managed miner, with status dot and drops badge
///   CAMPAIGNS — link to aggregated campaigns view
///   SYSTEM    — Logs, Settings
struct SidebarView: View {
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        @Bindable var nav = navigation
        List(selection: $nav.selectedItem) {
            // MARK: Activity
            Section {
                Label("Activity", systemImage: "chart.bar.fill")
                    .tag(NavigationModel.SidebarItem.activity)
            }

            // MARK: Accounts
            Section("ACCOUNTS") {
                ForEach(navigation.minerManager.miners) { miner in
                    MinerSidebarRow(miner: miner)
                        .tag(NavigationModel.SidebarItem.account(id: miner.id))
                }

                if navigation.minerManager.miners.isEmpty {
                    Text("No accounts")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .listRowSeparator(.hidden)
                }

                Button {
                    nav.showAddAccountSheet = true
                } label: {
                    Label("Add Account", systemImage: "plus.circle")
                        .foregroundStyle(.blue)
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
            }

            // MARK: Drops
            Section("DROPS") {
                HStack {
                    Label("Drops", systemImage: "gamecontroller.fill")
                    Spacer()
                    if claimableCount > 0 {
                        Text("\(claimableCount)")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green, in: Capsule())
                            .foregroundStyle(.white)
                    } else if activeCampaignCount > 0 {
                        Text("\(activeCampaignCount)")
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.2), in: Capsule())
                    }
                }
                .tag(NavigationModel.SidebarItem.campaigns)
            }

            // MARK: System
            Section("SYSTEM") {
                Label("Logs", systemImage: "text.alignleft")
                    .tag(NavigationModel.SidebarItem.logs)

                Label("Settings", systemImage: "gear")
                    .tag(NavigationModel.SidebarItem.settings)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("SwiftTwitchMiner")
        .toolbar {
            ToolbarItemGroup {
                // Start All / Stop All quick actions
                let hasRunning = navigation.minerManager.miners.contains { $0.isRunning }
                let hasStopped = navigation.minerManager.miners.contains { !$0.isRunning }

                if hasStopped {
                    Button {
                        Task { await navigation.minerManager.startAll() }
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .help("Start All Miners")
                }

                if hasRunning {
                    Button {
                        Task { await navigation.minerManager.stopAll() }
                    } label: {
                        Image(systemName: "stop.fill")
                    }
                    .help("Stop All Miners")
                }
            }
        }
    }

    /// Number of miners currently watching a campaign.
    private var activeCampaignCount: Int {
        navigation.minerManager.miners.filter { $0.currentCampaign != nil }.count
    }
    
    /// Total number of games with claimable drops across all miners.
    private var claimableCount: Int {
        let allCampaigns = navigation.minerManager.miners.flatMap { $0.allCampaigns }
        var uniqueGamesWithClaims = Set<String>()
        
        for c in allCampaigns {
            if c.hasClaimableDrops {
                uniqueGamesWithClaims.insert(c.game.id)
            }
        }
        return uniqueGamesWithClaims.count
    }
}

// MARK: - Miner Sidebar Row

private struct MinerSidebarRow: View {
    let miner: MinerManager.ManagedMiner

    var body: some View {
        HStack(spacing: 8) {
            // Avatar placeholder
            ZStack {
                Circle()
                    .fill(avatarColor.opacity(0.2))
                    .frame(width: 28, height: 28)
                Text(miner.username.prefix(1).uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(avatarColor)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(miner.username)
                    .font(.callout)
                    .lineLimit(1)

                if let campaign = miner.currentCampaign {
                    Text(campaign)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            // Status indicator
            statusIndicator
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if miner.dropsClaimed > 0 {
            Text("\(miner.dropsClaimed)")
                .font(.caption2.weight(.semibold))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.green.opacity(0.15), in: Capsule())
                .foregroundStyle(.green)
        }
        Circle()
            .fill(statusColor)
            .frame(width: 7, height: 7)
    }

    private var statusColor: Color {
        switch miner.status {
        case .watching:          return .green
        case .authenticating:    return .orange
        case .fetchingCampaigns: return .blue
        case .claiming:          return .purple
        case .paused:            return .orange
        case .error:             return .secondary
        case .idle:              return .gray
        }
    }

    private var avatarColor: Color {
        // Stable color derived from username
        let colors: [Color] = [.purple, .blue, .teal, .green, .orange, .pink, .indigo]
        let index = abs(miner.username.hashValue) % colors.count
        return colors[index]
    }
}

// MARK: - Preview

#Preview {
    NavigationSplitView {
        SidebarView()
    } content: {
        Text("Content")
    } detail: {
        Text("Detail")
    }
    .environment(NavigationModel(clientId: "preview"))
}
