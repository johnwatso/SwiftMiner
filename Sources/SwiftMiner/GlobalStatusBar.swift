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
        return demoExpanded(miners)
        #else
        return miners
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

// MARK: - Floating Global Status Dock

/// What changes the dock's width.
///
/// The live values behind Avg Uptime and Avg Last Poll are left out on purpose:
/// they tick every second inside fixed-width cells, so they never move anything
/// — keying off them would only animate the dock against itself.
private struct DockLayout: Equatable {
    let title: String
    let subtitle: String
    let symbol: String
    let healthTitle: String
    let healthSymbol: String
    let needsAccountLink: Bool

    init(state: OverviewSystemState, fleet: MinerFleetStatus) {
        title = state.title
        subtitle = state.compactSubtitle
        symbol = state.symbol
        healthTitle = fleet.healthTitle
        healthSymbol = fleet.healthSymbol
        needsAccountLink = state.needsAccountLink
    }
}


/// SwiftMiner's global heartbeat as a floating dock, in the spirit of the Music
/// app's Now Playing control: it hovers over the bottom of the content area
/// rather than occupying a band of it, and content scrolls underneath.
///
/// It presents state the app already owns — `SwiftMinerFleet.systemState` for
/// the headline and `MinerFleetStatus` for the three fleet metrics — and
/// computes none of its own. There is no expanded form: what a miner is doing
/// belongs to Miner Activity, and this surface answers the different question
/// of what SwiftMiner itself is doing.
struct GlobalStatusBar: View {
    @Environment(NavigationModel.self) private var navigation
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var settings: Settings { .shared }

    /// The last known campaign set, filtered the way Overview filters it. Read
    /// from the coordinator's cache rather than re-fetched: the dock is a
    /// passenger on whatever Overview and Drops already load.
    @State private var campaigns: [CampaignViewData] = []

    /// Footprint. Fixed so the space reserved beneath scrolling content stays
    /// correct whichever density `ViewThatFits` settles on.
    static let collapsedHeight: CGFloat = 72
    static let bottomMargin: CGFloat = 20

    /// Space to keep clear below page content so a page's last row can always be
    /// scrolled out from under the dock instead of hiding beneath it forever.
    static var reservedHeight: CGFloat { collapsedHeight + bottomMargin + 10 }

    /// How much room each section gets. The dock gives ground in the order the
    /// information can afford to lose it: horizontal padding first, then the gap
    /// between sections, then the width of the metric cells, and only at the
    /// very end their labels. No metric is ever dropped — all three are the
    /// point of the dock.
    private enum Density {
        case comfortable
        case compact
        case narrow
        case condensed

        /// Padding around the leading mining-state section.
        var sectionPadding: CGFloat {
            switch self {
            case .comfortable: return 20
            case .compact: return 14
            case .narrow: return 11
            case .condensed: return 9
            }
        }

        /// The gap between the metric cluster and the separators either side.
        var clusterInset: CGFloat {
            switch self {
            case .comfortable: return 9
            case .compact: return 5
            case .narrow, .condensed: return 2
            }
        }

        /// Wide enough at rest that "AVG LAST POLL" and its value never feel
        /// cramped; the per-miner default and below only once space is short.
        var cellWidth: CGFloat {
            switch self {
            case .comfortable: return 142
            case .compact: return 126
            case .narrow, .condensed: return 112
            }
        }

        /// The last thing to go. Below this there is nothing left to give, so
        /// the metrics stay put and the dock simply stops shrinking.
        var showsLabels: Bool {
            self != .condensed
        }
    }

    var body: some View {
        let miners = SwiftMinerFleet.displayedMiners(from: navigation.minerManager.miners)

        Group {
            if miners.isEmpty {
                // Nothing to report before an account exists; onboarding stays clear.
                Color.clear.frame(width: 0, height: 0)
            } else {
                dock(
                    state: SwiftMinerFleet.systemState(miners: miners, campaigns: campaigns),
                    fleet: MinerFleetStatus.make(miners: miners)
                )
            }
        }
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

    private func dock(state: OverviewSystemState, fleet: MinerFleetStatus) -> some View {
        let shape = Capsule(style: .continuous)

        // Spelled out rather than driven off a `CaseIterable` loop:
        // `ViewThatFits` picks between its direct subviews, and a `ForEach`
        // would be a single subview rather than four candidates.
        return ViewThatFits(in: .horizontal) {
            row(state: state, fleet: fleet, density: .comfortable)
            row(state: state, fleet: fleet, density: .compact)
            row(state: state, fleet: fleet, density: .narrow)
            row(state: state, fleet: fleet, density: .condensed)
        }
        .frame(height: Self.collapsedHeight)
        .background { surface(shape) }
        .overlay { perimeter(shape) }
        // Deliberately not clipped to the capsule: the surface and perimeter are
        // already capsule-shaped, and clipping here would crop off the very
        // shadows that make the dock read as floating.
        .padding(.horizontal, 14)
        .padding(.bottom, Self.bottomMargin)
        // The dock is centred and sizes to its content, so a state change moves
        // both its edges at once — the widest jump on the page for a change the
        // user did not ask for. Settle into the new width instead.
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.32),
            value: DockLayout(state: state, fleet: fleet)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("SwiftMiner status: \(state.title)")
    }

