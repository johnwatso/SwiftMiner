// Rows, sheets, banners, and chips supporting MinersOverviewView.
import SwiftUI
import SwiftMinerCore

struct MinerDiagnosticEvent: Identifiable {
    let id: String
    let title: String
    let detail: String
    let date: Date
    let category: String
    let symbol: String
    let tint: Color

    init(event: MinerManager.MinerEvent) {
        id = "structured:\(event.timestamp.timeIntervalSinceReferenceDate):\(event.type.rawValue):\(event.summary)"
        title = event.summary
        date = event.timestamp

        switch event.type {
        case .channelSwitched:
            detail = "Mining"
            category = "Mining"
            symbol = "arrow.left.arrow.right.circle.fill"
            tint = .blue
        case .campaignSelected:
            detail = "Campaign selected"
            category = "Mining"
            symbol = "flag.checkered"
            tint = .indigo
        case .stallDetected:
            detail = "Stall recovery"
            category = "Stall recovery"
            symbol = "exclamationmark.arrow.trianglehead.counterclockwise.rotate.90"
            tint = .yellow
        case .inventoryRefreshed:
            detail = "Campaign scan"
            category = "Scan"
            symbol = "arrow.clockwise.circle"
            tint = .teal
        case .dropClaimed:
            detail = "Drop claimed"
            category = "Drops"
            symbol = "gift.fill"
            tint = .green
        case .error:
            detail = "Error"
            category = "Errors"
            symbol = "xmark.octagon"
            tint = .red
        case .recoveryComplete:
            detail = "Recovery complete"
            category = "Stall recovery"
            symbol = "checkmark.circle.fill"
            tint = .green
        }
    }

    init(event: EventEntry) {
        let presentation = ActivityEventPresentation(event: event)

        id = "log:\(event.id.uuidString)"
        title = presentation.title
        detail = presentation.detail ?? presentation.category
        date = event.timestamp
        category = presentation.category
        symbol = presentation.symbol
        tint = presentation.color
    }
}

struct MinerRecoveryDiagnosticsPresentation {
    enum Tone: Equatable {
        case healthy
        case active
        case warning
        case critical
        case inactive

        var tint: Color {
            switch self {
            case .healthy: return .green
            case .active: return .blue
            case .warning: return .orange
            case .critical: return .red
            case .inactive: return .secondary
            }
        }
    }

    struct Signal: Identifiable {
        let id: String
        let title: String
        let value: String
        let symbol: String
        let date: Date?
        let dateLabel: String
        let missingDateLabel: String
        let tone: Tone
    }

    let title: String
    let detail: String
    let badge: String
    let symbol: String
    let tone: Tone
    let signals: [Signal]
    let isCompact: Bool

