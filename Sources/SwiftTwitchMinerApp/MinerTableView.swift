import SwiftUI
import SwiftTwitchMiner

/// SwiftUI Table displaying all miners and their status
struct MinerTableView: View {
    let miners: [MinerManager.ManagedMiner]
    @Environment(NavigationModel.self) private var navigation
    
    var body: some View {
        Table(miners, selection: .constant(navigation.selectedMinerId)) {
            TableColumn("Account") { miner in
                HStack(spacing: 8) {
                    Image(systemName: "person.circle.fill")
                        .foregroundStyle(.purple)
                    
                    Text(miner.username)
                        .fontWeight(.medium)
                }
            }
            .width(min: 100, ideal: 120)
            
            TableColumn("Status") { miner in
                StatusBadge(status: miner.status)
            }
            .width(min: 80, ideal: 100)
            
            TableColumn("Campaign") { miner in
                Text(miner.currentCampaign ?? "—")
                    .foregroundStyle(miner.currentCampaign == nil ? .secondary : .primary)
                    .lineLimit(1)
            }
            .width(min: 120, ideal: 180)
            
            TableColumn("Drops") { miner in
                Text("\(miner.dropsClaimed)")
                    .font(.system(.body, design: .monospaced))
            }
            .width(min: 60, ideal: 80)
            
            TableColumn("Actions") { miner in
                HStack(spacing: 8) {
                    if miner.isRunning {
                        Button {
                            Task { await stopMiner(miner) }
                        } label: {
                            Image(systemName: "stop.fill")
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                    } else {
                        Button {
                            Task { await startMiner(miner) }
                        } label: {
                            Image(systemName: "play.fill")
                                .foregroundStyle(.green)
                        }
                        .buttonStyle(.borderless)
                    }
                    
                    Button {
                        navigation.selectedMinerId = miner.id
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
            .width(min: 80, ideal: 100)
        }
        .tableStyle(.inset)
    }
    
    private func startMiner(_ miner: MinerManager.ManagedMiner) async {
        try? await navigation.minerManager.startMiner(minerId: miner.id)
    }
    
    private func stopMiner(_ miner: MinerManager.ManagedMiner) async {
        await navigation.minerManager.stopMiner(minerId: miner.id)
    }
}

// MARK: - Status Badge

struct StatusBadge: View {
    let status: MinerManager.MinerStatus
    
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            
            Text(status.displayName)
                .font(.caption)
                .fontWeight(.medium)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(statusColor.opacity(0.15))
        .clipShape(Capsule())
    }
    
    private var statusColor: Color {
        switch status {
        case .idle:
            return .gray
        case .authenticating:
            return .blue
        case .fetchingCampaigns:
            return .cyan
        case .watching:
            return .green
        case .claiming:
            return .purple
        case .paused:
            return .orange
        case .error:
            return .red
        }
    }
}

// MARK: - Preview

#Preview {
    MinerTableView(miners: [
        MinerManager.ManagedMiner(
            id: "1",
            accountId: "acc1",
            username: "John",
            status: .watching,
            currentCampaign: "Rust Drops",
            dropsClaimed: 5,
            isRunning: true
        ),
        MinerManager.ManagedMiner(
            id: "2",
            accountId: "acc2",
            username: "AltAccount",
            status: .idle,
            currentCampaign: nil,
            dropsClaimed: 0,
            isRunning: false
        ),
        MinerManager.ManagedMiner(
            id: "3",
            accountId: "acc3",
            username: "TestAccount",
            status: .error,
            currentCampaign: nil,
            dropsClaimed: 2,
            isRunning: false
        )
    ])
    .environment(NavigationModel(clientId: "preview"))
    .frame(height: 300)
}
