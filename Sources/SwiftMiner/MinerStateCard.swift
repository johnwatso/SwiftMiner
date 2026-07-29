import SwiftUI
import SwiftMinerCore

/// A unified hero card that represents the resolved PrimaryState of a miner.
/// Replaces legacy status badges and scattered state labels with a single story.
struct MinerStateCard: View {
    let miner: MinerManager.ManagedMiner
    var activityCampaigns: [Campaign] = []
    var onAction: (() -> Void)? = nil
    var onDismiss: ((String) -> Void)? = nil

    private var state: PrimaryState { miner.primaryState }
    private var resolved: ResolvedPrimaryState? { miner.resolvedPrimaryState }
    private var firstActivityCampaign: Campaign? { activityCampaigns.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            headerSection

            if case .mining(let progress) = state {
                miningProgressSection(progress)
            } else if case .overriding(_, .some(let progress)) = state {
                miningProgressSection(progress)
            } else if case .blocked(let reasons) = state, reasons.contains(.accountNotLinked) {
                let gameId = resolved?.resolved?.gameId ?? "all"
                actionSection(
                    title: "Action required",
                    subtitle: "Connect your game account to resume earning drops.",
                    buttonTitle: "Link Account",
                    secondaryButtonTitle: "Dismiss",
                    onSecondaryAction: {
                        onDismiss?(gameId)
                    }
                )
            }
        }
        .padding(22)
        .glassCard()
        .shadow(color: .black.opacity(0.07), radius: 6, y: 2)
    }

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 16) {
            AnimatedStatusIcon(symbol: config.icon, color: config.color, size: 44, weight: .bold)

            VStack(alignment: .leading, spacing: 4) {
                Text(config.headline)
                    .font(.title3.weight(.bold))

                if let subtitle = config.subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()
        }
    }

    private func miningProgressSection(_ progress: MiningProgress) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(progress.dropName)
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Text("\(Int(progress.progressFraction * 100))%")
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.green)
            }

            AnimatedLinearProgressView(value: progress.progressFraction, tint: .green)

            HStack {
                Text("\(progress.campaignName)")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if progress.minutesRemaining > 0 {
                    Text("\(progress.minutesRemaining) min remaining")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Ready to claim!")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: GlassRadius.small, style: .continuous))
    }

    private func actionSection(
        title: String,
        subtitle: String,
        buttonTitle: String,
        secondaryButtonTitle: String? = nil,
        onSecondaryAction: (() -> Void)? = nil
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let secondaryTitle = secondaryButtonTitle {
                Button {
                    onSecondaryAction?()
                } label: {
                    Text(secondaryTitle)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Button {
                onAction?()
            } label: {
                Text(buttonTitle)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(.orange)
        }
        .padding(14)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: GlassRadius.small, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: GlassRadius.small, style: .continuous)
                .strokeBorder(.orange.opacity(0.2), lineWidth: 1)
        }
    }

    // MARK: - View Config

    private var config: StateConfig {
        let gameName = resolved?.resolved?.gameName
        if miner.workerState.isRecovering {
            return StateConfig(
                headline: "Recovering...",
                subtitle: "Restarting this miner and restoring Twitch subscriptions.",
                icon: "wrench.and.screwdriver.fill",
                color: .orange
            )
        }

        if miner.isStalled {
            return StateConfig(
                headline: "Miner Unresponsive",
                subtitle: "This miner is not receiving Twitch activity while other miners continue polling.",
                icon: "bolt.horizontal.circle.fill",
                color: .red
            )
        }

        if miner.showsNoRecentActivityAttention {
            return StateConfig(
                headline: "No Recent Activity",
                subtitle: "The worker is running, but liveness signals have gone quiet.",
                icon: "clock.badge.exclamationmark",
                color: .yellow
            )
        }

        if !miner.isRunning {
            if miner.status == .authenticating {
                return StateConfig(
                    headline: "Starting...",
                    subtitle: "Preparing this miner and connecting to Twitch.",
                    icon: "arrow.triangle.2.circlepath",
                    color: .orange
                )
            }
            return StateConfig(
                headline: "Stopped",
                subtitle: "Start this miner to check for and earn drops.",
                icon: "stop.circle.fill",
                color: .secondary
            )
        }

        if miner.status == .fetchingCampaigns {
            return StateConfig(
                headline: "Updating…",
                subtitle: "Checking campaigns and drop progress.",
                icon: "arrow.clockwise",
                color: .blue
            )
        }

        switch state {
        case .blocked(let reasons):
            if reasons.contains(.accountNotLinked) {
                return StateConfig(
                    headline: "Blocked — Account not linked",
                    subtitle: gameName ?? "Link your account to earn drops.",
                    icon: "personalhotspot.slash",
                    color: .orange
                )
            } else if reasons.contains(.noEligibleCampaign) {
                if let campaign = firstActivityCampaign {
                    return StateConfig(
                        headline: campaign.game.name,
                        subtitle: campaign.activityStatus(for: miner).label,
                        icon: "calendar.badge.checkmark",
                        color: .green
                    )
                }

                return StateConfig(
                    headline: "Up to Date",
                    subtitle: "No drops available for prioritised games.",
                    icon: "calendar.badge.checkmark",
                    color: .green
                )
            } else {
                return StateConfig(
                    headline: "Looking for Streams",
                    subtitle: gameName ?? "No participating channels are live right now.",
                    icon: "antenna.radiowaves.left.and.right",
                    color: .cyan
                )
            }

        case .ready:
            if let campaign = firstActivityCampaign {
                return StateConfig(
                    headline: "Looking for Streams",
                    subtitle: campaign.game.name,
                    icon: "antenna.radiowaves.left.and.right",
                    color: .cyan
                )
            }

            return StateConfig(
                headline: "Up to Date",
                subtitle: "No drops available for prioritised games",
                icon: "calendar.badge.checkmark",
                color: .green
            )

        case .mining(let progress):
            return StateConfig(
                headline: "Watching \(progress.gameName)",
                subtitle: nil,
                icon: "dot.radiowaves.left.and.right",
                color: .green
            )

        case .completed:
            if let campaign = firstActivityCampaign {
                return StateConfig(
                    headline: "All Rewards Completed",
                    subtitle: campaign.game.name,
                    icon: "calendar.badge.checkmark",
                    color: .green
                )
            }

            return StateConfig(
                headline: "All Rewards Completed",
                subtitle: "All currently available drops are completed.",
                icon: "calendar.badge.checkmark",
                color: .green
            )

        case .overriding(let login, let progress):
            if let progress {
                return StateConfig(
                    headline: "Watching \(progress.gameName)",
                    subtitle: "Stream override · @\(login)",
                    icon: "person.fill.viewfinder",
                    color: .indigo
                )
            }

            return StateConfig(
                headline: "Watching @\(login)",
                subtitle: "Stream override active — until they go offline.",
                icon: "person.fill.viewfinder",
                color: .indigo
            )
        }
    }

    private struct StateConfig {
        let headline: String
        let subtitle: String?
        let icon: String
        let color: Color
    }
}

