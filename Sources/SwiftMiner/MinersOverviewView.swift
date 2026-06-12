import SwiftUI
import SwiftMinerCore
import TipKit

/// Execution layer overview - scalable multi-miner workspace.
struct MinersOverviewView: View {
    @Environment(NavigationModel.self) private var navigation
    @ObservedObject private var settings = Settings.shared
    @AppStorage("minersDiagnosticsExpanded", store: Settings.appStorageStore)
    private var diagnosticsExpanded = true
    @State private var selectedActivitySummary: MinerManager.MinerActivitySummary?
    @State private var hasCapturedInitialLinkIssues = false
    @State private var previousLinkIssuesById: [String: PrioritisedLinkIssue] = [:]
    @State private var linkNotice: LinkNotice?
    @State private var nicknameEditor: MinerNicknameEditorPresentation?
    @State private var isDiagnosticsHelpPresented = false

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
            NicknameMinerTip.minerCount = miners.count
            await NicknameMinerTip.viewedMinersList.donate()
        }
        .onChange(of: miners.map(\.id)) { _, _ in
            syncSelection()
            NicknameMinerTip.minerCount = miners.count
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
                            .modifier(NicknameTipAttachment(isFirstRow: index == 0))

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

                    selectedMinerWatchingStreamerSection(for: miner)

                    minerCampaignsSection(for: miner, campaigns: activeCampaigns)

                    minerDiagnosticsSection(for: miner)

                    pendingItemsSection(for: miner, campaigns: activeCampaigns)
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

    private func minerDiagnosticsSection(for miner: MinerManager.ManagedMiner) -> some View {
        let snapshot = MinerHealthSnapshot.make(miner: miner)
        let logEvents = navigation.events.filter { $0.minerId == miner.id }.prefix(5)
        let stallState = StallConfidenceState(percent: snapshot.stallConfidencePercent)

        return DisclosureGroup(isExpanded: $diagnosticsExpanded) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label(snapshot.statusLabel, systemImage: diagnosticsSystemImage(for: snapshot.health))
                        .font(.headline)
                        .foregroundStyle(diagnosticsTint(for: snapshot.health))

                    Spacer()

                    Label {
                        Text(stallState.title)
                    } icon: {
                        Image(systemName: stallState.systemImage)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(stallState.tint)
                }

                ProgressView(value: Double(snapshot.stallConfidencePercent), total: 100)
                    .tint(stallState.tint)

                if snapshot.stallSignals.isEmpty {
                    Text("Recent poll, event and worker signals look normal.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(snapshot.stallSignals, id: \.self) { signal in
                            Label(signal, systemImage: "smallcircle.filled.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Divider()
                    .opacity(0.55)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Recovery Timeline")
                        .font(.subheadline.weight(.semibold))

                    if selectedActivitySummary?.recentEvents.isEmpty != false && logEvents.isEmpty {
                        Text("No recent diagnostic events for this miner.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(selectedActivitySummary?.recentEvents.indices ?? 0..<0, id: \.self) { index in
                            if let event = selectedActivitySummary?.recentEvents[index] {
                                MinerDiagnosticTimelineRow(
                                    title: event.summary,
                                    detail: event.type.rawValue,
                                    date: event.timestamp
                                )
                            }
                        }

                        ForEach(Array(logEvents)) { event in
                            MinerDiagnosticTimelineRow(
                                title: event.message,
                                detail: event.level.rawValue.capitalized,
                                date: event.timestamp
                            )
                        }
                    }
                }
            }
            .padding(.top, 12)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg.rectangle")
                    .foregroundStyle(diagnosticsTint(for: snapshot.health))

                Text("DIAGNOSTICS")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)

                Text(snapshot.statusLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Button {
                    isDiagnosticsHelpPresented.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Explain stall confidence")
                .accessibilityLabel("Explain stall confidence")
                .popover(isPresented: $isDiagnosticsHelpPresented, arrowEdge: .top) {
                    StallConfidenceHelpPopover()
                }
            }
            .contentShape(Rectangle())
        }
        .padding(12)
        .background(.background.opacity(0.62), in: RoundedRectangle(cornerRadius: GlassRadius.small, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: GlassRadius.small, style: .continuous)
                .strokeBorder(.separator.opacity(0.32), lineWidth: 1)
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
    private func pendingItemsSection(for miner: MinerManager.ManagedMiner, campaigns: [Campaign]) -> some View {
        let items = pendingItems(for: miner, campaigns: campaigns)
        let activeCount = items.filter { !$0.isMuted }.count

        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text("PENDING")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)

                    Text("\(activeCount)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)

                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)

                VStack(spacing: 1) {
                    ForEach(items) { item in
                        PendingItemRow(item: item) {
                            togglePendingMute(item)
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
    }

    private func pendingItems(for miner: MinerManager.ManagedMiner, campaigns: [Campaign]) -> [PendingItem] {
        var items: [PendingItem] = []

        // Account-link issues (one per game)
        let allLinkIssues = prioritisedLinkIssues(for: miner, includeIgnored: true)
        for issue in allLinkIssues {
            items.append(PendingItem(
                kind: .accountLink(issue),
                isMuted: issue.isIgnored
            ))
        }

        // Subscription-gated campaigns (one per campaign)
        for campaign in campaigns where campaign.activityStatus(for: miner) == .requiresSubscription {
            let isMuted = settings.isIgnoringSubscriptionRequiredWarnings(
                for: miner.accountId,
                campaignId: campaign.id
            )
            items.append(PendingItem(
                kind: .subscriptionRequired(
                    minerId: miner.id,
                    accountId: miner.accountId,
                    campaignId: campaign.id,
                    gameName: campaign.game.name,
                    campaignName: campaign.name,
                    dropNames: campaign.subscriptionRequiredDrops.map(\.name).sorted()
                ),
                isMuted: isMuted
            ))
        }

        #if DEBUG
        items.append(contentsOf: debugFakePendingItems(for: miner))
        #endif

        return items.sorted { lhs, rhs in
            if lhs.isMuted != rhs.isMuted { return !lhs.isMuted }
            return lhs.severity.rank < rhs.severity.rank
        }
    }

    #if DEBUG
    /// Injects synthetic pending items when `SWIFTMINER_FAKE_PENDING=1`.
    /// Set the env var in the Xcode scheme (Run → Arguments → Environment Variables).
    /// Mute state persists in real Settings storage under the fake accountId namespace.
    private func debugFakePendingItems(for miner: MinerManager.ManagedMiner) -> [PendingItem] {
        guard ProcessInfo.processInfo.environment["SWIFTMINER_FAKE_PENDING"] == "1" else {
            return []
        }

        let fakeLinkGameId = "debug-fake-link-game"
        let fakeCampaignId = "debug-fake-campaign"

        // Reads use miner.accountId so mute writes (which also use miner.accountId)
        // round-trip correctly. Fake gameId/campaignId namespaces prevent collisions
        // with real warnings.
        let linkIssue = PrioritisedLinkIssue(
            minerId: miner.id,
            accountId: miner.accountId,
            minerName: miner.displayName,
            gameId: fakeLinkGameId,
            gameName: "Debug: Rust",
            campaignNames: ["Twitch Drops Week 3", "Community Skin Pack"],
            isIgnored: settings.isIgnoringAccountLinkWarnings(for: miner.accountId, gameId: fakeLinkGameId)
        )

        let subMuted = settings.isIgnoringSubscriptionRequiredWarnings(
            for: miner.accountId,
            campaignId: fakeCampaignId
        )

        return [
            PendingItem(
                kind: .accountLink(linkIssue),
                isMuted: linkIssue.isIgnored
            ),
            PendingItem(
                kind: .subscriptionRequired(
                    minerId: miner.id,
                    accountId: miner.accountId,
                    campaignId: fakeCampaignId,
                    gameName: "Debug: Diablo IV",
                    campaignName: "Season of the Construct",
                    dropNames: ["Hellfire Helm", "Cinder Wings"]
                ),
                isMuted: subMuted
            ),
        ]
    }
    #endif

    private func togglePendingMute(_ item: PendingItem) {
        switch item.kind {
        case .accountLink(let issue):
            setLinkReminder(item.isMuted, for: issue)
        case .subscriptionRequired(_, let accountId, let campaignId, _, _, _):
            settings.setIgnoreSubscriptionRequiredWarnings(
                !item.isMuted,
                for: accountId,
                campaignId: campaignId
            )
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
        case .requiresSubscription:
            return 3
        case .completed:
            return 4
        case .upcoming:
            return 5
        case .expired:
            return 6
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

    private func diagnosticsSystemImage(for health: MinerHealthSnapshot.Health) -> String {
        switch health {
        case .mining: return "play.circle.fill"
        case .blocked: return "exclamationmark.triangle.fill"
        case .needsAuth: return "person.crop.circle.badge.exclamationmark"
        case .stalled: return "waveform.path.ecg.rectangle"
        case .recovering: return "arrow.triangle.2.circlepath"
        case .idle: return "pause.circle"
        case .attention: return "exclamationmark.circle.fill"
        }
    }

    private func diagnosticsTint(for health: MinerHealthSnapshot.Health) -> Color {
        switch health {
        case .mining: return .green
        case .recovering: return .blue
        case .blocked, .needsAuth, .stalled, .attention: return .orange
        case .idle: return .secondary
        }
    }

}

private struct StallConfidenceState {
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

private struct StallConfidenceHelpPopover: View {
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

private struct StallConfidenceHelpRow: View {
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

private struct MinerDiagnosticTimelineRow: View {
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

private struct PendingItem: Identifiable, Equatable {
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

private struct PendingItemRow: View {
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
            .minerTip(AddMinerTip())
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .padding(24)
    }
}

#Preview {
    MinersOverviewView()
        .environment(NavigationModel(clientId: "preview"))
}

private struct NicknameTipAttachment: ViewModifier {
    let isFirstRow: Bool

    func body(content: Content) -> some View {
        if isFirstRow {
            content.minerTip(NicknameMinerTip())
        } else {
            content
        }
    }
}
