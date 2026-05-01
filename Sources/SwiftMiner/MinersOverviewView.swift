import SwiftUI
import SwiftMinerCore

/// Execution layer overview - scalable multi-miner workspace.
struct MinersOverviewView: View {
    @Environment(NavigationModel.self) private var navigation
    @ObservedObject private var settings = Settings.shared
    @State private var selectedActivitySummary: MinerManager.MinerActivitySummary?
    @State private var hasCapturedInitialLinkIssues = false
    @State private var previousLinkIssuesById: [String: PrioritisedLinkIssue] = [:]
    @State private var linkNotice: LinkNotice?
    @State private var nicknameEditor: MinerNicknameEditorPresentation?

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
            captureInitialLinkIssuesIfNeeded()
        }
        .onChange(of: miners.map(\.id)) { _, _ in
            syncSelection()
        }
        .onChange(of: rawLinkIssueSignature) { oldValue, newValue in
            handleLinkIssueSignatureChange(from: oldValue, to: newValue)
        }
        .sheet(item: $nicknameEditor) { presentation in
            MinerNicknameEditorSheet(
                miner: presentation.miner,
                navigation: navigation
            )
        }
    }

    private var minerListPane: some View {
        VStack(alignment: .leading, spacing: 12) {
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
                                    isSelected: selectionBinding.wrappedValue == miner.id,
                                    onEditNickname: { presentNicknameEditor(for: miner) },
                                    onClearNickname: { clearNickname(for: miner) }
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                nicknameContextMenu(for: miner)
                            }

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
                    }, onEditNickname: {
                        presentNicknameEditor(for: miner)
                    }, onClearNickname: {
                        clearNickname(for: miner)
                    })

                    if let linkNotice {
                        LinkNoticeBanner(notice: linkNotice) {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                self.linkNotice = nil
                            }
                        }
                    }

                    selectedMinerLinkIssuesSection(for: miner)

                    selectedMinerWatchingStreamerSection(for: miner)

                    minerCampaignsSection(for: miner, campaigns: activeCampaigns)
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
                antiStallRecoveryEnabled: Settings.shared.antiStallRecoveryEnabled,
                prioritiseFollowedStreamers: Settings.shared.prioritiseFollowedStreamers
            )
        }
    }

    private func presentNicknameEditor(for miner: MinerManager.ManagedMiner) {
        nicknameEditor = MinerNicknameEditorPresentation(miner: miner)
    }

    private func clearNickname(for miner: MinerManager.ManagedMiner) {
        Task {
            await navigation.minerManager.updateMinerNickname(
                minerId: miner.id,
                nickname: nil
            )
        }
    }

    @ViewBuilder
    private func nicknameContextMenu(for miner: MinerManager.ManagedMiner) -> some View {
        Button {
            presentNicknameEditor(for: miner)
        } label: {
            Label(miner.nickname == nil ? "Add Nickname" : "Edit Nickname", systemImage: "pencil")
        }

        if miner.nickname != nil {
            Button {
                clearNickname(for: miner)
            } label: {
                Label("Clear Nickname", systemImage: "xmark.circle")
            }
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
    private func selectedMinerLinkIssuesSection(for miner: MinerManager.ManagedMiner) -> some View {
        let issues = prioritisedLinkIssues(for: miner, includeIgnored: false)
        let mutedIssues = prioritisedLinkIssues(for: miner, includeIgnored: true)
            .filter(\.isIgnored)

        if !issues.isEmpty || !mutedIssues.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text("ACCOUNT LINK REMINDERS")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)

                    Text("\(issues.count)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)

                VStack(spacing: 1) {
                    ForEach(issues) { issue in
                        PrioritisedLinkIssueRow(
                            issue: issue,
                            actionTitle: "Dismiss",
                            actionSystemImage: "bell.slash",
                            actionRole: nil
                        ) {
                            setLinkReminder(false, for: issue)
                        }
                    }

                    ForEach(mutedIssues) { issue in
                        PrioritisedLinkIssueRow(
                            issue: issue,
                            actionTitle: "Remind me",
                            actionSystemImage: "bell",
                            actionRole: nil
                        ) {
                            setLinkReminder(true, for: issue)
                        }
                    }
                }
            }
            .background(.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: GlassRadius.small, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: GlassRadius.small, style: .continuous)
                    .strokeBorder(.orange.opacity(0.24), lineWidth: 1)
            }
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
                        let gameId = warningGameId(for: campaign)
                        let isIgnored = settings.isIgnoringAccountLinkWarnings(for: miner.accountId, gameId: gameId)

                        CampaignStatusRow(
                            miner: miner,
                            campaign: campaign,
                            isWarningIgnored: isIgnored,
                            onDismissWarning: {
                                setLinkReminder(false, for: miner, gameId: gameId, gameName: campaign.game.name)
                            },
                            onRemindWarning: {
                                setLinkReminder(true, for: miner, gameId: gameId, gameName: campaign.game.name)
                            }
                        )
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
        let configuredPriorityGames = miner.priorityGames.isEmpty ? settings.priorityGames : miner.priorityGames
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

    private var rawLinkIssueSignature: String {
        prioritisedLinkIssues(includeIgnored: true)
            .map(\.id)
            .sorted()
            .joined(separator: "|")
    }

    private func captureInitialLinkIssuesIfNeeded() {
        guard !hasCapturedInitialLinkIssues else { return }
        previousLinkIssuesById = Dictionary(
            uniqueKeysWithValues: prioritisedLinkIssues(includeIgnored: true).map { ($0.id, $0) }
        )
        hasCapturedInitialLinkIssues = true
    }

    private func handleLinkIssueSignatureChange(from oldValue: String, to newValue: String) {
        let currentIssues = prioritisedLinkIssues(includeIgnored: true)
        let currentById = Dictionary(uniqueKeysWithValues: currentIssues.map { ($0.id, $0) })

        guard hasCapturedInitialLinkIssues else {
            previousLinkIssuesById = currentById
            hasCapturedInitialLinkIssues = true
            return
        }

        let resolvedIds = Set(previousLinkIssuesById.keys).subtracting(currentById.keys)
        if let resolvedIssue = resolvedIds.sorted().compactMap({ previousLinkIssuesById[$0] }).first,
           isLinkedNow(resolvedIssue) {
            showLinkedNotice(for: resolvedIssue)
        }

        previousLinkIssuesById = currentById
    }

    private func showLinkedNotice(for issue: PrioritisedLinkIssue) {
        let notice = LinkNotice(
            id: UUID(),
            title: "\(issue.gameName) linked",
            message: "\(issue.minerName) can mine those prioritised drops now."
        )

        withAnimation(.easeInOut(duration: 0.18)) {
            linkNotice = notice
        }

        Task {
            let service = NotificationService()
            await service.configure(enabled: true)
            await service.notifyAccountLinked(gameName: issue.gameName)
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8 * 1_000_000_000)
            guard linkNotice?.id == notice.id else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                linkNotice = nil
            }
        }
    }

    private func prioritisedLinkIssues(includeIgnored: Bool) -> [PrioritisedLinkIssue] {
        miners.flatMap { prioritisedLinkIssues(for: $0, includeIgnored: includeIgnored) }
    }

    private func prioritisedLinkIssues(for miner: MinerManager.ManagedMiner, includeIgnored: Bool) -> [PrioritisedLinkIssue] {
        let grouped = Dictionary(grouping: activePrioritisedCampaigns(for: miner)) { campaign in
            warningGameId(for: campaign)
        }

        return grouped.compactMap { gameId, campaigns in
            let blockedCampaigns = campaigns.filter { $0.activityStatus(for: miner) == .requiresLink }
            guard !blockedCampaigns.isEmpty, let first = blockedCampaigns.first else { return nil }

            let isIgnored = settings.isIgnoringAccountLinkWarnings(for: miner.accountId, gameId: gameId)
            guard includeIgnored || !isIgnored else { return nil }

            return PrioritisedLinkIssue(
                minerId: miner.id,
                accountId: miner.accountId,
                minerName: miner.displayName,
                gameId: gameId,
                gameName: first.game.name,
                campaignNames: blockedCampaigns.map(\.name).sorted(),
                isIgnored: isIgnored
            )
        }
        .sorted {
            if $0.isIgnored != $1.isIgnored { return !$0.isIgnored }
            return $0.gameName.localizedCaseInsensitiveCompare($1.gameName) == .orderedAscending
        }
    }

    private func setLinkReminder(_ enabled: Bool, for issue: PrioritisedLinkIssue) {
        guard let miner = miners.first(where: { $0.id == issue.minerId }) else { return }
        setLinkReminder(enabled, for: miner, gameId: issue.gameId, gameName: issue.gameName)
    }

    private func setLinkReminder(
        _ enabled: Bool,
        for miner: MinerManager.ManagedMiner,
        gameId: String,
        gameName: String
    ) {
        settings.setIgnoreAccountLinkWarnings(!enabled, for: miner.accountId, gameId: gameId)

        Task {
            await navigation.minerManager.setAccountLinkWarningIgnored(
                minerId: miner.id,
                gameId: gameId,
                ignored: !enabled
            )
        }

        if enabled {
            linkNotice = LinkNotice(
                id: UUID(),
                title: "Reminder restored",
                message: "\(gameName) will show link reminders again."
            )
        }
    }

    private func isLinkedNow(_ issue: PrioritisedLinkIssue) -> Bool {
        guard let miner = miners.first(where: { $0.id == issue.minerId }) else { return false }

        return activePrioritisedCampaigns(for: miner).contains { campaign in
            warningGameId(for: campaign) == issue.gameId && campaign.isAccountConnected
        }
    }

    private func warningGameId(for campaign: Campaign) -> String {
        let id = campaign.game.id.trimmingCharacters(in: .whitespacesAndNewlines)
        if !id.isEmpty { return id }
        return normalizedGameKey(campaign.game.name)
    }
}