    @MainActor
    static func make(
        miner: MinerManager.ManagedMiner,
        snapshot: MinerHealthSnapshot
    ) -> MinerRecoveryDiagnosticsPresentation {
        let status: (String, String, String, String, Tone)
        switch snapshot.health {
        case .mining:
            status = (
                "Healthy",
                "Twitch, campaign inventory, and progress checks are reporting normally.",
                "Healthy",
                "checkmark.circle.fill",
                .healthy
            )
        case .recovering:
            status = (
                "Automatic recovery in progress",
                "SwiftMiner is checking the session and will resume mining when it is ready.",
                "Recovering",
                "arrow.triangle.2.circlepath",
                .active
            )
        case .needsAuth:
            status = (
                "Reconnect Twitch",
                "This miner cannot recover until its Twitch sign-in is renewed.",
                "Action needed",
                "person.badge.key.fill",
                .critical
            )
        case .stalled:
            status = (
                "Recovery needed",
                "The miner stopped responding and needs attention before it can continue.",
                "Stalled",
                "exclamationmark.triangle.fill",
                .critical
            )
        case .blocked:
            status = (
                "Action needed",
                "A blocking issue is preventing this miner from continuing.",
                "Blocked",
                "exclamationmark.octagon.fill",
                .critical
            )
        case .attention:
            status = (
                "Keep an eye on this miner",
                "One or more live signals are outside their normal range.",
                "Attention",
                "exclamationmark.triangle.fill",
                .warning
            )
        case .idle where !miner.isRunning:
            status = (
                "Miner is stopped",
                "Live checks and automatic recovery will resume when the miner starts.",
                "Stopped",
                "pause.circle.fill",
                .inactive
            )
        case .idle:
            status = (
                "Healthy",
                "The miner is connected and waiting for eligible work.",
                "Healthy",
                "checkmark.circle.fill",
                .healthy
            )
        }

        let twitchTone: Tone = !miner.isRunning ? .inactive : (miner.needsAuth ? .critical : .healthy)
        let inventoryTone: Tone = !miner.isRunning
            ? .inactive
            : (snapshot.lastCampaignRefreshAt == nil ? .warning : .healthy)
        let progressTone: Tone = !miner.isRunning
            ? .inactive
            : (miner.isNotEarning() ? .warning : .healthy)

        let signals = [
            Signal(
                id: "twitch",
                title: "Twitch",
                value: !miner.isRunning ? "Inactive" : (miner.needsAuth ? "Reconnect" : "Connected"),
                symbol: "network",
                date: snapshot.lastEventAt,
                dateLabel: "Last activity",
                missingDateLabel: "No activity yet",
                tone: twitchTone
            ),
            Signal(
                id: "inventory",
                title: "Campaigns",
                value: !miner.isRunning ? "Inactive" : (snapshot.lastCampaignRefreshAt == nil ? "Waiting" : "Current"),
                symbol: "shippingbox.fill",
                date: snapshot.lastCampaignRefreshAt,
                dateLabel: "Updated",
                missingDateLabel: "Not updated yet",
                tone: inventoryTone
            ),
            Signal(
                id: "progress",
                title: "Drop progress",
                value: !miner.isRunning ? "Inactive" : (miner.isNotEarning() ? "No progress" : "Tracking"),
                symbol: "chart.line.uptrend.xyaxis",
                date: snapshot.lastDropProgressAt ?? snapshot.lastSuccessfulPollAt,
                dateLabel: "Last checked",
                missingDateLabel: "Not checked yet",
                tone: progressTone
            ),
        ]

        return MinerRecoveryDiagnosticsPresentation(
            title: status.0,
            detail: status.1,
            badge: status.2,
            symbol: status.3,
            tone: status.4,
            signals: signals,
            isCompact: status.4 == .healthy && signals.allSatisfy { $0.tone == .healthy }
        )
    }
}

/// The normal operating state is intentionally terse. It keeps the same live
/// readings and expandable activity history without presenting them as a
/// troubleshooting surface.
struct CompactMinerStatusView: View {
    let presentation: MinerRecoveryDiagnosticsPresentation
    let events: [MinerDiagnosticEvent]
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(presentation.badge, systemImage: presentation.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(presentation.tone.tint)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 9)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(presentation.signals.enumerated()), id: \.element.id) { index, signal in
                        compactSignal(signal)

                        if index < presentation.signals.count - 1 {
                            Divider()
                                .frame(height: 34)
                                .padding(.vertical, 8)
                        }
                    }

                    Divider()
                        .frame(height: 34)
                        .padding(.vertical, 8)

                    recentActivityButton
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(spacing: 0) {
                    ForEach(Array(presentation.signals.enumerated()), id: \.element.id) { index, signal in
                        compactSignal(signal)

                        if index < presentation.signals.count - 1 {
                            Divider().padding(.horizontal, 14)
                        }
                    }

                    Divider().padding(.horizontal, 14)
                    recentActivityButton
                }
            }

            if isExpanded {
                Divider().padding(.horizontal, 14)
                RecoveryDiagnosticsEventList(events: events)
            }
        }
    }

    private func compactSignal(_ signal: MinerRecoveryDiagnosticsPresentation.Signal) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: signal.symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(signal.tone.tint)
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(signal.title)
                        .foregroundStyle(.secondary)
                    Text(signal.value)
                        .fontWeight(.semibold)
                        .foregroundStyle(signal.tone.tint)
                }
                .font(.caption)
                .lineLimit(1)

                signalDate(signal)
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func signalDate(_ signal: MinerRecoveryDiagnosticsPresentation.Signal) -> some View {
        if let date = signal.date {
            HStack(spacing: 3) {
                Text(signal.dateLabel)
                Text(date, style: .relative)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        } else {
            Text(signal.missingDateLabel)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
    }

    private var recentActivityButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Recent activity")
                    .font(.caption)
                Text(events.count.formatted())
                    .font(.caption.weight(.semibold).monospacedDigit())
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .foregroundStyle(.primary)
            .contentShape(Rectangle())
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isExpanded ? "Hide recent activity" : "Show recent activity")
    }
}

