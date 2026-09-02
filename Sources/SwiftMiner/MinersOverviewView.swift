import SwiftUI
import SwiftMinerCore
import SwiftMinerService

/// Execution layer overview - scalable multi-miner workspace.
struct MinersOverviewView: View {
    @Environment(NavigationModel.self) private var navigation
    @Environment(\.openURL) private var openURL
    private var settings: Settings { .shared }
    private var twitchAvatars: TwitchAvatarStore { .shared }
    @AppStorage("minersRecoveryHistoryExpanded", store: Settings.appStorageStore)
    private var recoveryHistoryExpanded = false
    @State private var selectedActivitySummary: MinerManager.MinerActivitySummary?
    @State private var hasCapturedInitialLinkIssues = false
    @State private var previousLinkIssuesById: [String: PrioritisedLinkIssue] = [:]
    @State private var linkNotice: LinkNotice?
    @State private var nicknameEditor: MinerNicknameEditorPresentation?
    @State private var streamOverrideEditor: MinerStreamOverridePresentation?
    @State private var isRefreshingSelectedMiner = false
    @State private var reminderDMStates: [String: ReminderDMSendState] = [:]
    /// When each pending item's reminder was last delivered over Discord,
    /// keyed by `PendingItem.id`. Rebuilt per selected miner.
    @State private var reminderDeliveries: [String: Date] = [:]

    private var miners: [MinerManager.ManagedMiner] {
        #if DEBUG
        if MarketingScreenshotFixture.isEnabled {
            return MarketingScreenshotFixture.miners(from: navigation.minerManager.miners)
        }
        #endif
        return navigation.minerManager.miners
    }

    private var selectedMiner: MinerManager.ManagedMiner? {
        guard let selectedId = navigation.selectedMinerId else { return miners.first }
        return miners.first { $0.id == selectedId } ?? miners.first
    }

    private var hasMultipleMiners: Bool {
        Self.shouldShowGlobalPriorityToggle(minerCount: miners.count)
    }

