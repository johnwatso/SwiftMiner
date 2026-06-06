import SwiftUI
import SwiftMinerCore
import SwiftMinerService

/// Navigation model for the multi-miner dashboard
/// Manages sidebar selection and view routing
@MainActor
@Observable
public final class NavigationModel {
    
    // MARK: - Navigation State
    public enum SidebarItem: Hashable, Identifiable {
        case overview
        case miners
        case drops
        case events
        case admin

        public var id: String {
            switch self {
            case .overview: return "overview"
            case .miners: return "miners"
            case .drops: return "drops"
            case .events: return "events"
            case .admin: return "admin"
            }
        }

        public var displayName: String {
            switch self {
            case .overview: return "Overview"
            case .miners: return "miners"
            case .drops: return "Drops"
            case .events: return "Activity Log"
            case .admin: return "Discord"
            }
        }
    }

    public enum DropsFilterIntent: Hashable {
        case upcoming
    }

    public enum OnboardingAccountState: Equatable {
        case noAccounts
        case hasAccounts(count: Int)
    }

    public enum OnboardingSetupStage: String, CaseIterable {
        case connecting
        case campaigns
        case inventory
        case finalising

        public var title: String {
            switch self {
            case .connecting: return "Connecting your account..."
            case .campaigns: return "Fetching active campaigns..."
            case .inventory: return "Syncing your inventory..."
            case .finalising: return "Preparing your dashboard..."
            }
        }
    }

    public struct OnboardingPresentation: Equatable {
        public let title: String
        public let subtitle: String
        public let accountState: OnboardingAccountState
        public let showsGamePreferences: Bool
        public let showsPreferences: Bool
        public let setupStage: OnboardingSetupStage?
    }
    
    public var selectedItem: SidebarItem? = .overview
    public var columnVisibility: NavigationSplitViewVisibility = .all
    public var requestedDropsFilter: DropsFilterIntent?


    // MARK: - Onboarding State

    /// Whether the optional onboarding surface should be visible.
    public var showOnboarding = false
    public private(set) var onboardingPresentation: OnboardingPresentation?
    public var onboardingSetupStage: OnboardingSetupStage = .connecting
    public var isRunningOnboardingSetup = false

    // MARK: - Sheet State

    /// Present the Add Account sheet from any view by setting this to true.
    public var showAddAccountSheet = false

    // MARK: - Content State

    public var selectedMinerId: String?
    public var selectedCampaignId: String?
    public private(set) var isDropsBackgroundRefreshRunning = false
    public var unownedAccounts: [Account] = []
    public var registeredUsers: [MinerUser] = []
    public var swiftBotState: SwiftBotConnectionState = .notConfigured
    public var pendingSwiftBotPairingRequest = false

    public func requestDropsFilter(_ intent: DropsFilterIntent) {
        requestedDropsFilter = intent
    }

    public func consumeDropsFilterIntent() -> DropsFilterIntent? {
        defer { requestedDropsFilter = nil }
        return requestedDropsFilter
    }

    public func requestSwiftBotPairing() {
        Settings.shared.swiftBotEnabled = true
        pendingSwiftBotPairingRequest = true
    }

    public func consumeSwiftBotPairingRequest() -> Bool {
        defer { pendingSwiftBotPairingRequest = false }
        return pendingSwiftBotPairingRequest
    }