struct RecoveryDiagnosticsStatusHeader: View {
    let presentation: MinerRecoveryDiagnosticsPresentation

    var body: some View {
        HStack(alignment: .center, spacing: 13) {
            Image(systemName: presentation.symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(presentation.tone.tint)
                .frame(width: 34, height: 34)
                .background(
                    presentation.tone.tint.opacity(0.12),
                    in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(presentation.title)
                    .font(.subheadline.weight(.semibold))

                Text(presentation.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            Text(presentation.badge)
                .font(.caption.weight(.semibold))
                .foregroundStyle(presentation.tone.tint)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(
                    presentation.tone.tint.opacity(0.10),
                    in: Capsule()
                )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .accessibilityElement(children: .combine)
    }
}

struct RecoveryDiagnosticsSignalStrip: View {
    let signals: [MinerRecoveryDiagnosticsPresentation.Signal]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(signals.enumerated()), id: \.element.id) { index, signal in
                signalView(signal)

                if index < signals.count - 1 {
                    Divider()
                        .frame(height: 44)
                        .padding(.vertical, 11)
                }
            }
        }
        .padding(.horizontal, 2)
    }

    private func signalView(_ signal: MinerRecoveryDiagnosticsPresentation.Signal) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: signal.symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(signal.tone.tint)
                .frame(width: 17, height: 17)

            VStack(alignment: .leading, spacing: 2) {
                Text(signal.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(signal.value)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(signal.tone.tint)
                    .lineLimit(1)

                if let date = signal.date {
                    HStack(spacing: 3) {
                        Text(signal.dateLabel)
                        Text(date, style: .relative)
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                } else {
                    Text(signal.missingDateLabel)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }
}

struct RecoveryDiagnosticsHistory: View {
    let events: [MinerDiagnosticEvent]
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 17)

                    Text("Recent activity")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)

                    Text(events.isEmpty ? "None recorded" : "\(events.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Hide recent activity" : "Show recent activity")

            if isExpanded {
                Divider()
                    .padding(.horizontal, 14)
                RecoveryDiagnosticsEventList(events: events)
            }
        }
    }
}

struct RecoveryDiagnosticsEventList: View {
    let events: [MinerDiagnosticEvent]

