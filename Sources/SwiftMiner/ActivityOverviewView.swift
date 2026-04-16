import SwiftUI
import SwiftMinerCore

/// Activity Overview - scalable multi-account workspace.
struct ActivityOverviewView: View {
    @Environment(NavigationModel.self) private var navigation
    @State private var aggregateProgress: AggregateProgress?

    private var miners: [MinerManager.ManagedMiner] {
        navigation.minerManager.miners
    }

    private var selectedMiner: MinerManager.ManagedMiner? {
        guard let selectedId = navigation.selectedMinerId else { return miners.first }
        return miners.first { $0.id == selectedId } ?? miners.first
    }

    private var hasMultipleMiners: Bool {
        miners.count > 1
    }

    var body: some View {
        Group {
            if miners.isEmpty {
                EmptyActivityStateView()
            } else if hasMultipleMiners {
                HSplitView {
                    minerListPane
                    selectedMinerPane
                }
            } else {
                selectedMinerPane
            }
        }
        .navigationTitle("Activity")
        .task {
            syncSelection()
            await refresh()
        }
        .onChange(of: miners.map(\.id)) { _, _ in
            syncSelection()
        }
    }

    private var minerListPane: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(hasMultipleMiners ? "Miners" : "Miner")
                    .font(.headline)

                Text(hasMultipleMiners ? "Select an account to inspect its live state." : "Single-account focus mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            List(selection: selectionBinding) {
                ForEach(miners) { miner in
                    MinerSourceListRow(miner: miner, compact: !hasMultipleMiners)
                        .tag(Optional(miner.id))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .frame(
            minWidth: hasMultipleMiners ? 220 : 148,
            idealWidth: hasMultipleMiners ? 248 : 164,
            maxWidth: hasMultipleMiners ? 280 : 176
        )
        .background {
            RoundedRectangle(cornerRadius: GlassRadius.subtle, style: .continuous)
                .fill(.thinMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: GlassRadius.subtle, style: .continuous))
        .padding(.leading, 24)
        .padding(.vertical, 24)
        .padding(.trailing, hasMultipleMiners ? 12 : 8)
    }

    @ViewBuilder
    private var selectedMinerPane: some View {
        if let miner = selectedMiner {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    MinerStateCard(miner: miner) {
                        if case .blocked(let reasons) = miner.primaryState, reasons.contains(.accountNotLinked) {
                            Task { try? await navigation.minerManager.startMiner(minerId: miner.id, priorityGames: [], excludedGames: [], strategy: .mineAll) }
                        }
                    }

                    queuedCampaignsSection(for: miner)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .id(miner.id)
            .transition(.opacity.combined(with: .move(edge: .trailing)))
            .animation(.easeInOut(duration: 0.22), value: miner.id)
        } else {
            MaterialEmptyStatePanel(
                "Select a miner",
                systemImage: "person.crop.square",
                description: "Pick an account from the list to inspect its live control panel and activity feed."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        }
    }

    private var selectionBinding: Binding<String?> {
        Binding(
            get: { navigation.selectedMinerId ?? miners.first?.id },
            set: { navigation.selectedMinerId = $0 }
        )
    }

    private func syncSelection() {
        guard !miners.isEmpty else {
            navigation.selectedMinerId = nil
            return
        }

        if let selectedId = navigation.selectedMinerId,
           miners.contains(where: { $0.id == selectedId }) {
            return
        }

        navigation.selectedMinerId = miners.first?.id
    }

    private func refresh() async {
        aggregateProgress = await navigation.minerManager.getAggregateProgress()
    }

    @ViewBuilder
    private func queuedCampaignsSection(for miner: MinerManager.ManagedMiner) -> some View {
        let queued = miner.allCampaigns.filter { 
            $0.id != miner.currentCampaignId && $0.isMiningEligible 
        }
        
        if !queued.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("UP NEXT")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)

                VStack(spacing: 8) {
                    ForEach(queued.prefix(3)) { campaign in
                        QueuedCampaignRow(campaign: campaign)
                    }
                }
            }
            .padding(.horizontal, 2)
        }
    }
}

private struct MinerSourceListRow: View {
    let miner: MinerManager.ManagedMiner
    let compact: Bool

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: compact ? 1 : 2) {
                Text(miner.username)
                    .font(.body.weight(.medium))
                    .lineLimit(1)

                if !compact {
                    Text(activityLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            if miner.isRunning {
                Image(systemName: "play.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, compact ? 8 : 10)
        .contentShape(Rectangle())
    }

    private var statusColor: Color {
        guard let resolved = miner.resolvedPrimaryState?.resolved else {
            if miner.needsAuth { return .orange }
            return miner.status == .watching ? .green : .gray
        }

        switch resolved.state {
        case .watching:
            return .green
        case .blocked:
            return resolved.reason == .notLinked ? .orange : .cyan
        case .idle:
            return .gray
        }
    }

    private var activityLabel: String {
        if let resolved = miner.resolvedPrimaryState?.resolved {
            switch resolved.state {
            case .watching:
                return "Watching \(resolved.gameName)"
            case .blocked:
                if resolved.reason == .notLinked {
                    return "Needs Link"
                }
                return "No active campaigns"
            case .idle:
                return "No active campaigns"
            }
        }

        if miner.needsAuth {
            return "Needs Link"
        }
        return "No active campaigns"
    }
}

private struct QueuedCampaignRow: View {
    let campaign: Campaign

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(.blue.opacity(0.3))
                .frame(width: 6, height: 6)

            Text(campaign.game.name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)

            Text("·")
                .foregroundStyle(.tertiary)

            Text(campaign.name)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: GlassRadius.small, style: .continuous))
    }
}

private struct EmptyActivityStateView: View {
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        MaterialEmptyStatePanel(
            "No Twitch accounts connected",
            systemImage: "person.badge.plus",
            description: "Add an account to turn this space into a live activity dashboard."
        ) {
            Button {
                navigation.showAddAccountSheet = true
            } label: {
                Label("Add Account", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .padding(24)
    }
}

#Preview {
    ActivityOverviewView()
        .environment(NavigationModel(clientId: "preview"))
}