// MARK: - Per-Miner Activity Card

enum MinerActivityCardProminence {
    case compact
    case expanded
}

struct MinerActivityCard: View {
    let miner: MinerManager.ManagedMiner
    var prominence: MinerActivityCardProminence = .compact
    var onSelect: (() -> Void)? = nil
    var onEditNickname: (() -> Void)? = nil
    var onClearNickname: (() -> Void)? = nil
    var onOverrideStream: (() -> Void)? = nil
    var onClearStreamOverride: (() -> Void)? = nil

    @Environment(NavigationModel.self) private var navigation
    private var settings: Settings { .shared }
    @State private var activityRefreshPulse = Date()
    @State private var streamOverrideEditor: MinerStreamOverridePresentation?
    @State private var nicknameEditor: MinerNicknameEditorPresentation?

    private var snapshot: MinerActivitySnapshot {
        _ = activityRefreshPulse
        return MinerActivitySnapshot.resolve(
            for: miner,
            priorityGames: settings.priorityGames,
            excludedGames: settings.excludedGames,
            strategy: settings.miningStrategy,
            includesBadgeAndEmoteCampaigns: settings.enableBadgesEmotes,
            ignoredAccountLinkGameIds: settings.activeIgnoredWarnings
                .filter { $0.hasPrefix("\(miner.accountId):") && $0.hasSuffix(":accountLink") }
                .compactMap { $0.components(separatedBy: ":").dropFirst().first }
        )
    }

    private var isExpanded: Bool {
        prominence == .expanded
    }

    /// Returns the accent colour only when coloured icons/status are enabled,
    /// otherwise falls back to `.secondary` for a monochrome look.
    private func effectiveAccent(_ color: Color) -> Color {
        settings.coloredStatusIcons ? color : .secondary
    }

    var body: some View {
        // Resolve the activity snapshot once per render. `MinerActivitySnapshot.resolve`
        // is expensive and was previously recomputed on every access (~10+ times per
        // render, multiplied by every miner card on screen).
        let snap = snapshot
        return VStack(alignment: .leading, spacing: isExpanded ? 14 : 12) {
            header(snap: snap)

            VStack(alignment: .leading, spacing: isExpanded ? 7 : 10) {
                ActivityLabel("Current Status", color: .secondary)
                currentActivity(snap: snap)
            }

            Divider()
                .opacity(0.45)

            VStack(alignment: .leading, spacing: 6) {
                ActivityLabel("Up Next", color: .secondary)
                if let next = snap.upNext {
                    nextActivity(next)
                } else {
                    emptyNextActivity
                }
            }
            .opacity(0.82)

            if prominence == .expanded, !snap.blockedPriority.isEmpty {
                Divider()
                    .opacity(0.6)

                blockedPriorityList(snap: snap)
            }
        }
        .padding(isExpanded ? 18 : 16)
        .frame(
            maxWidth: .infinity,
            minHeight: prominence == .compact ? 264 : nil,
            maxHeight: prominence == .compact ? 264 : nil,
            alignment: .topLeading
        )
        .glassCard()
        .contentShape(RoundedRectangle(cornerRadius: GlassRadius.medium, style: .continuous))
        .onTapGesture {
            onSelect?()
        }
        .contextMenu {
            minerContextMenu
        }
        .task(id: miner.id) {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15 * 1_000_000_000)
                activityRefreshPulse = Date()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(miner.displayName), now mining \(snap.now.title)")
        .sheet(item: $streamOverrideEditor) { presentation in
            MinerStreamOverrideSheet(miner: presentation.miner, navigation: navigation)
        }
        .sheet(item: $nicknameEditor) { presentation in
            MinerNicknameEditorSheet(miner: presentation.miner, navigation: navigation)
        }
    }

    private func header(snap: MinerActivitySnapshot) -> some View {
        HStack(alignment: .center, spacing: 8) {
            AnimatedStatusIcon(symbol: snap.now.symbol, color: snap.now.accent, size: 17, weight: .medium)

            Text(miner.displayName)
                .font(.title3.weight(.semibold))
                .lineLimit(1)

            Spacer(minLength: 8)
        }
    }

