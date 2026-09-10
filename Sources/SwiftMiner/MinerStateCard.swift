import SwiftUI
import SwiftMinerCore
import AppKit

/// A unified hero card that represents the resolved PrimaryState of a miner.
/// Replaces legacy status badges and scattered state labels with a single story.
struct MinerStateCard: View {
    let miner: MinerManager.ManagedMiner
    var activityCampaigns: [Campaign] = []
    var onAction: (() -> Void)? = nil
    var onDismiss: ((String) -> Void)? = nil

    @Environment(\.swiftMinerAppearance) private var appearance

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
                    .foregroundStyle(appearance.activityAccent(.green))
            }

            AnimatedLinearProgressView(
                value: progress.progressFraction,
                tint: appearance.activityAccent(.green)
            )

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
                    icon: SystemSymbolCompatibility.resolvedName(for: "personalhotspot.slash"),
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
                icon: "bolt.fill",
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.swiftMinerAppearance) private var appearance
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

    private func effectiveAccent(_ color: Color) -> Color {
        appearance.activityAccent(color)
    }

    var body: some View {
        // Resolve the activity snapshot once per render. `MinerActivitySnapshot.resolve`
        // is expensive and was previously recomputed on every access (~10+ times per
        // render, multiplied by every miner card on screen).
        let snap = snapshot
        return VStack(alignment: .leading, spacing: isExpanded ? 14 : 10) {
            header(snap: snap)

            if isExpanded {
                VStack(alignment: .leading, spacing: 7) {
                    ActivityLabel("Current Status", color: .secondary)
                    currentActivity(snap: snap)
                }
            } else {
                // No "Current Status" heading on a compact card: the status is the
                // largest line on it, and the heading cost a line to say so.
                currentActivity(snap: snap)
            }

            if isExpanded {
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
            } else {
                compactUpNext(snap.upNext)
                    .opacity(0.82)
            }

            if prominence == .expanded, !snap.blockedPriority.isEmpty {
                Divider()
                    .opacity(0.6)

                blockedPriorityList(snap: snap)
            }
        }
        .padding(isExpanded ? 18 : 14)
        // Compact cards reserve every slot they can ever fill — progress bar,
        // detail, live indicator, up next — so a miner changing state redraws
        // inside its own card instead of resizing the grid row and moving the
        // rest of the page. Expanded cards own the whole detail pane, where
        // nothing below them has to hold still, and fit their content.
        .frame(
            maxWidth: .infinity,
            maxHeight: prominence == .compact ? .infinity : nil,
            alignment: .topLeading
        )
        .glassCard()
        // Overview updates content in place. Only expanded details animate their
        // changing structure; a polling update must not animate the whole grid.
        .animation(
            reduceMotion || !isExpanded ? nil : .smooth(duration: 0.34),
            value: MinerActivityCardLayout(snap)
        )
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
        // On Overview the account is what the reader is looking for first, and the
        // status symbol is how they find the one card that needs them — so both
        // carry more weight than the status text below. Miner details keeps the
        // lighter pairing: there the account is already named by the page.
        HStack(alignment: .center, spacing: isExpanded ? 8 : 9) {
            AnimatedStatusIcon(
                symbol: snap.now.symbol,
                color: snap.now.accent,
                size: isExpanded ? 17 : 21,
                weight: isExpanded ? .medium : .bold
            )

            Text(miner.displayName)
                .font(isExpanded ? .title3.weight(.semibold) : .title2.weight(.bold))
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
            // Game and campaign lead; the drop's own artwork sits opposite them
            // so the card keeps one identity per side and the progress bar below
            // still spans the full width.
            HStack(alignment: isExpanded ? .top : .center, spacing: 10) {
                VStack(alignment: .leading, spacing: isExpanded ? 4 : 2) {
                    // Game over campaign, set tight like a track's album over its
                    // artist. Compact used to reserve a second title line to hold
                    // every card level, but the 46pt artwork opposite already
                    // floors the row — so the reserved line only ever showed as a
                    // gap under a one-line game name.
                    Text(snap.now.title)
                        .contentTransition(.opacity)
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: snap.now.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if isExpanded {
                        if let subtitle = snap.now.subtitle {
                            Text(subtitle)
                                .contentTransition(.opacity)
                                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: subtitle)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        // One line, reserved. Two lines held the card's shape just
                        // as well but spent height on a campaign name most cards
                        // fit anyway; the full text is on hover.
                        Text(snap.now.subtitle ?? "")
                            .contentTransition(.opacity)
                            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: snap.now.subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1, reservesSpace: true)
                            .help(snap.now.subtitle ?? "")
                    }
                }

                Spacer(minLength: 0)

                // Miner details still shows the drop's artwork. The compact card
                // does not: it repeated what the game name already says, and at
                // 46pt it set the row's height.
                //
                // Dropping it is also what keeps the grid level. The title no
                // longer reserves a second line, so a card is only taller than
                // its neighbours if the title wraps — and giving the text the
                // card's full width is what stops that. At the narrowest column
                // the grid allows (300 minus 14pt padding either side = 272pt),
                // the longest status the app can show, "Blocked — Authentication
                // expired", measures 239.9pt. Anything wordier than roughly that
                // wraps and stands its card taller than its neighbours.
                if isExpanded, let artworkURL = snap.now.artworkURL {
                    MinerActivityArtwork(url: artworkURL, size: 54)
                }
            }

            if let progress = snap.now.progressFraction {
                progressRow(progress: progress, percent: snap.now.progressPercent, accent: snap.now.accent)
            }

            if let detail = snap.now.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(isExpanded ? "" : detail)
            }

            // A known drop already shows cumulative watched time across every source.
            // Keep the session-only stopwatch for pure watch overrides, where no drop total exists.
            // Miner details can afford both lines; a compact card has room for one,
            // and the countdown is the one that answers "is this thing still alive".
            if isExpanded {
                if let deadline = nextCheckDeadline {
                    MinerNextCheckView(deadline: deadline, lastCheckedAt: miner.lastCampaignRefreshAt)
                }

                if snap.now.progressFraction == nil, let anchor = liveActivityAnchor {
                    MinerLiveActivityTimerView(
                        anchor: anchor,
                        accent: effectiveAccent(snap.now.accent)
                    )
                }
            } else if let deadline = nextCheckDeadline {
                MinerNextCheckView(deadline: deadline, lastCheckedAt: miner.lastCampaignRefreshAt)
                    .padding(.top, 2)
            } else if snap.now.progressFraction == nil, let anchor = liveActivityAnchor {
                MinerLiveActivityTimerView(
                    anchor: anchor,
                    accent: effectiveAccent(snap.now.accent)
                )
            }

            if !isExpanded {
                compactBallast(snap: snap)
            }
        }
    }

    /// Hidden copies of the compact rows this miner has nothing to put in,
    /// parked at the foot of the block.
    ///
    /// Reserving each row where it belongs kept the card one height, but an idle
    /// miner then showed the gap in the middle of its own card, between what it
    /// was saying and the line below — it read as something failing to load. The
    /// rows are the same rows, so the height is identical to the pixel; they are
    /// simply all collected under the content, where the slack reads as the
    /// card's own bottom margin and every card's footer still lines up.
    @ViewBuilder
    private func compactBallast(snap: MinerActivitySnapshot) -> some View {
        if snap.now.progressFraction == nil {
            progressRow(progress: 0, percent: 0, accent: snap.now.accent)
                .hidden()
        }

        if snap.now.detail == nil {
            Text(" ")
                .font(.caption)
                .lineLimit(1)
                .hidden()
        }

        if nextCheckDeadline == nil, snap.now.progressFraction != nil || liveActivityAnchor == nil {
            Text(" ")
                .font(.caption.monospacedDigit())
                .lineLimit(1)
                .padding(.top, 2)
                .hidden()
        }
    }

    /// The progress bar and its percentage, factored out so the compact card can
    /// draw the identical row hidden when there is no progress to report. Anything
    /// that reserves height by guessing at a constant drifts the moment the row's
    /// own type or spacing changes; this cannot.
    private func progressRow(progress: Double, percent: Int?, accent: Color) -> some View {
        HStack(spacing: 8) {
            AnimatedLinearProgressView(value: progress, tint: effectiveAccent(accent))

            // Reads as the bar's own value rather than metadata below
            // it, and comes off the same fraction the bar is drawn
            // from, so the two can never disagree. The fixed width
            // keeps every card's bar ending on the same line.
            if let percent {
                Text("\(percent)%")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(effectiveAccent(accent))
                    .frame(width: 32, alignment: .trailing)
                    // Rolls to the new figure alongside the bar's own
                    // sweep rather than snapping while the bar glides.
                    .contentTransition(.numericText())
                    .animation(
                        reduceMotion ? nil : .smooth(duration: 0.4),
                        value: percent
                    )
            }
        }
        .padding(.top, isExpanded ? 0 : 2)
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

    /// When an idle miner will next look for work, if it is waiting and the wait has not
    /// already elapsed. Anything the user should act on — unresponsive, recovering, needing
    /// auth — has its own wording and must not be softened into "waiting, all fine".
    private var nextCheckDeadline: Date? {
        guard miner.isRunning, !miner.needsAuth, !miner.isStalled, !miner.workerState.isRecovering else { return nil }
        guard let deadline = miner.nextCampaignCheckAt, deadline > Date() else { return nil }
        return deadline
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

                if let detail = item.detail {
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

    /// Up Next on one line, heading and item together. As a section it cost a
    /// divider, a heading and two more lines to name a single game — roughly a
    /// quarter of a compact card. The line is always drawn, so a queue that
    /// empties still cannot change the card's height.
    private func compactUpNext(_ item: MinerActivityItem?) -> some View {
        HStack(spacing: 6) {
            ActivityLabel("Up Next", color: .secondary)

            if let item {
                AnimatedStatusIcon(symbol: item.symbol, color: item.accent, size: 9, weight: .semibold)
                    .frame(width: 14, height: 14)

                Text(item.title)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .help(item.subtitle ?? item.title)
            } else {
                Text("Nothing queued")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
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

/// Everything about a snapshot that changes a miner card's shape.
///
/// Deliberately not the whole snapshot, and deliberately not the progress
/// fraction: the bar and the percentage animate themselves, and keying the whole
/// card off a value that ticks constantly would leave it permanently in motion.
/// What belongs here is structure — which sections exist, and what the lines of
/// text say — because those are what change the card's height and shove
/// everything below it.
private struct MinerActivityCardLayout: Equatable {
    let nowID: String
    let title: String
    let subtitle: String?
    let detail: String?
    let hasProgress: Bool
    let hasArtwork: Bool
    let upNextID: String?
    let upNextTitle: String?
    let blockedCount: Int

    init(_ snapshot: MinerActivitySnapshot) {
        nowID = snapshot.now.id
        title = snapshot.now.title
        subtitle = snapshot.now.subtitle
        detail = snapshot.now.detail
        hasProgress = snapshot.now.progressFraction != nil
        hasArtwork = snapshot.now.artworkURL != nil
        upNextID = snapshot.upNext?.id
        upNextTitle = snapshot.upNext?.title
        blockedCount = snapshot.blockedPriority.count
    }
}

/// The artwork for the drop a miner is currently progressing.
///
/// Loads through the shared campaign artwork cache — the same memory/disk store
/// the Drops feed reads — so a card costs no extra fetch. Nothing is drawn until
/// an image is actually available: a drop Twitch published no art for simply has
/// no thumbnail rather than a broken frame.
struct MinerActivityArtwork: View {
    let url: URL?
    var size: CGFloat = 46

    @State private var loadedArtwork: LoadedCampaignArtwork?

    private var resolvedURL: URL? { url?.highResolutionArtworkURL }

    private var displayedImage: NSImage? {
        guard loadedArtwork?.url == resolvedURL else { return nil }
        return loadedArtwork?.image
    }

    var body: some View {
        Group {
            if let displayedImage {
                Image(nsImage: displayedImage)
                    .resizable()
                    .interpolation(.high)
                    // Reward art is square, box art is portrait; fitting keeps
                    // either one honest rather than cropping it to a badge.
                    .aspectRatio(contentMode: .fit)
            } else {
                // Holds the slot while the image loads so the card does not
                // reflow underneath the user.
                Color.clear
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: GlassRadius.artwork, style: .continuous))
        .task(id: resolvedURL) {
            guard let resolvedURL else {
                loadedArtwork = nil
                return
            }

            let image = await CampaignArtworkCache.shared.image(for: resolvedURL)
            guard !Task.isCancelled else { return }
            loadedArtwork = image.map { LoadedCampaignArtwork(url: resolvedURL, image: $0) }
        }
        .accessibilityHidden(true)
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
    /// Campaign IDs in the miner's resolved scheduling order. This is the
    /// authoritative order for both the sequence summary and Campaign Queue.
    let orderedCampaignIds: [String]
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
        let currentCampaign = currentCampaign(for: miner) ?? waitingCampaign(for: miner)
        
        let activePriorityGames = miner.priorityGames.isEmpty ? priorityGames : miner.priorityGames
        let now = currentActivityItem(
            for: miner,
            campaign: currentCampaign,
            priorityGames: activePriorityGames,
            excludedGames: excludedGames,
            strategy: strategy,
            includesBadgeAndEmoteCampaigns: includesBadgeAndEmoteCampaigns
        )

        let orderedCandidates = orderedCampaignCandidates(
            for: miner,
            excludingCampaignId: currentCampaign?.id ?? miner.currentCampaignId,
            priorityGames: activePriorityGames,
            excludedGames: excludedGames,
            strategy: strategy,
            includesBadgeAndEmoteCampaigns: includesBadgeAndEmoteCampaigns
        )
        let next = likelyNextItem(
            from: orderedCandidates,
            priorityGames: activePriorityGames,
            strategy: strategy
        )

        // The candidate list is filtered against the miner's watch target, but the
        // current item can name a different campaign — the priority resolver's blocked
        // campaign, for one — so that ID can still be among the candidates. Dedupe here
        // or the Campaign Queue renders it twice under the same ForEach identity.
        var seenCampaignIds: Set<String> = []
        var orderedCampaignIds: [String] = []
        for campaignId in [now.campaignId].compactMap({ $0 }) + orderedCandidates.map(\.id)
        where seenCampaignIds.insert(campaignId).inserted {
            orderedCampaignIds.append(campaignId)
        }
        
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
            orderedCampaignIds: orderedCampaignIds,
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

    /// A waiting miner clears its watch target before its next channel probe, so recover the
    /// campaign from that probe to explain the wait on this miner's own status card.
    @MainActor
    private static func waitingCampaign(for miner: MinerManager.ManagedMiner) -> Campaign? {
        guard miner.status == .waitingForStream,
              let campaignID = miner.gameChannelAvailability.values
                .filter({ !$0.hasEligibleChannel && $0.campaignId != nil })
                .max(by: { $0.checkedAt < $1.checkedAt })?
                .campaignId
        else {
            return nil
        }

        return miner.allCampaigns.first { $0.id == campaignID }
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
                    campaignId: campaign.id,
                    artworkURL: progress?.artworkURL ?? campaign.game.boxArtURL
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
                symbol: "bolt.fill",
                accent: .green,
                progressFraction: progress?.fraction,
                campaignId: campaign.id,
                artworkURL: progress?.artworkURL ?? campaign.game.boxArtURL
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
                campaignId: campaign.id,
                artworkURL: activeDropProgress(for: campaign, miner: miner)?.artworkURL
                    ?? campaign.game.boxArtURL
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
                    return unlinkedPriorityItem(id: "unlinked-\(miner.id)-\(resolved.gameId)")
                }
                return blockedCurrentItem(for: miner, resolved: resolved, campaign: campaign)
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
            if let campaign {
                return MinerActivityItem(
                    id: "stream-\(miner.id)-\(campaign.id)",
                    title: "No eligible stream live",
                    subtitle: campaign.name,
                    detail: "SwiftMiner will automatically start earning when an eligible \(campaign.game.name) stream goes live.",
                    symbol: "antenna.radiowaves.left.and.right",
                    accent: .cyan,
                    campaignId: campaign.id
                )
            }

            return waitingItem(
                id: "stream-\(miner.id)",
                title: "Looking for Streams",
                subtitle: "Waiting for an eligible live stream.",
                symbol: "antenna.radiowaves.left.and.right",
                accent: .cyan
            )
        case .blockedAccountNotLinked:
            return unlinkedPriorityItem(id: "unlinked-\(miner.id)")
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

    private static func unlinkedPriorityItem(id: String) -> MinerActivityItem {
        MinerActivityItem(
            id: id,
            title: "Priority game ready",
            subtitle: "SwiftMiner can still mine it while account linking is pending.",
            detail: "Link the game account on Twitch to receive its rewards.",
            symbol: "personalhotspot",
            accent: .orange,
            requiresAccountLink: true
        )
    }

    private static func blockedCurrentItem(
        for miner: MinerManager.ManagedMiner,
        resolved: MinerGameState,
        campaign: Campaign?
    ) -> MinerActivityItem {
        switch resolved.reason {
        case .notLinked:
            return unlinkedPriorityItem(id: "unlinked-\(miner.id)-\(resolved.gameId)")
        case .noLiveStreams:
            return MinerActivityItem(
                id: "blocked-stream-\(miner.id)-\(resolved.gameId)",
                title: "No eligible stream live",
                subtitle: campaign?.name ?? resolved.gameName,
                detail: "SwiftMiner will automatically start earning when an eligible \(resolved.gameName) stream goes live.",
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

    /// The drop a miner is currently working towards, with the artwork that
    /// represents it — the reward image where Twitch published one, the game's
    /// box art otherwise.
    struct ActiveDropProgress {
        let dropName: String
        let fraction: Double
        let currentMinutes: Int
        let requiredMinutes: Int
        let artworkURL: URL?
    }

    @MainActor
    private static func activeDropProgress(
        for campaign: Campaign,
        miner: MinerManager.ManagedMiner
    ) -> ActiveDropProgress? {
        guard let drop = campaign.drops.first(where: { !$0.isClaimed && !$0.isClaimable })
            ?? campaign.drops.first(where: { !$0.isClaimed }) else {
            return nil
        }

        let dropState = miner.stateStore?.dropStates.first { $0.dropId == drop.id }
        let currentMinutes = max(dropState?.progressMinutes ?? 0, drop.progress?.currentMinutes ?? 0)
        let requiredMinutes = max(dropState?.requiredMinutes ?? 0, drop.progress?.requiredMinutes ?? drop.requiredMinutes)
        let dropName = drop.progress?.dropName.isEmpty == false ? drop.progress?.dropName ?? drop.name : drop.name
        let artworkURL = drop.imageURL ?? campaign.game.boxArtURL

        guard requiredMinutes > 0 else {
            return ActiveDropProgress(
                dropName: dropName,
                fraction: 0,
                currentMinutes: 0,
                requiredMinutes: 0,
                artworkURL: artworkURL
            )
        }

        let fraction = min(1.0, max(0.0, Double(currentMinutes) / Double(requiredMinutes)))
        return ActiveDropProgress(
            dropName: dropName,
            fraction: fraction,
            currentMinutes: currentMinutes,
            requiredMinutes: requiredMinutes,
            artworkURL: artworkURL
        )
    }

    /// Uses Twitch's cumulative per-drop total, reconciled with the miner's persisted ledger.
    /// This is intentionally not tied to the current channel or watch session.
    private static func watchedTimeDetail(for progress: ActiveDropProgress) -> String {
        guard progress.requiredMinutes > 0 else {
            return "\(progress.dropName) · watching eligible stream"
        }
        let watchedMinutes = min(progress.requiredMinutes, max(0, progress.currentMinutes))
        return "\(progress.dropName) · \(watchedMinutes) / \(progress.requiredMinutes) min watched"
    }

    private static func orderedCampaignCandidates(
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
            // Keep this in lockstep with `MinerEngine.candidateCampaigns`: a
            // claimable-but-not-yet-claimed reward has no watch progress left,
            // so it is not actually "Up next" for mining.
            guard campaign.canAttemptMining, !campaign.earnableDrops.isEmpty else {
                return false
            }
            if !includesBadgeAndEmoteCampaigns && campaign.hasOnlyBadgesOrEmotes {
                return false
            }
            return true
        }

        return sortedCandidates(eligible, priorityKeys: priorityKeys, strategy: strategy)
    }

    private static func likelyNextItem(
        from orderedCandidates: [Campaign],
        priorityGames: [String],
        strategy: MiningStrategy
    ) -> MinerActivityItem? {
        guard let campaign = orderedCandidates.first else {
            return nil
        }
        let priorityKeys = priorityGames.map(normalizedGameKey).filter { !$0.isEmpty }

        return MinerActivityItem(
            id: "next-\(campaign.id)",
            title: campaign.game.name,
            subtitle: campaign.name,
            detail: likelyNextDetail(
                for: campaign,
                among: orderedCandidates,
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
                symbol: SystemSymbolCompatibility.resolvedName(for: "personalhotspot.slash"),
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
            return SystemSymbolCompatibility.resolvedName(for: "checkmark.circle.trianglebadge.exclamationmark.fill")
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
            return "bolt.fill"
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
    /// Artwork for the drop this item is progressing — the reward image Twitch
    /// published for it, falling back to the game's box art. Nil where there is
    /// no drop to picture, such as a stopped or unresponsive miner.
    var artworkURL: URL? = nil

    /// `progressFraction` as a whole percent for display beside the bar.
    ///
    /// Held back from 100% until the drop is genuinely complete: 299 of 300
    /// minutes rounds to 100 and would read as finished a minute early.
    var progressPercent: Int? {
        guard let progressFraction else { return nil }
        guard progressFraction < 1 else { return 100 }
        return min(99, max(0, Int((progressFraction * 100).rounded())))
    }
}

/// "Next check in 3 minutes" for a miner idle with nothing eligible to mine.
///
/// That is the ordinary state now, not the exception, and the engine publishes nothing at
/// all while it waits — so the row sat perfectly still for minutes and read as stuck. The
/// reported symptom was exactly that: clicking a miner to find out whether it was alive,
/// which forced an off-cadence refresh and made the click look like the cure.
///
/// `Text(_:style:.relative)` counts down on its own, so an idle miner pays for no timer.
struct MinerNextCheckView: View {
    let deadline: Date
    let lastCheckedAt: Date?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "clock")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)

            (Text("Next check in ") + Text(deadline, style: .relative))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .help(helpText)
    }

    private var helpText: String {
        guard let lastCheckedAt else {
            return "This miner has nothing eligible to mine and is waiting for the next campaign check."
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let checked = formatter.localizedString(for: lastCheckedAt, relativeTo: Date())
        return "Nothing eligible to mine. Campaigns were last checked \(checked)."
    }
}

/// A shared live-session clock used anywhere miner activity is presented.
/// Drop progress remains Twitch's cumulative verified total; this clock only
/// describes how long the current uninterrupted watch session has been active.
struct MinerLiveActivityTimerView: View {
    let anchor: Date
    let accent: Color
    var label: String? = nil

    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        if controlActiveState == .inactive {
            // No second-by-second layout work is needed in the background. The
            // foreground timeline recomputes elapsed time from the original anchor.
            timerContent(at: Date())
        } else {
            TimelineView(.periodic(from: anchor, by: 1)) { context in
                timerContent(at: context.date)
            }
        }
    }

    private func timerContent(at date: Date) -> some View {
        let elapsed = max(0, date.timeIntervalSince(anchor))
        return HStack(spacing: 5) {
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        if reduceMotion || controlActiveState == .inactive {
            dot
        } else {
            dot.phaseAnimator([false, true]) { content, pulsing in
                content
                    .opacity(pulsing ? 0.3 : 1.0)
                    .scaleEffect(pulsing ? 0.82 : 1.0)
            } animation: { _ in
                .easeInOut(duration: 0.9)
            }
        }
    }

    private var dot: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
    }
}
