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

                if progress.progressFraction == 0, progress.minutesRemaining > 0 {
                    Text("Checking progress with Twitch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if progress.minutesRemaining > 0 {
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

        if miner.isRunning && !miner.needsAuth && !miner.isHealthy {
            return StateConfig(
                headline: "No Recent Activity",
                subtitle: "The worker is running, but liveness signals have gone quiet.",
                icon: "clock.badge.exclamationmark",
                color: .yellow
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
    var onLinkAccount: (() -> Void)? = nil
    var onEditNickname: (() -> Void)? = nil
    var onClearNickname: (() -> Void)? = nil
    var onOverrideStream: (() -> Void)? = nil
    var onClearStreamOverride: (() -> Void)? = nil

    @ObservedObject private var settings = Settings.shared
    @State private var activityRefreshPulse = Date()

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

    private var showsLinkAccountButton: Bool {
        snapshot.now.requiresAccountLink || snapshot.upNext?.requiresAccountLink == true
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
        VStack(alignment: .leading, spacing: isExpanded ? 14 : 12) {
            header

            VStack(alignment: .leading, spacing: isExpanded ? 7 : 10) {
                ActivityLabel("Current Status", color: .secondary)
                currentActivity
            }

            if showsLinkAccountButton {
                Button {
                    onLinkAccount?()
                } label: {
                    Label("Link Account", systemImage: "personalhotspot.slash")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(onLinkAccount == nil)
            }

            Divider()
                .opacity(0.45)

            VStack(alignment: .leading, spacing: 6) {
                ActivityLabel("Up Next", color: .secondary)
                if let next = snapshot.upNext {
                    nextActivity(next)
                } else {
                    emptyNextActivity
                }
            }
            .opacity(0.82)

            if prominence == .expanded, !snapshot.blockedPriority.isEmpty {
                Divider()
                    .opacity(0.6)

                blockedPriorityList
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
        .task(id: miner.id) {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15 * 1_000_000_000)
                activityRefreshPulse = Date()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(miner.displayName), now mining \(snapshot.now.title)")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            AnimatedStatusIcon(symbol: snapshot.now.symbol, color: snapshot.now.accent, size: 17, weight: .medium)

            Text(miner.displayName)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .contextMenu {
                    minerContextMenu
                }

            Spacer(minLength: 8)
        }
        .contextMenu {
            minerContextMenu
        }
    }

    @ViewBuilder
    private var minerContextMenu: some View {
        if let onOverrideStream {
            Button(action: onOverrideStream) {
                Label("Override Stream...", systemImage: "dot.radiowaves.left.and.right")
            }
        }

        if miner.streamOverrideLogin != nil, let onClearStreamOverride {
            Button(action: onClearStreamOverride) {
                Label("Clear Stream Override", systemImage: "xmark.circle")
            }
        }

        if let onEditNickname {
            Button(action: onEditNickname) {
                Label(miner.nickname == nil ? "Add Nickname" : "Edit Nickname", systemImage: "pencil")
            }
        }

        if miner.nickname != nil, let onClearNickname {
            Button(action: onClearNickname) {
                Label("Clear Nickname", systemImage: "xmark.circle")
            }
        }
    }

    private var currentActivity: some View {
        VStack(alignment: .leading, spacing: isExpanded ? 4 : 6) {
            Text(snapshot.now.title)
                .font(.title3.weight(.semibold))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if let subtitle = snapshot.now.subtitle {
                Text(subtitle)
                    .font(isExpanded ? .callout : .subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let overrideLogin = miner.streamOverrideLogin {
                Label("@\(overrideLogin)", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let progress = snapshot.now.progressFraction {
                AnimatedLinearProgressView(value: progress, tint: effectiveAccent(snapshot.now.accent))
                    .padding(.top, isExpanded ? 0 : 2)
            }

            if let detail = snapshot.now.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(isExpanded ? 1 : 2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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

    private var blockedPriorityList: some View {
        VStack(alignment: .leading, spacing: 10) {
            ActivityLabel("Needs Linking", color: .orange)

            ForEach(snapshot.blockedPriority) { item in
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

                    Button {
                        onLinkAccount?()
                    } label: {
                        Text("Link")
                            .font(.caption2.weight(.bold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(.orange)
                    .disabled(onLinkAccount == nil)
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
    @State private var displayedValue: Double = 0

    private var clampedValue: Double {
        min(1, max(0, value))
    }

    var body: some View {
        ProgressView(value: displayedValue)
            .progressViewStyle(.linear)
            .tint(tint)
            .onAppear {
                guard !reduceMotion else {
                    displayedValue = clampedValue
                    return
                }

                displayedValue = 0
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: duration)) {
                        displayedValue = clampedValue
                    }
                }
            }
            .onChange(of: clampedValue) { _, newValue in
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
            includesBadgeAndEmoteCampaigns: includesBadgeAndEmoteCampaigns,
            ignoredAccountLinkGameIds: ignoredAccountLinkGameIds
        )

        let next = likelyNextItem(
            for: miner,
            excludingCampaignId: currentCampaign?.id ?? miner.currentCampaignId,
            priorityGames: activePriorityGames,
            excludedGames: excludedGames,
            strategy: strategy,
            includesBadgeAndEmoteCampaigns: includesBadgeAndEmoteCampaigns,
            ignoredAccountLinkGameIds: ignoredAccountLinkGameIds
        )
        
        let blocked = blockedPriorityItems(
            for: miner,
            excludingCampaignId: currentCampaign?.id ?? miner.currentCampaignId,
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
        includesBadgeAndEmoteCampaigns: Bool,
        ignoredAccountLinkGameIds: [String]
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

        if miner.isRunning && !miner.needsAuth && !miner.isHealthy {
            return waitingItem(
                id: "quiet-\(miner.id)",
                title: "No Recent Activity",
                subtitle: "Worker is running, but it has not reported recent liveness yet.",
                symbol: "clock.badge.exclamationmark",
                accent: .yellow
            )
        }

        if miner.status == .watching, let campaign, hasUnclaimedDrop(in: campaign) {
            let progress = activeDropProgress(for: campaign, miner: miner)
            let detail = progress.map { item in
                if item.currentMinutes == 0, item.remainingMinutes == 0 {
                    return "\(item.dropName) · checking progress with Twitch"
                }
                if item.currentMinutes == 0, item.remainingMinutes > 0 {
                    return "\(item.dropName) · checking progress with Twitch"
                }
                return item.remainingMinutes > 0
                    ? "\(item.dropName) · \(item.remainingMinutes) min remaining"
                    : "\(item.dropName) · claiming reward"
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

        if let resolved = miner.resolvedPrimaryState?.resolved {
            switch resolved.state {
            case .blocked:
                if resolved.reason == .notLinked,
                   isAccountLinkWarningIgnored(
                    gameId: resolved.gameId,
                    gameName: resolved.gameName,
                    ignoredAccountLinkGameIds: ignoredAccountLinkGameIds
                   ) {
                    return upToDateItem(
                        id: "ignored-link-\(miner.id)-\(resolved.gameId)",
                        subtitle: "No mineable drops are available after dismissed link warnings."
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
                title: "Up to Date",
                subtitle: "Checking for active campaigns...",
                symbol: "calendar.badge.checkmark",
                accent: .green
            )
        case .waitingForStream:
            return waitingItem(
                id: "stream-\(miner.id)",
                title: "Looking for Streams",
                subtitle: "Waiting for an eligible live stream.",
                symbol: "antenna.radiowaves.left.and.right",
                accent: .cyan
            )
        case .blockedAccountNotLinked:
            if allAccountLinkBlocksIgnored(
                for: miner,
                excludingCampaignId: campaign?.id ?? miner.currentCampaignId,
                priorityGames: priorityGames,
                excludedGames: excludedGames,
                strategy: strategy,
                includesBadgeAndEmoteCampaigns: includesBadgeAndEmoteCampaigns,
                ignoredAccountLinkGameIds: ignoredAccountLinkGameIds
            ) {
                return upToDateItem(
                    id: "ignored-link-\(miner.id)",
                    subtitle: "No mineable drops are available after dismissed link warnings."
                )
            }
            return waitingItem(
                id: "link-\(miner.id)",
                title: "Blocked — Account not linked",
                subtitle: "Link your account to earn drops.",
                symbol: "personalhotspot.slash",
                accent: .orange
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
            return MinerActivityItem(
                id: "blocked-link-\(miner.id)-\(resolved.gameId)",
                title: "Blocked — Account not linked",
                subtitle: resolved.gameName,
                detail: "Link this game account to earn drops.",
                symbol: "personalhotspot.slash",
                accent: .orange,
                campaignId: resolved.campaignId,
                requiresAccountLink: true
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
    ) -> (dropName: String, fraction: Double, remainingMinutes: Int, currentMinutes: Int)? {
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
                remainingMinutes: 0,
                currentMinutes: 0
            )
        }

        let fraction = min(1.0, max(0.0, Double(currentMinutes) / Double(requiredMinutes)))
        return (
            dropName: dropName,
            fraction: fraction,
            remainingMinutes: max(0, requiredMinutes - currentMinutes),
            currentMinutes: currentMinutes
        )
    }

    private static func likelyNextItem(
        for miner: MinerManager.ManagedMiner,
        excludingCampaignId activeCampaignId: String?,
        priorityGames: [String],
        excludedGames: [String],
        strategy: MiningStrategy,
        includesBadgeAndEmoteCampaigns: Bool,
        ignoredAccountLinkGameIds: [String]
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
            guard !excludedSet.contains(gameName), !excludedSet.contains(gameId) else { return false }
            guard strategy != .onlyPriority || prioritySet.contains(gameName) || prioritySet.contains(gameId) else { return false }
            return true
        }

        let eligible = candidates.filter { campaign in
            guard campaign.canAttemptMining else {
                return false
            }
            // Unlinked campaigns are only attemptable when prioritised for this miner;
            // mirror the engine so "Up Next" doesn't surface another miner's priority.
            if !campaign.isAccountConnected {
                let gameName = normalizedGameKey(campaign.game.name)
                let gameId = normalizedGameKey(campaign.game.id)
                guard prioritySet.contains(gameName) || prioritySet.contains(gameId) else {
                    return false
                }
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
            guard let blockedCampaign = sortedCandidates(candidates, priorityKeys: priorityKeys, strategy: strategy).first(where: { campaign in
                !campaign.isAccountConnected &&
                isAccountLinkWarningIgnored(
                    gameId: campaign.game.id,
                    gameName: campaign.game.name,
                    ignoredAccountLinkGameIds: ignoredAccountLinkGameIds
                )
            }) else {
                return nil
            }

            return MinerActivityItem(
                id: "next-blocked-\(blockedCampaign.id)",
                title: blockedCampaign.game.name,
                subtitle: blockedCampaign.name,
                detail: "Blocked — account not linked",
                symbol: "personalhotspot.slash",
                accent: .orange,
                campaignId: blockedCampaign.id,
                requiresAccountLink: false
            )
        }

        return MinerActivityItem(
            id: "next-\(campaign.id)",
            title: campaign.game.name,
            subtitle: campaign.name,
            detail: "Likely based on current priority rules",
            symbol: "arrow.forward.circle",
            accent: .secondary,
            campaignId: campaign.id
        )
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

    private static func allAccountLinkBlocksIgnored(
        for miner: MinerManager.ManagedMiner,
        excludingCampaignId activeCampaignId: String?,
        priorityGames: [String],
        excludedGames: [String],
        strategy: MiningStrategy,
        includesBadgeAndEmoteCampaigns: Bool,
        ignoredAccountLinkGameIds: [String]
    ) -> Bool {
        let blocked = accountLinkBlockedCampaigns(
            for: miner,
            excludingCampaignId: activeCampaignId,
            priorityGames: priorityGames,
            excludedGames: excludedGames,
            strategy: strategy,
            includesBadgeAndEmoteCampaigns: includesBadgeAndEmoteCampaigns
        )
        guard !blocked.isEmpty else { return false }

        return blocked.allSatisfy { campaign in
            isAccountLinkWarningIgnored(
                gameId: campaign.game.id,
                gameName: campaign.game.name,
                ignoredAccountLinkGameIds: ignoredAccountLinkGameIds
            )
        }
    }

    private static func accountLinkBlockedCampaigns(
        for miner: MinerManager.ManagedMiner,
        excludingCampaignId activeCampaignId: String?,
        priorityGames: [String],
        excludedGames: [String],
        strategy: MiningStrategy,
        includesBadgeAndEmoteCampaigns: Bool
    ) -> [Campaign] {
        let priorityKeys = priorityGames.map(normalizedGameKey).filter { !$0.isEmpty }
        let prioritySet = Set(priorityKeys)
        let excludedSet = Set(excludedGames.map(normalizedGameKey).filter { !$0.isEmpty })

        return miner.allCampaigns.filter { campaign in
            guard campaign.id != activeCampaignId else { return false }
            guard !isSpecialEventsCampaign(campaign) else { return false }
            guard !campaign.drops.isEmpty else { return false }
            guard campaign.isTimeActive, campaign.status != .disabled else { return false }
            guard !campaign.drops.allSatisfy(\.isClaimed) else { return false }

            let gameName = normalizedGameKey(campaign.game.name)
            let gameId = normalizedGameKey(campaign.game.id)
            guard !excludedSet.contains(gameName), !excludedSet.contains(gameId) else { return false }
            guard strategy != .onlyPriority || prioritySet.contains(gameName) || prioritySet.contains(gameId) else { return false }
            if !prioritySet.isEmpty {
                guard prioritySet.contains(gameName) || prioritySet.contains(gameId) else { return false }
            }
            guard !campaign.isAccountConnected else { return false }
            if !includesBadgeAndEmoteCampaigns && campaign.hasOnlyBadgesOrEmotes {
                return false
            }
            return true
        }
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

    private static func statusText(for miner: MinerManager.ManagedMiner, now: MinerActivityItem) -> String {
        if miner.workerState.isRecovering {
            return "Recovering..."
        }
        if miner.isStalled {
            return "Miner Unresponsive"
        }
        if miner.isRunning && !miner.needsAuth && !miner.isHealthy {
            return "No Recent Activity"
        }
        if now.id.hasPrefix("waiting-drops-") || now.id.hasPrefix("ignored-link-") {
            return "Up to Date"
        }

        switch miner.status {
        case .watching:
            return "Watching \(now.title)"
        case .claiming:
            return "Claiming Rewards"
        case .waitingForStream:
            return "Looking for Streams"
        case .fetchingCampaigns:
            return "Up to Date"
        case .authenticating:
            return "Reconnecting"
        case .paused:
            return "Paused"
        case .error:
            return "Blocked — Needs attention"
        case .idleNoEligibleCampaigns:
            return "Up to Date"
        case .blockedAccountNotLinked:
            return "Blocked — Account not linked"
        case .idle:
            return "Up to Date"
        }
    }

    private static func statusSymbol(for miner: MinerManager.ManagedMiner, now: MinerActivityItem) -> String {
        if miner.workerState.isRecovering {
            return "wrench.and.screwdriver.fill"
        }
        if miner.isStalled {
            return "bolt.horizontal.circle.fill"
        }
        if miner.isRunning && !miner.needsAuth && !miner.isHealthy {
            return "checkmark.circle.trianglebadge.exclamationmark.fill"
        }
        if now.id.hasPrefix("ignored-link-") {
            return "calendar.badge.checkmark"
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
            return "calendar.badge.checkmark"
        case .authenticating:
            return "arrow.triangle.2.circlepath"
        case .paused:
            return "pause.fill"
        case .error:
            return "exclamationmark.triangle.fill"
        case .idleNoEligibleCampaigns:
            return "calendar.badge.checkmark"
        case .blockedAccountNotLinked:
            return "personalhotspot.slash"
        case .idle:
            return "calendar.badge.checkmark"
        }
    }

    private static func statusColor(for miner: MinerManager.ManagedMiner, now: MinerActivityItem) -> Color {
        if miner.workerState.isRecovering {
            return .orange
        }
        if miner.isStalled {
            return .red
        }
        if miner.isRunning && !miner.needsAuth && !miner.isHealthy {
            return .yellow
        }
        if now.id.hasPrefix("ignored-link-") {
            return .green
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
            return .orange
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