    @ViewBuilder
    private var minerContextMenu: some View {
        Button(action: handleOverrideStream) {
            Label("Override Stream...", systemImage: "person.fill.viewfinder")
        }

        if miner.streamOverrideLogin != nil {
            Button(action: handleClearStreamOverride) {
                Label("Stop Stream Override", systemImage: "xmark.circle")
            }
        }

        Button(action: handleEditNickname) {
            Label(miner.nickname == nil ? "Add Nickname" : "Edit Nickname", systemImage: "pencil")
        }

        if miner.nickname != nil {
            Button(action: handleClearNickname) {
                Label("Clear Nickname", systemImage: "xmark.circle")
            }
        }
    }

    private func handleOverrideStream() {
        if let onOverrideStream {
            onOverrideStream()
        } else {
            streamOverrideEditor = MinerStreamOverridePresentation(miner: miner)
        }
    }

    private func handleClearStreamOverride() {
        if let onClearStreamOverride {
            onClearStreamOverride()
        } else {
            Task { await navigation.minerManager.clearStreamOverride(minerId: miner.id) }
        }
    }

    private func handleEditNickname() {
        if let onEditNickname {
            onEditNickname()
        } else {
            nicknameEditor = MinerNicknameEditorPresentation(miner: miner)
        }
    }

    private func handleClearNickname() {
        if let onClearNickname {
            onClearNickname()
        } else {
            Task { await navigation.minerManager.updateMinerNickname(minerId: miner.id, nickname: nil) }
        }
    }

    private func currentActivity(snap: MinerActivitySnapshot) -> some View {
        VStack(alignment: .leading, spacing: isExpanded ? 4 : 6) {
            Text(snap.now.title)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if let subtitle = snap.now.subtitle {
                Text(subtitle)
                    .font(isExpanded ? .callout : .subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let progress = snap.now.progressFraction {
                AnimatedLinearProgressView(value: progress, tint: effectiveAccent(snap.now.accent))
                    .padding(.top, isExpanded ? 0 : 2)
            }

            if let detail = snap.now.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(isExpanded ? 1 : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // A known drop already shows cumulative watched time across every source.
            // Keep the session-only stopwatch for pure watch overrides, where no drop total exists.
            if snap.now.progressFraction == nil, let anchor = liveActivityAnchor {
                MinerLiveActivityTimerView(
                    anchor: anchor,
                    accent: effectiveAccent(snap.now.accent)
                )
            }
        }
    }

    /// When the miner is actively watching a stream, the timestamp the live timer counts from.
    /// `statusChangedAt` only moves on a real status transition, so it tracks the current watch
    /// session. Returns nil unless the miner is genuinely watching — searching for a stream,
    /// fetching campaigns, idle, blocked, paused, or unresponsive all hide the timer.
    private var liveActivityAnchor: Date? {
        guard miner.isRunning, !miner.needsAuth, !miner.isStalled, miner.isHealthy else { return nil }
        guard miner.status == .watching else { return nil }
        return miner.statusChangedAt
    }

    private func nextActivity(_ item: MinerActivityItem) -> some View {
        HStack(alignment: .top, spacing: 9) {
            AnimatedStatusIcon(symbol: item.symbol, color: item.accent, size: 9, weight: .semibold)
                .frame(width: 16, height: 16)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)

                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if prominence == .expanded, let detail = item.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)
        }
    }

    private var emptyNextActivity: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "clock")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 18, height: 18)

            Text("No likely follow-up yet")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer(minLength: 6)
        }
    }

    private func blockedPriorityList(snap: MinerActivitySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ActivityLabel("Needs Linking", color: .orange)

            ForEach(snap.blockedPriority) { item in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: item.symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(effectiveAccent(item.accent))
                        .frame(width: 18, height: 18)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)

                        Text(item.subtitle ?? "Account not linked")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 6)
                }
            }
        }
    }

}

private struct ActivityLabel: View {
    let text: String
    let color: Color

    init(_ text: String, color: Color) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
    }
}

struct AnimatedLinearProgressView: View {
    let value: Double
    let tint: Color
    var duration: Double = 0.65

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedValue: Double

    init(value: Double, tint: Color, duration: Double = 0.65) {
        self.value = value
        self.tint = tint
        self.duration = duration
        // Seed at the true value so the bar renders where it actually is on the
        // first frame. Previously it reset to 0 and swept up on every appear,
        // which looked like the bar re-filling each time the Overview was shown
        // or refreshed — and masked the small, live incremental steps.
        _displayedValue = State(initialValue: min(1, max(0, value)))
    }

    private var clampedValue: Double {
        min(1, max(0, value))
    }

    var body: some View {
        ProgressView(value: displayedValue)
            .progressViewStyle(.linear)
            .tint(tint)
            .onChange(of: clampedValue) { _, newValue in
                // Animate only genuine progress changes, not the initial render.
                guard !reduceMotion else {
                    displayedValue = newValue
                    return
                }

                withAnimation(.easeInOut(duration: duration)) {
                    displayedValue = newValue
                }
            }
    }
}

struct MinerActivitySnapshot {
    let now: MinerActivityItem
    let upNext: MinerActivityItem?
    let blockedPriority: [MinerActivityItem]
    let statusText: String
    let statusColor: Color
    let statusSymbol: String

    /// True only when the snapshot represents an actual watch session. A
    /// campaign ID can also be attached to waiting or blocked status items, so
    /// it is not sufficient evidence that the miner is currently watching.
    var isActivelyWatching: Bool {
        now.id.hasPrefix("now-") || now.id.hasPrefix("override-")
    }

