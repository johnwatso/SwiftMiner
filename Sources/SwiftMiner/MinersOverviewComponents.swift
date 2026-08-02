// Rows, sheets, banners, and chips supporting MinersOverviewView.
import SwiftUI
import SwiftMinerCore

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
            if isMuted { return "Game account isn't linked · reminder muted for \(issue.minerName)." }
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
            .tahoeButtonStyle()
            .controlSize(.small)
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

    private var hasMinerPriorityOverride: Bool {
        let accountId = miner.accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        return settings.accountPriorityGames[accountId] != nil || !settings.includesGlobalPriorityGames(forAccountId: accountId)
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
