import SwiftUI
import SwiftTwitchMiner

/// Activity Overview - displays miners as cards with controls.
struct ActivityOverviewView: View {
    @Environment(NavigationModel.self) private var navigation
    @State private var aggregateProgress: AggregateProgress?
    @State private var isRefreshing = false
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Metrics
                metricsHeader
                
                // Miners Grid
                if navigation.minerManager.miners.isEmpty {
                    EmptyStateView()
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 400), spacing: 16)], spacing: 16) {
                        ForEach(navigation.minerManager.miners) { miner in
                            MinerCardView(miner: miner)
                        }
                    }
                }
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
                    Task { await navigation.minerManager.startAll() }
                } label: {
                    Label("Start All", systemImage: "play.fill")
                }
                
                Button {
                    Task { await navigation.minerManager.stopAll() }
                } label: {
                    Label("Stop All", systemImage: "stop.fill")
                }
            }
        }
        .task {
            await refresh()
        }
    }
    
    private var metricsHeader: some View {
        HStack(spacing: 20) {
            MetricView(title: "Miners", value: "\(aggregateProgress?.activeMiners ?? 0)", icon: "person.2.fill", color: .blue)
            MetricView(title: "Claimed Today", value: "\(aggregateProgress?.claimedToday ?? 0)", icon: "gift.fill", color: .green)
            MetricView(title: "Pending", value: "\(aggregateProgress?.pendingDrops ?? 0)", icon: "hourglass", color: .orange)
            Spacer()
        }
        .padding(.bottom, 8)
    }
    
    private func refresh() async {
        isRefreshing = true
        aggregateProgress = await navigation.minerManager.getAggregateProgress()
        isRefreshing = false
    }
}

// MARK: - Miner Card View

struct MinerCardView: View {
    let miner: MinerManager.ManagedMiner
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                Circle()
                    .fill(statusColor.opacity(0.2))
                    .frame(width: 32, height: 32)
                    .overlay(
                        Text(miner.username.prefix(1).uppercased())
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(statusColor)
                    )
                
                VStack(alignment: .leading, spacing: 0) {
                    Text(miner.username)
                        .font(.headline)
                    Text(miner.status.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                statusIcon
            }
            
            Divider().opacity(0.1)
            
            // Current Activity
            VStack(alignment: .leading, spacing: 4) {
                Text("CURRENT CAMPAIGN")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.tertiary)
                
                Text(miner.currentCampaign ?? "None")
                    .font(.subheadline)
                    .lineLimit(1)
            }
            .frame(height: 40, alignment: .topLeading)
            
            // Stats
            HStack {
                Label("\(miner.dropsClaimed) claimed", systemImage: "gift")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            
            Spacer(minLength: 0)
            
            // Controls
            HStack(spacing: 8) {
                if miner.isRunning {
                    Button {
                        Task { await navigation.minerManager.stopMiner(minerId: miner.id) }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        Task { try? await navigation.minerManager.startMiner(minerId: miner.id) }
                    } label: {
                        Label("Start", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                
                Button {
                    Task { try? await navigation.minerManager.claimAllDrops(minerId: miner.id) }
                } label: {
                    Image(systemName: "gift.fill")
                }
                .buttonStyle(.bordered)
                .help("Claim all available drops")
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .background(statusColor.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(statusColor.opacity(0.1), lineWidth: 1)
        )
    }
    
    private var statusColor: Color {
        switch miner.status {
        case .watching: return .green
        case .claiming: return .purple
        case .authenticating, .fetchingCampaigns: return .blue
        case .error: return .red
        case .idle, .paused: return .gray
        }
    }
    
    @ViewBuilder
    private var statusIcon: some View {
        switch miner.status {
        case .watching:
            Image(systemName: "play.circle.fill").foregroundStyle(.green)
        case .claiming:
            Image(systemName: "gift.circle.fill").foregroundStyle(.purple)
        case .error:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        default:
            EmptyView()
        }
    }
}

// MARK: - Metric View

struct MetricView: View {
    let title: String
    let value: String
    let icon: String
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundStyle(color)
                Text(title)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.secondary.opacity(0.05))
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
            
            Button {
                navigation.showAddAccountSheet = true
            } label: {
                Label("Add Account", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .padding()
    }
}

// MARK: - Preview

#Preview {
    ActivityOverviewView()
        .environment(NavigationModel(clientId: "preview"))
}
