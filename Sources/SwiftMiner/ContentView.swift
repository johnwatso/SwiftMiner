import SwiftUI
import SwiftMinerCore
import AppKit
import UniformTypeIdentifiers

/// Root view — 2-column NavigationSplitView (Sidebar | Detail)
struct ContentView: View {
    @Environment(NavigationModel.self) var navigation

    var body: some View {
        @Bindable var nav = navigation
        NavigationSplitView(columnVisibility: $nav.columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 180, max: 180)
        } detail: {
            detailContainer
        }
        .background(WindowZoomConfigurator())
        .frame(minWidth: 800, minHeight: 600)
        .sheet(isPresented: $nav.showAddAccountSheet) {
            AuthRequiredSheet(
                isPresented: $nav.showAddAccountSheet,
                reconnectingMinerId: nav.reconnectingMinerId
            )
                .environment(navigation)
                .onDisappear {
                    navigation.reconnectingMinerId = nil
                }
        }
        .onAppear {
            navigation.columnVisibility = .all
            navigation.preloadDropsTab()
        }
        .onChange(of: navigation.minerManager.miners.count) { _, _ in
            navigation.handleAccountCountChange()
            navigation.preloadDropsTab(force: true)
        }
    }

    // MARK: - Detail View

    private var detailContainer: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()

            detailView
                .id(navigation.selectedItem ?? .overview)
        }
        .animation(nil, value: navigation.selectedItem)
    }

    @ViewBuilder
    private var detailView: some View {
        switch navigation.selectedItem {
        case .overview, .none:
            OverviewView()

        case .miners:
            MinersOverviewView()

        case .drops:
            DropsListView()

        case .events:
            EventLogView()

        case .admin:
            if Settings.shared.swiftBotEnabled {
                AdminView()
            } else {
                OverviewView()
            }
        }
    }
}

// MARK: - Overview View

enum OverviewArtworkResolver {
    static func artworkURL(
        for preference: GamePreference,
        campaigns: [CampaignViewData]
    ) -> URL? {
        campaigns.lazy.compactMap { campaign in
            guard matches(
                gameId: campaign.gameId,
                gameName: campaign.gameName,
                preference: preference
            ) else { return nil }
            return usable(campaign.artworkURL)
        }.first
    }

    static func artworkURL(
        for preference: GamePreference,
        campaigns: [Campaign]
    ) -> URL? {
        campaigns.lazy.compactMap { campaign in
            guard matches(
                gameId: campaign.game.id,
                gameName: campaign.game.name,
                preference: preference
            ) else { return nil }
            return usable(campaign.game.boxArtURL)
        }.first
    }

    static func matches(
        gameId: String?,
        gameName: String,
        preference: GamePreference
    ) -> Bool {
        let idMatches = gameId.map { !$0.isEmpty && $0 == preference.gameId } ?? false
        let nameMatches = gameName.localizedCaseInsensitiveCompare(preference.gameName) == .orderedSame
            || comparableName(gameName) == comparableName(preference.gameName)
        return idMatches || nameMatches
    }

    /// Artwork for preferred games that have no eligible campaign of their own, indexed
    /// under the same match keys the feed uses.
    ///
    /// Resolving this per preference rescanned every campaign — and re-flattened every
    /// miner's campaign list — once for each preferred game still waiting for a campaign.
    /// Built at most once per feed derivation, and only when some game actually needs it.
    struct ArtworkIndex {
        /// The first campaign, in the order the sources were given, whose usable artwork
        /// matched a key. Keeping the position preserves the "first match wins, primary
        /// source before fallback" order the linear scan produced.
        private var byKey: [String: (position: Int, url: URL)] = [:]

        init(sources: [[(gameId: String?, gameName: String, artworkURL: URL?)]]) {
            var position = 0
            for source in sources {
                for campaign in source {
                    defer { position += 1 }
                    let keys = GameMatchIndex.keys(
                        gameId: campaign.gameId,
                        gameName: campaign.gameName
                    ).filter { byKey[$0] == nil }
                    guard !keys.isEmpty, let url = usable(campaign.artworkURL) else { continue }
                    for key in keys {
                        byKey[key] = (position, url)
                    }
                }
            }
        }

        func artworkURL(for preference: GamePreference) -> URL? {
            GameMatchIndex.keys(gameId: preference.gameId, gameName: preference.gameName)
                .compactMap { byKey[$0] }
                .min(by: { $0.position < $1.position })?
                .url
        }
    }