    var currentSectionTitle: String {
        if now.id.hasPrefix("now-") {
            return "Currently mining"
        }
        if now.id.hasPrefix("override-") {
            return "Currently watching"
        }
        return "Current status"
    }

    var sourceListActivityLabel: String {
        if isActivelyWatching {
            return "Watching \(now.title)"
        }
        if statusText == "Up to Date", let upNext {
            return "Likely next: \(upNext.title)"
        }
        return statusText
    }

    @MainActor
    static func resolve(
        for miner: MinerManager.ManagedMiner,
        priorityGames: [String],
        excludedGames: [String],
        strategy: MiningStrategy,
        includesBadgeAndEmoteCampaigns: Bool,
        ignoredAccountLinkGameIds: [String] = []
    ) -> MinerActivitySnapshot {
        let currentCampaign = currentCampaign(for: miner)
        
        let activePriorityGames = miner.priorityGames.isEmpty ? priorityGames : miner.priorityGames
        let now = currentActivityItem(
            for: miner,
            campaign: currentCampaign,
            priorityGames: activePriorityGames,
            excludedGames: excludedGames,
            strategy: strategy,
            includesBadgeAndEmoteCampaigns: includesBadgeAndEmoteCampaigns
        )

        let next = likelyNextItem(
            for: miner,
            excludingCampaignId: currentCampaign?.id ?? miner.currentCampaignId,
            priorityGames: activePriorityGames,
            excludedGames: excludedGames,
            strategy: strategy,
            includesBadgeAndEmoteCampaigns: includesBadgeAndEmoteCampaigns
        )
        
        let blocked = blockedPriorityItems(
            for: miner,
            // A stale current ID for an unlinked campaign must not suppress its
            // separate Pending reminder; it is no longer current scheduling work.
            excludingCampaignId: currentCampaign?.isAccountConnected == true
                ? (currentCampaign?.id ?? miner.currentCampaignId)
                : nil,
            priorityGames: activePriorityGames,
            excludedGames: excludedGames,
            strategy: strategy,
            includesBadgeAndEmoteCampaigns: includesBadgeAndEmoteCampaigns,
            ignoredAccountLinkGameIds: ignoredAccountLinkGameIds
        )

        return MinerActivitySnapshot(
            now: now,
            upNext: next,
            blockedPriority: blocked,
            statusText: statusText(for: miner, now: now),
            statusColor: statusColor(for: miner, now: now),
            statusSymbol: statusSymbol(for: miner, now: now)
        )
    }

    @MainActor
    private static func currentCampaign(for miner: MinerManager.ManagedMiner) -> Campaign? {
        if let campaignId = miner.currentCampaignId,
           let campaign = miner.allCampaigns.first(where: { $0.id == campaignId }) {
            return campaign
        }

        guard let campaignName = miner.currentCampaign else {
            return nil
        }

        return miner.allCampaigns.first { campaign in
            campaign.name == campaignName
        }
    }

