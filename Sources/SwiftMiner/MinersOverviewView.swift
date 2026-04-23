import SwiftUI
import SwiftMinerCore

/// Execution layer overview - scalable multi-miner workspace.
struct MinersOverviewView: View {
    @Environment(NavigationModel.self) private var navigation
    @State private var aggregateProgress: AggregateProgress?
    @State private var statsExpanded = true

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
                EmptyMinersStateView()
            } else if hasMultipleMiners {
                HSplitView {
                    minerListPane
                    selectedMinerPane
                }
            } else {
                selectedMinerPane
            }
        }
        .navigationTitle("Miners")
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

                Text(hasMultipleMiners ? "Select a miner to inspect its state." : "Single-miner focus mode.")
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
                    MinerActivityCard(miner: miner, prominence: .expanded, onSelect: {
                        navigation.selectedMinerId = miner.id
                    }, onLinkAccount: {
                        startLinkAccountFlow(for: miner)
                    })

                    minerCampaignsSection(for: miner, campaigns: activeCampaigns)

                    acrossAllAccountsSection
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
                description: "Pick a miner from the list to inspect its live control panel and activity feed."
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(24)
        }
    }

    private var acrossAllAccountsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    statsExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Text("ACROSS ALL ACCOUNTS")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)

                    Image(systemName: statsExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)

                    Spacer()
                }
                .padding(.leading, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if statsExpanded {
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3),
                    spacing: 14
                ) {
                    MetricCard(
                        title: "Configured Accounts",
                        value: "\(miners.count)",
                        subtitle: "\(aggregateProgress?.activeMiners ?? miners.filter { $0.isRunning }.count) running or waiting",
                        icon: "person.2.fill",
                        color: .blue
                    )
                    MetricCard(
                        title: "Eligible Campaigns",
                        value: "\(aggregateProgress?.totalCampaigns ?? 0)",
                        subtitle: "across all accounts",
                        icon: "play.fill",
                        color: .green
                    )
                    MetricCard(
                        title: "Claimed Today",
                        value: "\(aggregateProgress?.claimedToday ?? 0)",
                        subtitle: "\(aggregateProgress?.claimedDrops ?? 0) total claimed",
                        icon: "sparkles.tv.fill",
                        color: .orange
                    )
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 2)
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

    private func startLinkAccountFlow(for miner: MinerManager.ManagedMiner) {
        Task {
            try? await navigation.minerManager.startMiner(
                minerId: miner.id,
                priorityGames: [],
                excludedGames: [],
                strategy: .mineAll
            )
        }
    }

    @ViewBuilder
    private func minerCampaignsSection(for miner: MinerManager.ManagedMiner, campaigns: [Campaign]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PRIORITISED CAMPAIGNS")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)

            VStack(spacing: 8) {
                if campaigns.isEmpty {
                    NoActiveCampaignsRow()
                } else {
                    ForEach(campaigns) { campaign in
                        CampaignStatusRow(miner: miner, campaign: campaign)
                    }
                }
            }
        }
        .padding(.horizontal, 2)
    }

    private func activePrioritisedCampaigns(for miner: MinerManager.ManagedMiner) -> [Campaign] {
        let configuredPriorityGames = miner.priorityGames.isEmpty ? Settings.shared.priorityGames : miner.priorityGames
        let priorityKeys = configuredPriorityGames
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
    @ObservedObject private var settings = Settings.shared

    private var snapshot: MinerActivitySnapshot {
        MinerActivitySnapshot.resolve(
            for: miner,
            priorityGames: settings.priorityGames,
            excludedGames: settings.excludedGames,
            strategy: settings.miningStrategy,
            includesBadgeAndEmoteCampaigns: settings.enableBadgesEmotes
        )
    }

    private var hasBlockingIssues: Bool {
        miner.status == .blockedAccountNotLinked || miner.status == .error || miner.needsAuth
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                
                if hasBlockingIssues {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 4, height: 4)
                        .offset(x: 2, y: -2)
                }
            }

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
        snapshot.statusColor
    }

    private var activityLabel: String {
        if snapshot.now.campaignId != nil {
            return "Watching \(snapshot.now.title)"
        }
        if let next = snapshot.upNext {
            return "Likely next: \(next.title)"
        }
        return snapshot.statusText
    }
}

private struct CampaignStatusRow: View {
    let miner: MinerManager.ManagedMiner
    let campaign: Campaign

    private var status: CampaignActivityStatus {
        campaign.activityStatus(for: miner)
    }

    private var isWatching: Bool {
        status == .watching
    }

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

            Text(status.label)
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
                Text("Idle — No eligible campaigns")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)

                Text("No prioritised drops are available for this account right now.")
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

// MARK: - Metric Card

struct MetricCard: View {
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(color.opacity(0.12))

                    Image(systemName: icon)
                        .foregroundStyle(color)
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(width: 28, height: 28)

                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)
            }

            Text(value)
                .font(.system(size: 32, weight: .semibold, design: .rounded))

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: GlassRadius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: GlassRadius.medium, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.06), radius: 5, y: 2)
    }
}

private struct EmptyMinersStateView: View {
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        MaterialEmptyStatePanel(
            "No Twitch accounts connected",
            systemImage: "person.badge.plus",
            description: "Add an account to turn this space into a live miner dashboard."
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
    MinersOverviewView()
        .environment(NavigationModel(clientId: "preview"))
}
