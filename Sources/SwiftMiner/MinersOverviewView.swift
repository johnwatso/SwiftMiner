import SwiftUI
import SwiftMinerCore

/// Execution layer overview - scalable multi-miner workspace.
struct MinersOverviewView: View {
    @Environment(NavigationModel.self) private var navigation
    @State private var selectedActivitySummary: MinerManager.MinerActivitySummary?

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
        }
        .onChange(of: miners.map(\.id)) { _, _ in
            syncSelection()
        }
    }

    private var minerListPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(hasMultipleMiners ? "Miners" : "Miner")
                    .font(.headline)

                Text(hasMultipleMiners ? "Select a miner to inspect its state." : "Single-miner focus mode.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.top, 14)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(miners.enumerated()), id: \.element.id) { index, miner in
                        VStack(spacing: 0) {
                            Button {
                                navigation.selectedMinerId = miner.id
                            } label: {
                                MinerSourceListRow(
                                    miner: miner,
                                    compact: !hasMultipleMiners,
                                    isSelected: selectionBinding.wrappedValue == miner.id
                                )
                            }
                            .buttonStyle(.plain)

                            if index < miners.count - 1 {
                                Divider()
                                    .padding(.leading, 38)
                                    .padding(.trailing, 10)
                            }
                        }
                    }
                }
                .padding(3)
                .background(.background.opacity(0.24), in: RoundedRectangle(cornerRadius: GlassRadius.medium, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: GlassRadius.medium, style: .continuous)
                        .strokeBorder(.separator.opacity(0.18), lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: GlassRadius.medium, style: .continuous))
                .padding(.horizontal, 8)
            }
            .scrollIndicators(.never)

            if hasMultipleMiners {
                Spacer(minLength: 18)

                compactAcrossAllAccountsSection
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            }
        }
        .frame(
            minWidth: hasMultipleMiners ? 220 : 148,
            idealWidth: hasMultipleMiners ? 248 : 164,
            maxWidth: hasMultipleMiners ? 280 : 176
        )
        .padding(.leading, 24)
        .padding(.vertical, 24)
        .padding(.trailing, hasMultipleMiners ? 12 : 8)
    }

    @ViewBuilder
    private var selectedMinerPane: some View {
        if let miner = selectedMiner {
            let activeCampaigns = activePrioritisedCampaigns(for: miner)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    MinerActivityCard(miner: miner, prominence: .expanded, onSelect: {
                        navigation.selectedMinerId = miner.id
                    }, onLinkAccount: {
                        startLinkAccountFlow(for: miner)
                    })

                    selectedMinerWatchingStreamerSection(for: miner)

                    minerCampaignsSection(for: miner, campaigns: activeCampaigns)

                    if !hasMultipleMiners {
                        acrossAllAccountsSection
                    }
                }
                .frame(maxWidth: 1180, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
            }
            .id(miner.id)
            .task(id: miner.id) {
                await refreshSelectedActivitySummary(for: miner.id)
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
                    await refreshSelectedActivitySummary(for: miner.id)
                }
            }
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

    private func refreshSelectedActivitySummary(for minerId: String) async {
        selectedActivitySummary = await navigation.minerManager.getMinerActivitySummary(minerId: minerId)
    }

    private var acrossAllAccountsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ACROSS ALL ACCOUNTS")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 14), count: 3),
                spacing: 14
            ) {
                MetricCard(
                    title: "Watching Now",
                    value: "\(activeMinerCount)",
                    subtitle: "\(miners.count) configured accounts",
                    icon: "play.fill",
                    color: .blue
                )
                MetricCard(
                    title: "Prioritised Campaigns",
                    value: "\(prioritisedCampaignCount)",
                    subtitle: "active campaigns",
                    icon: "list.bullet.rectangle",
                    color: .green
                )
                MetricCard(
                    title: "Ready to Claim",
                    value: "\(claimableDropCount)",
                    subtitle: "\(earningDropCount) drops earning",
                    icon: "tray.and.arrow.down.fill",
                    color: .orange
                )
            }
        }
        .padding(.horizontal, 2)
    }

    private var compactAcrossAllAccountsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ACROSS ALL ACCOUNTS")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)

            VStack(spacing: 8) {
                CompactMetricCard(
                    title: "Watching",
                    value: "\(activeMinerCount)",
                    subtitle: "\(miners.count) accounts",
                    icon: "play.fill",
                    color: .blue
                )
                CompactMetricCard(
                    title: "Prioritised",
                    value: "\(prioritisedCampaignCount)",
                    subtitle: "active campaigns",
                    icon: "list.bullet.rectangle",
                    color: .green
                )
                CompactMetricCard(
                    title: "Ready",
                    value: "\(claimableDropCount)",
                    subtitle: "\(earningDropCount) earning",
                    icon: "tray.and.arrow.down.fill",
                    color: .orange
                )
            }
        }
        .padding(12)
        .background(.background.opacity(0.40), in: RoundedRectangle(cornerRadius: GlassRadius.small, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: GlassRadius.small, style: .continuous)
                .strokeBorder(.separator.opacity(0.22), lineWidth: 1)
        }
    }

    private var activeMinerCount: Int {
        miners.filter { miner in
            miner.status == .watching || miner.status == .claiming
        }.count
    }

    private var prioritisedCampaignCount: Int {
        var campaignIds = Set<String>()
        for miner in miners {
            for campaign in activePrioritisedCampaigns(for: miner) {
                campaignIds.insert(campaign.id)
            }
        }
        return campaignIds.count
    }

    private var claimableDropCount: Int {
        miners.reduce(0) { total, miner in
            total + miner.allCampaigns.reduce(0) { campaignTotal, campaign in
                campaignTotal + campaign.drops.filter(\.isClaimable).count
            }
        }
    }

    private var earningDropCount: Int {
        miners.reduce(0) { total, miner in
            total + miner.allCampaigns.reduce(0) { campaignTotal, campaign in
                campaignTotal + campaign.drops.filter { drop in
                    guard !drop.isClaimed, !drop.isClaimable else { return false }
                    return (drop.progress?.currentMinutes ?? 0) > 0
                }.count
            }
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

    private func startLinkAccountFlow(for miner: MinerManager.ManagedMiner) {
        Task {
            try? await navigation.minerManager.startMiner(
                minerId: miner.id,
                priorityGames: [],
                excludedGames: [],
                strategy: .mineAll,
                avoidDuplicateStreams: Settings.shared.avoidDuplicateStreams,
                prioritiseFollowedStreamers: Settings.shared.prioritiseFollowedStreamers
            )
        }
    }

    private func selectedMinerWatchingStreamerSection(for miner: MinerManager.ManagedMiner) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("WATCHING STREAMER")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            SelectedMinerStreamerRow(
                streamerName: selectedActivitySummary?.currentChannelName,
                streamerId: selectedActivitySummary?.currentChannelId,
                campaignName: selectedActivitySummary?.currentCampaignName ?? miner.currentCampaign,
                status: miner.status,
                isRunning: miner.isRunning
            )
        }
        .background(.background.opacity(0.62), in: RoundedRectangle(cornerRadius: GlassRadius.small, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: GlassRadius.small, style: .continuous)
                .strokeBorder(.separator.opacity(0.32), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func minerCampaignsSection(for miner: MinerManager.ManagedMiner, campaigns: [Campaign]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("PRIORITISED CAMPAIGNS")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)

                Text("\(campaigns.count)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            VStack(spacing: 1) {
                if campaigns.isEmpty {
                    NoActiveCampaignsRow()
                } else {
                    ForEach(campaigns) { campaign in
                        CampaignStatusRow(miner: miner, campaign: campaign)
                    }
                }
            }
        }
        .background(.background.opacity(0.62), in: RoundedRectangle(cornerRadius: GlassRadius.small, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: GlassRadius.small, style: .continuous)
                .strokeBorder(.separator.opacity(0.32), lineWidth: 1)
        }
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
                let leftStatusRank = campaignSortStatusRank(lhs.activityStatus(for: miner))
                let rightStatusRank = campaignSortStatusRank(rhs.activityStatus(for: miner))
                if leftStatusRank != rightStatusRank { return leftStatusRank < rightStatusRank }

                let leftMiningRank = campaignSortMiningRank(lhs.miningStatus)
                let rightMiningRank = campaignSortMiningRank(rhs.miningStatus)
                if leftMiningRank != rightMiningRank { return leftMiningRank < rightMiningRank }

                let leftPriority = priorityIndex(for: lhs, priorityKeys: priorityKeys)
                let rightPriority = priorityIndex(for: rhs, priorityKeys: priorityKeys)
                if leftPriority != rightPriority { return leftPriority < rightPriority }
                if lhs.endDate != rhs.endDate { return lhs.endDate < rhs.endDate }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    private func campaignSortStatusRank(_ status: CampaignActivityStatus) -> Int {
        switch status {
        case .watching:
            return 0
        case .waitingForStream:
            return 1
        case .requiresLink:
            return 2
        case .completed:
            return 3
        case .upcoming:
            return 4
        case .expired:
            return 5
        }
    }

    private func campaignSortMiningRank(_ status: MiningCampaignStatus) -> Int {
        switch status {
        case .claimable:
            return 0
        case .inProgress:
            return 1
        case .available:
            return 2
        case .claimed:
            return 3
        case .expired:
            return 4
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
    let isSelected: Bool
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

    private var statusSymbol: String {
        if snapshot.statusText == "Waiting" {
            return "clock"
        }
        if hasBlockingIssues {
            return "exclamationmark.triangle.fill"
        }
        return snapshot.statusSymbol
    }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: statusSymbol)
                .font(.system(size: 12, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(statusColor)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: compact ? 1 : 2) {
                Text(miner.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                if !compact {
                    Text(activityLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, compact ? 7 : 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(0.13))
            }
        }
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.18), lineWidth: 1)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: GlassRadius.small, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
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

    private var statusIcon: String {
        switch status {
        case .watching:
            return "play.fill"
        case .completed:
            return "checkmark"
        case .requiresLink:
            return "link.badge.plus"
        case .waitingForStream:
            return "antenna.radiowaves.left.and.right"
        case .upcoming:
            return "calendar"
        case .expired:
            return "clock.badge.xmark"
        }
    }

    private var statusColor: Color {
        switch status {
        case .watching, .completed:
            return .green
        case .requiresLink:
            return .orange
        case .waitingForStream:
            return .cyan
        case .upcoming, .expired:
            return .secondary
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: statusIcon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 18, height: 18)

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
                .font(.caption.weight(.semibold))
                .foregroundStyle(statusColor)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.background.opacity(0.001))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.separator.opacity(0.28))
                .frame(height: 1)
                .padding(.leading, 42)
        }
    }
}