private struct PrioritisedLinkIssue: Identifiable, Equatable {
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

private struct LinkNotice: Identifiable, Equatable {
    let id: UUID
    let title: String
    let message: String
}

private struct MinerNicknameEditorPresentation: Identifiable {
    let miner: MinerManager.ManagedMiner

    var id: String {
        miner.id
    }
}

private struct MinerSourceListRow: View {
    let miner: MinerManager.ManagedMiner
    let compact: Bool
    let isSelected: Bool
    let onEditNickname: () -> Void
    let onClearNickname: () -> Void
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
                    .contextMenu {
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

private struct MinerNicknameEditorSheet: View {
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

private struct LinkNoticeBanner: View {
    let notice: LinkNotice
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.green)
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

private struct PrioritisedLinkIssueRow: View {
    let issue: PrioritisedLinkIssue
    let actionTitle: String
    let actionSystemImage: String
    let actionRole: ButtonRole?
    let onAction: () -> Void

    private var subtitle: String {
        let campaigns = issue.campaignNames.prefix(2).joined(separator: ", ")
        if issue.campaignNames.count > 2 {
            return "\(campaigns), and more need a linked account."
        }
        return "\(campaigns) needs a linked account."
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: issue.isIgnored ? "bell.slash" : "link.badge.plus")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(issue.isIgnored ? Color.secondary : Color.orange)
                .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 3) {
                Text(issue.gameName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(issue.isIgnored ? "Reminder muted for \(issue.minerName)." : subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            Button(role: actionRole, action: onAction) {
                Label(actionTitle, systemImage: actionSystemImage)
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

private struct CampaignStatusRow: View {
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