    @MainActor
    private static func currentActivityItem(
        for miner: MinerManager.ManagedMiner,
        campaign: Campaign?,
        priorityGames: [String],
        excludedGames: [String],
        strategy: MiningStrategy,
        includesBadgeAndEmoteCampaigns: Bool
    ) -> MinerActivityItem {
        if miner.workerState.isRecovering {
            return waitingItem(
                id: "recovering-\(miner.id)",
                title: "Recovering...",
                subtitle: "Restarting this miner and rebuilding its Twitch worker pipeline.",
                symbol: "wrench.and.screwdriver.fill",
                accent: .orange
            )
        }

        if miner.isStalled {
            return waitingItem(
                id: "stalled-\(miner.id)",
                title: "Miner Unresponsive",
                subtitle: "This miner stopped receiving Twitch activity while other miners are still active.",
                symbol: "bolt.horizontal.circle.fill",
                accent: .red
            )
        }

        if miner.showsNoRecentActivityAttention {
            return waitingItem(
                id: "quiet-\(miner.id)",
                title: "No Recent Activity",
                subtitle: "Worker is running, but it has not reported recent liveness yet.",
                symbol: "clock.badge.exclamationmark",
                accent: .yellow
            )
        }

        if !miner.isRunning {
            if miner.status == .authenticating {
                return waitingItem(
                    id: "starting-\(miner.id)",
                    title: "Starting...",
                    subtitle: "Preparing this miner and connecting to Twitch.",
                    symbol: "arrow.triangle.2.circlepath",
                    accent: .orange
                )
            }
            return waitingItem(
                id: "stopped-\(miner.id)",
                title: "Stopped",
                subtitle: "Start this miner to check for and earn drops.",
                symbol: "stop.circle.fill",
                accent: .secondary
            )
        }

        // Stream override pins this miner to one streamer until they go offline.
        if let overrideLogin = miner.streamOverrideLogin, miner.isRunning {
            if let campaign, hasUnclaimedDrop(in: campaign) {
                let progress = activeDropProgress(for: campaign, miner: miner)
                let detail = progress.map { item in
                    watchedTimeDetail(for: item)
                } ?? "Watching this streamer for drops"

                return MinerActivityItem(
                    id: "override-\(miner.id)",
                    title: campaign.game.name,
                    subtitle: "Stream override · @\(overrideLogin)",
                    detail: detail,
                    symbol: "person.fill.viewfinder",
                    accent: .indigo,
                    progressFraction: progress?.fraction,
                    campaignId: campaign.id
                )
            }

            return MinerActivityItem(
                id: "override-\(miner.id)",
                title: "@\(overrideLogin)",
                subtitle: "Stream override active",
                detail: "Watching until the stream goes offline.",
                symbol: "person.fill.viewfinder",
                accent: .indigo
            )
        }

        if miner.status == .watching, let campaign, hasUnclaimedDrop(in: campaign) {
            let progress = activeDropProgress(for: campaign, miner: miner)
            let detail = progress.map { item in
                watchedTimeDetail(for: item)
            } ?? "Tracking eligible stream progress"

            return MinerActivityItem(
                id: "now-\(campaign.id)",
                title: campaign.game.name,
                subtitle: campaign.name,
                detail: detail,
                symbol: "play.fill",
                accent: .green,
                progressFraction: progress?.fraction,
                campaignId: campaign.id
            )
        }

        if miner.status == .claiming, let campaign {
            return MinerActivityItem(
                id: "claiming-\(campaign.id)",
                title: campaign.game.name,
                subtitle: campaign.name,
                detail: "Claiming completed reward",
                symbol: "gift.fill",
                accent: .purple,
                campaignId: campaign.id
            )
        }

        if miner.needsAuth {
            return MinerActivityItem(
                id: "needs-auth-\(miner.id)",
                title: "Blocked — Authentication expired",
                subtitle: "Reconnect account to resume mining.",
                detail: nil,
                symbol: "person.crop.circle.badge.exclamationmark",
                accent: .orange,
                requiresAccountLink: true
            )
        }

        // Refresh status takes precedence over cached campaign state. Otherwise a previous
        // no-drops snapshot can briefly present as "Up to Date" while launch hydration is
        // still determining the current answer.
        if miner.status == .fetchingCampaigns {
            return waitingItem(
                id: "fetch-\(miner.id)",
                title: "Updating…",
                subtitle: "Checking campaigns and drop progress.",
                symbol: "arrow.clockwise",
                accent: .blue
            )
        }

        if let resolved = miner.resolvedPrimaryState?.resolved {
            switch resolved.state {
            case .blocked:
                if resolved.reason == .notLinked {
                    return upToDateItem(
                        id: "unlinked-\(miner.id)-\(resolved.gameId)",
                        subtitle: "Unlinked campaigns are not included in this miner's queue."
                    )
                }
                return blockedCurrentItem(for: miner, resolved: resolved)
            case .idle:
                if resolved.reason == .noDropsAvailable {
                    // The resolver only inspects prioritised games. If the engine
                    // is actively waiting for a stream on a non-prioritised but
                    // linked game, prefer that live status over the stale
                    // "no drops available" summary derived from priorities.
                    if miner.status != .waitingForStream {
                        return MinerActivityItem(
                            id: "waiting-drops-\(miner.id)-\(resolved.gameId)",
                            title: "Up to Date",
                            subtitle: "No active drops are available for this account.",
                            detail: nil,
                            symbol: "calendar.badge.checkmark",
                            accent: .green
                        )
                    }
                }
            case .watching:
                break
            }
        }

        switch miner.status {
        case .authenticating:
            return waitingItem(
                id: "auth-\(miner.id)",
                title: "Reconnecting",
                subtitle: "Reconnecting account...",
                symbol: "arrow.triangle.2.circlepath",
                accent: .orange
            )
        case .fetchingCampaigns:
            return waitingItem(
                id: "fetch-\(miner.id)",
                title: "Updating…",
                subtitle: "Checking campaigns and drop progress.",
                symbol: "arrow.clockwise",
                accent: .blue
            )
        case .waitingForStream:
            // Subscription-gated campaigns are never scheduled, so they must not
            // stand in for the miner's real state here. They stay visible as a
            // mutable Pending item on the miner instead.
            return waitingItem(
                id: "stream-\(miner.id)",
                title: "Looking for Streams",
                subtitle: "Waiting for an eligible live stream.",
                symbol: "antenna.radiowaves.left.and.right",
                accent: .cyan
            )
        case .blockedAccountNotLinked:
            return upToDateItem(
                id: "unlinked-\(miner.id)",
                subtitle: "Unlinked campaigns are not included in this miner's queue."
            )
        case .idleNoEligibleCampaigns:
            return waitingItem(
                id: "idle-\(miner.id)",
                title: "Up to Date",
                subtitle: "Nothing is available to mine for this account.",
                symbol: "calendar.badge.checkmark",
                accent: .green
            )
        case .error:
            return waitingItem(
                id: "error-\(miner.id)",
                title: "Blocked — Needs attention",
                subtitle: "Check Events for the latest issue.",
                symbol: "exclamationmark.triangle.fill",
                accent: .red
            )
        case .paused:
            return waitingItem(
                id: "paused-\(miner.id)",
                title: "Paused",
                subtitle: "Mining is paused for this account.",
                symbol: "pause.fill",
                accent: .secondary
            )
        case .idle, .watching, .claiming:
            return waitingItem(
                id: "idle-\(miner.id)",
                title: "Up to Date",
                subtitle: "Nothing is available to mine for this account.",
                symbol: "calendar.badge.checkmark",
                accent: .green
            )
        }
    }

    private static func waitingItem(
        id: String,
        title: String,
        subtitle: String,
        symbol: String,
        accent: Color
    ) -> MinerActivityItem {
        MinerActivityItem(
            id: id,
            title: title,
            subtitle: subtitle,
            detail: nil,
            symbol: symbol,
            accent: accent
        )
    }

    private static func upToDateItem(id: String, subtitle: String) -> MinerActivityItem {
        MinerActivityItem(
            id: id,
            title: "Up to Date",
            subtitle: subtitle,
            detail: nil,
            symbol: "calendar.badge.checkmark",
            accent: .green
        )
    }