    /// Start the in-process HTTP server that exposes the SwiftMiner REST API to SwiftBot.
    /// Without this, SwiftBot's `/miner` command and pairing health checks have nothing to talk to.
    private func startSwiftMinerHTTPServerIfNeeded() async {
        guard httpAPIServer == nil else { return }
        Settings.shared.ensureSwiftBotSecrets()
        let apiKey = Settings.shared.swiftMinerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard apiKey.count >= 32 else {
            logEvent(message: "API server not started — API key missing", level: .warning)
            return
        }
        let endpoint = Settings.shared.swiftMinerAPIEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = URL(string: endpoint)?.port.flatMap { UInt16(exactly: $0) } ?? 8080

        let projectionBuilder = DiscordProjectionBuilder(
            manager: sqliteManager,
            stateProvider: NavigationProjectionStateProvider(model: self)
        )
        let clientId = Settings.shared.resolvedClientId
        let authService = TwitchAuthService(clientId: clientId, tokenStore: minerManager.tokenStore)
        let routes = DiscordAPIRoutes(
            manager: sqliteManager,
            projectionBuilder: projectionBuilder,
            apiKey: apiKey,
            adminLinkingService: adminLinkingService,
            authService: authService
        )
        await routes.setOnAccountActivated { [weak self] account, discordUserId in
            guard let self else { return }
            await self.minerManager.attachActivatedAccount(account)
            // Persist the Discord ↔ Twitch link to the Keychain account and the in-memory
            // miner so the new miner shows up as Linked immediately and survives restarts.
            await MainActor.run {
                self.minerManager.setOwnerDiscordId(forAccountId: account.id, to: discordUserId)
            }
            // Confirm to the user via Discord DM with their Twitch username and current app-level priority games.
            let priorityGames = await MainActor.run { Settings.shared.priorityGames }
            _ = await self.swiftBotConnectionService.sendLinkedDM(
                to: discordUserId,
                twitchUsername: account.username,
                priorityGames: priorityGames
            )
        }
        await routes.setOnMinerControl { [weak self] discordUserId, action in
            guard let self else {
                return MinerControlResponse(ok: false, action: action.rawValue, state: "unavailable", twitchUsername: nil, message: "SwiftMiner is not available.")
            }
            return await self.handleDiscordMinerControl(discordUserId: discordUserId, action: action)
        }
        await routes.setOnIgnoreLinkWarning { [weak self] discordUserId, gameName in
            guard let self else { return false }
            return await self.handleDiscordIgnoreLinkWarning(discordUserId: discordUserId, gameName: gameName)
        }
        await routes.setOnPauseLinkWarning { [weak self] discordUserId, gameName, expiresAt in
            guard let self else { return false }
            return await self.handleDiscordPauseLinkWarning(
                discordUserId: discordUserId,
                gameName: gameName,
                expiresAt: expiresAt
            )
        }
        await routes.setOnPrioritiseGame { [weak self] discordUserId, accountId, gameName in
            guard let self else { return nil }
            return await self.handleDiscordPrioritiseGame(
                discordUserId: discordUserId,
                accountId: accountId,
                gameName: gameName
            )
        }
        await routes.setOnSetPriorities { [weak self] discordUserId, accountId, games in
            guard let self else { return nil }
            return await self.handleDiscordSetPriorities(
                discordUserId: discordUserId,
                accountId: accountId,
                games: games
            )
        }
        let router = HTTPRouter()
        await routes.configure(router)
        let server = HTTPAPIServer(port: port, apiKey: apiKey, router: router)
        do {
            try await server.start()
            httpAPIServer = server
            logEvent(message: "API server listening on port \(port)", level: .info)
            print("[NavigationModel] SwiftMiner HTTP server listening on port \(port)")
        } catch {
            logEvent(message: "API server failed on port \(port): \(error.localizedDescription)", level: .error)
            print("[NavigationModel] Failed to start HTTP server on port \(port): \(error)")
        }
    }

    /// Upserts every MinerManager account into SQLite so AdminLinkingService can find them.
    /// Only touches twitch_id and username — never overwrites owner_discord_id or tokens.
    func syncMinersToSQLite() async {
        for miner in minerManager.miners {
            await adminLinkingService.upsertAccountIdentity(twitchId: miner.accountId, username: miner.username)
        }
    }

    public func refreshUnownedAccounts() async {
        unownedAccounts = await adminLinkingService.getUnownedAccounts()
    }

    public func refreshRegisteredUsers() async {
        registeredUsers = await adminLinkingService.getAllUsers()
    }

    // MARK: - SwiftBot Integration

    /// Trigger a SwiftBot connectivity check and update local state.
    public func checkSwiftBotConnection() async {
        guard Settings.shared.swiftBotEnabled else {
            self.swiftBotState = .notConfigured
            return
        }
        let newState = await swiftBotConnectionService.checkHealth()
        self.swiftBotState = newState
    }

    /// Update the SwiftBot endpoint and refresh connectivity.
    public func updateSwiftBotEndpoint(_ urlString: String) async {
        guard Settings.shared.swiftBotEnabled else { return }
        await swiftBotConnectionService.updateEndpoint(urlString)
        await checkSwiftBotConnection()
    }

    /// Refresh webhook delivery settings after the user edits the SwiftBot callback URL or HMAC secret.
    public func updateSwiftBotWebhookConfig() async {
        await eventOutboxService.updateConfig(
            webhookURL: URL(string: Settings.shared.swiftBotWebhookURL),
            hmacSecret: Settings.shared.swiftBotHmacSecret
        )
        if Settings.shared.swiftBotEnabled {
            await eventOutboxService.start()
        }
    }

