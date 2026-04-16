import SwiftUI
import SwiftMinerCore

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
                StatusBadge(miner: miner)
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
}

// MARK: - Status Badge

struct StatusBadge: View {
    let miner: MinerManager.ManagedMiner

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)

            Text(label)
                .font(.caption2)
                .fontWeight(.bold)
                .textCase(.uppercase)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay {
                    Capsule()
                        .fill(statusColor.opacity(0.12))
                }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Status: \(label)")
    }

    private var label: String {
        miner.statusLabel
    }

    private var statusColor: Color {
        guard let resolved = miner.resolvedPrimaryState?.resolved else {
            return fallbackColor
        }
        switch resolved.state {
        case .watching:
            return .green
        case .blocked:
            switch resolved.reason {
            case .notLinked: return .orange
            case .noLiveStreams: return .cyan
            default: return .secondary
            }
        case .idle:
            return .gray
        }
    }

    private var fallbackColor: Color {
        switch miner.status {
        case .idle: return .gray
        case .authenticating: return .blue
        case .fetchingCampaigns: return .cyan
        case .watching: return .green
        case .waitingForStream: return .yellow
        case .claiming: return .purple
        case .paused: return .orange
        case .error: return .red
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