    private static func usable(_ url: URL?) -> URL? {
        guard let url else { return nil }
        guard url.isFileURL else { return url }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private static func comparableName(_ value: String) -> String {
        value
            .lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }
}

struct OverviewView: View {
    @Environment(NavigationModel.self) var navigation
    var settings: Settings { .shared }
    @State var overviewCampaigns: [CampaignViewData] = []
    /// `overviewCampaigns` with excluded games removed. Held rather than derived because
    /// the feed, the system-state banner, the activity section, and artwork resolution all
    /// read it, and each read used to re-run a locale comparison against every exclusion.
    @State var visibleCampaigns: [CampaignViewData] = []
    @State var isRefreshing = false
    @State var isShowingGameManagement = false
    @State var customArtworkImportGame: Game?
    @State var isShowingArtworkImporter = false
    @State var isMinerStatusLegendPresented = false
    /// Drag state for reordering the prioritised rail. Stored here because an
    /// extension cannot declare stored properties; the reordering itself lives in
    /// OverviewView+CampaignFeed.swift.
    @State var activePriorityDragIndex: Int?
    @State var projectedPriorityDropIndex: Int?
    @State var activePriorityDragProgress: CGFloat = 0

    var campaigns: [CampaignViewData] { visibleCampaigns }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !navigation.minerManager.miners.isEmpty {
                    systemStateBanner
                }
                minerActivitySection
                campaignFeedSection
            }
            .padding(24)
        }
        .navigationTitle("Overview")
        .onReceive(NotificationCenter.default.publisher(for: .dropsCampaignsDidUpdate)) { _ in
            // Miner registration makes the per-account disk caches available after
            // Overview's first task may already have returned empty. Drops listens to
            // this same event; keep Overview on the same source-of-truth timeline.
            Task { @MainActor in
                applyOverviewCampaigns(await navigation.minerManager.dataCoordinator.allCampaigns())
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await refreshFromOverview() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(isRefreshing)
            }
        }
        .task { await refreshSummary() }
        .onChange(of: settings.excludedGames) { _, excluded in
            visibleCampaigns = Self.campaignsExcludingHiddenGames(in: overviewCampaigns, excludedGames: excluded)
        }
        .sheet(isPresented: $isShowingGameManagement) {
            GamePreferenceManagementView(
                settings: settings,
                minerManager: navigation.minerManager
            )
        }
        .fileImporter(
            isPresented: $isShowingArtworkImporter,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            guard let game = customArtworkImportGame else { return }
            defer { customArtworkImportGame = nil }

            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    try settings.setCustomArtwork(from: url, for: game)
                } catch {
                    Logger.artwork.error("Custom artwork import failed: \(error.localizedDescription)")
                }
            case .failure(let error):
                Logger.artwork.error("Custom artwork selection failed: \(error.localizedDescription)")
            }
        }
    }





// MARK: - Miner Status Legend Popover

struct MinerStatusLegendPopover: View {
    var settings: Settings { .shared }

    private struct StatusEntry {
        let symbol: String
        let paletteColors: (Color, Color)?
        let monoColor: Color
        let title: String
        let description: String
    }

    private var entries: [StatusEntry] {
        [
            StatusEntry(
                symbol: "bolt.fill",
                paletteColors: nil,
                monoColor: .green,
                title: "Watching",
                description: "Actively watching a live stream and earning drops."
            ),
            StatusEntry(
                symbol: "gift.fill",
                paletteColors: nil,
                monoColor: .purple,
                title: "Claiming Reward",
                description: "A completed drop is being claimed from Twitch."
            ),
            StatusEntry(
                symbol: "arrow.clockwise",
                paletteColors: nil,
                monoColor: .blue,
                title: "Updating",
                description: "Refreshing campaigns and verified drop progress from Twitch."
            ),
            StatusEntry(
                symbol: "antenna.radiowaves.left.and.right",
                paletteColors: nil,
                monoColor: .cyan,
                title: "Looking for Streams",
                description: "Eligible campaigns found — waiting for a live channel to become available."
            ),
            StatusEntry(
                symbol: "calendar.badge.checkmark",
                paletteColors: (.green, .red),
                monoColor: .green,
                title: "Up to Date",
                description: "No drops left to earn right now. The miner is standing by."
            ),
            StatusEntry(
                symbol: "clock.badge.exclamationmark",
                paletteColors: (.red, Color(nsColor: .labelColor)),
                monoColor: .yellow,
                title: "No Recent Activity",
                description: "Worker is running but hasn't reported a liveness signal yet."
            ),
            StatusEntry(
                symbol: "wrench.and.screwdriver.fill",
                paletteColors: nil,
                monoColor: .orange,
                title: "Recovering",
                description: "Restarting the miner and rebuilding Twitch subscriptions after a stall."
            ),
            StatusEntry(
                symbol: "bolt.horizontal.circle.fill",
                paletteColors: nil,
                monoColor: .red,
                title: "Miner Unresponsive",
                description: "This miner stopped receiving Twitch activity while others are still active."
            ),
            StatusEntry(
                symbol: SystemSymbolCompatibility.resolvedName(for: "personalhotspot.slash"),
                paletteColors: nil,
                monoColor: .orange,
                title: "Account Not Linked",
                description: "The game account must be connected on Twitch before drops can be earned."
            ),
            StatusEntry(
                symbol: "person.crop.circle.badge.exclamationmark",
                paletteColors: nil,
                monoColor: .orange,
                title: "Authentication Expired",
                description: "Twitch credentials have expired. Re-link the account to resume."
            ),
            StatusEntry(
                symbol: "arrow.triangle.2.circlepath",
                paletteColors: nil,
                monoColor: .orange,
                title: "Reconnecting",
                description: "Refreshing the Twitch session after a token or network interruption."
            ),
            StatusEntry(
                symbol: "exclamationmark.triangle.fill",
                paletteColors: nil,
                monoColor: .red,
                title: "Error",
                description: "Something went wrong. Check the Activity Log for details."
            ),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Miner Card Statuses")
                .font(.headline)

            VStack(alignment: .leading, spacing: 11) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    HStack(alignment: .top, spacing: 10) {
                        Group {
                            if let (primary, secondary) = entry.paletteColors {
                                Image(systemName: entry.symbol)
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(primary, secondary)
                            } else {
                                Image(systemName: entry.symbol)
                                    .foregroundStyle(entry.monoColor)
                            }
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .frame(width: 20, alignment: .center)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.title)
                                .font(.system(size: 13, weight: .semibold))

                            Text(entry.description)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .lineSpacing(1.5)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 360, alignment: .leading)
    }
}