    /// Dismiss the account-link ("needs linking") warning for a game across all
    /// of the requesting Discord user's miners — the same state the GUI dismiss
    /// sets, so it both stops future DMs and clears the GUI warning.
    /// Returns true when at least one owned miner was updated.
    public func handleDiscordIgnoreLinkWarning(discordUserId: String, gameName: String) async -> Bool {
        let owned = minerManager.miners.filter { $0.ownerDiscordId == discordUserId }
        guard !owned.isEmpty else { return false }

        // Prefer a real game id resolved from loaded campaigns; fall back to the
        // lowercased name (the engine suppresses by either id or lowercased name).
        let gameKey = accountLinkWarningGameKey(for: gameName)

        for miner in owned {
            await minerManager.setAccountLinkWarningIgnored(minerId: miner.id, gameId: gameKey, ignored: true)
            Settings.shared.setIgnoreAccountLinkWarnings(true, for: miner.accountId, gameId: gameKey)
        }
        return true
    }

    public func handleDiscordPauseLinkWarning(discordUserId: String, gameName: String, expiresAt: Date) async -> Bool {
        let owned = minerManager.miners.filter { $0.ownerDiscordId == discordUserId }
        guard !owned.isEmpty else { return false }

        let gameKey = accountLinkWarningGameKey(for: gameName)
        for miner in owned {
            await minerManager.setAccountLinkWarningIgnored(minerId: miner.id, gameId: gameKey, ignored: true)
            Settings.shared.setTemporaryIgnoreWarning(
                until: expiresAt,
                accountId: miner.accountId,
                gameId: gameKey,
                type: .accountLink
            )
        }
        return true
    }

    public func handleDiscordPrioritiseGame(discordUserId: String, accountId: String, gameName: String) async -> [String]? {
        guard let miner = minerManager.miners.first(where: { $0.ownerDiscordId == discordUserId && $0.accountId == accountId }) else {
            return nil
        }
        let priorities = Settings.shared.prioritiseGameForAccount(accountId: accountId, gameName: gameName)
        minerManager.updatePriorityGames(priorities, forMinerId: miner.id)
        if miner.isRunning {
            await minerManager.forceRefreshMiner(minerId: miner.id)
        }
        return priorities
    }

    /// Replace a miner's personal priority games with `games` (the Discord "edit games"
    /// modal submits the whole personal list at once). Returns the resulting effective list.
    public func handleDiscordSetPriorities(discordUserId: String, accountId: String, games: [String]) async -> [String]? {
        guard let miner = minerManager.miners.first(where: { $0.ownerDiscordId == discordUserId && $0.accountId == accountId }) else {
            return nil
        }
        let priorities = Settings.shared.setPersonalPriorityGames(accountId: accountId, games: games)
        minerManager.updatePriorityGames(priorities, forMinerId: miner.id)
        if miner.isRunning {
            await minerManager.forceRefreshMiner(minerId: miner.id)
        }
        return priorities
    }

    private func accountLinkWarningGameKey(for gameName: String) -> String {
        let target = gameName.lowercased()
        return minerManager.campaignStore.campaigns
            .first(where: { $0.game.name.lowercased() == target })?.game.id ?? target
    }

    public func handleDiscordMinerControl(discordUserId: String, action: MinerControlAction) async -> MinerControlResponse {
        guard let miner = minerManager.miners.first(where: { $0.ownerDiscordId == discordUserId }) else {
            return MinerControlResponse(
                ok: false,
                action: action.rawValue,
                state: "not_linked",
                twitchUsername: nil,
                message: "No linked Twitch account was found for this Discord user."
            )
        }

        switch action {
        case .status:
            return MinerControlResponse(
                ok: true,
                action: action.rawValue,
                state: miner.status.rawValue,
                twitchUsername: miner.username,
                message: miner.statusLabel
            )
        case .pause:
            await minerManager.stopMiner(minerId: miner.id)
            return MinerControlResponse(
                ok: true,
                action: action.rawValue,
                state: "PAUSED",
                twitchUsername: miner.username,
                message: "Miner paused for \(miner.displayName)."
            )
        case .resume:
            do {
                let settings = Settings.shared
                try await minerManager.startMiner(
                    minerId: miner.id,
                    priorityGames: priorityGames(for: miner),
                    excludedGames: settings.excludedGames,
                    strategy: settings.miningStrategy,
                    enableBadgesEmotes: settings.enableBadgesEmotes,
                    showClaimNotifications: settings.showClaimNotifications && settings.allowsOperatorNotifications(),
                    avoidDuplicateStreams: settings.avoidDuplicateStreams,
                    antiStallRecoveryEnabled: settings.antiStallRecoveryEnabled,
                    prioritiseFollowedStreamers: settings.prioritiseFollowedStreamers
                )
                return MinerControlResponse(
                    ok: true,
                    action: action.rawValue,
                    state: "RESUMING",
                    twitchUsername: miner.username,
                    message: "Miner resume requested for \(miner.displayName)."
                )
            } catch {
                return MinerControlResponse(
                    ok: false,
                    action: action.rawValue,
                    state: "ERROR",
                    twitchUsername: miner.username,
                    message: error.localizedDescription
                )
            }
        case .refresh:
            await minerManager.forceRefreshMiner(minerId: miner.id)
            return MinerControlResponse(
                ok: true,
                action: action.rawValue,
                state: miner.status.rawValue,
                twitchUsername: miner.username,
                message: "Miner refresh requested for \(miner.displayName)."
            )
        }
    }