    var body: some View {
        if events.isEmpty {
            ContentUnavailableView(
                "No recent events",
                systemImage: "clock.badge.checkmark",
                description: Text("Miner activity will appear here when there is something to review.")
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                    MinerDiagnosticTimelineRow(event: event)

                    if index < events.count - 1 {
                        Divider()
                            .padding(.leading, 48)
                            .padding(.trailing, 14)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }
}

struct MinerDiagnosticTimelineRow: View {
    let event: MinerDiagnosticEvent

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: event.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(event.tint)
                .symbolRenderingMode(.hierarchical)
                .frame(width: 24, height: 24)
                .help(event.category)

            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(2)

                Text(event.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Text(event.date.formatted(date: .omitted, time: .standard))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }
}

struct PrioritisedLinkIssue: Identifiable, Equatable {
    let minerId: String
    let accountId: String
    let minerName: String
    let gameId: String
    let gameName: String
    let campaignNames: [String]
    let isIgnored: Bool

    var id: String {
        "\(minerId):\(gameId)"
    }
}

struct PendingItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case accountLink(PrioritisedLinkIssue)
        case subscriptionRequired(
            minerId: String,
            accountId: String,
            campaignId: String,
            gameName: String,
            campaignName: String,
            dropNames: [String]
        )
    }

    enum Severity {
        case link
        case subscription

        var rank: Int {
            switch self {
            case .link: return 0
            case .subscription: return 1
            }
        }
    }

    let kind: Kind
    let isMuted: Bool

    var id: String {
        switch kind {
        case .accountLink(let issue):
            return "link:\(issue.id)"
        case .subscriptionRequired(let minerId, _, let campaignId, _, _, _):
            return "sub:\(minerId):\(campaignId)"
        }
    }

    var severity: Severity {
        switch kind {
        case .accountLink: return .link
        case .subscriptionRequired: return .subscription
        }
    }

    var title: String {
        switch kind {
        case .accountLink(let issue): return "Link \(issue.gameName) to Twitch"
        case .subscriptionRequired(_, _, _, let gameName, _, _): return gameName
        }
    }

    var subtitle: String {
        switch kind {
        case .accountLink(let issue):
            let names = issue.campaignNames.prefix(2).joined(separator: ", ")
            let campaignDescription = issue.campaignNames.count > 2
                ? "\(names), and more"
                : names
            if isMuted {
                return "Reminder muted. Open Twitch Drops whenever you’re ready to link the game account."
            }
            return "To earn \(campaignDescription), open Twitch Drops and link your game account."
        case .subscriptionRequired(_, _, _, _, let campaignName, let dropNames):
            if isMuted { return "\(campaignName) is muted." }
            let names = dropNames.prefix(2).joined(separator: ", ")
            let extra = dropNames.count > 2 ? ", and more" : ""
            if names.isEmpty {
                return "\(campaignName) needs a paid Twitch sub."
            }
            return "\(names)\(extra) needs a paid Twitch sub."
        }
    }

    var iconSystemName: String {
        if isMuted { return "bell.slash" }
        switch kind {
        case .accountLink: return "personalhotspot.slash"
        case .subscriptionRequired: return "creditcard"
        }
    }

    var iconColor: Color {
        if isMuted { return .secondary }
        switch kind {
        case .accountLink: return .orange
        case .subscriptionRequired: return .pink
        }
    }

    var actionTitle: String { isMuted ? "Remind me" : "Dismiss" }
    var actionSystemImage: String { isMuted ? "bell" : "bell.slash" }

    var resolutionTitle: String? {
        guard case .accountLink = kind else { return nil }
        return "Open Twitch Drops"
    }

    var resolutionSystemImage: String? {
        guard resolutionTitle != nil else { return nil }
        return "arrow.up.right.square"
    }
}

struct PendingItemRow: View {
    let item: PendingItem
    let onResolve: (() -> Void)?
    let onAction: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: item.iconSystemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(item.iconColor)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
                if let resolutionTitle = item.resolutionTitle,
                   let resolutionSystemImage = item.resolutionSystemImage,
                   let onResolve {
                    Button(action: onResolve) {
                        Label(resolutionTitle, systemImage: resolutionSystemImage)
                            .labelStyle(.titleAndIcon)
                    }
                    .tahoeButtonStyle()
                    .controlSize(.small)
                }

                Button(action: onAction) {
                    Label(item.actionTitle, systemImage: item.actionSystemImage)
                        .labelStyle(.titleAndIcon)
                }
                .tahoeButtonStyle()
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.background.opacity(0.001))
    }
}

struct LinkNotice: Identifiable, Equatable {
    let id: UUID
    let title: String
    let message: String
}

struct MinerNicknameEditorPresentation: Identifiable {
    let miner: MinerManager.ManagedMiner

    var id: String {
        miner.id
    }
}