    private static func blockedCurrentItem(for miner: MinerManager.ManagedMiner, resolved: MinerGameState) -> MinerActivityItem {
        switch resolved.reason {
        case .notLinked:
            return upToDateItem(
                id: "unlinked-\(miner.id)-\(resolved.gameId)",
                subtitle: "Unlinked campaigns are not included in this miner's queue."
            )
        case .noLiveStreams:
            return MinerActivityItem(
                id: "blocked-stream-\(miner.id)-\(resolved.gameId)",
                title: "Looking for Streams",
                subtitle: resolved.gameName,
                detail: "Waiting for an eligible live stream.",
                symbol: "antenna.radiowaves.left.and.right",
                accent: .cyan,
                campaignId: resolved.campaignId
            )
        default:
            return MinerActivityItem(
                id: "blocked-empty-\(miner.id)-\(resolved.gameId)",
                title: "Up to Date",
                subtitle: "No eligible campaign is available for \(resolved.gameName).",
                detail: nil,
                symbol: "checkmark.circle.fill",
                accent: .green,
                campaignId: resolved.campaignId
            )
        }
    }

    private static func hasUnclaimedDrop(in campaign: Campaign) -> Bool {
        campaign.drops.contains { !$0.isClaimed }
    }

    @MainActor
    private static func activeDropProgress(
        for campaign: Campaign,
        miner: MinerManager.ManagedMiner
    ) -> (dropName: String, fraction: Double, currentMinutes: Int, requiredMinutes: Int)? {
        guard let drop = campaign.drops.first(where: { !$0.isClaimed && !$0.isClaimable })
            ?? campaign.drops.first(where: { !$0.isClaimed }) else {
            return nil
        }

        let dropState = miner.stateStore?.dropStates.first { $0.dropId == drop.id }
        let currentMinutes = max(dropState?.progressMinutes ?? 0, drop.progress?.currentMinutes ?? 0)
        let requiredMinutes = max(dropState?.requiredMinutes ?? 0, drop.progress?.requiredMinutes ?? drop.requiredMinutes)
        let dropName = drop.progress?.dropName.isEmpty == false ? drop.progress?.dropName ?? drop.name : drop.name

        guard requiredMinutes > 0 else {
            return (
                dropName: dropName,
                fraction: 0,
                currentMinutes: 0,
                requiredMinutes: 0
            )
        }

        let fraction = min(1.0, max(0.0, Double(currentMinutes) / Double(requiredMinutes)))
        return (
            dropName: dropName,
            fraction: fraction,
            currentMinutes: currentMinutes,
            requiredMinutes: requiredMinutes
        )
    }

    /// Uses Twitch's cumulative per-drop total, reconciled with the miner's persisted ledger.
    /// This is intentionally not tied to the current channel or watch session.
    private static func watchedTimeDetail(
        for progress: (dropName: String, fraction: Double, currentMinutes: Int, requiredMinutes: Int)
    ) -> String {
        guard progress.requiredMinutes > 0 else {
            return "\(progress.dropName) · watching eligible stream"
        }
        let watchedMinutes = min(progress.requiredMinutes, max(0, progress.currentMinutes))
        return "\(progress.dropName) · \(watchedMinutes) / \(progress.requiredMinutes) min watched"
    }

    private static func likelyNextItem(
        for miner: MinerManager.ManagedMiner,
        excludingCampaignId activeCampaignId: String?,
        priorityGames: [String],
        excludedGames: [String],
        strategy: MiningStrategy,
        includesBadgeAndEmoteCampaigns: Bool
    ) -> MinerActivityItem? {
        let priorityKeys = priorityGames.map(normalizedGameKey).filter { !$0.isEmpty }
        let prioritySet = Set(priorityKeys)
        let excludedSet = Set(excludedGames.map(normalizedGameKey).filter { !$0.isEmpty })

        let candidates = miner.allCampaigns.filter { campaign in
            guard campaign.id != activeCampaignId else { return false }
            guard !isSpecialEventsCampaign(campaign) else { return false }
            guard !campaign.drops.isEmpty else { return false }
            guard campaign.isTimeActive, campaign.status != .disabled else { return false }
            guard !campaign.drops.allSatisfy(\.isClaimed) else { return false }

            let gameName = normalizedGameKey(campaign.game.name)
            let gameId = normalizedGameKey(campaign.game.id)
            let isPriority = prioritySet.contains(gameName) || prioritySet.contains(gameId)
            // Match the engine: an unlinked campaign is still schedulable when this miner
            // explicitly prioritises its game. The resulting item carries the link warning
            // rather than disappearing from "Up Next".
            guard campaign.isAccountConnected || isPriority else { return false }
            guard !excludedSet.contains(gameName), !excludedSet.contains(gameId) else { return false }
            guard strategy != .onlyPriority || isPriority else { return false }
            return true
        }

        let eligible = candidates.filter { campaign in
            guard campaign.canAttemptMining else {
                return false
            }
            if !includesBadgeAndEmoteCampaigns && campaign.hasOnlyBadgesOrEmotes {
                return false
            }
            switch campaign.miningStatus {
            case .available, .inProgress, .claimable:
                return true
            case .claimed, .expired:
                return false
            }
        }

        guard let campaign = sortedCandidates(eligible, priorityKeys: priorityKeys, strategy: strategy).first else {
            return nil
        }

        return MinerActivityItem(
            id: "next-\(campaign.id)",
            title: campaign.game.name,
            subtitle: campaign.name,
            detail: likelyNextDetail(
                for: campaign,
                among: eligible,
                priorityKeys: priorityKeys,
                strategy: strategy
            ),
            symbol: "arrow.forward.circle",
            accent: .secondary,
            campaignId: campaign.id,
            requiresAccountLink: !campaign.isAccountConnected
        )
    }

