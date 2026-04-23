import SwiftUI
import SwiftMinerCore

/// Unified Events view with segmented filter.
/// All | Active | Blocked | Expired | Logs
struct EventLogView: View {
    @Environment(NavigationModel.self) private var navigation
    @State private var selectedSegment: EventSegment = .all
    @Namespace private var segmentAnimation

    // MARK: - Derived feed

    private var miners: [MinerManager.ManagedMiner] { navigation.minerManager.miners }

    private var allCampaigns: [Campaign] {
        var seen = Set<String>()
        return miners.flatMap { $0.allCampaigns }.filter { seen.insert($0.id).inserted }
    }

    private var activeCampaigns: [Campaign] {
        allCampaigns.filter { $0.isTimeActive && $0.isAccountConnected && !$0.isFullyComplete }
    }

    private var blockedCampaigns: [Campaign] {
        allCampaigns.filter { $0.isTimeActive && !$0.isAccountConnected && !$0.isFullyComplete }
    }

    private var expiredCampaigns: [Campaign] {
        allCampaigns.filter { !$0.isTimeActive || $0.status == .expired || $0.isFullyComplete }
    }

    private var visibleCampaigns: [Campaign] {
        switch selectedSegment {
        case .all:      return activeCampaigns + blockedCampaigns + expiredCampaigns
        case .active:   return activeCampaigns
        case .blocked:  return blockedCampaigns
        case .expired:  return expiredCampaigns
        case .logs:     return []
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            segmentedControl
                .padding(.horizontal, 24)
                .padding(.top, 16)
                .padding(.bottom, 12)

            ScrollView {
                LazyVStack(spacing: 8) {
                    if selectedSegment == .all {
                        SystemStatusRow(miners: miners)
                            .transition(.opacity)
                    }

                    if selectedSegment == .logs {
                        logsFeed
                    } else {
                        campaignFeed
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
                .animation(.easeInOut(duration: 0.2), value: selectedSegment)
            }
        }
        .navigationTitle("Events")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    navigation.clearEvents()
                } label: {
                    Image(systemName: "trash")
                }
                .help("Clear logs")
                .disabled(navigation.events.isEmpty)
            }
        }
    }

    // MARK: - Segmented Control

    private var segmentedControl: some View {
        HStack(spacing: 4) {
            ForEach(EventSegment.allCases) { segment in
                segmentButton(segment)
            }
        }
        .padding(4)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func segmentButton(_ segment: EventSegment) -> some View {
        let isSelected = selectedSegment == segment
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                selectedSegment = segment
            }
        } label: {
            Text(segment.label)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 9)
                            .fill(Color.primary.opacity(0.08))
                            .matchedGeometryEffect(id: "segment", in: segmentAnimation)
                    }
                }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Feeds

    @ViewBuilder
    private var campaignFeed: some View {
        if visibleCampaigns.isEmpty {
            emptyState
        } else {
            ForEach(visibleCampaigns) { campaign in
                CampaignFeedRow(campaign: campaign)
            }
        }
    }

    @ViewBuilder
    private var logsFeed: some View {
        if navigation.events.isEmpty {
            emptyState
        } else {
            ForEach(navigation.events) { event in
                LogFeedRow(event: event)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 32))
                .foregroundStyle(.secondary.opacity(0.4))
            Text("No \(selectedSegment.emptyLabel)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 56)
    }
}

// MARK: - Segment

enum EventSegment: String, CaseIterable, Identifiable {
    case all, active, blocked, expired, logs
    var id: String { rawValue }

    var label: String {
        switch self {
        case .all:     return "All"
        case .active:  return "Active"
        case .blocked: return "Blocked"
        case .expired: return "Expired"
        case .logs:    return "Logs"
        }
    }

    var emptyLabel: String {
        switch self {
        case .all:     return "activity"
        case .active:  return "active campaigns"
        case .blocked: return "blocked campaigns"
        case .expired: return "expired campaigns"
        case .logs:    return "log entries"
        }
    }
}

// MARK: - System Status Row

private struct SystemStatusRow: View {
    let miners: [MinerManager.ManagedMiner]