private struct SelectedMinerStreamerRow: View {
    let streamerName: String?
    let streamerId: String?
    let campaignName: String?
    let status: MinerManager.MinerStatus
    let isRunning: Bool

    private var title: String {
        guard let streamerName, !streamerName.isEmpty else {
            return isRunning ? "Waiting for stream" : "Not watching"
        }
        return streamerName
    }

    private var subtitle: String {
        if let campaignName, !campaignName.isEmpty {
            return campaignName
        }

        switch status {
        case .watching:
            return "Mining active drops"
        case .waitingForStream:
            return "No eligible live stream yet"
        case .fetchingCampaigns:
            return "Refreshing campaigns"
        case .paused:
            return "Miner is paused"
        case .error, .blockedAccountNotLinked:
            return "Needs attention"
        default:
            return isRunning ? "Ready when a stream is available" : "Start miner to watch"
        }
    }

    private var iconName: String {
        streamerName == nil ? "tv" : "play.tv.fill"
    }

    private var iconColor: Color {
        streamerName == nil ? .secondary : .green
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if status == .watching {
                Text("Live")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .lineLimit(1)
            } else if let streamerId, !streamerId.isEmpty {
                Text(streamerId)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.background.opacity(0.001))
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
        .background(.background.opacity(0.001))
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
        .background(.background.opacity(0.62), in: RoundedRectangle(cornerRadius: GlassRadius.small, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: GlassRadius.small, style: .continuous)
                .strokeBorder(.separator.opacity(0.26), lineWidth: 1)
        }
    }
}

private struct CompactMetricCard: View {
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(color.opacity(0.12))

                Image(systemName: icon)
                    .foregroundStyle(color)
                    .font(.system(size: 11, weight: .semibold))
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.background.opacity(0.50), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(.separator.opacity(0.18), lineWidth: 1)
        }
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