struct MinerStreamOverridePresentation: Identifiable {
    let miner: MinerManager.ManagedMiner

    var id: String {
        miner.id
    }
}

struct MinerSourceListRow: View {
    let miner: MinerManager.ManagedMiner
    let avatarURL: URL?
    let compact: Bool
    let isSelected: Bool
    let onEditNickname: () -> Void
    let onClearNickname: () -> Void
    let onOverrideStream: () -> Void
    let onClearStreamOverride: () -> Void
    private var settings: Settings { .shared }

    /// Resolved once per render and threaded through the helpers below. As a
    /// computed property this ran `resolve` seven times per row per render —
    /// once for every property that touched it.
    private var resolvedSnapshot: MinerActivitySnapshot {
        MinerActivitySnapshot.resolve(
            for: miner,
            priorityGames: displayedPriorityGames,
            excludedGames: settings.excludedGames,
            strategy: settings.miningStrategy,
            includesBadgeAndEmoteCampaigns: settings.enableBadgesEmotes
        )
    }

    private var displayedPriorityGames: [String] {
        settings.priorityGames(forAccountId: miner.accountId)
    }

    private var hasBlockingIssues: Bool {
        miner.status == .blockedAccountNotLinked || miner.status == .error || miner.needsAuth
    }

    private func statusSymbol(for snapshot: MinerActivitySnapshot) -> String {
        if snapshot.statusText == "Waiting" {
            return "clock"
        }
        if hasBlockingIssues {
            return "exclamationmark.triangle.fill"
        }
        return snapshot.statusSymbol
    }