    private var showsDiscordSection: Bool {
        #if DEBUG
        return settings.swiftBotEnabled || MarketingScreenshotFixture.isEnabled
        #else
        return settings.swiftBotEnabled
        #endif
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
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    guard let miner = selectedMiner else { return }
                    refreshMiner(miner)
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help(selectedMiner?.isRunning == true
                    ? "Refresh this miner's Twitch campaigns and inventory"
                    : "Start this miner before refreshing its Twitch campaigns and inventory")
                .disabled(selectedMiner?.isRunning != true || isRefreshingSelectedMiner)
            }
        }
        .task {
            syncSelection()
            captureInitialLinkIssuesIfNeeded()
            // Populates the Discord user cache the header avatar reads from.
            // Only worth a request when a miner is actually Discord-linked, and
            // detached so an unreachable SwiftBot burns its 5s timeout off to
            // the side rather than inside this task.
            if settings.swiftBotEnabled, miners.contains(where: { $0.ownerDiscordId != nil }) {
                Task { await navigation.refreshDiscordDisplayNames() }
            }
            // Twitch pictures come from a per-account lookup, so this is detached
            // for the same reason and re-checked at most once a day per miner.
            // Every account is eligible because Twitch backs up a Discord choice
            // that has no custom avatar.
            Task { await refreshTwitchAvatars() }
        }
        .onChange(of: settings.accountAvatarSourcesData) { _, _ in
            // The selected URL itself swaps synchronously from the observed
            // setting. Refresh both providers behind it so Settings changes
            // also replace missing or stale cache data in this overview.
            Task {
                if settings.swiftBotEnabled,
                   miners.contains(where: { $0.ownerDiscordId != nil }) {
                    await navigation.refreshDiscordDisplayNames()
                }
                await refreshTwitchAvatars()
            }
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
        .sheet(item: $streamOverrideEditor) { presentation in
            MinerStreamOverrideSheet(
                miner: presentation.miner,
                navigation: navigation
            )
        }
    }

    // Tahoe source lists are plain: no enclosing box, no inter-row rules — the
    // selection pill alone carries the structure.
    private var minerListPane: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(miners) { miner in
                    Button {
                        navigation.selectedMinerId = miner.id
                    } label: {
                        MinerSourceListRow(
                            miner: miner,
                            avatarURL: avatarURL(for: miner),
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
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .scrollIndicators(.never)
        .frame(
            minWidth: hasMultipleMiners ? 236 : 156,
            idealWidth: hasMultipleMiners ? 264 : 172,
            maxWidth: hasMultipleMiners ? 300 : 184
        )
        .padding(.leading, 18)
        .padding(.vertical, 20)
        .padding(.trailing, hasMultipleMiners ? 8 : 6)
    }

    @ViewBuilder
    private var selectedMinerPane: some View {
        if let miner = selectedMiner {
            let presentation = operatorPresentation(for: miner)
            let health = MinerHealthSnapshot.make(miner: miner)
            let miningType = miningType(for: miner)

            ScrollView {
                // Lazy, matching the Drops feed: sections below the fold (the
                // campaign queue's artwork rows in particular) aren't built
                // until they're scrolled to.
                LazyVStack(alignment: .leading, spacing: TahoeMetrics.sectionSpacing) {
                    MinerOperatorHeader(
                        miner: miner,
                        health: health,
                        avatarURL: avatarURL(for: miner),
                        priorityTitle: miningType.title,
                        prioritySymbol: miningType.symbol,
                        hasCustomPriorityGames: settings.hasCustomPriorityGames(forAccountId: miner.accountId),
                        onResetPrioritiesToGlobal: {
                            resetPrioritiesToGlobal(for: miner)
                        }
                    )
                    .contextMenu {
                        minerContextMenu(for: miner)
                    }

                    if let attention = MinerAttentionIssue.resolve(miner: miner, events: navigation.events) {
                        minerAttentionSection(for: miner, attention: attention)
                    }

                    MinerMiningSequenceView(
                        miner: miner,
                        presentation: presentation,
                        channelName: selectedActivitySummary?.currentChannelName
                    )

                    if let linkNotice {
                        LinkNoticeBanner(notice: linkNotice) {
                            withAnimation(.easeInOut(duration: 0.18)) {
                                self.linkNotice = nil
                            }
                        }
                    }

                    pendingItemsSection(for: miner, campaigns: miner.allCampaigns)

                    minerCampaignQueueSection(for: miner, presentation: presentation)

                    // Discord is a capability of this miner, not a destination:
                    // it sits between the queue and Status, and stays out of the
                    // Status strip below.
                    if showsDiscordSection {
                        MinerDiscordSection(miner: miner)
                    }

                    minerRecoveryDiagnosticsSection(for: miner)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
            }
            .id(miner.id)
            .task(id: miner.id) {
                // Cleared first so a slower query can never leave the previous
                // miner's Discord delivery notes on this one's pending rows.
                reminderDeliveries = [:]
                await refreshSelectedActivitySummary(for: miner.id)
                await refreshReminderDeliveries(for: miner)
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

    private func operatorPresentation(for miner: MinerManager.ManagedMiner) -> MinerOperatorPresentation {
        MinerOperatorPresentation.resolve(
            for: miner,
            priorityGames: settings.priorityGames(forAccountId: miner.accountId),
            excludedGames: settings.excludedGames(forAccountId: miner.accountId),
            strategy: settings.miningStrategy,
            includesBadgeAndEmoteCampaigns: settings.enableBadgesEmotes,
            ignoredAccountLinkGameIds: settings.activeIgnoredWarnings
                .filter { $0.hasPrefix("\(miner.accountId):") && $0.hasSuffix(":accountLink") }
                .compactMap { $0.components(separatedBy: ":").dropFirst().first }
        )
    }

    /// The picture shown in the miner header, from that account's selected
    /// service. Discord selections automatically fall back to Twitch; callers
    /// draw the initial when neither provider has a usable picture yet.
    private func avatarURL(for miner: MinerManager.ManagedMiner) -> URL? {
        settings.avatarSource(forAccountId: miner.accountId).resolve(
            discord: discordAvatarURL(for: miner),
            twitch: twitchAvatars.url(forAccountId: miner.accountId)
        )
    }

    /// Discord avatar for the account this miner is linked to. Resolved from
    /// the SwiftBot user cache, which only holds anything once
    /// `refreshDiscordDisplayNames()` has run.
    private func discordAvatarURL(for miner: MinerManager.ManagedMiner) -> URL? {
        guard let discordId = miner.ownerDiscordId else { return nil }
        return navigation.discordUsersById[discordId]?.avatarURL
    }

    private func refreshTwitchAvatars() async {
        twitchAvatars.pruneEntries(keepingAccountIds: Set(miners.map(\.accountId)))
        await twitchAvatars.refreshIfNeeded(
            miners: miners,
            manager: navigation.minerManager
        )
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
        navigation.reconnectTwitchAccount(for: miner.id)
    }

    private func restartMiner(for miner: MinerManager.ManagedMiner) {
        Task {
            await navigation.minerManager.stopMiner(minerId: miner.id)
            try? await navigation.minerManager.startMiner(
                minerId: miner.id,
                priorityGames: settings.priorityGames(forAccountId: miner.accountId),
                excludedGames: settings.excludedGames(forAccountId: miner.accountId),
                strategy: settings.miningStrategy,
                enableBadgesEmotes: settings.enableBadgesEmotes,
                showClaimNotifications: settings.showClaimNotifications,
                avoidDuplicateStreams: settings.avoidDuplicateStreams,
                antiStallRecoveryEnabled: settings.antiStallRecoveryEnabled,
                prioritiseFollowedStreamers: settings.prioritiseFollowedStreamers,
                failoverStreamers: settings.gameFailoverStreamers
            )
            await refreshSelectedActivitySummary(for: miner.id)
        }
    }

    /// Refreshes only the selected miner. This leaves every other miner's
    /// engine, channel and Twitch request budget untouched.
    private func refreshMiner(_ miner: MinerManager.ManagedMiner) {
        guard miner.isRunning, !isRefreshingSelectedMiner else { return }

        Task {
            isRefreshingSelectedMiner = true
            defer { isRefreshingSelectedMiner = false }

            await navigation.minerManager.forceRefreshMiner(minerId: miner.id)
            await navigation.minerManager.dataCoordinator.refreshMiner(minerId: miner.id)
            await refreshSelectedActivitySummary(for: miner.id)
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

    private func minerRecoveryDiagnosticsSection(for miner: MinerManager.ManagedMiner) -> some View {
        let snapshot = MinerHealthSnapshot.make(miner: miner)
        let presentation = MinerRecoveryDiagnosticsPresentation.make(
            miner: miner,
            snapshot: snapshot
        )
        let events = diagnosticEvents(for: miner)

        return TahoeSection("Status") {
            VStack(spacing: 0) {
                if presentation.isCompact {
                    CompactMinerStatusView(
                        presentation: presentation,
                        events: events,
                        isExpanded: $recoveryHistoryExpanded
                    )
                } else {
                    RecoveryDiagnosticsStatusHeader(presentation: presentation)

                    Divider()
                        .padding(.horizontal, 14)

                    RecoveryDiagnosticsSignalStrip(signals: presentation.signals)

                    Divider()
                        .padding(.horizontal, 14)

                    RecoveryDiagnosticsHistory(
                        events: events,
                        isExpanded: $recoveryHistoryExpanded
                    )
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func minerAttentionSection(
        for miner: MinerManager.ManagedMiner,
        attention: MinerAttentionIssue
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text("Needs attention")
                    .font(.headline)
                Spacer()
            }

            Text(attention.title)
                .font(.subheadline.weight(.semibold))

            Text(attention.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            VStack(alignment: .leading, spacing: 3) {
                Text("What to do")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(attention.recommendation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                if let action = attention.action {
                    Button(action.title) {
                        switch action {
                        case .reconnect:
                            startLinkAccountFlow(for: miner)
                        case .restart:
                            restartMiner(for: miner)
                        case .openTwitchDrops:
                            openTwitchDropsInventory()
                        }
                    }
                    .tahoeButtonStyle()
                }

                let dmKey = "attention:\(miner.id):\(attention.title)"
                ReminderDMButton(
                    state: reminderDMStates[dmKey] ?? .idle,
                    isAvailable: canSendReminderDM(to: miner),
                    unavailableReason: reminderDMUnavailableReason(for: miner)
                ) {
                    sendReminderDM(
                        attention.dmRequest(
                            miner: miner,
                            priorityGames: settings.priorityGames(forAccountId: miner.accountId),
                            portal: portalLink
                        ),
                        to: miner,
                        key: dmKey
                    )
                }

                // Only the campaign reminders offer this — see `MinerAttentionIssue.Dismissal`.
                // It writes the same per-account mute the Pending row's Dismiss does, so the
                // banner and the list cannot disagree about whether an item is silenced, and
                // the item stays in Pending with a "Remind me" button to undo it.
                if let dismissal = attention.dismissal {
                    Button("Dismiss") {
                        dismissAttention(dismissal, for: miner)
                    }
                    .tahoeButtonStyle()
                    .accessibilityHint("Stops this reminder for this miner. Restore it from the Pending list.")
                }
            }
        }
        .padding(16)
        .tahoeCard(tint: .red.opacity(0.08))
        .accessibilityElement(children: .contain)
    }

    private func dismissAttention(
        _ dismissal: MinerAttentionIssue.Dismissal,
        for miner: MinerManager.ManagedMiner
    ) {
        switch dismissal {
        case let .accountLink(gameId, gameName):
            setLinkReminder(false, for: miner, gameId: gameId, gameName: gameName)
        case let .subscriptionRequired(campaignId):
            settings.setIgnoreSubscriptionRequiredWarnings(
                true,
                for: miner.accountId,
                campaignId: campaignId
            )
        }
    }

    private func diagnosticEvents(for miner: MinerManager.ManagedMiner) -> [MinerDiagnosticEvent] {
        let structuredEvents = (selectedActivitySummary?.minerId == miner.id
            ? selectedActivitySummary?.recentEvents
            : nil
        )?.map {
            MinerDiagnosticEvent(event: $0)
        } ?? []
        let logEvents = navigation.events
            .lazy
            .filter { $0.minerId == miner.id }
            .prefix(5)
            .map { MinerDiagnosticEvent(event: $0) }

        return (structuredEvents + logEvents)
            .sorted { $0.date > $1.date }
    }

    private func liveActivityAnchor(for miner: MinerManager.ManagedMiner) -> Date? {
        guard miner.isRunning, !miner.needsAuth, !miner.isStalled, miner.isHealthy else { return nil }
        guard miner.status == .watching else { return nil }
        return miner.statusChangedAt
    }

    // MARK: - Priorities

    private func miningType(for miner: MinerManager.ManagedMiner) -> (title: String, symbol: String) {
        switch settings.prioritySource(forAccountId: miner.accountId) {
        case .global:
            return ("Global", "globe")
        case .globalAndPersonal:
            return ("Global + Personal", "point.3.connected.trianglepath.dotted")
        case .personal:
            return ("Personal", "person")
        }
    }

    private func resetPrioritiesToGlobal(for miner: MinerManager.ManagedMiner) {
        Task {
            _ = await navigation.resetPrioritiesToGlobal(forAccountId: miner.accountId)
        }
    }

    @ViewBuilder
    private func pendingItemsSection(for miner: MinerManager.ManagedMiner, campaigns: [Campaign]) -> some View {
        let items = pendingItems(for: miner, campaigns: campaigns)
        let activeCount = items.filter { !$0.isMuted }.count

        if !items.isEmpty {
            // The count tracks items still needing attention, so it's dropped
            // rather than shown as "0" when every listed item is muted.
            TahoeSection("Pending", count: activeCount > 0 ? activeCount : nil) {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        PendingItemRow(
                            item: item,
                            onResolve: { openTwitchDropsInventory() },
                            dmState: reminderDMStates[item.id] ?? .idle,
                            canSendDM: canSendReminderDM(to: miner),
                            dmUnavailableReason: reminderDMUnavailableReason(for: miner),
                            reminderNote: reminderNote(for: item, miner: miner),
                            onSendDM: {
                                sendReminderDM(
                                    item.dmRequest(
                                        miner: miner,
                                        priorityGames: settings.priorityGames(forAccountId: miner.accountId),
                                        portal: portalLink
                                    ),
                                    to: miner,
                                    key: item.id
                                )
                            }
                        ) {
                            togglePendingMute(item)
                        }

                        if index < items.count - 1 {
                            TahoeRowDivider(leadingInset: 44)
                        }
                    }
                }
            }
        }
    }

    private func pendingItems(for miner: MinerManager.ManagedMiner, campaigns: [Campaign]) -> [PendingItem] {
        var items: [PendingItem] = []

        // Every item below is derived from campaign data, so none of it is
        // trustworthy while that data is the launch-time disk seed. Matches the
        // badge rule in MinerAttention.hasPendingAttention.
        guard !miner.campaignsAreProvisional else { return items }

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

    private func openTwitchDropsInventory() {
        guard let url = URL(string: "https://www.twitch.tv/drops/inventory") else { return }
        openURL(url)
    }

    /// Discord's line on one pending item: when its reminder last went out, or
    /// that the automatic one is switched off. Silent when this miner has no
    /// Discord link, where neither statement would mean anything.
    private func reminderNote(
        for item: PendingItem,
        miner: MinerManager.ManagedMiner
    ) -> PendingReminderNote? {
        guard canSendReminderDM(to: miner) else { return nil }
        if let sentAt = reminderDeliveries[item.id] { return .sent(sentAt) }
        guard !automaticRemindersEnabled(for: item) else { return nil }
        return .automaticRemindersOff
    }

    private func automaticRemindersEnabled(for item: PendingItem) -> Bool {
        switch item.reminderMessageType {
        case .prioritisedGameNeedsLinking: return settings.dmLinkRequiredEnabled
        case .accountActionRequired: return settings.dmAccountActionRequiredEnabled
        default: return true
        }
    }

    /// Deep-link builder for the portal, or nil when no public URL is set.
    /// A manual reminder then carries no portal button, same as an automatic one.
    private var portalLink: SwiftMinerPortalLink? {
        SwiftMinerPortalLink(base: NavigationModel.portalBase())
    }

    private func canSendReminderDM(to miner: MinerManager.ManagedMiner) -> Bool {
        settings.swiftBotEnabled && miner.ownerDiscordId != nil
    }

    private func reminderDMUnavailableReason(for miner: MinerManager.ManagedMiner) -> String {
        if miner.ownerDiscordId == nil {
            return "Link this miner to a Discord user before sending a DM."
        }
        return "Enable the Discord integration before sending a DM."
    }

    private func sendReminderDM(
        _ request: SwiftBotDMRequest,
        to miner: MinerManager.ManagedMiner,
        key: String
    ) {
        guard let discordId = miner.ownerDiscordId, settings.swiftBotEnabled else { return }
        reminderDMStates[key] = .sending

        Task {
            let sent = await navigation.swiftBotConnectionService.sendEventDM(
                to: discordId,
                request: request
            )
            reminderDMStates[key] = sent ? .sent : .failed
            if sent {
                await refreshReminderDeliveries(for: miner)
            }
        }
    }

    /// Matches this miner's logged DM payloads back onto its pending items, so
    /// a row can say when its own reminder last went out. Only successful sends
    /// reach the log, so a match means the DM was delivered.
    private func refreshReminderDeliveries(for miner: MinerManager.ManagedMiner) async {
        guard settings.swiftBotEnabled, let discordId = miner.ownerDiscordId else {
            reminderDeliveries = [:]
            return
        }

        let payloads = await navigation.dmLogStore.recentProductionPayloads(
            forDiscordId: discordId,
            limit: 50
        )
        guard !payloads.isEmpty else {
            reminderDeliveries = [:]
            return
        }

        // Payloads arrive newest-first, so the first match is the latest send.
        var deliveries: [String: Date] = [:]
        for item in pendingItems(for: miner, campaigns: miner.allCampaigns) {
            if let match = payloads.first(where: { item.matchesReminder($0.request) }) {
                deliveries[item.id] = match.sentAt
            }
        }
        reminderDeliveries = deliveries
    }

    @ViewBuilder
    private func minerCampaignQueueSection(
        for miner: MinerManager.ManagedMiner,
        presentation: MinerOperatorPresentation
    ) -> some View {
        TahoeSection("Campaign queue", count: presentation.queue.count) {
            if presentation.queue.isEmpty {
                NoActiveCampaignsRow()
            } else {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        Text("Order").frame(width: 56, alignment: .leading)
                        Text("Campaign").frame(maxWidth: .infinity, alignment: .leading)
                        Text("Status").frame(width: 150, alignment: .leading)
                        Text("Progress").frame(width: 250, alignment: .leading)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.top, 11)
                    .padding(.bottom, 8)

                    ForEach(Array(presentation.queue.enumerated()), id: \.element.id) { index, entry in
                        MinerCampaignQueueRow(entry: entry)

                        if index < presentation.queue.count - 1 {
                            TahoeRowDivider(leadingInset: 76)
                        }
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    private func activePrioritisedCampaigns(for miner: MinerManager.ManagedMiner) -> [Campaign] {
        let configuredPriorityGames = settings.priorityGames(forAccountId: miner.accountId)
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
        previousLinkIssuesById = linkIssuesById(prioritisedLinkIssues(includeIgnored: true))
        hasCapturedInitialLinkIssues = true
    }

    private func handleLinkIssueSignatureChange(from oldValue: String, to newValue: String) {
        let currentIssues = prioritisedLinkIssues(includeIgnored: true)
        let currentById = linkIssuesById(currentIssues)

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
        // An account that was removed and re-added can briefly be represented by
        // two miner snapshots during startup. Keep one issue per stable issue ID;
        // Dictionary(uniqueKeysWithValues:) traps on this otherwise recoverable
        // duplicate and prevents the app from launching.
        let issues = miners.flatMap { prioritisedLinkIssues(for: $0, includeIgnored: includeIgnored) }
        return linkIssuesById(issues)
            .values
            .sorted {
                if $0.isIgnored != $1.isIgnored { return !$0.isIgnored }
                if $0.minerName != $1.minerName {
                    return $0.minerName.localizedCaseInsensitiveCompare($1.minerName) == .orderedAscending
                }
                return $0.gameName.localizedCaseInsensitiveCompare($1.gameName) == .orderedAscending
            }
    }

    private func linkIssuesById(_ issues: [PrioritisedLinkIssue]) -> [String: PrioritisedLinkIssue] {
        Dictionary(issues.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func prioritisedLinkIssues(for miner: MinerManager.ManagedMiner, includeIgnored: Bool) -> [PrioritisedLinkIssue] {
        let grouped = Dictionary(grouping: activePrioritisedCampaigns(for: miner)) { campaign in
            warningGameId(for: campaign)
        }

        return grouped.compactMap { gameId, campaigns in
            // Tests the link directly rather than going through `activityStatus`.
            // That status is single-valued and returns `.watching` for the miner's
            // current campaign before it ever reaches the link check, so filtering
            // on `.requiresLink` silently dropped the warning for the one campaign
            // actively accruing watch time toward an undeliverable reward.
            let blockedCampaigns = campaigns.filter { !$0.isAccountConnected }
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
                isIgnored: isIgnored,
                // Only when nothing is left to earn anywhere in the group, so a
                // group with one unclaimed campaign keeps the stronger wording.
                awaitingDelivery: blockedCampaigns.allSatisfy(\.isFullyComplete)
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
