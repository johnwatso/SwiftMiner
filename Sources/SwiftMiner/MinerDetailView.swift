import SwiftUI
import SwiftMinerCore

// MARK: - Miner Detail (Content Panel)

/// Full-panel view for a single managed miner.
/// Shows status, stats, controls, and a live log console.
struct MinerDetailView: View {
    let miner: MinerManager.ManagedMiner

    @Environment(NavigationModel.self) private var navigation
    @State private var activitySummary: MinerManager.MinerActivitySummary?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                MinerStateCard(miner: miner, onAction: {
                    if case .blocked(let reasons) = miner.primaryState, reasons.contains(.accountNotLinked) {
                        Task {
                            try? await navigation.minerManager.startMiner(
                                minerId: miner.id,
                                priorityGames: [],
                                excludedGames: [],
                                strategy: .mineAll,
                                avoidDuplicateStreams: Settings.shared.avoidDuplicateStreams,
                                antiStallRecoveryEnabled: Settings.shared.antiStallRecoveryEnabled,
                                prioritiseFollowedStreamers: Settings.shared.prioritiseFollowedStreamers
                            )
                        }
                    }
                }, onDismiss: { gameId in
                    Task {
                        await navigation.minerManager.setAccountLinkWarningIgnored(minerId: miner.id, gameId: gameId, ignored: true)
                        // Persist immediately
                        Settings.shared.setIgnoreAccountLinkWarnings(true, for: miner.accountId, gameId: gameId)
                    }
                })

                secondaryStatsSection
                watchingStreamerSection
                controlsSection
                
                logSection
            }
            .padding(24)
        }
        .task(id: miner.id) {
            await refreshActivitySummary()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
                await refreshActivitySummary()
            }
        }
        .navigationTitle(miner.displayName)
        .toolbar {
            ToolbarItem {
                Button(role: .destructive) {
                    Task { await navigation.minerManager.removeAccount(minerId: miner.id) }
                } label: {
                    Image(systemName: "trash")
                }
                .help("Remove miner")
            }
        }
    }

    private func refreshActivitySummary() async {
        activitySummary = await navigation.minerManager.getMinerActivitySummary(minerId: miner.id)
    }

    // MARK: Stats

    private var secondaryStatsSection: some View {
        HStack(spacing: 12) {
            MinerStatCard(
                label: "Drops Claimed",
                value: "\(miner.dropsClaimed)",
                icon: "gift.fill",
                color: .green
            )
            
            MinerStatCard(
                label: "Campaign",
                value: miner.currentCampaign ?? "None",
                icon: "gamecontroller.fill",
                color: .purple
            )
        }
    }

    // MARK: Watching Streamer

    private var watchingStreamerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Watching Streamer")
                .font(.headline)

            WatchingStreamerCard(
                streamerName: activitySummary?.currentChannelName,
                streamerId: activitySummary?.currentChannelId,
                campaignName: activitySummary?.currentCampaignName ?? miner.currentCampaign,
                status: miner.status,
                isRunning: miner.isRunning
            )
        }
        .padding(20)
        .glassCard()
    }

    // MARK: Controls

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Actions")
                .font(.headline)

            HStack(spacing: 12) {
                Button {
                    Task { try? await navigation.minerManager.claimAllDrops(minerId: miner.id) }
                } label: {
                    Label("Claim Drops", systemImage: "gift")
                }
                .buttonStyle(.bordered)
                .disabled(!miner.isRunning)
            }
            .padding(8)
            .glassControlSurface()
        }
        .padding(20)
        .glassCard()
    }

    // MARK: Log Console

    private var minerEvents: [EventEntry] {
        navigation.events.filter { $0.minerId == miner.id }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Activity Log")
                    .font(.headline)
                Spacer()
                if !minerEvents.isEmpty {
                    Button {
                        navigation.clearEvents()
                    } label: {
                        Text("Clear All")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }

            let events = minerEvents

            if events.isEmpty {
                Text(miner.isRunning ? "Waiting for activity…" : "This miner will resume automatically when campaigns are available.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .glassControlSurface()
            } else {
                MinerLogConsole(entries: events)
                    .frame(minHeight: 160, maxHeight: 320)
            }
        }
        .padding(20)
        .glassCard()
    }

}

private struct MinerStatCard: View {
    let label: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 12) {
            // Icon with tinted glass backing (P1 hierarchy)
            ZStack {
                Circle()
                    .fill(color.opacity(0.12))
                    .frame(width: 40, height: 40)
                
                if #available(macOS 26, *) {
                    Circle()
                        .fill(.clear)
                        .glassEffect(.regular.interactive())
                        .frame(width: 40, height: 40)
                }

                Image(systemName: icon)
                    .font(.headline)
                    .foregroundStyle(color)
            }

            VStack(spacing: 2) {
                Text(value)
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text(label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .padding(.horizontal, 12)
        .glassPanel(cornerRadius: GlassRadius.small)
    }
}