    private static func likelyNextDetail(
        for campaign: Campaign,
        among candidates: [Campaign],
        priorityKeys: [String],
        strategy: MiningStrategy
    ) -> String {
        let selectedPriority = priorityIndex(for: campaign, priorityKeys: priorityKeys)

        switch strategy {
        case .mineAll:
            if selectedPriority == Int.max,
               let prioritised = sortedCandidates(
                   candidates.filter { priorityIndex(for: $0, priorityKeys: priorityKeys) != Int.max },
                   priorityKeys: priorityKeys,
                   strategy: .mineAll
               ).first {
                return "Ends before prioritised \(prioritised.game.name) · Smart strategy"
            }
            return "Earliest-ending eligible campaign · Smart strategy"
        case .prioritiseSelected, .onlyPriority:
            if selectedPriority != Int.max {
                return "Prioritised game #\(selectedPriority + 1)"
            }
            return "Next eligible campaign after prioritised games"
        }
    }

    private static func blockedPriorityItems(
        for miner: MinerManager.ManagedMiner,
        excludingCampaignId activeCampaignId: String?,
        priorityGames: [String],
        excludedGames: [String],
        strategy: MiningStrategy,
        includesBadgeAndEmoteCampaigns: Bool,
        ignoredAccountLinkGameIds: [String]
    ) -> [MinerActivityItem] {
        let priorityKeys = priorityGames.map(normalizedGameKey).filter { !$0.isEmpty }
        let prioritySet = Set(priorityKeys)
        let excludedSet = Set(excludedGames.map(normalizedGameKey).filter { !$0.isEmpty })

        let activePriorityUnlinked = miner.allCampaigns.filter { campaign in
            guard campaign.id != activeCampaignId else { return false }
            guard !isSpecialEventsCampaign(campaign) else { return false }
            guard !campaign.drops.isEmpty else { return false }
            guard campaign.isTimeActive, campaign.status != .disabled else { return false }
            guard !campaign.drops.allSatisfy(\.isClaimed) else { return false }

            let gameName = normalizedGameKey(campaign.game.name)
            let gameId = normalizedGameKey(campaign.game.id)
            
            // 1. Must NOT be excluded
            guard !excludedSet.contains(gameName), !excludedSet.contains(gameId) else { return false }
            
            // 2. Must be prioritized
            guard prioritySet.contains(gameName) || prioritySet.contains(gameId) else { return false }
            
            // 3. Must be UNLINKED
            guard !campaign.isAccountConnected else { return false }
            guard !isAccountLinkWarningIgnored(
                gameId: campaign.game.id,
                gameName: campaign.game.name,
                ignoredAccountLinkGameIds: ignoredAccountLinkGameIds
            ) else { return false }
            
            // 4. Badge/Emote preference
            if !includesBadgeAndEmoteCampaigns && campaign.hasOnlyBadgesOrEmotes {
                return false
            }

            return true
        }

        let sorted = sortedCandidates(activePriorityUnlinked, priorityKeys: priorityKeys, strategy: strategy)
        
        return sorted.map { campaign in
            MinerActivityItem(
                id: "blocked-\(campaign.id)",
                title: campaign.game.name,
                subtitle: campaign.name,
                detail: "Account not linked",
                symbol: "personalhotspot.slash",
                accent: .orange,
                campaignId: campaign.id,
                requiresAccountLink: true
            )
        }
    }

    private static func sortedCandidates(
        _ campaigns: [Campaign],
        priorityKeys: [String],
        strategy: MiningStrategy
    ) -> [Campaign] {
        campaigns.enumerated().sorted { lhs, rhs in
            let left = lhs.element
            let right = rhs.element
            let leftPriority = priorityIndex(for: left, priorityKeys: priorityKeys)
            let rightPriority = priorityIndex(for: right, priorityKeys: priorityKeys)
            let leftIsPriority = leftPriority != Int.max
            let rightIsPriority = rightPriority != Int.max

            switch strategy {
            case .mineAll:
                if left.endDate != right.endDate { return left.endDate < right.endDate }
                if leftIsPriority != rightIsPriority { return leftIsPriority }
                if leftPriority != rightPriority { return leftPriority < rightPriority }
            case .prioritiseSelected, .onlyPriority:
                if leftIsPriority != rightIsPriority { return leftIsPriority }
                if leftPriority != rightPriority { return leftPriority < rightPriority }
                if left.endDate != right.endDate { return left.endDate < right.endDate }
            }

            return lhs.offset < rhs.offset
        }
        .map(\.element)
    }

    private static func priorityIndex(for campaign: Campaign, priorityKeys: [String]) -> Int {
        let gameName = normalizedGameKey(campaign.game.name)
        let gameId = normalizedGameKey(campaign.game.id)
        return priorityKeys.firstIndex { $0 == gameName || $0 == gameId } ?? Int.max
    }

    private static func normalizedGameKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func isSpecialEventsCampaign(_ campaign: Campaign) -> Bool {
        let name = campaign.game.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = campaign.game.id.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.localizedCaseInsensitiveCompare("Just Chatting") == .orderedSame || id == "509658"
    }

    private static func isAccountLinkWarningIgnored(
        gameId: String,
        gameName: String,
        ignoredAccountLinkGameIds: [String]
    ) -> Bool {
        let ignored = Set(ignoredAccountLinkGameIds.map(normalizedGameKey).filter { !$0.isEmpty })
        return ignored.contains("all") ||
            ignored.contains(normalizedGameKey(gameId)) ||
            ignored.contains(normalizedGameKey(gameName))
    }

