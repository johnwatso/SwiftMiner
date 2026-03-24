import SwiftUI
import SwiftTwitchMiner

// MARK: - Account Detail (Content Panel)

/// Full-panel view for a single managed miner.
/// Shows status, stats, controls, and a live log console.
struct AccountDetailView: View {
    let miner: MinerManager.ManagedMiner

    @Environment(NavigationModel.self) private var navigation
    @State private var isStarting = false
    @State private var isStopping = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                headerSection
                statsSection
                controlsSection
                logSection
            }
            .padding(24)
        }
        .navigationTitle(miner.username)
        .toolbar {
            ToolbarItem {
                Button(role: .destructive) {
                    Task { await navigation.minerManager.removeAccount(minerId: miner.id) }
                } label: {
                    Image(systemName: "trash")
                }
                .help("Remove account")
            }
        }
    }

    // MARK: Header

    private var headerSection: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .frame(width: 56, height: 56)
                Text(miner.username.prefix(1).uppercased())
                    .font(.title2.weight(.bold))
                    .foregroundStyle(avatarColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(miner.username)
                    .font(.title2.weight(.semibold))

                StatusBadge(status: miner.status)
            }

            Spacer()

            primaryButton
        }
        .padding(20)
        .glassContentSurface()
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
                Label(isStopping ? "Stopping…" : "Stop Mining", systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
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
                        enableBadgesEmotes: settings.enableBadgesEmotes,
                        showClaimNotifications: settings.showClaimNotifications
                    )
                    isStarting = false
                }
            } label: {
                Label(isStarting ? "Starting…" : "Start Mining", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(isStarting)
        }
    }

    // MARK: Stats

    private var statsSection: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible()),
            GridItem(.flexible())
        ], spacing: 12) {
            MinerStatCard(
                label: "Drops Claimed",
                value: "\(miner.dropsClaimed)",
                icon: "gift.fill",
                color: .green
            )
            MinerStatCard(
                label: "Status",
                value: miner.status.displayName,
                icon: statusIcon,
                color: statusColor
            )
            MinerStatCard(
                label: "Campaign",
                value: miner.currentCampaign ?? "None",
                icon: "gamecontroller.fill",
                color: .purple
            )
        }
        .padding(18)
        .glassContentSurface()
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
        .glassContentSurface()
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
                Text(miner.isRunning ? "Waiting for activity…" : "Start mining to see activity here.")
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
        .glassContentSurface()
    }

    // MARK: Helpers

    private var avatarColor: Color {
        let colors: [Color] = [.purple, .blue, .teal, .green, .orange, .pink, .indigo]
        return colors[abs(miner.username.hashValue) % colors.count]
    }

    private var statusIcon: String {
        switch miner.status {
        case .watching:          return "eye.fill"
        case .authenticating:    return "key.fill"
        case .fetchingCampaigns: return "arrow.down.circle.fill"
        case .claiming:          return "gift.fill"
        case .waitingForStream:  return "clock.fill"
        case .paused:            return "pause.fill"
        case .error:             return "exclamationmark.triangle.fill"
        case .idle:              return "moon.fill"
        }
    }

    private var statusColor: Color {
        switch miner.status {
        case .watching:          return .green
        case .authenticating:    return .orange
        case .fetchingCampaigns: return .blue
        case .claiming:          return .purple
        case .waitingForStream:  return .cyan
        case .paused:            return .orange
        case .error:             return .secondary
        case .idle:              return .gray
        }
    }
}

// MARK: - Stat Card

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
                            EventRow(event: entry, showRaw: false)
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

// MARK: - Account Inspector (third column)

struct AccountInspectorView: View {
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
                    inspectorSection(title: "Account") {
                        LabeledContent("Username", value: miner.username)
                        LabeledContent("Status", value: miner.status.displayName)
                        LabeledContent("Running", value: miner.isRunning ? "Yes" : "No")
                    }

                    inspectorSection(title: "Activity") {
                        LabeledContent("Campaign", value: miner.currentCampaign ?? "—")
                        LabeledContent("Drops Claimed", value: "\(miner.dropsClaimed)")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Controls")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)

                        if miner.isRunning {
                            Button(role: .destructive) {
                                Task { await navigation.minerManager.stopMiner(minerId: miner.id) }
                            } label: {
                                Label("Stop", systemImage: "stop.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        } else {
                            Button {
                                Task {
                                    let settings = Settings.shared
                                    try? await navigation.minerManager.startMiner(
                                        minerId: miner.id,
                                        priorityGames: settings.priorityGames,
                                        excludedGames: settings.excludedGames,
                                        strategy: settings.miningStrategy,
                                        enableBadgesEmotes: settings.enableBadgesEmotes,
                                        showClaimNotifications: settings.showClaimNotifications
                                    )
                                }
                            } label: {
                                Label("Start", systemImage: "play.fill")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }
                    .padding(14)
                    .glassControlSurface()
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
                        LabeledContent("Total Accounts", value: "\(miners.count)")
                        LabeledContent("Active Miners", value: "\(running.count)")
                        LabeledContent("Total Drops", value: "\(totalDrops)")
                    }

                    if !running.isEmpty {
                        inspectorSection(title: "Active") {
                            ForEach(running) { miner in
                                HStack {
                                    StatusDot(isActive: true)
                                    Text(miner.username)
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

#Preview("Account Detail") {
    AccountDetailView(miner: MinerManager.ManagedMiner(
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

#Preview("Account Inspector") {
    AccountInspectorView(miner: MinerManager.ManagedMiner(
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