private struct WatchingStreamerCard: View {
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

    private var tint: Color {
        streamerName == nil ? .secondary : .purple
    }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: GlassRadius.small, style: .continuous)
                    .fill(tint.opacity(0.12))
                    .frame(width: 54, height: 54)

                Image(systemName: iconName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(tint)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if let streamerId, !streamerId.isEmpty {
                    Text("Channel ID \(streamerId)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if status == .watching {
                Label("Live", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            }
        }
        .padding(16)
        .glassPanel(cornerRadius: GlassRadius.small)
    }
}

// MARK: - Log Console

struct MinerLogConsole: View {
    let entries: [EventEntry]
    @State private var autoScroll = true
    @State private var scrollTask: Task<Void, Never>?

    private static let maxVisibleEntries = 200

    private var visibleEntries: [EventEntry] {
        entries.count > Self.maxVisibleEntries
            ? Array(entries.suffix(Self.maxVisibleEntries))
            : entries
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("Auto-scroll", isOn: $autoScroll)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Spacer()
                Text("\(entries.count) entries")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(visibleEntries) { entry in
                            MinerEventRow(event: entry, showRaw: false)
                                .id(entry.id)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: entries.count) { _, _ in
                    guard autoScroll, let lastId = visibleEntries.last?.id else { return }
                    scrollTask?.cancel()
                    scrollTask = Task {
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo(lastId, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .glassPanel(cornerRadius: GlassRadius.small)
    }
}

// MARK: - Miner Inspector (third column)

struct MinerInspectorView: View {
    let miner: MinerManager.ManagedMiner
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Miner Details")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    inspectorSection(title: "Miner") {
                        if miner.nickname != nil {
                            LabeledContent("Nickname", value: miner.displayName)
                        }
                        LabeledContent("Username", value: miner.username)
                        LabeledContent("Status", value: miner.statusLabel)
                        LabeledContent("Running", value: miner.isRunning ? "Yes" : "No")
                    }

                    inspectorSection(title: "Activity") {
                        LabeledContent("Campaign", value: miner.currentCampaign ?? "—")
                        LabeledContent("Drops Claimed", value: "\(miner.dropsClaimed)")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .frame(minWidth: 200)
        .background {
            SidebarMaterialBackground()
        }
    }

    private func inspectorSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            content()
                .font(.callout)
        }
        .padding(14)
        .glassControlSurface()
    }
}

// MARK: - System Inspector

struct SystemInspectorView: View {
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("System Status")
                .font(.headline)
                .padding(.horizontal, 20)
                .padding(.top, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    let miners = navigation.minerManager.miners
                    let running = miners.filter(\.isRunning)
                    let totalDrops = miners.reduce(0) { $0 + $1.dropsClaimed }

                    inspectorSection(title: "Overview") {
                        LabeledContent("Total Miners", value: "\(miners.count)")
                        LabeledContent("Active Miners", value: "\(running.count)")
                        LabeledContent("Total Drops", value: "\(totalDrops)")
                    }

                    if !running.isEmpty {
                        inspectorSection(title: "Active") {
                            ForEach(running) { miner in
                                HStack {
                                    StatusDot(isActive: true)
                                    Text(miner.displayName)
                                        .font(.callout)
                                    Spacer()
                                    Text(miner.currentCampaign ?? "—")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
        .frame(minWidth: 200)
        .background {
            SidebarMaterialBackground()
        }
    }

    private func inspectorSection<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            content()
                .font(.callout)
        }
        .padding(14)
        .glassControlSurface()
    }
}

/// Tiny status dot used in sidebars and inspectors
struct StatusDot: View {
    let isActive: Bool

    var body: some View {
        Circle()
            .fill(isActive ? Color.green : Color.gray)
            .frame(width: 7, height: 7)
    }
}

// MARK: - Preview

#Preview("Miner Detail") {
    MinerDetailView(miner: MinerManager.ManagedMiner(
        id: "preview",
        accountId: "acc1",
        username: "JohnStreamer",
        status: .watching,
        currentCampaign: "Rust Drops Season 3",
        dropsClaimed: 12,
        isRunning: true
    ))
    .environment(NavigationModel(clientId: "preview"))
    .frame(width: 600, height: 700)
}

#Preview("Miner Inspector") {
    MinerDetailView(miner: MinerManager.ManagedMiner(
        id: "preview",
        accountId: "acc1",
        username: "JohnStreamer",
        status: .watching,
        currentCampaign: "Rust Drops",
        dropsClaimed: 5,
        isRunning: true
    ))
    .environment(NavigationModel(clientId: "preview"))
    .frame(width: 240, height: 400)
}