    @MainActor
    private static func statusText(for miner: MinerManager.ManagedMiner, now: MinerActivityItem) -> String {
        // Precedence lives in MinerPresentedState so this card and `ManagedMiner.statusLabel`
        // cannot drift apart again — they previously resolved independently and contradicted
        // each other. Only the wording is chosen here; the card keeps its own richer phrasing
        // and the few refinements below that depend on the resolved activity item.
        let state = MinerPresentedState.resolve(for: miner)

        // Item-level refinements the canonical state deliberately does not model: these describe
        // *why* there is nothing to do, which only the activity item knows.
        if !state.isOperationalFault {
            if now.id.hasPrefix("starting-") || now.id.hasPrefix("stopped-") {
                return now.title
            }
            if now.id.hasPrefix("waiting-drops-") ||
                now.id.hasPrefix("ignored-link-") ||
                now.id.hasPrefix("unlinked-") {
                return "Up to Date"
            }
        }

        switch state {
        case .recovering:
            return "Recovering..."
        case .unresponsive:
            return "Miner Unresponsive"
        case .noRecentActivity:
            return "No Recent Activity"
        case .notEarning:
            return "Watching — Not Earning"
        case .starting:
            return "Starting..."
        case .stopped:
            return "Stopped"
        case .paused:
            return "Paused"
        case .needsAttention:
            return "Blocked — Needs attention"
        case .reconnecting:
            return "Reconnecting"
        case .updating:
            return "Updating…"
        case .watchingOverride:
            return "Watching \(now.title)"
        case .watching:
            return "Watching \(now.title)"
        case .claiming:
            return "Claiming Rewards"
        case .lookingForStreams:
            return "Looking for Streams"
        case .upToDate:
            return "Up to Date"
        }
    }

    @MainActor
    private static func statusSymbol(for miner: MinerManager.ManagedMiner, now: MinerActivityItem) -> String {
        if miner.workerState.isRecovering {
            return "wrench.and.screwdriver.fill"
        }
        if miner.isStalled {
            return "bolt.horizontal.circle.fill"
        }
        if miner.showsNoRecentActivityAttention {
            return "checkmark.circle.trianglebadge.exclamationmark.fill"
        }
        if now.id.hasPrefix("starting-") || now.id.hasPrefix("stopped-") {
            return now.symbol
        }
        if now.id.hasPrefix("ignored-link-") || now.id.hasPrefix("unlinked-") {
            return "calendar.badge.checkmark"
        }
        if now.id.hasPrefix("override-") {
            return now.symbol
        }
        if now.requiresAccountLink || miner.needsAuth {
            return "exclamationmark.triangle.fill"
        }

        switch miner.status {
        case .watching:
            return "dot.radiowaves.left.and.right"
        case .claiming:
            return "gift.fill"
        case .waitingForStream:
            return "antenna.radiowaves.left.and.right"
        case .fetchingCampaigns:
            return "arrow.clockwise"
        case .authenticating:
            return "arrow.triangle.2.circlepath"
        case .paused:
            return "pause.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        case .idleNoEligibleCampaigns:
            return "calendar.badge.checkmark"
        case .blockedAccountNotLinked:
            return "calendar.badge.checkmark"
        case .idle:
            return "calendar.badge.checkmark"
        }
    }

    @MainActor
    private static func statusColor(for miner: MinerManager.ManagedMiner, now: MinerActivityItem) -> Color {
        if miner.workerState.isRecovering {
            return .orange
        }
        if miner.isStalled {
            return .red
        }
        if miner.showsNoRecentActivityAttention {
            return .yellow
        }
        if now.id.hasPrefix("starting-") || now.id.hasPrefix("stopped-") {
            return now.accent
        }
        if now.id.hasPrefix("ignored-link-") || now.id.hasPrefix("unlinked-") {
            return .green
        }
        if now.id.hasPrefix("override-") {
            return now.accent
        }
        switch miner.status {
        case .watching:
            return .green
        case .claiming:
            return .purple
        case .waitingForStream:
            return .cyan
        case .fetchingCampaigns:
            return .blue
        case .authenticating:
            return .orange
        case .paused:
            return .secondary
        case .error:
            return .red
        case .idleNoEligibleCampaigns:
            return .secondary
        case .blockedAccountNotLinked:
            return .green
        case .idle:
            return now.accent
        }
    }
}

struct MinerActivityItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let detail: String?
    let symbol: String
    let accent: Color
    var progressFraction: Double? = nil
    var campaignId: String? = nil
    var requiresAccountLink: Bool = false
}

/// A shared live-session clock used anywhere miner activity is presented.
/// Drop progress remains Twitch's cumulative verified total; this clock only
/// describes how long the current uninterrupted watch session has been active.
struct MinerLiveActivityTimerView: View {
    let anchor: Date
    let accent: Color
    var label: String? = nil

    var body: some View {
        TimelineView(.periodic(from: anchor, by: 1)) { context in
            let elapsed = max(0, context.date.timeIntervalSince(anchor))
            HStack(spacing: 5) {
                PulsingActivityDot(color: accent)

                Image(systemName: "timer")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)

                if let label {
                    Text(label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(Self.formatElapsed(elapsed))
                    .font(.caption.weight(.medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
            .accessibilityLabel("\(label ?? "Active") for \(Self.formatElapsed(elapsed))")
        }
    }

    static func formatElapsed(_ interval: TimeInterval) -> String {
        let total = Int(interval)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

/// A small dot that gently pulses to signal the miner is alive and working.
private struct PulsingActivityDot: View {
    let color: Color
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .opacity(pulsing ? 0.3 : 1.0)
            .scaleEffect(pulsing ? 0.82 : 1.0)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}
