import SwiftUI
import SwiftMinerCore

// MARK: - Fleet Derivations

/// The fleet-wide derivations behind the floating global status control.
///
/// Overview used to compute these inline for the banner that sat across the top
/// of the page. The banner is gone and the control is app-wide, so the
/// derivations moved here and Overview reads the same helpers — there is still
/// exactly one place that decides what the app's global state is.
@MainActor
enum SwiftMinerFleet {
    /// Miners the UI presents. Normally exactly the real ones; in DEBUG the list
    /// can be padded for marketing screenshots — see `demoExpanded(_:)`.
    static func displayedMiners(from miners: [MinerManager.ManagedMiner]) -> [MinerManager.ManagedMiner] {
        #if DEBUG
        if MarketingScreenshotFixture.isEnabled {
            return MarketingScreenshotFixture.miners(from: miners)
        }
        return Settings.shared.orderedMiners(demoExpanded(miners))
        #else
        return Settings.shared.orderedMiners(miners)
        #endif
    }

    /// Campaigns that could be mined right now — the figure that separates a
    /// fleet with nothing to do from one that is merely between streams.
    static func activeCampaignCount(in campaigns: [CampaignViewData], now: Date = Date()) -> Int {
        campaigns
            .filter { campaign in
                campaign.isAccountConnected
                    && campaign.startDate <= now
                    && campaign.endDate > now
                    && !campaign.isCompleted
                    && campaign.overviewRemainingRewardCount > 0
            }
            .count
    }

    /// The single global state the app reports, worst-first: anything the user
    /// has to act on outranks anything that is merely working.
    static func systemState(
        miners: [MinerManager.ManagedMiner],
        campaigns: [CampaignViewData]
    ) -> OverviewSystemState {
        let miningMinerCount = miners.filter { $0.status == .watching }.count

        if miners.contains(where: { $0.needsAuth }) {
            return .blockedAuthenticationExpired
        }

        if miners.contains(where: \.isStalled) {
            return .minerUnresponsive
        }

        if miners.contains(where: { $0.workerState.isRecovering }) {
            return .recovering
        }

        let accountLinkBlockedMiners = miners.filter { $0.status == .blockedAccountNotLinked }
        if !accountLinkBlockedMiners.isEmpty {
            return .blockedAccountNotLinked(
                minerName: accountLinkBlockedMiners.count == 1 ? accountLinkBlockedMiners[0].displayName : nil,
                blockedCount: accountLinkBlockedMiners.count
            )
        }

        if miners.contains(where: { $0.status == .error }) {
            return .blockedNeedsAttention
        }

        if miners.contains(where: { $0.showsNoRecentActivityAttention }) {
            return .noRecentActivity
        }

        if miningMinerCount > 0 {
            return .mining(
                activeMinerCount: miningMinerCount,
                totalMinerCount: miners.count
            )
        }

        if miners.contains(where: { $0.status == .waitingForStream }) {
            return .waitingForLiveStream
        }

        if miners.contains(where: { $0.status == .fetchingCampaigns }) {
            return .waitingRefreshingCampaigns
        }

        if miners.contains(where: { $0.status == .authenticating }) {
            return .waitingAuthenticating
        }

        if !campaigns.isEmpty && campaigns.allSatisfy(\.isCompleted) {
            return .idleAllCampaignsCompleted
        }

        return .idleNoEligibleCampaigns
    }

    #if DEBUG
    /// Pads the miner list with copies of the real ones under demo names, so a
    /// larger fleet can be captured for the website without inventing pixels —
    /// the cards are the real UI rendered over real campaign data.
    ///
    /// Set `SWIFTMINER_DEMO_MINERS=5` in the scheme's environment. Compiled out
    /// of Release entirely, and a no-op unless the variable asks for more
    /// miners than actually exist.
    private static func demoExpanded(_ miners: [MinerManager.ManagedMiner]) -> [MinerManager.ManagedMiner] {
        guard let raw = ProcessInfo.processInfo.environment["SWIFTMINER_DEMO_MINERS"],
              let target = Int(raw),
              target > miners.count,
              !miners.isEmpty else {
            return miners
        }

        let demoNames = ["pixelpanda", "nightowl", "emberfox", "quietcomet", "saltmarsh"]
        var result = miners
        for index in 0..<(target - miners.count) {
            // Cycle the real miners as templates so the extra cards differ from
            // one another rather than repeating a single campaign.
            let template = miners[index % miners.count]
            let name = demoNames[index % demoNames.count]
            result.append(
                MinerManager.ManagedMiner(
                    id: "demo-\(index)-\(name)",
                    accountId: "demo-\(index)",
                    username: name,
                    status: template.status,
                    needsAuth: false,
                    currentCampaign: template.currentCampaign,
                    currentCampaignId: template.currentCampaignId,
                    allCampaigns: template.allCampaigns,
                    dropsClaimed: template.dropsClaimed,
                    isRunning: template.isRunning,
                    priorityGames: template.priorityGames,
                    lastEventAt: template.lastEventAt,
                    lastSuccessfulPollAt: template.lastSuccessfulPollAt,
                    lastCampaignRefreshAt: template.lastCampaignRefreshAt,
                    lastDropProgressAt: template.lastDropProgressAt,
                    workerStartedAt: template.workerStartedAt,
                    workerState: template.workerState,
                    isHealthy: true,
                    isStalled: false
                )
            )
        }
        return result
    }
    #endif
}

