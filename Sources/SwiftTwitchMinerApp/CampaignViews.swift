import SwiftUI
import SwiftTwitchMiner

// MARK: - Sidebar

/// Sidebar list of all active campaigns.
struct CampaignSidebarView: View {
    @Environment(AppModel.self) private var appModel
    @Binding var selectedId: String?

    private var campaigns: [Campaign] { appModel.campaigns }

    var body: some View {
        List(campaigns, selection: $selectedId) { campaign in
            CampaignRowView(campaign: campaign)
                .tag(campaign.id)
        }
        .scrollContentBackground(.hidden)
        .navigationTitle("Campaigns")
        .overlay {
            if campaigns.isEmpty {
                MaterialEmptyStatePanel(
                    "No Active Campaigns",
                    systemImage: "calendar.badge.exclamationmark",
                    description: "Start the miner to fetch campaigns."
                )
            }
        }
    }
}

/// One row in the campaign sidebar.
struct CampaignRowView: View {
    let campaign: Campaign

    private var claimedCount: Int { campaign.drops.filter(\.isClaimed).count }
    private var totalCount: Int   { campaign.drops.count }

    var body: some View {
        HStack(spacing: 10) {
            // Game box art
            if let url = campaign.game.boxArtURL {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(.tertiary)
                }
                .frame(width: 36, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.tertiary)
                    .frame(width: 36, height: 48)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(campaign.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)

                Text(campaign.game.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text("\(claimedCount)/\(totalCount) drops")
                    .font(.caption2)
                    .foregroundStyle(claimedCount == totalCount ? .green : .secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Campaign Detail

/// Detail panel showing the drops for a selected campaign.
struct CampaignDetailView: View {
    let campaign: Campaign

    var body: some View {
        List {
            Section {
                ForEach(campaign.drops) { drop in
                    DropRowView(drop: drop)
                }
            } header: {
                HStack {
                    Text(campaign.name)
                        .font(.headline)
                    Spacer()
                    CampaignStatusBadge(status: campaign.status)
                }
                .padding(.bottom, 4)
            } footer: {
                Text("Ends \(campaign.endDate.formatted(date: .abbreviated, time: .shortened))")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .navigationTitle(campaign.game.name)
    }
}

/// One row for a single drop.
struct DropRowView: View {
    let drop: Drop

    private var progress: Double {
        guard let p = drop.progress else { return 0 }
        return p.percentComplete / 100.0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                // Drop image
                if let url = drop.imageURL {
                    AsyncImage(url: url) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Circle().fill(.tertiary)
                    }
                    .frame(width: 32, height: 32)
                    .clipShape(Circle())
                } else {
                    Image(systemName: "gift.fill")
                        .frame(width: 32, height: 32)
                        .foregroundStyle(.purple)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(drop.name)
                        .font(.callout.weight(.medium))

                    if let p = drop.progress {
                        Text("\(p.currentMinutes)/\(p.requiredMinutes) min")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("\(drop.requiredMinutes) min required")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                DropStatusBadge(drop: drop)
            }

            // Progress bar
            if !drop.isClaimed {
                ProgressView(value: progress)
                    .tint(drop.isClaimable ? .green : .purple)
            }
        }
        .padding(.vertical, 4)
        .opacity(drop.isClaimed ? 0.5 : 1.0)
    }
}

// MARK: - Badges

struct CampaignStatusBadge: View {
    let status: CampaignStatus

    var body: some View {
        Text(status.rawValue)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case .active:   return .green
        case .upcoming: return .orange
        case .expired:  return .gray
        case .disabled: return .red
        }
    }
}

struct DropStatusBadge: View {
    let drop: Drop

    var body: some View {
        if drop.isClaimed {
            Label("Claimed", systemImage: "checkmark.seal.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.green)
        } else if drop.isClaimable {
            Label("Complete", systemImage: "gift.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        } else {
            EmptyView()
        }
    }
}

// MARK: - Status indicator (toolbar)

/// Shows the current session status in the toolbar.
struct StatusIndicatorView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .shadow(color: statusColor.opacity(0.6), radius: 3)

            Text(appModel.sessionStatus.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                .font(.callout.weight(.medium))
                .foregroundStyle(.primary)

            if let progress = appModel.overallProgress {
                Text("·")
                    .foregroundStyle(.secondary)
                Text("\(progress.claimedDrops)/\(progress.totalDrops) drops")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusColor: Color {
        switch appModel.sessionStatus {
        case .watching:          return .green
        case .authenticating:    return .orange
        case .fetchingCampaigns: return .blue
        case .claiming:          return .yellow
        case .error:             return .red
        case .stopped, .idle:    return .gray
        case .paused:            return .orange
        }
    }
}

// MARK: - Log console

/// Scrolling log console for the detail column.
struct LogConsoleView: View {
    @Environment(AppModel.self) private var appModel
    @State private var isAutoScrolling = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Log")
                    .font(.headline)
                Spacer()
                Toggle("Auto-scroll", isOn: $isAutoScrolling)
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(appModel.logMessages) { entry in
                            LogEntryView(entry: entry)
                                .id(entry.id)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: appModel.logMessages.count) { _, _ in
                    if isAutoScrolling, let last = appModel.logMessages.last {
                        withAnimation(.easeOut(duration: 0.1)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .glassPanel(cornerRadius: 20)
        .navigationTitle("Log")
    }
}

struct LogEntryView: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(entry.timestamp.formatted(.dateTime.hour().minute().second()))
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 72, alignment: .leading)

            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(textColor)
                .textSelection(.enabled)
        }
    }

    private var textColor: Color {
        switch entry.level {
        case .error:   return .red
        case .warning: return .orange
        case .info:    return .primary
        case .debug:   return .secondary
        }
    }
}
