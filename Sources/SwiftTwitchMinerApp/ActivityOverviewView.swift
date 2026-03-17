import SwiftUI
import SwiftTwitchMiner

/// Activity Overview - the default landing screen showing system-wide status
/// Displays aggregated metrics and a table of all miners
struct ActivityOverviewView: View {
    @Environment(NavigationModel.self) private var navigation
    @State private var aggregateProgress: AggregateProgress?
    @State private var isRefreshing = false
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                headerSection
                
                Divider()
                
                // Stats Grid
                statsSection
                
                Divider()
                
                // Miner Table
                minerTableSection
            }
            .padding()
        }
        .navigationTitle("Activity")
        .toolbar {
            ToolbarItemGroup {
                Button {
                    Task { await refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isRefreshing)
                
                Button {
                    Task { await startAll() }
                } label: {
                    Label("Start All", systemImage: "play.fill")
                }
                
                Button {
                    Task { await stopAll() }
                } label: {
                    Label("Stop All", systemImage: "stop.fill")
                }
            }
        }
        .task {
            await refresh()
        }
    }
    
    // MARK: - Sections
    
    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SwiftTwitchMiner")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text("Multi-account Twitch drops miner")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
    
    private var statsSection: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible()),
            GridItem(.flexible()),
            GridItem(.flexible())
        ], spacing: 16) {
            StatCard(
                title: "Active Miners",
                value: "\(aggregateProgress?.activeMiners ?? 0)",
                icon: "person.2.fill",
                color: .blue
            )
            
            StatCard(
                title: "Active Campaigns",
                value: "\(aggregateProgress?.totalCampaigns ?? 0)",
                icon: "gamecontroller.fill",
                color: .purple
            )
            
            StatCard(
                title: "Drops Claimed",
                value: "\(aggregateProgress?.claimedDrops ?? 0)",
                icon: "gift.fill",
                color: .green
            )
            
            StatCard(
                title: "Pending Drops",
                value: "\(aggregateProgress?.pendingDrops ?? 0)",
                icon: "hourglass",
                color: .orange
            )
        }
    }
    
    private var minerTableSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Miners")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Spacer()
                
                Text("\(navigation.minerManager.miners.count) accounts")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            if navigation.minerManager.miners.isEmpty {
                EmptyStateView()
            } else {
                MinerTableView(miners: navigation.minerManager.miners)
            }
        }
    }
    
    // MARK: - Actions
    
    private func refresh() async {
        isRefreshing = true
        aggregateProgress = await navigation.minerManager.getAggregateProgress()
        isRefreshing = false
    }
    
    private func startAll() async {
        await navigation.minerManager.startAll()
        await refresh()
    }
    
    private func stopAll() async {
        await navigation.minerManager.stopAll()
        await refresh()
    }
}

// MARK: - Stat Card

struct StatCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
            
            Text(value)
                .font(.system(size: 32, weight: .bold, design: .rounded))
            
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color.secondary.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Empty State

struct EmptyStateView: View {
    @Environment(NavigationModel.self) private var navigation
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.badge.plus")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            
            Text("No Twitch accounts connected")
                .font(.headline)
            
            Text("Add a Twitch account to start mining drops")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            
            Button {
                // Show add account sheet
            } label: {
                Label("Add Twitch Account", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
        .padding()
    }
}

// MARK: - Preview

#Preview {
    ActivityOverviewView()
        .environment(NavigationModel(clientId: "preview"))
}
