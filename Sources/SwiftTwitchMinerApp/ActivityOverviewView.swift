import SwiftUI
import SwiftTwitchMiner

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
            } else {
                HSplitView {
                    minerListPane
                    selectedMinerPane
                }
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
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.thinMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding(.leading, 24)
        .padding(.vertical, 24)
        .padding(.trailing, hasMultipleMiners ? 12 : 8)
    }

    @ViewBuilder
    private var selectedMinerPane: some View {
        if let miner = selectedMiner {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    MinerControlPanel(
                        miner: miner,
                        aggregateProgress: aggregateProgress,
                        nextAction: nextAction(for: miner)
                    )

                    MinerActivityFeedSection(
                        miner: miner,
                        entries: minerEvents(for: miner)
                    )
                }
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

    private func minerEvents(for miner: MinerManager.ManagedMiner) -> [EventEntry] {
        navigation.events.filter { $0.minerId == miner.id }
    }

    private func nextAction(for miner: MinerManager.ManagedMiner) -> MinerNextAction {
        switch miner.status {
        case .watching:
            return MinerNextAction(
                title: "Watching for progress",
                detail: "Staying on an eligible stream until the current campaign advances or completes.",
                color: .green
            )
        case .claiming:
            return MinerNextAction(
                title: "Claiming completed rewards",
                detail: "Wrapping up finished drops before returning to live watching.",
                color: .purple
            )
        case .fetchingCampaigns:
            return MinerNextAction(
                title: "Scanning Twitch",
                detail: "Refreshing campaign availability and looking for the next eligible route.",
                color: .blue
            )
        case .authenticating:
            return MinerNextAction(
                title: "Refreshing session",
                detail: "Checking credentials so the miner can resume automated watching.",
                color: .orange
            )
        case .paused:
            return MinerNextAction(
                title: "Paused between opportunities",
                detail: "Waiting for a live eligible campaign or an operator action.",
                color: .orange
            )
        case .error:
            return MinerNextAction(
                title: "Needs attention",
                detail: "Open Events for deeper context, then refresh or reconnect this account.",
                color: .red
            )
        case .idle:
            return MinerNextAction(
                title: "Ready to start",
                detail: "Start this miner to fetch campaigns and begin watching for drops.",
                color: .secondary
            )
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
                    Text(miner.currentCampaign ?? miner.status.displayName)
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
        switch miner.status {
        case .watching: return .green
        case .claiming: return .purple
        case .authenticating, .fetchingCampaigns: return .blue
        case .paused: return .orange
        case .error: return .red
        case .idle: return .gray
        }
    }
}

private struct MinerControlPanel: View {
    let miner: MinerManager.ManagedMiner
    let aggregateProgress: AggregateProgress?
    let nextAction: MinerNextAction

    @Environment(NavigationModel.self) private var navigation
    @State private var isStarting = false
    @State private var isStopping = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(miner.username)
                        .font(.title2.weight(.semibold))

                    HStack(spacing: 8) {
                        Circle()
                            .fill(nextAction.color)
                            .frame(width: 8, height: 8)

                        Text(miner.status.displayName)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                HStack(spacing: 10) {
                    primaryButton

                    Button {
                        Task { await navigation.minerManager.forceRefreshMiner(minerId: miner.id) }
                    }
                    label: {
                        Text("Rescan")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                }
            }

            HStack(spacing: 14) {
                ControlPanelInfoBlock(
                    title: "Campaign",
                    value: miner.currentCampaign ?? "No campaign selected",
                    subtitle: miner.currentCampaign == nil ? "Standing by" : "Currently assigned"
                )

                ControlPanelInfoBlock(
                    title: "Next Action",
                    value: nextAction.title,
                    subtitle: nextAction.detail
                )

                ControlPanelInfoBlock(
                    title: "Drops Claimed",
                    value: "\(miner.dropsClaimed)",
                    subtitle: aggregateProgress.map { "\($0.claimedToday) claimed today across all miners" } ?? "Live dashboard stats"
                )
            }
        }
        .padding(22)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.regularMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.10), radius: 22, y: 10)
    }

    @ViewBuilder
    private var primaryButton: some View {
        if miner.isRunning {
            Button {
                Task {
                    isStopping = true
                    await navigation.minerManager.stopMiner(minerId: miner.id)
                    isStopping = false
                }
            } label: {
                Text(isStopping ? "Stopping…" : "Stop")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red.opacity(0.85))
            .disabled(isStopping)
        } else {
            Button {
                Task {
                    isStarting = true
                    let settings = Settings.shared
                    try? await navigation.minerManager.startMiner(
                        minerId: miner.id,
                        priorityGames: settings.priorityGames,
                        excludedGames: settings.excludedGames,
                        strategy: settings.miningStrategy,
                        enableBadgesEmotes: settings.enableBadgesEmotes
                    )
                    isStarting = false
                }
            } label: {
                Text(isStarting ? "Starting…" : "Start")
            }
            .buttonStyle(.borderedProminent)
            .disabled(isStarting)
        }
    }
}

private struct ControlPanelInfoBlock: View {
    let title: String
    let value: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)

            Text(value)
                .font(.headline)
                .lineLimit(2)

            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .glassControlSurface(cornerRadius: 18)
    }
}

private struct MinerActivityFeedSection: View {
    let miner: MinerManager.ManagedMiner
    let entries: [EventEntry]

    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Live Activity")
                        .font(.title3.weight(.semibold))
                    Text("Recent account-specific events for \(miner.username).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !entries.isEmpty {
                    Button("Clear All") {
                        navigation.clearEvents()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            if entries.isEmpty {
                Text(miner.isRunning ? "Waiting for new activity…" : "Start this miner to populate the live feed.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(16)
                    .glassControlSurface(cornerRadius: 18)
            } else {
                MinerLogConsole(entries: entries)
                    .frame(minHeight: 260)
            }
        }
        .padding(22)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.thinMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 18, y: 8)
    }
}

private struct MinerNextAction {
    let title: String
    let detail: String
    let color: Color
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