    private var state: (title: String, subtitle: String, icon: String, color: Color) {
        if miners.isEmpty {
            return ("Idle", "No accounts connected", "pause.circle.fill", .secondary)
        }
        let running = miners.filter { $0.isRunning }
        if running.isEmpty {
            return ("Idle", "No miners running", "pause.circle.fill", .secondary)
        }
        for miner in running {
            if case .mining(let p) = miner.primaryState {
                return ("Mining", "Watching \(p.gameName)", "play.circle.fill", .green)
            }
        }
        for miner in running {
            if case .blocked(let reasons) = miner.primaryState {
                let reason: String = reasons.first.map { r in
                    switch r {
                    case .accountNotLinked:   return "Account not linked"
                    case .noEligibleCampaign: return "No eligible campaigns"
                    case .noLiveStreams:       return "No live stream"
                    }
                } ?? "Blocked"
                return ("Blocked", reason, "exclamationmark.triangle.fill", .orange)
            }
        }
        if running.allSatisfy({ $0.primaryState == .completed }) {
            return ("All done", "Every eligible drop has been earned", "checkmark.circle.fill", .blue)
        }
        return ("Idle", "\(running.count) miner\(running.count == 1 ? "" : "s") running", "pause.circle.fill", .secondary)
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: state.icon)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(state.color)
                .frame(width: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(state.title)
                    .font(.headline)
                Text(state.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .glassCard()
    }
}

// MARK: - Campaign Feed Row

private struct CampaignFeedRow: View {
    let campaign: Campaign

    private var stateLabel: String {
        if campaign.isFullyComplete { return "Completed" }
        if !campaign.isTimeActive || campaign.status == .expired { return "Expired" }
        if !campaign.isAccountConnected { return "Not linked" }
        return "Active"
    }

    private var stateColor: Color {
        if campaign.isFullyComplete { return .blue }
        if !campaign.isTimeActive || campaign.status == .expired { return .secondary }
        if !campaign.isAccountConnected { return .orange }
        return .green
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(stateColor)
                .frame(width: 8, height: 8)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(campaign.game.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(campaign.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(stateLabel)
                .font(.caption.weight(.medium))
                .foregroundStyle(stateColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(stateColor.opacity(0.12), in: Capsule())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Log Feed Row

private let relativeDateFormatter: RelativeDateTimeFormatter = {
    let f = RelativeDateTimeFormatter()
    f.unitsStyle = .abbreviated
    return f
}()

private struct LogFeedRow: View {
    let event: EventEntry
    @Environment(NavigationModel.self) private var navigation

    private var levelColor: Color {
        switch event.level {
        case .info:    return .blue
        case .warning: return .orange
        case .error:   return .red
        }
    }

    private var cleanedMessage: String {
        let cleaned = event.message
            .replacingOccurrences(of: #"\[[^\]]+\]\s*"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? event.message : cleaned
    }

    private var relativeTime: String {
        relativeDateFormatter.localizedString(for: event.timestamp, relativeTo: Date())
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(levelColor)
                .frame(width: 6, height: 6)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                Text(cleanedMessage)
                    .font(.subheadline)
                    .lineLimit(2)

                HStack(spacing: 5) {
                    Text(relativeTime)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)

                    if let minerId = event.minerId,
                       let miner = navigation.minerManager.miners.first(where: { $0.id == minerId }) {
                        Text("·").foregroundStyle(.quaternary)
                        Text(miner.username)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Legacy row (used by MinerDetailView)

struct MinerEventRow: View {
    let event: EventEntry
    let showRaw: Bool
    @Environment(NavigationModel.self) private var navigation

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                severityIcon

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(event.timestamp.formatted(.dateTime.hour().minute().second()))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)

                        if let minerId = event.minerId {
                            Text("•").foregroundStyle(.tertiary)
                            Text(minerName(for: minerId))
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(showRaw ? (event.rawMessage ?? event.message) : event.message)
                        .font(.body)
                        .foregroundStyle(.primary)

                    if showRaw, let raw = event.rawMessage {
                        Text(raw)
                            .font(.caption.monospaced())
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 4))
                            .padding(.top, 4)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassCard()
        .padding(.vertical, 4)
    }

    private func minerName(for minerId: String) -> String {
        navigation.minerManager.miners.first(where: { $0.id == minerId }).map(\.username)
            ?? "Miner \(minerId.prefix(4))"
    }

    @ViewBuilder
    private var severityIcon: some View {
        let color: Color = {
            switch event.level {
            case .info:    return .blue
            case .warning: return .orange
            case .error:   return .red
            }
        }()
        let icon: String = {
            switch event.level {
            case .info:    return "info.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .error:   return "xmark.circle.fill"
            }
        }()
        Image(systemName: icon)
            .foregroundStyle(color)
            .font(.system(size: 16))
            .frame(width: 24, height: 24)
    }
}

#Preview {
    EventLogView()
        .environment(NavigationModel(clientId: "preview"))
}
