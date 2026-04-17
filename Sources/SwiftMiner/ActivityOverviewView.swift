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
            let activeCampaigns = activePrioritisedCampaigns(for: miner)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    MinerStateCard(miner: miner, activityCampaigns: activeCampaigns) {
                        if case .blocked(let reasons) = miner.primaryState, reasons.contains(.accountNotLinked) {
                            Task { try? await navigation.minerManager.startMiner(minerId: miner.id, priorityGames: [], excludedGames: [], strategy: .mineAll) }
                        }
                    }

                    campaignActivitySection(for: miner, campaigns: activeCampaigns)
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
    private func campaignActivitySection(for miner: MinerManager.ManagedMiner, campaigns: [Campaign]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CAMPAIGNS")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)

            VStack(spacing: 8) {
                if campaigns.isEmpty {
                    NoActiveCampaignsRow()
                } else {
                    ForEach(campaigns) { campaign in
                        let isWatching = miner.status == .watching && miner.currentCampaignId == campaign.id
                        CampaignActivityRow(campaign: campaign, isWatching: isWatching)
                    }
                }
            }
        }
        .padding(.horizontal, 2)
    }

    private func activePrioritisedCampaigns(for miner: MinerManager.ManagedMiner) -> [Campaign] {
        let priorityKeys = miner.priorityGames
            .map { normalizedGameKey($0) }
            .filter { !$0.isEmpty }

        guard !priorityKeys.isEmpty else { return [] }

        let prioritySet = Set(priorityKeys)

        return miner.allCampaigns
            .filter { campaign in
                campaign.isTimeActive &&
                campaign.status != .disabled &&
                (
                    prioritySet.contains(normalizedGameKey(campaign.game.name)) ||
                    prioritySet.contains(normalizedGameKey(campaign.game.id))
                )
            }
            .sorted { lhs, rhs in
                let leftPriority = priorityIndex(for: lhs, priorityKeys: priorityKeys)
                let rightPriority = priorityIndex(for: rhs, priorityKeys: priorityKeys)
                if leftPriority != rightPriority { return leftPriority < rightPriority }
                if lhs.endDate != rhs.endDate { return lhs.endDate < rhs.endDate }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private func priorityIndex(for campaign: Campaign, priorityKeys: [String]) -> Int {
        let gameName = normalizedGameKey(campaign.game.name)
        let gameId = normalizedGameKey(campaign.game.id)
        return priorityKeys.firstIndex { $0 == gameName || $0 == gameId } ?? Int.max
    }

    private func normalizedGameKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
                if let campaign = firstActivePrioritisedCampaign {
                    return campaign.activityStatusMessage
                }
                return "No active campaigns"
            case .idle:
                if let campaign = firstActivePrioritisedCampaign {
                    return campaign.activityStatusMessage
                }
                return "No active campaigns"
            }
        }

        if miner.needsAuth {
            return "Needs Link"
        }
        return "No active campaigns"
    }

    private var firstActivePrioritisedCampaign: Campaign? {
        let priorityKeys = miner.priorityGames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }

        guard !priorityKeys.isEmpty else { return nil }

        let prioritySet = Set(priorityKeys)
        return miner.allCampaigns.first { campaign in
            campaign.isTimeActive &&
            campaign.status != .disabled &&
            (
                prioritySet.contains(campaign.game.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) ||
                prioritySet.contains(campaign.game.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            )
        }
    }
}

private struct CampaignActivityRow: View {
    let campaign: Campaign
    let isWatching: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(campaign.game.name)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(campaign.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Text(campaign.activityStatusMessage(isWatching: isWatching))
                .font(.caption)
                .foregroundStyle(isWatching ? AnyShapeStyle(Color.green) : AnyShapeStyle(.tertiary))
                .lineLimit(1)
                .frame(minWidth: 150, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: GlassRadius.small, style: .continuous))
    }
}

private struct NoActiveCampaignsRow: View {
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("No active campaigns")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)

                Text("Prioritised games will appear here when drops are live.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: GlassRadius.small, style: .continuous))
    }
}

extension Campaign {
    var activityStatusMessage: String {
        activityStatusMessage(isWatching: false)
    }

    func activityStatusMessage(isWatching: Bool) -> String {
        if !isAccountConnected {
            return "Account not linked"
        }
        if isWatching {
            return "Mining"
        }
        return "Waiting for eligible stream"
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
