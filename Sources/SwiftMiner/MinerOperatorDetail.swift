import SwiftUI
import SwiftMinerCore

struct MinerCampaignProgress: Equatable {
    let currentMinutes: Int
    let requiredMinutes: Int

    var fraction: Double {
        guard requiredMinutes > 0 else { return 0 }
        return min(1, max(0, Double(currentMinutes) / Double(requiredMinutes)))
    }

    var percent: Int {
        Int((fraction * 100).rounded())
    }
}

struct MinerCampaignQueueEntry: Identifiable {
    let campaign: Campaign
    let position: Int
    let status: CampaignActivityStatus
    let progress: MinerCampaignProgress?

    var id: String { campaign.id }
}

struct MinerOperatorPresentation {
    let snapshot: MinerActivitySnapshot
    let queue: [MinerCampaignQueueEntry]

    var currentCampaign: Campaign? {
        guard let campaignId = snapshot.now.campaignId else { return nil }
        return queue.first(where: { $0.campaign.id == campaignId })?.campaign
    }

    var currentProgress: MinerCampaignProgress? {
        guard let campaignId = snapshot.now.campaignId else { return nil }
        return queue.first(where: { $0.campaign.id == campaignId })?.progress
    }

    var nextCampaign: Campaign? {
        guard let campaignId = snapshot.upNext?.campaignId else { return nil }
        return queue.first(where: { $0.campaign.id == campaignId })?.campaign
    }

    var thenCampaigns: [Campaign] {
        let excludedIds = Set([snapshot.now.campaignId, snapshot.upNext?.campaignId].compactMap { $0 })
        return queue.lazy
            .map(\.campaign)
            .filter { !excludedIds.contains($0.id) }
            .prefix(2)
            .map { $0 }
    }

