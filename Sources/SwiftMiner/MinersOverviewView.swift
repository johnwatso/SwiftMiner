import SwiftUI
import SwiftMinerCore
import TipKit

/// Execution layer overview - scalable multi-miner workspace.
struct MinersOverviewView: View {
    @Environment(NavigationModel.self) private var navigation
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
    @State private var isShowingGameManagement = false

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
            // Populates the Discord user cache the header avatar reads from.
            // Only worth a request when a miner is actually Discord-linked, and
            // detached so an unreachable SwiftBot burns its 5s timeout off to
            // the side rather than inside this task.
            if settings.swiftBotEnabled, miners.contains(where: { $0.ownerDiscordId != nil }) {
                Task { await navigation.refreshDiscordDisplayNames() }
            }
            // Twitch pictures come from a per-account lookup, so this is detached
            // for the same reason and re-checked at most once a day per miner.
            Task { await refreshTwitchAvatars() }
        }
        .onChange(of: settings.minerAvatarSource) { _, _ in
            // Switching to Twitch can need pictures the Discord-only pass skipped.
            Task { await refreshTwitchAvatars() }
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
        .sheet(isPresented: $isShowingGameManagement) {
            GamePreferenceManagementView(
                settings: settings,
                minerManager: navigation.minerManager
            )
        }
    }

    // Tahoe source lists are plain: no enclosing box, no inter-row rules — the
    // selection pill alone carries the structure.
    private var minerListPane: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(Array(miners.enumerated()), id: \.element.id) { index, miner in
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
            let queueCampaigns = presentation.queue.map(\.campaign)
            let health = MinerHealthSnapshot.make(miner: miner)

            ScrollView {
                // Lazy, matching the Drops feed: sections below the fold (the
                // campaign queue's artwork rows in particular) aren't built
                // until they're scrolled to.
                LazyVStack(alignment: .leading, spacing: TahoeMetrics.sectionSpacing) {
                    MinerOperatorHeader(
                        miner: miner,
                        health: health,
                        avatarURL: avatarURL(for: miner),
                        menu: AnyView(
                            HStack(spacing: 8) {
                                if miner.needsAuth || miner.status == .blockedAccountNotLinked {
                                    Button {
                                        startLinkAccountFlow(for: miner)
                                    } label: {
                                        Label("Reconnect", systemImage: "personalhotspot")
                                    }
                                    .tahoeButtonStyle()
                                    .controlSize(.small)
                                }

                                Menu {
                                    minerContextMenu(for: miner)
                                } label: {
                                    Image(systemName: "ellipsis")
                                        .frame(width: 26, height: 22)
                                }
                                .menuStyle(.borderlessButton)
                                .help("Miner actions")
                                .accessibilityLabel("Miner actions")
                            }
                        )
                    )

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

                    pendingItemsSection(for: miner, campaigns: queueCampaigns)

                    minerCampaignQueueSection(for: miner, presentation: presentation)

                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 16) {
                            minerHealthSummarySection(for: miner)
                                .frame(minWidth: 300, maxWidth: .infinity, alignment: .topLeading)
                            minerPrioritiesSection(for: miner)
                                .frame(minWidth: 300, maxWidth: .infinity, alignment: .topLeading)
                        }

                        VStack(alignment: .leading, spacing: TahoeMetrics.sectionSpacing) {
                            minerHealthSummarySection(for: miner)
                            minerPrioritiesSection(for: miner)
                        }
                    }

                    minerRecoveryHistorySection(for: miner)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
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

    private func operatorPresentation(for miner: MinerManager.ManagedMiner) -> MinerOperatorPresentation {
        MinerOperatorPresentation.resolve(
            for: miner,
            priorityGames: settings.priorityGames(forAccountId: miner.accountId),
            excludedGames: settings.excludedGames,
            strategy: settings.miningStrategy,
            includesBadgeAndEmoteCampaigns: settings.enableBadgesEmotes,
            ignoredAccountLinkGameIds: settings.activeIgnoredWarnings
                .filter { $0.hasPrefix("\(miner.accountId):") && $0.hasSuffix(":accountLink") }
                .compactMap { $0.components(separatedBy: ":").dropFirst().first }
        )
    }

    /// The picture shown in the miner header, from whichever service the
    /// Appearance setting prefers — falling back to the other one, and to the
    /// initial when neither has anything yet.
    private func avatarURL(for miner: MinerManager.ManagedMiner) -> URL? {
        settings.minerAvatarSource.resolve(
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

    /// Miners whose Twitch picture is worth a lookup: all of them when Twitch is
    /// the chosen source, otherwise only the ones with no Discord picture to show,
    /// so an all-Discord setup spends nothing on requests it will never draw.
    private var minersNeedingTwitchAvatar: [MinerManager.ManagedMiner] {
        guard settings.minerAvatarSource == .discord else { return miners }
        return miners.filter { discordAvatarURL(for: $0) == nil }
    }

    private func refreshTwitchAvatars() async {
        twitchAvatars.pruneEntries(keepingAccountIds: Set(miners.map(\.accountId)))
        await twitchAvatars.refreshIfNeeded(
            miners: minersNeedingTwitchAvatar,
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

    private func minerHealthSummarySection(for miner: MinerManager.ManagedMiner) -> some View {
        let snapshot = MinerHealthSnapshot.make(miner: miner)

        return TahoeSection("Miner health") {
            VStack(spacing: 0) {
                healthCheckRow(
                    title: "Connected to Twitch",
                    status: miner.needsAuth ? "Reconnect" : (miner.isRunning ? "OK" : "Stopped"),
                    date: snapshot.lastEventAt,
                    isHealthy: miner.isRunning && !miner.needsAuth
                )
                TahoeRowDivider(leadingInset: 39)
                healthCheckRow(
                    title: "Campaign inventory",
                    status: snapshot.lastCampaignRefreshAt == nil ? "Waiting" : "OK",
                    date: snapshot.lastCampaignRefreshAt,
                    isHealthy: snapshot.lastCampaignRefreshAt != nil
                )
                TahoeRowDivider(leadingInset: 39)
                healthCheckRow(
                    title: "Progress detection",
                    status: miner.isNotEarning() ? "No progress" : "OK",
                    date: snapshot.lastDropProgressAt ?? snapshot.lastSuccessfulPollAt,
                    isHealthy: !miner.isNotEarning()
                )
            }
        }
    }

    private func healthCheckRow(
        title: String,
        status: String,
        date: Date?,
        isHealthy: Bool
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: isHealthy ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isHealthy ? .green : .orange)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 15)

            Text(title)
                .font(.subheadline)
                .lineLimit(1)

            Spacer(minLength: 8)

            // Both trailing values sit in fixed columns. Previously the status
            // was free-width, so it slid sideways whenever the relative time
            // grew ("29 secs" vs "1 min, 33 secs"), and rows carrying no
            // timestamp pushed their status out to the row edge.
            Text(status)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(isHealthy ? .green : .orange)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(width: 96, alignment: .trailing)

            Group {
                if let date {
                    Text(date, style: .relative)
                } else {
                    Text("—")
                }
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .frame(width: 92, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func minerRecoveryHistorySection(for miner: MinerManager.ManagedMiner) -> some View {
        let logEvents = navigation.events.filter { $0.minerId == miner.id }.prefix(5)
        let recentEventCount = (selectedActivitySummary?.recentEvents.count ?? 0) + logEvents.count

        return DisclosureGroup(isExpanded: $recoveryHistoryExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                if selectedActivitySummary?.recentEvents.isEmpty != false && logEvents.isEmpty {
                    Text("No recent recovery or diagnostic events for this miner.")
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
            .padding(.top, 12)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "clock.arrow.circlepath")
                    .foregroundStyle(.secondary)

                Text("Recovery & diagnostics")
                    .font(.subheadline.weight(.semibold))

                Text(recentEventCount == 0 ? "No recent events" : "\(recentEventCount) recent")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 4)
            }
            .contentShape(Rectangle())
        }
        .padding(14)
        .tahoeCard()
    }

    private func liveActivityAnchor(for miner: MinerManager.ManagedMiner) -> Date? {
        guard miner.isRunning, !miner.needsAuth, !miner.isStalled, miner.isHealthy else { return nil }
        guard miner.status == .watching else { return nil }
        return miner.statusChangedAt
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
        return TahoeSection("Priority queue") {
            Button {
                isShowingGameManagement = true
            } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tahoeButtonStyle()
            .controlSize(.small)

            if hasMultipleMiners {
                Toggle("Use global", isOn: Binding(
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
        } content: {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("This miner")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)

                    if personal.isEmpty {
                        Text("No personal priorities — add them from the dashboard or Discord.")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(personal.enumerated()), id: \.element) { index, game in
                                HStack(spacing: 9) {
                                    Text("\(index + 1)")
                                        .font(.caption.weight(.semibold).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 20, height: 20)
                                        .background(.quaternary, in: Circle())
                                    Text(game)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                    Spacer()
                                    Button {
                                        removePersonalPriority(game, from: miner)
                                    } label: {
                                        Image(systemName: "xmark.circle")
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                    .help("Remove \(game) from this miner")
                                }
                                .padding(.vertical, 7)

                                if index < personal.count - 1 { Divider() }
                            }
                        }
                        .padding(.horizontal, 10)
                        .tahoeCard(cornerRadius: TahoeMetrics.nested)
                    }
                }

                if includesGlobal {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Global queue")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        if global.isEmpty {
                            Text(settings.priorityGames.isEmpty
                                ? "The global list is empty."
                                : "All global games are already covered by this miner's own list.")
                                .font(.callout)
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
            .padding(14)
        }
    }

    private func removePersonalPriority(_ gameName: String, from miner: MinerManager.ManagedMiner) {
        let updated = settings.deprioritiseGameForAccount(accountId: miner.accountId, gameName: gameName)
        navigation.minerManager.updatePriorityGames(updated, forMinerId: miner.id)
        if miner.isRunning {
            Task { await navigation.minerManager.forceRefreshMiner(minerId: miner.id) }
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
                        PendingItemRow(item: item) {
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
                        let gameId = warningGameId(for: entry.campaign)
                        let isIgnored = settings.isIgnoringAccountLinkWarnings(
                            for: miner.accountId,
                            gameId: gameId
                        )

                        MinerCampaignQueueRow(
                            entry: entry,
                            isWarningIgnored: isIgnored,
                            onDismissWarning: {
                                setLinkReminder(false, for: miner, gameId: gameId, gameName: entry.campaign.game.name)
                            },
                            onRemindWarning: {
                                setLinkReminder(true, for: miner, gameId: gameId, gameName: entry.campaign.game.name)
                            }
                        )

                        if index < presentation.queue.count - 1 {
                            TahoeRowDivider(leadingInset: 76)
                        }
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    @ViewBuilder
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

}
