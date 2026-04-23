import SwiftUI
import SwiftMinerCore

/// Unified view for managing miner instances and their live execution state.
struct MinerOverviewView: View {
    @Environment(NavigationModel.self) private var navigation
    
    private var miners: [MinerManager.ManagedMiner] {
        navigation.minerManager.miners
    }

    var body: some View {
        Group {
            if miners.isEmpty {
                emptyState
            } else {
                MinersOverviewView() // Points to the existing multi-column workspace
            }
        }
        .navigationTitle("Miners")
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            Image(systemName: "cpu")
                .font(.system(size: 64))
                .foregroundStyle(.secondary.opacity(0.5))
            
            VStack(spacing: 8) {
                Text("No Miners Configured")
                    .font(.title2.weight(.bold))
                
                Text("Add a Twitch account to start mining drops automatically. Each account runs in its own isolated engine.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            Button {
                navigation.showAddAccountSheet = true
            } label: {
                Label("Add Miner", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    MinerOverviewView()
        .environment(NavigationModel(clientId: "preview"))
}