    @MainActor
    static func resolve(
        for miner: MinerManager.ManagedMiner,
        priorityGames: [String],
        excludedGames: [String],
        strategy: MiningStrategy,
        includesBadgeAndEmoteCampaigns: Bool,
        ignoredAccountLinkGameIds: [String] = [],
        now: Date = Date()
    ) -> MinerOperatorPresentation {
        let snapshot = MinerActivitySnapshot.resolve(
            for: miner,
            priorityGames: priorityGames,
            excludedGames: excludedGames,
            strategy: strategy,
            includesBadgeAndEmoteCampaigns: includesBadgeAndEmoteCampaigns,
            ignoredAccountLinkGameIds: ignoredAccountLinkGameIds
        )

        let effectivePriorities = miner.priorityGames.isEmpty ? priorityGames : miner.priorityGames
        let priorityKeys = effectivePriorities.map(normalizedKey).filter { !$0.isEmpty }
        let prioritySet = Set(priorityKeys)
        let excludedSet = Set(excludedGames.map(normalizedKey).filter { !$0.isEmpty })
        let recentEndCutoff = now.addingTimeInterval(-24 * 60 * 60)

        var campaigns = miner.allCampaigns.filter { campaign in
            guard campaign.status != .disabled, !campaign.isLikelyInternalTestCampaign else { return false }
            if campaign.id != snapshot.now.campaignId {
                let gameId = normalizedKey(campaign.game.id)
                let gameName = normalizedKey(campaign.game.name)
                let isPriority = prioritySet.contains(gameId) || prioritySet.contains(gameName)
                guard !excludedSet.contains(gameId), !excludedSet.contains(gameName) else { return false }
                guard includesBadgeAndEmoteCampaigns || !campaign.hasOnlyBadgesOrEmotes else { return false }

                if strategy == .onlyPriority {
                    guard isPriority else { return false }
                } else if !isPriority {
                    // Match the engine's eligibility rule: an unlinked campaign is only
                    // attemptable when its game is explicitly prioritised for this miner.
                    guard campaign.isAccountConnected,
                          campaign.isTimeActive,
                          campaign.canAttemptMining,
                          !campaign.drops.isEmpty,
                          !campaign.drops.allSatisfy(\.isClaimed) else { return false }
                }
            }

            let status = campaign.activityStatus(for: miner)
            return status != .expired || campaign.endDate >= recentEndCutoff
        }

        campaigns.sort { lhs, rhs in
            let leftCurrent = lhs.id == snapshot.now.campaignId
            let rightCurrent = rhs.id == snapshot.now.campaignId
            if leftCurrent != rightCurrent { return leftCurrent }

            let leftNext = lhs.id == snapshot.upNext?.campaignId
            let rightNext = rhs.id == snapshot.upNext?.campaignId
            if leftNext != rightNext { return leftNext }

            let leftStatus = statusRank(lhs.activityStatus(for: miner))
            let rightStatus = statusRank(rhs.activityStatus(for: miner))
            if leftStatus != rightStatus { return leftStatus < rightStatus }

            let leftPriority = priorityIndex(for: lhs, keys: priorityKeys)
            let rightPriority = priorityIndex(for: rhs, keys: priorityKeys)
            switch strategy {
            case .mineAll:
                if lhs.endDate != rhs.endDate { return lhs.endDate < rhs.endDate }
                if leftPriority != rightPriority { return leftPriority < rightPriority }
            case .prioritiseSelected, .onlyPriority:
                let leftIsPriority = leftPriority != Int.max
                let rightIsPriority = rightPriority != Int.max
                if leftIsPriority != rightIsPriority { return leftIsPriority }
                if leftPriority != rightPriority { return leftPriority < rightPriority }
                if lhs.endDate != rhs.endDate { return lhs.endDate < rhs.endDate }
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        let queue = campaigns.enumerated().map { index, campaign in
            MinerCampaignQueueEntry(
                campaign: campaign,
                position: index + 1,
                status: campaign.activityStatus(for: miner),
                progress: aggregateProgress(for: campaign, miner: miner)
            )
        }

        return MinerOperatorPresentation(snapshot: snapshot, queue: queue)
    }

    @MainActor
    static func aggregateProgress(
        for campaign: Campaign,
        miner: MinerManager.ManagedMiner
    ) -> MinerCampaignProgress? {
        let timedDrops = campaign.drops.filter { $0.requiredMinutes > 0 }
        guard !timedDrops.isEmpty else { return nil }

        let states = Dictionary(
            uniqueKeysWithValues: (miner.stateStore?.dropStates ?? []).map { ($0.dropId, $0) }
        )

        var current = 0
        var required = 0
        for drop in timedDrops {
            let state = states[drop.id]
            let requiredMinutes = max(
                drop.requiredMinutes,
                max(state?.requiredMinutes ?? 0, drop.progress?.requiredMinutes ?? 0)
            )
            let observedMinutes = max(state?.progressMinutes ?? 0, drop.progress?.currentMinutes ?? 0)
            required += requiredMinutes
            current += drop.isClaimed ? requiredMinutes : min(requiredMinutes, max(0, observedMinutes))
        }

        return MinerCampaignProgress(currentMinutes: current, requiredMinutes: required)
    }

    private static func normalizedKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func priorityIndex(for campaign: Campaign, keys: [String]) -> Int {
        let gameId = normalizedKey(campaign.game.id)
        let gameName = normalizedKey(campaign.game.name)
        return keys.firstIndex { $0 == gameId || $0 == gameName } ?? Int.max
    }

    private static func statusRank(_ status: CampaignActivityStatus) -> Int {
        switch status {
        case .watching: return 0
        case .waitingForStream: return 1
        case .requiresLink: return 2
        case .requiresSubscription: return 3
        case .upcoming: return 4
        case .completed: return 5
        case .expired: return 6
        }
    }
}

struct MinerOperatorHeader: View {
    let miner: MinerManager.ManagedMiner
    let health: MinerHealthSnapshot
    /// Avatar of the Discord account this miner is linked to, when there is
    /// one. Falls back to the initial when the miner is unlinked or SwiftBot
    /// hasn't resolved the user yet.
    var discordAvatarURL: URL?
    let menu: AnyView

    var body: some View {
        HStack(spacing: 14) {
            CachedDiscordAvatar(url: discordAvatarURL) {
                initialAvatar
            }
            .frame(width: 46, height: 46)
            .clipShape(Circle())
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(miner.displayName)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)

                Label(connectionLabel, systemImage: connectionSymbol)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(connectionTint)
            }

            Spacer(minLength: 18)

            ViewThatFits(in: .horizontal) {
                statusCluster(showsLabels: true)
                statusCluster(showsLabels: false)
            }

            menu
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .tahoeRaisedSurface(cornerRadius: TahoeMetrics.card)
        .accessibilityElement(children: .contain)
    }

    private var initialAvatar: some View {
        Circle()
            .fill(Color.accentColor.gradient)
            .overlay {
                Text(initial)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
            }
    }

    private var initial: String {
        String(miner.displayName.trimmingCharacters(in: .whitespacesAndNewlines).first ?? "?").uppercased()
    }

    /// The three operational metrics as one grouped cluster of equal-width
    /// cells. Drops the labels — not the cells — when the window is too narrow,
    /// so the grouping survives at every width.
    private func statusCluster(showsLabels: Bool) -> some View {
        HStack(spacing: 0) {
            MinerStatusCell(
                label: "Uptime",
                systemImage: "clock",
                showsLabel: showsLabels
            ) {
                if let started = miner.workerStartedAt, miner.isRunning {
                    RelativeDurationText(startDate: started)
                } else {
                    Text("—")
                }
            }

            cellDivider

            MinerStatusCell(
                label: "Last Poll",
                systemImage: "clock.arrow.circlepath",
                showsLabel: showsLabels
            ) {
                if let date = health.lastSuccessfulPollAt {
                    Text(date, style: .relative)
                } else {
                    Text("Not yet")
                }
            }

            cellDivider

            MinerStatusCell(
                label: "Health",
                systemImage: healthSymbol,
                iconTint: healthTint,
                showsLabel: showsLabels
            ) {
                Text(healthTitle)
                    .foregroundStyle(healthTint)
            }
        }
        .frame(height: showsLabels ? 44 : 34)
        .background(
            .background.secondary,
            in: RoundedRectangle(cornerRadius: TahoeMetrics.nested, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: TahoeMetrics.nested, style: .continuous)
                .strokeBorder(.separator.opacity(0.22), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
    }

    private var cellDivider: some View {
        Divider().frame(height: 22)
    }

    /// The miner's actual health verdict — deliberately *not* `statusLabel`,
    /// which describes current mining activity ("Watching <game>") and belongs
    /// to the sequence card, not here.
    private var healthTitle: String {
        switch health.health {
        case .mining: return "Healthy"
        case .idle: return "Idle"
        case .recovering: return "Recovering"
        case .attention: return "Attention"
        case .stalled: return "Unresponsive"
        case .needsAuth: return "Auth needed"
        case .blocked: return "Blocked"
        }
    }

    private var healthSymbol: String {
        switch health.health {
        case .mining: return "checkmark.circle.fill"
        case .idle: return "pause.circle.fill"
        case .recovering: return "arrow.triangle.2.circlepath.circle.fill"
        case .attention: return "exclamationmark.circle.fill"
        case .stalled: return "exclamationmark.triangle.fill"
        case .needsAuth: return "person.crop.circle.badge.exclamationmark.fill"
        case .blocked: return "xmark.circle.fill"
        }
    }

    private var connectionLabel: String {
        if !miner.isRunning { return "Stopped" }
        if miner.needsAuth { return "Needs authentication" }
        if miner.isStalled { return "Unresponsive" }
        if !miner.isHealthy { return "Attention" }
        return "Online"
    }

    private var connectionSymbol: String {
        miner.isRunning && miner.isHealthy && !miner.needsAuth ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
    }

    private var connectionTint: Color {
        miner.isRunning && miner.isHealthy && !miner.needsAuth ? .green : .orange
    }

    private var healthTint: Color {
        switch health.health {
        case .mining: return .green
        case .recovering: return .blue
        case .attention: return .orange
        case .stalled, .needsAuth, .blocked: return .red
        case .idle: return .secondary
        }
    }
}

/// One cell of the header status cluster: a leading symbol, a small uppercase
/// label, and the value beneath it. Fixed width so the three cells stay equal
/// regardless of how long any single value renders.
private struct MinerStatusCell<Content: View>: View {
    let label: String
    let systemImage: String
    var iconTint: Color = .secondary
    var showsLabel: Bool = true
    @ViewBuilder let content: Content

    init(
        label: String,
        systemImage: String,
        iconTint: Color = .secondary,
        showsLabel: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.label = label
        self.systemImage = systemImage
        self.iconTint = iconTint
        self.showsLabel = showsLabel
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(iconTint)
                .frame(width: 15)

            VStack(alignment: .leading, spacing: 1) {
                if showsLabel {
                    Text(label.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .kerning(0.5)
                        .foregroundStyle(.secondary)
                }

                content
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .frame(width: showsLabel ? 118 : 96)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(label)
    }
}

private struct RelativeDurationText: View {
    let startDate: Date

    var body: some View {
        // The format only resolves to hours and minutes, so a 1s tick bought
        // nothing but a header rebuild every second.
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(Self.format(context.date.timeIntervalSince(startDate)))
        }
    }

    static func format(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

struct MinerMiningSequenceView: View {
    let miner: MinerManager.ManagedMiner
    let presentation: MinerOperatorPresentation
    let channelName: String?

    /// Width of the "Currently mining" and "Up next" artwork. They're peer
    /// columns, so both use it; height is driven by the row instead. "Then" is
    /// a compact secondary list and stays small and square.
    private static let leadArtworkWidth: CGFloat = 76

    var body: some View {
        ViewThatFits(in: .horizontal) {
            // Every column is stretched to the tallest one's height, which then
            // flows down to the artwork — so the two lead thumbnails end up the
            // same height as each other and as tall as the text beside them.
            HStack(alignment: .top, spacing: 0) {
                nowColumn.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                separator
                nextColumn.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                separator
                thenColumn.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 16) {
                nowColumn
                Divider()
                nextColumn
                Divider()
                thenColumn
            }
        }
        .padding(18)
        .tahoeCard(tint: Color.accentColor.opacity(0.05))
        .accessibilityElement(children: .contain)
    }

    private var separator: some View {
        Divider().padding(.horizontal, 18)
    }

    private var nowColumn: some View {
        SequenceColumn(title: "Currently mining") {
            HStack(alignment: .top, spacing: 12) {
                CampaignArtworkThumbnail(
                    url: presentation.currentCampaign?.game.boxArtURL,
                    symbol: presentation.snapshot.now.symbol,
                    size: Self.leadArtworkWidth,
                    fillsHeight: true
                )
                VStack(alignment: .leading, spacing: 5) {
                    Text(presentation.snapshot.now.title)
                        .font(.headline)
                        .lineLimit(2)
                    if let subtitle = presentation.snapshot.now.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    if let progress = presentation.currentProgress {
                        AnimatedLinearProgressView(value: progress.fraction, tint: .green)
                        HStack {
                            Text("\(progress.currentMinutes) / \(progress.requiredMinutes) minutes watched")
                            Spacer(minLength: 8)
                            Text("\(progress.percent)%")
                                .fontWeight(.semibold)
                        }
                        .font(.caption)
                        .monospacedDigit()
                    } else if let detail = presentation.snapshot.now.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    channelLine
                }
            }
        }
    }

    @ViewBuilder private var channelLine: some View {
        if let channelName, !channelName.isEmpty, miner.status == .watching {
            Label("Watching \(channelName)", systemImage: "play.tv.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
                .lineLimit(1)
        }
    }

    private var nextColumn: some View {
        SequenceColumn(title: "Up next") {
            if let item = presentation.snapshot.upNext {
                HStack(alignment: .top, spacing: 12) {
                    CampaignArtworkThumbnail(
                        url: presentation.nextCampaign?.game.boxArtURL,
                        symbol: item.symbol,
                        size: Self.leadArtworkWidth,
                        fillsHeight: true
                    )
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                        if let subtitle = item.subtitle {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                        if let detail = item.detail {
                            Label(detail, systemImage: item.symbol)
                                .font(.caption)
                                .foregroundStyle(item.accent)
                                .lineLimit(2)
                        }
                    }
                }
            } else {
                Label("Nothing queued", systemImage: "checkmark.circle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var thenColumn: some View {
        SequenceColumn(title: "Then") {
            if presentation.thenCampaigns.isEmpty {
                Text("No further campaigns")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(presentation.thenCampaigns) { campaign in
                        HStack(spacing: 9) {
                            CampaignArtworkThumbnail(url: campaign.game.boxArtURL, symbol: "gamecontroller.fill", size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(campaign.game.name).font(.caption.weight(.semibold)).lineLimit(1)
                                Text(campaign.name).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct SequenceColumn<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            // Absorbs any height the column was stretched to, passing it down
            // to artwork that asked to fill.
            content
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

struct CampaignArtworkThumbnail: View {
    let url: URL?
    let symbol: String
    let size: CGFloat
    /// When true the artwork stretches to the height of its row rather than
    /// staying square, so the text beside it doesn't overhang the image.
    /// `size` then means width only, and `size` is the floor on height.
    var fillsHeight: Bool = false

    private var cornerRadius: CGFloat {
        min(14, size * 0.24)
    }

    var body: some View {
        CampaignCardArtwork(url: url, tint: .accentColor)
            .frame(width: size)
            .frame(minHeight: size, maxHeight: fillsHeight ? .infinity : size)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                if url == nil {
                    Image(systemName: symbol)
                        .font(.system(size: size * 0.3, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
    }
}

struct MinerCampaignQueueRow: View {
    let entry: MinerCampaignQueueEntry
    let isWarningIgnored: Bool
    let onDismissWarning: () -> Void
    let onRemindWarning: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Text("\(entry.position)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(.quaternary, in: Circle())

            Image(systemName: statusSymbol)
                .font(.system(size: 12, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(statusTint)
                .frame(width: 18)

            CampaignArtworkThumbnail(url: entry.campaign.game.boxArtURL, symbol: "gamecontroller.fill", size: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.campaign.game.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(entry.campaign.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            statusView
                .frame(width: 150, alignment: .leading)

            infoView
                .frame(width: 250, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var statusView: some View {
        if entry.status == .requiresLink {
            Button {
                isWarningIgnored ? onRemindWarning() : onDismissWarning()
            } label: {
                Label(isWarningIgnored ? "Remind me" : "Dismiss", systemImage: isWarningIgnored ? "bell" : "bell.slash")
            }
            .tahoeButtonStyle()
            .controlSize(.small)
        } else {
            Text(statusLabel)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(statusTint)
                .lineLimit(1)
        }
    }

    @ViewBuilder private var infoView: some View {
        switch entry.status {
        case .watching:
            progressView
        case .completed:
            Text("All timed drops completed")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .upcoming:
            VStack(alignment: .leading, spacing: 2) {
                Text(relativeStartLabel)
                    .font(.caption.weight(.medium))
                Text(entry.campaign.startDate, format: .dateTime.weekday(.abbreviated).hour().minute())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .expired:
            Text("Ended \(entry.campaign.endDate.formatted(.relative(presentation: .named)))")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .waitingForStream:
            Text("No eligible channels live")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .requiresLink:
            Text("Link the game account on Twitch")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .requiresSubscription:
            Text("A paid Twitch subscription is required")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var progressView: some View {
        if let progress = entry.progress {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("\(progress.currentMinutes) / \(progress.requiredMinutes) min")
                    Spacer(minLength: 8)
                    Text("\(progress.percent)%")
                        .foregroundStyle(.secondary)
                }
                .font(.caption.monospacedDigit())
                AnimatedLinearProgressView(value: progress.fraction, tint: .green)
            }
        } else {
            Text("Watching eligible stream")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var relativeStartLabel: String {
        "Starts \(entry.campaign.startDate.formatted(.relative(presentation: .numeric)))"
    }

    private var statusLabel: String {
        switch entry.status {
        case .watching: return "Watching"
        case .waitingForStream: return "Waiting"
        case .requiresLink: return "Needs setup"
        case .requiresSubscription: return "Subscription"
        case .completed: return "Completed"
        case .upcoming: return "Upcoming"
        case .expired: return "Ended"
        }
    }

    private var statusSymbol: String {
        switch entry.status {
        case .watching: return "play.fill"
        case .waitingForStream: return "antenna.radiowaves.left.and.right"
        case .requiresLink: return "personalhotspot.slash"
        case .requiresSubscription: return "creditcard"
        case .completed: return "checkmark"
        case .upcoming: return "calendar"
        case .expired: return "clock.badge.xmark"
        }
    }

    private var statusTint: Color {
        switch entry.status {
        case .watching, .completed: return .green
        case .waitingForStream: return .cyan
        case .requiresLink, .upcoming: return .orange
        case .requiresSubscription: return .pink
        case .expired: return .secondary
        }
    }
}