// MARK: - Bottom Status Bar

/// Hosts the Overview status banner at the bottom of the content area.
///
/// This view feeds and anchors the informational banner; nothing here is clickable.
///
/// It lives inside the detail column, attached as a bottom safe-area inset, so
/// it ends where the content plane ends and the sidebar carries on past it
/// uninterrupted, still its own higher surface.
struct GlobalStatusBar: View {
    @Environment(NavigationModel.self) private var navigation
    private var settings: Settings { .shared }

    /// The last known campaign set, filtered the way Overview filters it. Read
    /// from the coordinator's cache rather than re-fetched: the bar is a
    /// passenger on whatever Overview and Drops already load.
    @State private var campaigns: [CampaignViewData] = []

    /// Whether this bar should be on screen at all — the user's preference and
    /// whether a fleet exists — is `ContentView`'s call, since it also owns the
    /// safe-area inset. By the time this renders, there is something to report.
    var body: some View {
        let miners = SwiftMinerFleet.displayedMiners(from: navigation.minerManager.miners)

        OverviewSystemStateBanner(
            state: SwiftMinerFleet.systemState(miners: miners, campaigns: campaigns),
            fleet: MinerFleetStatus.make(miners: miners)
        )
        // The same 24pt gutter the page content uses, so the banner lines up
        // with the cards above it exactly as it did when it sat at the top.
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .task { syncCampaigns() }
        .onReceive(NotificationCenter.default.publisher(for: .dropsCampaignsDidUpdate)) { _ in
            syncCampaigns()
        }
        .onChange(of: settings.excludedGames) { _, _ in
            syncCampaigns()
        }
    }

    private func syncCampaigns() {
        let fresh = OverviewView.campaignsExcludingHiddenGames(
            in: navigation.minerManager.dataCoordinator.lastKnownAllCampaigns,
            excludedGames: settings.excludedGames
        )
        guard fresh != campaigns else { return }
        campaigns = fresh
    }
}

/// The system-state banner uses native Liquid Glass on macOS 26 and a material
/// surface on earlier versions.
///
/// The one omission is the trailing action button ("View Drops", "Link
/// Account"): the bar reports status and nothing else now, and navigation is
/// already reachable from the sidebar.
///
/// Squad Health remains the fleet's *condition*, not its activity — a fleet with
/// nothing to mine reads "Up to Date" on the left and still "Healthy" on the
/// right. That distinction lives in `MinerFleetStatus`, not here.
struct OverviewSystemStateBanner: View {
    let state: OverviewSystemState
    let fleet: MinerFleetStatus

    private var statusIconSize: CGFloat {
        // The composed bolt is already enlarged inside AnimatedStatusIcon so its narrow
        // glyph and overhanging badge carry the same visual weight as wider symbols.
        // Give every other overview symbol the same optical 15% lift while leaving the
        // mining symbol at the size that established the target proportions.
        switch state.symbol {
        case "bolt.badge.checkmark.fill",
             "bolt.trianglebadge.exclamationmark.fill",
             "bolt.badge.clock.fill":
            return 16
        default:
            return 16 * 1.15
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            AnimatedStatusIcon(symbol: state.symbol, color: state.color, size: statusIconSize, weight: .semibold)
                .frame(width: 38, height: 38, alignment: .center)

            VStack(alignment: .leading, spacing: 4) {
                Text(state.title)
                    .font(.headline.weight(.semibold))

                Text(state.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 18)

            // Same cluster the Miners tab shows per miner, carrying fleet-wide
            // values. Drops its labels before it drops cells when space is
            // tight, so the grouping survives at every width.
            ViewThatFits(in: .horizontal) {
                fleetCluster(showsLabels: true)
                fleetCluster(showsLabels: false)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { statusSurface }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("SwiftMiner status: \(state.title)")
    }

    @ViewBuilder
    private var statusSurface: some View {
        AppearanceRoundedSurface(
            role: .elevated,
            cornerRadius: 18,
            material: .regularMaterial,
            usesNativeGlass: true
        )
    }

    private func fleetCluster(showsLabels: Bool) -> some View {
        MinerStatusCluster(
            uptimeStart: fleet.uptimeStart,
            lastPollAt: fleet.lastPollAt,
            healthTitle: fleet.healthTitle,
            healthSymbol: fleet.healthSymbol,
            healthTint: fleet.healthTint,
            uptimeLabel: "Avg Uptime",
            lastPollLabel: "Avg Last Poll",
            healthLabel: "Squad Health",
            showsLabels: showsLabels,
            // Wider than the per-miner cluster: these labels carry the "Avg" and
            // "Squad" qualifiers and must stay on one line.
            cellWidth: 136
        )
    }
}