    @ViewBuilder
    func sectionHeading(_ title: String) -> some View {
        Text(title)
            .font(.title3.weight(.medium))
            .padding(.top, 10)
    }

    @ViewBuilder
    func sectionHeading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title3.weight(.medium))
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 10)
    }
}

// MARK: - Supporting Types

enum OverviewSystemState: Equatable {
    case idleNoEligibleCampaigns
    case idleAllCampaignsCompleted
    case waitingForLiveStream
    case waitingRefreshingCampaigns
    case waitingAuthenticating
    case minerUnresponsive
    case recovering
    case noRecentActivity
    case blockedAccountNotLinked(minerName: String?, blockedCount: Int)
    case blockedAuthenticationExpired
    case blockedNeedsAttention
    case mining(activeMinerCount: Int, totalMinerCount: Int)

    var title: String {
        switch self {
        case .idleNoEligibleCampaigns, .idleAllCampaignsCompleted:
            return "Up to Date"
        case .waitingForLiveStream:
            return "Looking for Streams"
        case .waitingRefreshingCampaigns:
            return "Updating…"
        case .waitingAuthenticating:
            return "Reconnecting"
        case .recovering:
            return "Waiting"
        case .minerUnresponsive, .noRecentActivity:
            return "Attention"
        case .blockedAccountNotLinked(let minerName, let blockedCount):
            if let minerName {
                return "\(minerName) is blocked"
            }
            return "\(blockedCount) miners blocked"
        case .blockedAuthenticationExpired, .blockedNeedsAttention:
            return "Blocked"
        case .mining:
            return "Mining Active"
        }
    }

    var subtitle: String {
        switch self {
        case .idleNoEligibleCampaigns:
            return "No active campaigns are available right now."
        case .idleAllCampaignsCompleted:
            return "All campaigns have been earned and completed."
        case .waitingForLiveStream:
            return "Checking channels for active streams."
        case .waitingRefreshingCampaigns:
            return "Checking campaigns and drop progress."
        case .waitingAuthenticating:
            return "Reconnecting and restoring Twitch subscriptions."
        case .minerUnresponsive:
            return "One or more miners stopped receiving Twitch activity while other miners are still active."
        case .recovering:
            return "A miner is being restarted and refreshed automatically."
        case .noRecentActivity:
            return "A miner is running but has not reported recent activity yet."
        case .blockedAccountNotLinked(let minerName, let blockedCount):
            if let minerName {
                return "Account not linked. Link \(minerName)'s account to start mining drops."
            }
            return "\(blockedCount) miners need account linking before they can mine drops."
        case .blockedAuthenticationExpired:
            return "Account authentication expired. Please re-connect."
        case .blockedNeedsAttention:
            return "Check Activity Log for the latest issue before mining can continue."
        case .mining(let activeMinerCount, let totalMinerCount):
            if totalMinerCount <= 1 {
                return "Miner is currently active."
            }
            if activeMinerCount == totalMinerCount {
                return "All miners are currently active."
            }
            return "\(activeMinerCount) of \(totalMinerCount) miners are currently active."
        }
    }

