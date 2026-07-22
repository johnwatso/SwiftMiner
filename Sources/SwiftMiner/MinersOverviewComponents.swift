// Rows, sheets, banners, and chips supporting MinersOverviewView.
import SwiftUI
import SwiftMinerCore
import TipKit

struct StallConfidenceState {
    let percent: Int

    var title: String {
        switch percent {
        case 0..<25: return "Normal"
        case 25...50: return "Early Warning"
        case 51..<75: return "Likely Trouble"
        default: return "High Risk"
        }
    }

    var systemImage: String {
        switch percent {
        case 0..<25: return "checkmark.circle.fill"
        case 25...50: return "checkmark.circle.badge.questionmark.fill"
        case 51..<75: return "checkmark.circle.trianglebadge.exclamationmark.fill"
        default: return "checkmark.circle.badge.xmark.fill"
        }
    }

    var tint: Color {
        switch percent {
        case 0..<25: return .green
        case 25...50: return .yellow
        case 51..<75: return .orange
        default: return .red
        }
    }
}

struct StallConfidenceHelpPopover: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Stall Confidence")
                .font(.headline)

            Text("This estimates how likely the selected miner is stuck. Lower is healthier: 0% means no stall signals, while 100% means the supervisor has marked the miner unresponsive.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineSpacing(1.5)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                StallConfidenceHelpRow(state: StallConfidenceState(percent: 0), range: "0-24%")
                StallConfidenceHelpRow(state: StallConfidenceState(percent: 25), range: "25-50%")
                StallConfidenceHelpRow(state: StallConfidenceState(percent: 51), range: "51-74%")
                StallConfidenceHelpRow(state: StallConfidenceState(percent: 75), range: "75-100%")
            }
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
    }
}

struct StallConfidenceHelpRow: View {
    let state: StallConfidenceState
    let range: String

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: state.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(state.tint)
                .frame(width: 16)

            Text(range)
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 62, alignment: .leading)

            Text(state.title)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }
}

struct MinerDiagnosticTimelineRow: View {
    let title: String
    let detail: String
    let date: Date

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Color.secondary.opacity(0.45))
                .frame(width: 6, height: 6)
                .padding(.top, 6)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(2)

                Text("\(detail) · \(date.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
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
        case .accountLink(let issue): return issue.gameName
        case .subscriptionRequired(_, _, _, let gameName, _, _): return gameName
        }
    }

    var subtitle: String {
        switch kind {
        case .accountLink(let issue):
            if isMuted { return "Reminder muted for \(issue.minerName)." }
            let names = issue.campaignNames.prefix(2).joined(separator: ", ")
            if issue.campaignNames.count > 2 {
                return "\(names), and more need a linked account."
            }
            return "\(names) needs a linked account."
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
}

struct PendingItemRow: View {
    let item: PendingItem
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

            Button(action: onAction) {
                Label(item.actionTitle, systemImage: item.actionSystemImage)
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.background.opacity(0.001))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(.separator.opacity(0.24))
                .frame(height: 1)
                .padding(.leading, 42)
        }
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
    let compact: Bool
    let isSelected: Bool
    let onEditNickname: () -> Void
    let onClearNickname: () -> Void
    let onOverrideStream: () -> Void
    let onClearStreamOverride: () -> Void
    private var settings: Settings { .shared }

    private var snapshot: MinerActivitySnapshot {
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

    private var hasMinerPriorityOverride: Bool {
        let accountId = miner.accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        return settings.accountPriorityGames[accountId] != nil || !settings.includesGlobalPriorityGames(forAccountId: accountId)
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
                    Text(activityLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Image(systemName: hasMinerPriorityOverride ? "person.crop.square.badge.checkmark" : "target")
                            .font(.system(size: 9, weight: .semibold))

                        Text(priorityLabel)
                            .lineLimit(1)
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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
        if snapshot.now.id.hasPrefix("override-") {
            return "Watching \(snapshot.now.title)"
        }
        if snapshot.now.campaignId != nil {
            return "Watching \(snapshot.now.title)"
        }
        if let next = snapshot.upNext {
            return "Likely next: \(next.title)"
        }
        return snapshot.statusText
    }

    private var priorityLabel: String {
        guard !displayedPriorityGames.isEmpty else {
            return "No priority games set"
        }

        let visibleGames = displayedPriorityGames.prefix(2).joined(separator: ", ")
        let remainingCount = displayedPriorityGames.count - 2
        let summary = remainingCount > 0 ? "\(visibleGames) +\(remainingCount)" : visibleGames
        if !settings.includesGlobalPriorityGames(forAccountId: miner.accountId) {
            return "Miner only: \(summary)"
        }
        return "\(hasMinerPriorityOverride ? "Miner" : "Global"): \(summary)"
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
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.green.opacity(0.08), in: RoundedRectangle(cornerRadius: GlassRadius.small, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: GlassRadius.small, style: .continuous)
                .strokeBorder(.green.opacity(0.22), lineWidth: 1)
        }
    }
}

struct CampaignStatusRow: View {
    let miner: MinerManager.ManagedMiner
    let campaign: Campaign
    let isWarningIgnored: Bool
    let onDismissWarning: () -> Void
    let onRemindWarning: () -> Void

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
            return "personalhotspot.slash"
        case .requiresSubscription:
            return "creditcard"
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
        case .requiresSubscription:
            return .pink
        case .waitingForStream:
            return .cyan
        case .upcoming, .expired:
            return .secondary
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Group {
                if status == .completed && !campaign.isAccountConnected {
                    // Claimed, but the game account isn't linked — the reward
                    // won't reach the game until the user links it on Twitch.
                    Image(systemName: "checkmark.circle.badge.questionmark.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.orange, .green)
                        .help("Claimed, but this game isn't linked on Twitch — link it so the reward reaches the game.")
                } else {
                    Image(systemName: statusIcon)
                        .foregroundStyle(statusColor)
                }
            }
            .font(.system(size: 12, weight: .semibold))
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

            if status == .requiresLink {
                Button {
                    isWarningIgnored ? onRemindWarning() : onDismissWarning()
                } label: {
                    Label(
                        isWarningIgnored ? "Remind me" : "Dismiss",
                        systemImage: isWarningIgnored ? "bell" : "bell.slash"
                    )
                    .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            } else if status == .requiresSubscription {
                Text(status.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
            } else {
                Text(status.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .lineLimit(1)
            }
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

struct SelectedMinerStreamerRow: View {
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
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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
            .minerTip(AddMinerTip())
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
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background((isGlobal ? Color.gray.opacity(0.10) : Color.accentColor.opacity(0.12)), in: Capsule())
        .overlay {
            Capsule().stroke(
                isGlobal ? Color.gray.opacity(0.25) : Color.accentColor.opacity(0.35),
                lineWidth: 1
            )
        }
        .contentShape(Capsule())
    }
}

#Preview {
    MinersOverviewView()
        .environment(NavigationModel(clientId: "preview"))
}

struct NicknameTipAttachment: ViewModifier {
    let isFirstRow: Bool

    func body(content: Content) -> some View {
        if isFirstRow {
            content.minerTip(NicknameMinerTip())
        } else {
            content
        }
    }
}