    var body: some View {
        let snapshot = resolvedSnapshot

        return HStack(spacing: 9) {
            CachedAvatarImage(url: avatarURL) {
                Image(systemName: statusSymbol(for: snapshot))
                    .font(.system(size: 12, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(snapshot.statusColor)
            }
            .frame(width: 28, height: 28)
            .background(.quaternary, in: Circle())
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: compact ? 1 : 2) {
                Text(miner.displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .contextMenu {
                        Button(action: onOverrideStream) {
                            Label("Override Stream...", systemImage: "person.fill.viewfinder")
                        }

                        if miner.streamOverrideLogin != nil {
                            Button(action: onClearStreamOverride) {
                                Label("Stop Stream Override", systemImage: "xmark.circle")
                            }
                        }

                        Button(action: onEditNickname) {
                            Label(miner.nickname == nil ? "Add Nickname" : "Edit Nickname", systemImage: "pencil")
                        }

                        if miner.nickname != nil {
                            Button(action: onClearNickname) {
                                Label("Clear Nickname", systemImage: "xmark.circle")
                            }
                        }
                    }

                if !compact {
                    Text(activityLabel(for: snapshot))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            if MinerAttention.hasPendingAttention(for: miner, settings: settings) {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel("Has pending items")
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, compact ? 8 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Tahoe source-list selection: a soft filled pill, no outline.
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: TahoeMetrics.row, style: .continuous)
                    .fill(Color.accentColor.opacity(0.16))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: TahoeMetrics.row, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private func activityLabel(for snapshot: MinerActivitySnapshot) -> String {
        snapshot.sourceListActivityLabel
    }

}

struct MinerNicknameEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    let miner: MinerManager.ManagedMiner
    let navigation: NavigationModel
    @State private var nickname: String
    @FocusState private var isNicknameFocused: Bool

    init(miner: MinerManager.ManagedMiner, navigation: NavigationModel) {
        self.miner = miner
        self.navigation = navigation
        self._nickname = State(initialValue: miner.nickname ?? "")
    }

    private var normalizedNickname: String? {
        Account.normalizedNickname(nickname)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text(miner.nickname == nil ? "Add Nickname" : "Edit Nickname")
                    .font(.title3.weight(.semibold))

                Text("@\(miner.username)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            TextField("Nickname", text: $nickname)
                .textFieldStyle(.roundedBorder)
                .focused($isNicknameFocused)
                .onSubmit {
                    saveAndDismiss()
                }

            HStack(spacing: 10) {
                if miner.nickname != nil {
                    Button {
                        nickname = ""
                        saveAndDismiss()
                    } label: {
                        Label("Clear", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    saveAndDismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 360)
        .onAppear {
            isNicknameFocused = true
        }
    }

    private func saveAndDismiss() {
        guard normalizedNickname != miner.nickname else {
            dismiss()
            return
        }

        Task {
            await navigation.minerManager.updateMinerNickname(
                minerId: miner.id,
                nickname: normalizedNickname
            )
        }
        dismiss()
    }
}

struct MinerStreamOverrideSheet: View {
    @Environment(\.dismiss) private var dismiss
    let miner: MinerManager.ManagedMiner
    let navigation: NavigationModel
    @State private var streamLogin: String
    @FocusState private var isStreamFocused: Bool

    init(miner: MinerManager.ManagedMiner, navigation: NavigationModel) {
        self.miner = miner
        self.navigation = navigation
        self._streamLogin = State(initialValue: miner.streamOverrideLogin.map { "@\($0)" } ?? "")
    }

    private var normalizedLogin: String? {
        MinerManager.ManagedMiner.normalizedStreamOverrideLogin(streamLogin)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Override Stream")
                    .font(.title3.weight(.semibold))

                Text(miner.displayName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                TextField("Username or twitch.tv link", text: $streamLogin)
                    .textFieldStyle(.roundedBorder)
                    .focused($isStreamFocused)
                    .onSubmit {
                        saveAndDismiss()
                    }

                if let normalizedLogin {
                    Text("Will watch twitch.tv/\(normalizedLogin) until they go offline.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("Paste a stream URL or type a username — e.g. @flats.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            HStack(spacing: 10) {
                if miner.streamOverrideLogin != nil {
                    Button {
                        streamLogin = ""
                        saveAndDismiss()
                    } label: {
                        Label("Clear", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    saveAndDismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(normalizedLogin == nil && miner.streamOverrideLogin == nil)
            }
        }
        .padding(22)
        .frame(width: 360)
        .onAppear {
            isStreamFocused = true
        }
    }

    private func saveAndDismiss() {
        guard normalizedLogin != miner.streamOverrideLogin else {
            dismiss()
            return
        }

        Task {
            await navigation.minerManager.setStreamOverride(
                minerId: miner.id,
                login: normalizedLogin
            )
        }
        dismiss()
    }
}

struct LinkNoticeBanner: View {
    let notice: LinkNotice
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            AnimatedStatusIcon(symbol: "checkmark.circle.fill", color: .green, size: 15, weight: .semibold)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(notice.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(notice.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Dismiss")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.green.opacity(0.10), in: RoundedRectangle(cornerRadius: TahoeMetrics.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: TahoeMetrics.card, style: .continuous)
                .strokeBorder(.green.opacity(0.22), lineWidth: 1)
        }
    }
}

struct NoActiveCampaignsRow: View {
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
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.background.opacity(0.001))
    }
}

struct EmptyMinersStateView: View {
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

struct RankedPriorityChip: View {
    let rank: Int
    let gameName: String
    let isGlobal: Bool
    let onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 5) {
            Text("\(rank)")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 15, height: 15)
                .background(
                    Circle().fill(isGlobal ? AnyShapeStyle(Color.gray.opacity(0.55)) : AnyShapeStyle(Color.accentColor))
                )

            Text(gameName)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(isGlobal ? .secondary : .primary)

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove \(gameName) from this miner's personal priorities")
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        // Tahoe chips read as soft filled capsules; the outline is dropped so
        // a long list of them doesn't turn into a grid of boxes.
        .background((isGlobal ? Color.gray.opacity(0.16) : Color.accentColor.opacity(0.16)), in: Capsule())
        .contentShape(Capsule())
    }
}

#Preview {
    MinersOverviewView()
        .environment(NavigationModel(clientId: "preview"))
}