    public func priorityGames(for miner: MinerManager.ManagedMiner) -> [String] {
        Settings.shared.priorityGames(forAccountId: miner.accountId)
    }

    private func startSwiftBotStateSync() {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30 seconds
                guard Settings.shared.swiftBotEnabled else { continue }
                let newState = await swiftBotConnectionService.checkHealth()
                await MainActor.run {
                    self.swiftBotState = newState
                }
            }
        }
    }

    // MARK: - Events

    /// Human-readable event entries.
    public var events: [EventEntry] = []
    private let maxEvents = 1000

    // MARK: - Drop Completion Tracking

    /// Timestamps of when a drop was first seen as claimed/completed.
    /// Key: dropId, Value: completion Date.
    public var completedDropTimestamps: [String: Date] = [:]

    // MARK: - Miner Manager

    public let minerManager: MinerManager
    public let adminLinkingService: any AdminLinkingService
    public let swiftBotConnectionService: any SwiftBotConnectionService
    public let eventOutboxService: EventOutboxService
    public let eventEmitter: EventEmitterService
    public let dmLogStore: DMLogStore
    public private(set) var dmEventService: SwiftMinerDMEventService?
    /// Cached Discord display names keyed by Discord user ID. Refreshed from
    /// SwiftBot whenever the connection is healthy or the Discord tab loads.
    public private(set) var discordDisplayNamesById: [String: String] = [:]
    public private(set) var discordUsersById: [String: SwiftBotDiscordUser] = [:]
    private let sqliteManager: SQLiteManager
    private var httpAPIServer: HTTPAPIServer?
    private var onboardingSetupTask: Task<Void, Never>?
    @ObservationIgnored private var dropsPreloadTask: Task<Void, Never>?
    @ObservationIgnored private var dropsBackgroundRefreshTask: Task<Void, Never>?
    private var lastDropsBackgroundRefreshStartedAt: Date?
    private var lastKnownAccountCount = 0
    private var hasConfiguredOnboardingBaseline = false

    // MARK: - Initialization

    public init(clientId: String, minerManager: MinerManager? = nil) {
        self.minerManager = minerManager ?? MinerManager(clientId: clientId)
        
        let folderURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwiftMiner")
        
        // Create directory synchronously to avoid races in Phase 1
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        
        let dbURL = folderURL.appendingPathComponent("miner.db")
        let manager = SQLiteManager(databaseURL: dbURL)
        self.sqliteManager = manager
        self.adminLinkingService = SQLiteAdminLinkingService(manager: manager)
        self.eventEmitter = EventEmitterService(manager: manager)
        let dmLogStore = DMLogStore(manager: manager)
        self.dmLogStore = dmLogStore
        
        // Initialize event outbox delivery service first so connection service can reference it
        let webhookURL = URL(string: Settings.shared.swiftBotWebhookURL)
        let outboxService = EventOutboxService(
            manager: manager,
            webhookURL: webhookURL,
            hmacSecret: Settings.shared.swiftBotHmacSecret
        )
        self.eventOutboxService = outboxService

        // Initialize SwiftBot connection service
        let endpoint = Settings.shared.swiftBotEndpoint
        self.swiftBotConnectionService = RestSwiftBotConnectionService(
            endpoint: endpoint,
            dmLogStore: dmLogStore
        ) {
            outboxService
        }
    }

    // MARK: - Setup

    /// Wire MinerManager callbacks and load saved accounts.
    /// Must be awaited before `AppModel.setup()` so `miners` is populated.
    public func setup() async {
        // Phase 1: Open DB before any service calls
        do {
            try await sqliteManager.open()
        } catch {
            print("[NavigationModel] Failed to open database: \(error)")
        }

        await wireDMActivityLogging()

        await startSwiftMinerHTTPServerIfNeeded()

        if Settings.shared.swiftBotEnabled {
            await checkSwiftBotConnection()
            await eventOutboxService.updateConfig(
                webhookURL: URL(string: Settings.shared.swiftBotWebhookURL),
                hmacSecret: Settings.shared.swiftBotHmacSecret
            )
            await eventOutboxService.start()
            await refreshDiscordDisplayNames()
        }
        startSwiftBotStateSync()

        // Wire DM event production — lightweight event emission, notification decisions stay in SwiftBot
        let dmEventService = SwiftMinerDMEventService(connectionService: swiftBotConnectionService)
        self.dmEventService = dmEventService

        // No Discord DM is sent per drop claim — user-facing DMs are sent only
        // when the full campaign completes, to keep DM volume low.

        minerManager.onAuthRequiredEvent = { [weak self] minerId in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard Settings.shared.dmConnectionExpiredEnabled else { return }
                guard Settings.shared.allowsOperatorNotifications() else { return }
                guard let miner = self.minerManager.miners.first(where: { $0.id == minerId }) else { return }
                let priorityGames = self.priorityGames(for: miner)
                await dmEventService.emitReauthRequired(
                    accountId: miner.accountId,
                    discordUserId: miner.ownerDiscordId,
                    twitchUsername: miner.username,
                    priorityGames: priorityGames
                )
            }
        }

        minerManager.onCampaignCompletedEvent = { [weak self] minerId, campaign in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard Settings.shared.dmCampaignCompletedEnabled else { return }
                guard Settings.shared.allowsOperatorNotifications() else { return }
                guard let miner = self.minerManager.miners.first(where: { $0.id == minerId }) else { return }
                let priorityGames = self.priorityGames(for: miner)
                await dmEventService.emitCampaignCompleted(
                    campaignId: campaign.id,
                    campaignName: campaign.name,
                    gameName: campaign.game.name,
                    gameId: campaign.game.id,
                    gameArtworkURL: campaign.game.boxArtURL?.absoluteString,
                    accountId: miner.accountId,
                    minerDisplayName: miner.displayName,
                    discordUserId: miner.ownerDiscordId,
                    priorityGames: priorityGames
                )
            }
        }

        minerManager.onCampaignDetectedEvent = { [weak self] minerId, campaign in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard Settings.shared.dmCampaignDetectedEnabled else { return }
                guard Settings.shared.allowsOperatorNotifications() else { return }
                guard let miner = self.minerManager.miners.first(where: { $0.id == minerId }) else { return }
                let priorityGames = self.priorityGames(for: miner)
                guard priorityGames.contains(where: { $0.caseInsensitiveCompare(campaign.game.name) == .orderedSame }) else { return }
                await dmEventService.emitCampaignDetected(
                    campaignId: campaign.id,
                    campaignName: campaign.name,
                    gameName: campaign.game.name,
                    gameId: campaign.game.id,
                    gameArtworkURL: campaign.game.boxArtURL?.absoluteString,
                    accountId: miner.accountId,
                    minerDisplayName: miner.displayName,
                    discordUserId: miner.ownerDiscordId,
                    priorityGames: priorityGames
                )
            }
        }

        minerManager.onLinkWarningEvent = { [weak self] minerId, gameName in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard Settings.shared.dmLinkRequiredEnabled else { return }
                guard Settings.shared.allowsOperatorNotifications() else { return }
                guard let miner = self.minerManager.miners.first(where: { $0.id == minerId }) else { return }
                let priorityGames = self.priorityGames(for: miner)
                let gameId = self.accountLinkWarningGameKey(for: gameName)
                await dmEventService.emitPrioritisedGameNeedsLinking(
                    gameName: gameName,
                    gameId: gameId,
                    accountId: miner.accountId,
                    minerDisplayName: miner.displayName,
                    discordUserId: miner.ownerDiscordId,
                    priorityGames: priorityGames
                )
            }
        }

        minerManager.onAccountActionRequiredEvent = { [weak self] minerId, reason in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard Settings.shared.dmAccountActionRequiredEnabled else { return }
                guard Settings.shared.allowsOperatorNotifications() else { return }
                guard let miner = self.minerManager.miners.first(where: { $0.id == minerId }) else { return }
                let priorityGames = self.priorityGames(for: miner)
                await dmEventService.emitAccountActionRequired(
                    accountId: miner.accountId,
                    reason: reason,
                    discordUserId: miner.ownerDiscordId,
                    twitchUsername: miner.username,
                    priorityGames: priorityGames
                )
            }
        }

        minerManager.onWelcomeBackEvent = { [weak self] minerId in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard Settings.shared.dmWelcomeBackEnabled else { return }
                guard Settings.shared.allowsOperatorNotifications() else { return }
                guard let miner = self.minerManager.miners.first(where: { $0.id == minerId }) else { return }
                let priorityGames = self.priorityGames(for: miner)
                await dmEventService.emitWelcomeBack(
                    accountId: miner.accountId,
                    discordUserId: miner.ownerDiscordId,
                    twitchUsername: miner.username,
                    priorityGames: priorityGames
                )
            }
        }

        minerManager.onLogMessage = { [weak self] minerId, message in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.processLogMessage(minerId: minerId, message: message)
            }
        }
        let settings = Settings.shared
        minerManager.updateClientId(settings.resolvedClientId)
        minerManager.onMinersChanged = { [weak self] in
            Task { [weak self] in
                await self?.syncMinersToSQLite()
            }
        }
        minerManager.onAccountRemoved = { [weak self] twitchAccountId in
            Task { [weak self] in
                await self?.adminLinkingService.deleteAccountRow(twitchId: twitchAccountId)
            }
        }

        await minerManager.setup(
            autoStart: true,
            priorityGames: settings.priorityGames,
            excludedGames: settings.excludedGames,
            strategy: settings.miningStrategy,
            enableBadgesEmotes: settings.enableBadgesEmotes,
            avoidDuplicateStreams: settings.avoidDuplicateStreams,
            antiStallRecoveryEnabled: settings.antiStallRecoveryEnabled,
            prioritiseFollowedStreamers: settings.prioritiseFollowedStreamers,
            ignoredWarnings: settings.activeIgnoredWarnings,
            priorityGamesForMiner: { miner in
                settings.priorityGames(forAccountId: miner.accountId)
            }
        )
        await syncMinersToSQLite()
        preloadDropsTab()
    }

    public func preloadDropsTab(force: Bool = false) {
        guard !minerManager.miners.isEmpty else { return }

        let coordinator = minerManager.dataCoordinator
        if !force, !coordinator.lastKnownAllCampaigns.isEmpty {
            return
        }
        if !force, dropsPreloadTask != nil {
            return
        }

        dropsPreloadTask?.cancel()
        dropsPreloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.dropsPreloadTask = nil }

            let coordinator = self.minerManager.dataCoordinator
            if !force, !coordinator.lastKnownAllCampaigns.isEmpty {
                return
            }

            _ = await coordinator.allCampaigns(
                preferSteamArtwork: Settings.shared.preferSteamArtwork
            )
            guard !Task.isCancelled else { return }

            _ = self.refreshDropsInBackground(force: force)
        }
    }

    @discardableResult
    public func refreshDropsInBackground(force: Bool = false) -> Bool {
        guard !minerManager.miners.isEmpty else { return false }

        if dropsBackgroundRefreshTask != nil {
            return true
        }

        let minimumRefreshInterval: TimeInterval = 120
        if !force,
           let lastDropsBackgroundRefreshStartedAt,
           Date().timeIntervalSince(lastDropsBackgroundRefreshStartedAt) < minimumRefreshInterval {
            return false
        }

        lastDropsBackgroundRefreshStartedAt = Date()
        isDropsBackgroundRefreshRunning = true
        dropsBackgroundRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isDropsBackgroundRefreshRunning = false
                self.dropsBackgroundRefreshTask = nil
            }

            let coordinator = self.minerManager.dataCoordinator
            await coordinator.refreshAll()
            guard !Task.isCancelled else { return }

            _ = await coordinator.allCampaigns(
                preferSteamArtwork: Settings.shared.preferSteamArtwork
            )
            NotificationCenter.default.post(name: .dropsCampaignsDidUpdate, object: coordinator)
        }
        return true
    }

    public func configureOnboardingPresentation() {
        lastKnownAccountCount = minerManager.miners.count
        hasConfiguredOnboardingBaseline = true
        clearOnboardingPresentation()
    }

    public func refreshOnboardingPresentation() {
        clearOnboardingPresentation()
    }

    public func dismissOnboarding() {
        onboardingSetupTask?.cancel()
        onboardingSetupTask = nil
        isRunningOnboardingSetup = false
        settings.hasDismissedOnboarding = true
        clearOnboardingPresentation()
    }

    public func updateOnboardingSetupStage(_ stage: OnboardingSetupStage) {
        onboardingSetupStage = stage
        clearOnboardingPresentation()
    }

    public func handleOnboardingAuthenticationCompleted(resetDismissal _: Bool = true) {
        clearOnboardingPresentation()
    }

    public func handleAccountCountChange() {
        let currentCount = minerManager.miners.count

        // Ignore account-load churn before the initial onboarding baseline is configured.
        // This prevents restoring multiple saved accounts from accidentally resetting
        // a previously dismissed onboarding flow.
        guard hasConfiguredOnboardingBaseline else {
            lastKnownAccountCount = currentCount
            return
        }

        let previousCount = lastKnownAccountCount
        guard currentCount != previousCount else {
            clearOnboardingPresentation()
            return
        }

        lastKnownAccountCount = currentCount
        clearOnboardingPresentation()
    }

    public func startOnboardingSetupIfNeeded() {
        clearOnboardingPresentation()
    }

    private func processLogMessage(minerId: String, message: String) {
        let level: EventLevel = message.contains("⚠️") ? .warning : (message.contains("❌") || message.contains("Error")) ? .error : .info
        
        // Transform common logs into readable events
        var displayMessage = message
        if message.contains("[Engine] Started watching") {
            displayMessage = "Started watching campaign"
        } else if message.contains("CLAIMED") {
            displayMessage = "Drop claimed successfully"
        }
        
        logEvent(message: displayMessage, level: level, minerId: minerId, rawMessage: message)
    }

    public func logEvent(message: String, level: EventLevel = .info, minerId: String? = nil, rawMessage: String? = nil) {
        let entry = EventEntry(message: message, level: level, minerId: minerId, rawMessage: rawMessage)
        events.insert(entry, at: 0)
        if events.count > maxEvents {
            events.removeLast()
        }
    }

    /// Wires DM dispatch in the connection service into the activity log.
    /// Production sends only — debug previews stay out of the timeline.
    private func wireDMActivityLogging() async {
        guard let rest = swiftBotConnectionService as? RestSwiftBotConnectionService else { return }
        await rest.setDMActivityHandler { [weak self] messageType, discordUserId, success, debug in
            guard !debug else { return }
            await MainActor.run {
                self?.logDMActivityEvent(
                    messageType: messageType,
                    discordUserId: discordUserId,
                    success: success
                )
            }
        }
    }

    private func logDMActivityEvent(
        messageType: SwiftBotDMMessageType,
        discordUserId: String,
        success: Bool
    ) {
        let miner = minerManager.miners.first { $0.ownerDiscordId == discordUserId }
        // Prefer the Discord display name — it's the human-readable handle the
        // recipient actually recognises. Fall back to the miner's Twitch
        // display name only if SwiftBot hasn't told us the Discord name yet,
        // and finally to a generic placeholder if neither is known.
        let target = discordDisplayNamesById[discordUserId]
            ?? miner?.displayName
            ?? "Discord user"
        let message: String
        if success {
            message = "Sent \(messageType.displayName) DM to \(target)"
        } else {
            message = "Failed to send \(messageType.displayName) DM to \(target)"
        }
        // Tag rawMessage with the sentinel so EventLogView's filter resolver
        // routes this entry to the .discord chip.
        let tagged = "[discord-dm] \(messageType.rawValue) \(success ? "ok" : "fail") \(discordUserId)"
        logEvent(
            message: message,
            level: success ? .info : .warning,
            minerId: miner?.id,
            rawMessage: tagged
        )

        // If we logged the event without a known Discord name, opportunistically
        // refresh the cache so future DMs to this user get the proper handle.
        if discordDisplayNamesById[discordUserId] == nil {
            Task { [weak self] in await self?.refreshDiscordDisplayNames() }
        }
    }

    /// Refreshes the Discord display-name cache from SwiftBot. Cheap (one
    /// HTTP call) and best-effort — any failure just leaves the cache as-is.
    public func refreshDiscordDisplayNames() async {
        let users = await swiftBotConnectionService.fetchDiscordUsers()
        guard !users.isEmpty else { return }
        var map: [String: String] = [:]
        var usersMap: [String: SwiftBotDiscordUser] = [:]
        for user in users {
            map[user.id] = user.displayName
            usersMap[user.id] = user
        }
        discordDisplayNamesById = map
        discordUsersById = usersMap
    }

    /// Clear all events.
    public func clearEvents() {
        events.removeAll()
    }

    /// Recreate the useful parts of app launch from an already-open Overview:
    /// restart miner workers with current settings, then refresh campaign and
    /// inventory projections so the dashboard reflects the recovered state.
    public func restartMinersAndRefreshOverviewData() async {
        let settings = Settings.shared
        guard !minerManager.miners.isEmpty else {
            await minerManager.dataCoordinator.refreshAll()
            return
        }

        await minerManager.stopAll()
        for miner in minerManager.miners {
            try? await minerManager.startMiner(
                minerId: miner.id,
                priorityGames: priorityGames(for: miner),
                excludedGames: settings.excludedGames,
                strategy: settings.miningStrategy,
                enableBadgesEmotes: settings.enableBadgesEmotes,
                showClaimNotifications: settings.showClaimNotifications,
                avoidDuplicateStreams: settings.avoidDuplicateStreams,
                antiStallRecoveryEnabled: settings.antiStallRecoveryEnabled,
                prioritiseFollowedStreamers: settings.prioritiseFollowedStreamers
            )
        }
        await minerManager.forceRefreshAllMiners()
        await minerManager.dataCoordinator.refreshAll()
    }

    private var settings: Settings { Settings.shared }

    private func clearOnboardingPresentation() {
        onboardingPresentation = nil
        showOnboarding = false
    }

    private func runOnboardingSetupSequence() async {
        defer {
            isRunningOnboardingSetup = false
            onboardingSetupTask = nil
            refreshOnboardingPresentation()
        }

        updateOnboardingSetupStage(.connecting)
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }

        updateOnboardingSetupStage(.campaigns)
        await minerManager.forceRefreshAllMiners()
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled else { return }

        updateOnboardingSetupStage(.inventory)
        await minerManager.dataCoordinator.refreshAll()
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }

        updateOnboardingSetupStage(.finalising)
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
    }
}

