import SwiftUI
import SwiftMinerCore
import TipKit

/// Execution layer overview - scalable multi-miner workspace.
struct MinersOverviewView: View {
    @Environment(NavigationModel.self) private var navigation
    private var settings: Settings { .shared }
    @AppStorage("minersDiagnosticsExpanded", store: Settings.appStorageStore)
    private var diagnosticsExpanded = true
    @State private var selectedActivitySummary: MinerManager.MinerActivitySummary?
    @State private var hasCapturedInitialLinkIssues = false
    @State private var previousLinkIssuesById: [String: PrioritisedLinkIssue] = [:]
    @State private var linkNotice: LinkNotice?
    @State private var nicknameEditor: MinerNicknameEditorPresentation?
    @State private var streamOverrideEditor: MinerStreamOverridePresentation?
    @State private var isDiagnosticsHelpPresented = false

    private var miners: [MinerManager.ManagedMiner] {
        navigation.minerManager.miners
    }

    private var selectedMiner: MinerManager.ManagedMiner? {
        guard let selectedId = navigation.selectedMinerId else { return miners.first }
        return miners.first { $0.id == selectedId } ?? miners.first
    }

    private var hasMultipleMiners: Bool {
        Self.shouldShowGlobalPriorityToggle(minerCount: miners.count)
    }

    static func shouldShowGlobalPriorityToggle(minerCount: Int) -> Bool {
        minerCount > 1
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
        .sheet(item: $streamOverrideEditor) { presentation in
            MinerStreamOverrideSheet(
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
                                    onClearNickname: { clearNickname(for: miner) },
                                    onOverrideStream: { presentStreamOverrideEditor(for: miner) },
                                    onClearStreamOverride: { clearStreamOverride(for: miner) }
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                minerContextMenu(for: miner)
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
                    }, onOverrideStream: {
                        presentStreamOverrideEditor(for: miner)
                    }, onClearStreamOverride: {
                        clearStreamOverride(for: miner)
                    })

                    if let linkNotice {
                        LinkNoticeBanner(notice: linkNotice) {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                self.linkNotice = nil
                            }
                        }
                    }

                    selectedMinerWatchingStreamerSection(for: miner)

                    minerPrioritiesSection(for: miner)

                    minerCampaignsSection(for: miner, campaigns: activeCampaigns)

                    minerDiagnosticsSection(for: miner)

                    pendingItemsSection(for: miner, campaigns: activeCampaigns)
                }
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
                prioritiseFollowedStreamers: Settings.shared.prioritiseFollowedStreamers,
                failoverStreamers: Settings.shared.gameFailoverStreamers
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

    private func presentStreamOverrideEditor(for miner: MinerManager.ManagedMiner) {
        streamOverrideEditor = MinerStreamOverridePresentation(miner: miner)
    }

    private func clearStreamOverride(for miner: MinerManager.ManagedMiner) {
        Task {
            await navigation.minerManager.clearStreamOverride(minerId: miner.id)
        }
    }

    @ViewBuilder
    private func minerContextMenu(for miner: MinerManager.ManagedMiner) -> some View {
        Button {
            presentStreamOverrideEditor(for: miner)
        } label: {
            Label("Override Stream...", systemImage: "person.fill.viewfinder")
        }

        if miner.streamOverrideLogin != nil {
            Button {
                clearStreamOverride(for: miner)
            } label: {
                Label("Stop Stream Override", systemImage: "xmark.circle")
            }
        }

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

    // MARK: - Priorities

    /// Games prioritised specifically for this miner. Derived from the miner's
    /// reactive effective list so DM/web/global changes refresh it live. Global
    /// duplicates are hidden only while the global list applies — when this
    /// miner opts out of global priorities, its own entries stand alone.
    private func personalPriorityGames(for miner: MinerManager.ManagedMiner) -> [String] {
        guard settings.includesGlobalPriorityGames(forAccountId: miner.accountId) else {
            return miner.priorityGames
        }
        let globalKeys = Set(settings.priorityGames.map { $0.lowercased() })
        return miner.priorityGames.filter { !globalKeys.contains($0.lowercased()) }
    }

    private func minerPrioritiesSection(for miner: MinerManager.ManagedMiner) -> some View {
        let includesGlobal = settings.includesGlobalPriorityGames(forAccountId: miner.accountId)
        let personal = personalPriorityGames(for: miner)
        let personalKeys = Set(personal.map { $0.lowercased() })
        let global = includesGlobal
            ? settings.priorityGames.filter { !personalKeys.contains($0.lowercased()) }
            : []
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Priorities")
                    .font(.headline)
                Spacer()
                if hasMultipleMiners {
                    Toggle("Use global priorities", isOn: Binding(
                        get: { settings.includesGlobalPriorityGames(forAccountId: miner.accountId) },
                        set: { include in
                            settings.setIncludesGlobalPriorityGames(include, forAccountId: miner.accountId)
                            let updated = settings.priorityGames(forAccountId: miner.accountId)
                            navigation.minerManager.updatePriorityGames(updated, forMinerId: miner.id)
                            if miner.isRunning {
                                Task { await navigation.minerManager.forceRefreshMiner(minerId: miner.id) }
                            }
                        }
                    ))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
            }

            Text(includesGlobal
                ? "Mining order: this miner's own games first, then the global list."
                : "Mining order: this miner's own games only — the global list is ignored.")
            .font(.caption)
            .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text("THIS MINER")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .kerning(0.8)

                if personal.isEmpty {
                    Text("No personal priorities yet — add games from the web dashboard or Discord.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    FlowLayout(spacing: 6) {
                        ForEach(Array(personal.enumerated()), id: \.element) { index, game in
                            RankedPriorityChip(
                                rank: index + 1,
                                gameName: game,
                                isGlobal: false,
                                onRemove: { removePersonalPriority(game, from: miner) }
                            )
                        }
                    }
                }
            }

            if includesGlobal {
                VStack(alignment: .leading, spacing: 6) {
                    Text("THEN GLOBAL")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .kerning(0.8)

                    if global.isEmpty {
                        Text(settings.priorityGames.isEmpty
                            ? "The global list is empty."
                            : "All global games are already covered by this miner's own list.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        FlowLayout(spacing: 6) {
                            ForEach(Array(global.enumerated()), id: \.element) { index, game in
                                RankedPriorityChip(
                                    rank: personal.count + index + 1,
                                    gameName: game,
                                    isGlobal: true,
                                    onRemove: nil
                                )
                            }
                        }
                    }
                }
            }
        }
        .padding(20)
        .glassCard()
    }

    private func removePersonalPriority(_ gameName: String, from miner: MinerManager.ManagedMiner) {
        let updated = settings.deprioritiseGameForAccount(accountId: miner.accountId, gameName: gameName)
        navigation.minerManager.updatePriorityGames(updated, forMinerId: miner.id)
        if miner.isRunning {
            Task { await navigation.minerManager.forceRefreshMiner(minerId: miner.id) }
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