    var symbol: String {
        switch self {
        case .idleNoEligibleCampaigns:
            return "calendar.badge.checkmark"
        case .idleAllCampaignsCompleted:
            return "calendar.badge.checkmark"
        case .waitingForLiveStream:
            // Mining that cannot start yet, not a fault.
            return SystemSymbolCompatibility.resolvedName(for: "bolt.badge.clock.fill")
        case .waitingRefreshingCampaigns:
            return "arrow.clockwise"
        case .waitingAuthenticating:
            return "arrow.triangle.2.circlepath"
        case .minerUnresponsive:
            return SystemSymbolCompatibility.resolvedName(for: "bolt.trianglebadge.exclamationmark.fill")
        case .recovering:
            return "wrench.and.screwdriver.fill"
        case .noRecentActivity:
            // Running, but banking nothing — a mining problem, so a badged bolt like the rest.
            return SystemSymbolCompatibility.resolvedName(for: "bolt.trianglebadge.exclamationmark.fill")
        case .blockedAccountNotLinked:
            return SystemSymbolCompatibility.resolvedName(for: "personalhotspot.slash")
        case .blockedAuthenticationExpired, .blockedNeedsAttention:
            return "exclamationmark.triangle.fill"
        case .mining(let activeMinerCount, let totalMinerCount):
            // The bolt is what mining looks like everywhere else in the app, so the banner
            // uses it too, badged with whether the whole squad is up.
            return SystemSymbolCompatibility.resolvedName(
                for: activeMinerCount < totalMinerCount
                    ? "bolt.trianglebadge.exclamationmark.fill"
                    : "bolt.badge.checkmark.fill"
            )
        }
    }

    var color: Color {
        switch self {
        case .idleNoEligibleCampaigns, .idleAllCampaignsCompleted:
            return .green
        case .waitingForLiveStream:
            return .cyan
        case .waitingRefreshingCampaigns:
            return .blue
        case .waitingAuthenticating:
            return .orange
        case .minerUnresponsive:
            return .red
        case .recovering:
            return .orange
        case .noRecentActivity:
            return .yellow
        case .blockedAccountNotLinked, .blockedAuthenticationExpired, .blockedNeedsAttention:
            return .orange
        case .mining:
            return .green
        }
    }

    var action: OverviewSystemAction? {
        switch self {
        case .idleNoEligibleCampaigns, .idleAllCampaignsCompleted:
            return .viewDrops
        case .waitingForLiveStream, .waitingAuthenticating, .recovering:
            return .viewSchedule
        case .waitingRefreshingCampaigns:
            return nil
        case .minerUnresponsive, .noRecentActivity:
            return nil
        case .blockedAccountNotLinked, .blockedAuthenticationExpired, .blockedNeedsAttention:
            return .linkAccount
        case .mining:
            return nil
        }
    }
}

enum OverviewSystemAction {
    case viewDrops
    case viewSchedule
    case linkAccount

    var title: String {
        switch self {
        case .viewDrops:
            return "View Drops"
        case .viewSchedule:
            return "View Schedule"
        case .linkAccount:
            return "Link Account"
        }
    }
}

struct OverviewSystemStateBanner: View {
    let state: OverviewSystemState
    let fleet: MinerFleetStatus
    let onAction: (OverviewSystemAction) -> Void

    var body: some View {
        HStack(spacing: 14) {
            AnimatedStatusIcon(symbol: state.symbol, color: state.color, size: 16, weight: .semibold)
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

            if let action = state.action {
                Button {
                    onAction(action)
                } label: {
                    Text(action.title)
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(state.color)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Match the corner radius of the Miner Activity cards below, which use
        // `.glassCard()` (default radius 18).
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 1)
        }
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

// MARK: - Campaign Summary Row



// MARK: - Window Configuration

private struct WindowZoomConfigurator: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            configure(window, coordinator: context.coordinator)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        configure(window, coordinator: context.coordinator)
    }

    private func configure(_ window: NSWindow, coordinator: Coordinator) {
        if !coordinator.didConfigure {
            coordinator.didConfigure = true
            window.styleMask.insert(.resizable)
            window.collectionBehavior.remove([
                .fullScreenPrimary,
                .fullScreenAuxiliary,
                .fullScreenAllowsTiling
            ])
            window.collectionBehavior.insert([
                .fullScreenNone,
                .fullScreenDisallowsTiling
            ])
        }
    }

    final class Coordinator: NSObject {
        var didConfigure = false
    }
}

// MARK: - Preview

#Preview {
    ContentView()
        .environment(NavigationModel(clientId: "preview"))
        .environment(AppModel(clientId: "preview"))
}