    /// The dock has to read as floating over a near-white Overview without
    /// turning into an opaque toolbar, so the separation is built from depth
    /// rather than fill: two stacked shadows — a tight contact shadow and a
    /// wide ambient one, the way macOS lights its own floating controls — under
    /// a translucent surface carrying a faint highlight down from its top edge.
    @ViewBuilder
    private func surface(_ shape: Capsule) -> some View {
        if #available(macOS 26, *) {
            // Tahoe puts Liquid Glass on the control layer, and a control
            // floating over scrolling content is exactly that layer. Its own
            // refraction and specular do the surface work; the shadows only
            // add the elevation.
            shape
                .fill(.clear)
                .glassEffect(.regular.interactive())
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.34 : 0.10), radius: 3, y: 1)
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.40 : 0.16), radius: 22, y: 9)
        } else {
            ZStack {
                shape.fill(.regularMaterial)

                // Sits behind the content, never over it, so the labels keep
                // their contrast.
                shape.fill(
                    LinearGradient(
                        colors: [
                            .white.opacity(colorScheme == .dark ? 0.10 : 0.42),
                            .clear
                        ],
                        startPoint: .top,
                        endPoint: .center
                    )
                )
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.34 : 0.10), radius: 3, y: 1)
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.40 : 0.16), radius: 22, y: 9)
        }
    }

    /// Perimeter in two passes at the same inset: a hairline the whole way
    /// round, then a brighter arc over the top where light would catch it. The
    /// silhouette comes from that light, not from an outline drawn around it.
    private func perimeter(_ shape: Capsule) -> some View {
        ZStack {
            shape
                .strokeBorder(.separator.opacity(0.65), lineWidth: 1)

            shape
                .strokeBorder(
                    LinearGradient(
                        stops: [
                            .init(color: .white.opacity(colorScheme == .dark ? 0.42 : 0.85), location: 0),
                            .init(color: .white.opacity(colorScheme == .dark ? 0.10 : 0.30), location: 0.42),
                            .init(color: .clear, location: 0.6)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 1
                )
        }
        .allowsHitTesting(false)
    }

    private func row(
        state: OverviewSystemState,
        fleet: MinerFleetStatus,
        density: Density
    ) -> some View {
        HStack(spacing: 0) {
            primaryStatus(state: state, density: density)

            separator

            fleetCluster(fleet, density: density)

            if state.needsAccountLink {
                separator
                linkAccountButton(tint: state.color, density: density)
            }
        }
    }

    /// The strongest section in the dock: what SwiftMiner itself is doing. It
    /// carries the only saturated colour in the row, so a healthy fleet is not
    /// washed in green and a failing one can still change the accent.
    private func primaryStatus(state: OverviewSystemState, density: Density) -> some View {
        HStack(spacing: 13) {
            AnimatedStatusIcon(symbol: state.symbol, color: state.color, size: 20, weight: .semibold)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(state.title)
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)

                Text(state.compactSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.leading, density.sectionPadding + 2)
        .padding(.trailing, density.sectionPadding)
        .help(state.subtitle)
    }

    /// The very cluster the Miners tab shows per miner, carrying fleet-wide
    /// values — label above value, one cell per metric, hairlines between them.
    /// Reusing it is what keeps "Avg Last Poll" here and "Last Poll" there
    /// reading as the same number rather than two similar ones.
    private func fleetCluster(_ fleet: MinerFleetStatus, density: Density) -> some View {
        MinerStatusCluster(
            uptimeStart: fleet.uptimeStart,
            lastPollAt: fleet.lastPollAt,
            healthTitle: fleet.healthTitle,
            healthSymbol: fleet.healthSymbol,
            healthTint: fleet.healthTint,
            uptimeLabel: "Avg Uptime",
            lastPollLabel: "Avg Last Poll",
            healthLabel: "Squad Health",
            showsLabels: density.showsLabels,
            cellWidth: density.cellWidth,
            // The dock is already the surface; a second boxed one inside it
            // would be a card within a card.
            showsContainer: false,
            usesProminentSeparators: true
        )
        .padding(.horizontal, density.clusterInset)
    }

    /// Shown only while a miner is blocked on its account link — the one thing
    /// the dock can put right that nothing else on screen can.
    private func linkAccountButton(tint: Color, density: Density) -> some View {
        Button(action: linkAccount) {
            Text("Link Account")
                .font(.system(size: 12, weight: .semibold))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(tint)
        .padding(.horizontal, density.sectionPadding)
    }

    /// Matches the cluster's own inter-cell hairline, so the four sections are
    /// parted by one consistent line rather than two different ones.
    private var separator: some View {
        Rectangle()
            .fill(.primary.opacity(0.13))
            .frame(width: 1, height: 28)
    }

    private func linkAccount() {
        if let miner = firstMinerForAccountLinkAction {
            navigation.reconnectTwitchAccount(for: miner.id)
        } else {
            navigation.showAddAccountSheet = true
        }
    }

    private var firstMinerForAccountLinkAction: MinerManager.ManagedMiner? {
        let miners = navigation.minerManager.miners
        return miners.first { $0.needsAuth }
            ?? miners.first { $0.status == .blockedAccountNotLinked }
            ?? miners.first { $0.status == .error }
    }
}