private final class NavigationProjectionStateProvider: ProjectionStateProvider, @unchecked Sendable {
    private weak var model: NavigationModel?

    init(model: NavigationModel) {
        self.model = model
    }

    func activeCampaign(for discordUserId: String) async -> DiscordUserProjection.ActiveCampaign? {
        await MainActor.run {
            guard let miner = model?.minerForDiscordUser(discordUserId),
                  let campaignId = miner.currentCampaignId,
                  let campaign = miner.allCampaigns.first(where: { $0.id == campaignId }) else {
                return nil
            }
            return Self.activeCampaignProjection(from: campaign)
        }
    }

    func recentCompletedCampaigns(
        for discordUserId: String,
        limit: Int
    ) async -> [DiscordUserProjection.RecentCampaign] {
        await MainActor.run {
            guard let miner = model?.minerForDiscordUser(discordUserId) else { return [] }
            return miner.allCampaigns
                .filter { !$0.drops.isEmpty && $0.drops.allSatisfy(\.isClaimed) }
                .sorted { Self.completedSortDate($0) > Self.completedSortDate($1) }
                .prefix(max(limit, 0))
                .map(Self.recentCampaignProjection)
        }
    }

    func projectionState(for discordUserId: String) async -> DiscordUserProjection.ProjectionState? {
        await MainActor.run {
            guard let miner = model?.minerForDiscordUser(discordUserId) else { return nil }
            if miner.needsAuth || miner.status == .blockedAccountNotLinked || miner.status == .error {
                return .blocked
            }
            if miner.currentCampaignId != nil {
                return .active
            }
            return nil
        }
    }

    func priorityGames(for discordUserId: String) async -> [String] {
        await MainActor.run {
            guard let model, let miner = model.minerForDiscordUser(discordUserId) else { return [] }
            return model.priorityGames(for: miner)
        }
    }

    func personalPriorityGames(for discordUserId: String) async -> [String] {
        await MainActor.run {
            guard let model, let miner = model.minerForDiscordUser(discordUserId) else { return [] }
            return Settings.shared.personalPriorityGames(forAccountId: miner.accountId)
        }
    }

    private static func activeCampaignProjection(from campaign: Campaign) -> DiscordUserProjection.ActiveCampaign {
        let totalRequired = max(campaign.drops.map(\.requiredMinutes).reduce(0, +), 0)
        let totalCurrent = campaign.drops.reduce(0) { total, drop in
            total + (drop.isClaimed ? drop.requiredMinutes : min(drop.progress?.currentMinutes ?? 0, drop.requiredMinutes))
        }
        let pct = totalRequired > 0 ? min(Int((Double(totalCurrent) / Double(totalRequired)) * 100), 100) : 0
        return DiscordUserProjection.ActiveCampaign(
            campaignId: campaign.id,
            game: campaign.game.name,
            progress: DiscordUserProjection.Progress(
                current: totalCurrent,
                required: totalRequired,
                unit: "minutes",
                pct: pct
            ),
            endsAt: campaign.endDate
        )
    }

    private static func recentCampaignProjection(from campaign: Campaign) -> DiscordUserProjection.RecentCampaign {
        DiscordUserProjection.RecentCampaign(
            campaignId: campaign.id,
            campaignName: campaign.name,
            game: campaign.game.name,
            completedAt: completedSortDate(campaign),
            claimedDrops: campaign.drops.filter(\.isClaimed).count,
            totalDrops: campaign.drops.count
        )
    }

    private static func completedSortDate(_ campaign: Campaign) -> Date {
        min(campaign.endDate, Date())
    }
}

private extension NavigationModel {
    func minerForDiscordUser(_ discordUserId: String) -> MinerManager.ManagedMiner? {
        minerManager.miners.first { miner in
            miner.ownerDiscordId == discordUserId
        }
    }
}

// MARK: - Supporting Models

public enum EventLevel: String, Codable, Sendable {
    case info
    case warning
    case error
}

public struct EventEntry: Identifiable, Sendable, Equatable {
    public let id = UUID()
    public let timestamp = Date()
    public let message: String
    public let level: EventLevel
    public let minerId: String?
    public let rawMessage: String?
}
