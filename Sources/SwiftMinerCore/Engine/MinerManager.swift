import Foundation

/// Manages multiple MinerEngine instances for multi-account mining.
/// Each account gets its own isolated engine with separate state.
@MainActor
@Observable
public final class MinerManager {
    
    // MARK: - Types

    public enum AccountError: LocalizedError, Equatable {
        case duplicateAccount(username: String)

        public var errorDescription: String? {
            switch self {
            case .duplicateAccount(let username):
                return "\(username) is already added to SwiftMiner."
            }
        }
    }
    
    /// Represents a managed miner instance
    public struct ManagedMiner: Identifiable, Sendable {
        public let id: String
        public let accountId: String
        public let username: String
        public var nickname: String?
        public var ownerDiscordId: String?
        public var status: MinerStatus
        public var needsAuth: Bool
        public var currentCampaign: String?
        public var currentCampaignId: String?
        public var allCampaigns: [Campaign] = []
        public var dropsClaimed: Int
        public var isRunning: Bool
        public var priorityGames: [String]
        public var lastEventAt: Date?
        public var lastSuccessfulPollAt: Date?
        public var lastCampaignRefreshAt: Date?
        public var workerState: MinerWorkerState = .idle
        public var workerTaskID: String?
        public var isHealthy: Bool = true
        public var isStalled: Bool = false
        
        /// Resolved "Primary State" for the user-facing activity UI (Phase 4).
        @MainActor
        public var primaryState: PrimaryState {
            PrimaryStateResolver.resolve(for: self)
        }

        /// Per-miner, per-game state breakdown (Phase: MinerGameState refactor).
        @MainActor
        public var gameStates: [MinerGameState] {
            MinerManager.evaluateGameStates(for: self, priorityGames: priorityGames)
        }

        /// The resolved primary state from the per-game list (Phase: MinerGameState refactor).
        @MainActor
        public var resolvedPrimaryState: ResolvedPrimaryState? {
            let states = gameStates
            guard !states.isEmpty else { return nil }
            return ResolvedPrimaryState(gameStates: states)
        }

        /// A concise, deterministic status label for UI badges and list rows.
        @MainActor
        public var statusLabel: String {
            if workerState.isRecovering {
                return "Recovering..."
            }
            if isStalled {
                return "Miner Unresponsive"
            }
            if isRunning && !needsAuth && !isHealthy {
                return "No Recent Activity"
            }
            guard let resolved = resolvedPrimaryState?.resolved else {
                return status.displayName
            }
            switch resolved.state {
            case .watching:
                return "Watching \(resolved.gameName)"
            case .blocked:
                switch resolved.reason {
                case .notLinked:
                    return "Blocked — Account not linked"
                case .noLiveStreams:
                    return "Waiting — No live stream"
                case .noCampaign, .noEligibleCampaign, .campaignExpired, .noDropsAvailable, .none:
                    return "Idle — No eligible campaigns"
                }
            case .idle:
                switch resolved.reason {
                case .noDropsAvailable:
                    return "Drops complete"
                case .noCampaign, .noEligibleCampaign, .campaignExpired:
                    return "Idle — No eligible campaigns"
                case .none, .notLinked, .noLiveStreams:
                    return "Idle — No eligible campaigns"
                }
            }
        }

        /// Account-specific drop state store (Phase 2). Set asynchronously after engine is ready.
        public var stateStore: AccountStateStore?
        /// When the miner last transitioned to its current status. Used for stuck-detection in health UI.
        public var statusChangedAt: Date = Date()

        public init(
            id: String,
            accountId: String,
            username: String,
            nickname: String? = nil,
            ownerDiscordId: String? = nil,
            stateStore: AccountStateStore? = nil,
            status: MinerStatus = .idle,
            needsAuth: Bool = false,
            currentCampaign: String? = nil,
            currentCampaignId: String? = nil,
            allCampaigns: [Campaign] = [],
            dropsClaimed: Int = 0,
            isRunning: Bool = false,
            priorityGames: [String] = [],
            lastEventAt: Date? = nil,
            lastSuccessfulPollAt: Date? = nil,
            lastCampaignRefreshAt: Date? = nil,
            workerState: MinerWorkerState = .idle,
            workerTaskID: String? = nil,
            isHealthy: Bool = true,
            isStalled: Bool = false
        ) {
            self.id = id
            self.accountId = accountId
            self.username = username
            self.nickname = Account.normalizedNickname(nickname)
            self.ownerDiscordId = ownerDiscordId
            self.stateStore = stateStore
            self.status = status
            self.needsAuth = needsAuth
            self.currentCampaign = currentCampaign
            self.currentCampaignId = currentCampaignId
            self.allCampaigns = allCampaigns
            self.dropsClaimed = dropsClaimed
            self.isRunning = isRunning
            self.priorityGames = priorityGames
            self.lastEventAt = lastEventAt
            self.lastSuccessfulPollAt = lastSuccessfulPollAt
            self.lastCampaignRefreshAt = lastCampaignRefreshAt
            self.workerState = workerState
            self.workerTaskID = workerTaskID
            self.isHealthy = isHealthy
            self.isStalled = isStalled
        }

        public var displayName: String {
            nickname ?? username
        }
    }    
    public enum MinerStatus: String, Sendable, Equatable {
        case idle = "IDLE"
        case authenticating = "AUTHENTICATING"
        case fetchingCampaigns = "FETCHING_CAMPAIGNS"
        case watching = "WATCHING"
        case claiming = "CLAIMING"
        case waitingForStream = "WAITING_FOR_STREAM"
        case paused = "PAUSED"
        case error = "ERROR"
        /// No eligible campaigns exist for this account to mine (Task 3).
        case idleNoEligibleCampaigns = "IDLE_NO_ELIGIBLE_CAMPAIGNS"
        /// Campaigns exist but account is not linked, preventing mining (Task 4).
        case blockedAccountNotLinked = "BLOCKED_ACCOUNT_NOT_LINKED"

        public var displayName: String {
            switch self {
            case .idle: return "Idle — No eligible campaigns"
            case .authenticating: return "Waiting — Authenticating"
            case .fetchingCampaigns: return "Waiting — Refreshing campaigns"
            case .watching: return "Watching"
            case .claiming: return "Claiming"
            case .waitingForStream: return "Waiting — No live stream"
            case .paused: return "Paused"
            case .error: return "Blocked — Needs attention"
            case .idleNoEligibleCampaigns: return "Idle — No eligible campaigns"
            case .blockedAccountNotLinked: return "Blocked — Account not linked"
            }
        }
    }
    
    // MARK: - Activity Summary Types
    
    /// Structured summary of a miner's current activity state for UI display.
    public struct MinerActivitySummary: Sendable {
        public let minerId: String
        public let status: MinerStatus
        
        // Current work context
        public let currentCampaignName: String?
        public let currentCampaignId: String?
        public let currentChannelName: String?
        public let currentChannelId: String?
        
        // Stall/recovery state
        public let minutesSinceLastProgress: Int
        public let isStalled: Bool
        public let stallRecoveryAction: StallRecoveryAction?
        
        // Last switch reasoning
        public let lastSwitchReason: SwitchReason?
        public let lastSwitchAt: Date?
        
        // Recent activity (last 10 structured events)
        public let recentEvents: [MinerEvent]
    }
    
    public enum StallRecoveryAction: String, Sendable {
        case refreshingInventory = "Refreshing Inventory"
        case switchingChannel = "Switching Channel"
        case waitingForProgress = "Waiting for Progress"
        case none = "None"
    }
    
    public enum SwitchReason: Sendable {
        case stallDetected(minutes: Int)
        case higherPriorityChannel
        case externalDropClaimed
        case channelWentOffline
        case manualSelection
        
        public var summary: String {
            switch self {
            case .stallDetected(let minutes): return "Stall detected (\(minutes) min)"
            case .higherPriorityChannel: return "Higher priority channel available"
            case .externalDropClaimed: return "Drop claimed externally"
            case .channelWentOffline: return "Channel went offline"
            case .manualSelection: return "Manual selection"
            }
        }
    }
    
    public struct MinerEvent: Sendable {
        public let timestamp: Date
        public let type: EventType
        public let summary: String
        
        public enum EventType: String, Sendable {
            case channelSwitched = "Channel Switched"
            case campaignSelected = "Campaign Selected"
            case stallDetected = "Stall Detected"
            case inventoryRefreshed = "Inventory Refreshed"
            case dropClaimed = "Drop Claimed"
            case error = "Error"
            case recoveryComplete = "Recovery Complete"
        }
    }
    
    // MARK: - Properties
    
    /// All managed miners
    public private(set) var miners: [ManagedMiner] = []
    
    /// Global campaign store (Phase 1)
    public let campaignStore: CampaignStore
    
    /// Data coordinator for multi-miner campaign aggregation
    public let dataCoordinator: MiningDataCoordinator

    /// Whether the manager has been setup (loaded accounts)
    private var isSetup = false
    
    /// Track notification preference
    public var showClaimNotifications: Bool = false
    public var avoidDuplicateStreams: Bool = true
    public var prioritiseFollowedStreamers: Bool = false
    public var antiStallRecoveryEnabled: Bool = true
    /// Debug-only: broadcast to every engine to bypass link/eligibility gates. Stored here
    /// so engines attached later (e.g. newly added accounts) pick up the current value.
    public var debugBypassLinkRequirement: Bool = false
    /// Scoped warnings: [accountId: Set<gameId>]
    private var ignoredAccountLinkWarnings: [String: Set<String>] = [:]

    /// The actual engine instances (by miner ID)
    private var engines: [String: MinerEngine] = [:]

    /// Tracks in-flight engine setup tasks (setAccount + callback registration).
    /// `startMiner()` awaits these before starting the engine, eliminating the
    /// race condition where status callbacks were not yet registered on autostart.
    private var engineSetupTasks: [String: Task<Void, Never>] = [:]

    /// Background recovery loop for miners that get wedged after network or progress stalls.
    private var antiStallMonitorTask: Task<Void, Never>?
    private let supervisor = MinerSupervisor()
    private var initializedCampaignSnapshots: Set<String> = []

    /// Last start options, used when anti-stall recovery restarts an individual miner.
    private var currentPriorityGames: [String] = []
    private var currentExcludedGames: [String] = []
    private var currentStrategy: MiningStrategy = .mineAll
    private var currentEnableBadgesEmotes: Bool = false
    
    /// Client ID for Twitch API (mutable so it can be updated before first account is added)
    private var clientId: String

    /// Persistent store for account tokens (Phase: Managed Platform)
    public let tokenStore: any TokenStore

    /// Track drop IDs claimed today (locally)
    private var claimedTodayIds: Set<String> = []
    private var lastClaimDate: Date = Date()
    
    /// Callbacks for aggregated events
    public var onMinerStatusChange: (@Sendable (ManagedMiner) -> Void)?
    public var onMinersChanged: (@Sendable () -> Void)?
    /// Fired right after an account has been removed from the manager, with its Twitch ID.
    public var onAccountRemoved: (@Sendable (String) -> Void)?
    public var onAggregateProgress: (@Sendable (AggregateProgress) -> Void)?
    public var onLogMessage: (@Sendable (String, String) -> Void)? // (minerId, message)

    // MARK: - DM Event Callbacks
    /// Fired when a drop is successfully claimed. (minerId, drop, campaignName?)
    public var onDropClaimedEvent: (@Sendable (String, Drop, String?) -> Void)?
    /// Fired when manual re-authentication is required. (minerId)
    public var onAuthRequiredEvent: (@Sendable (String) -> Void)?
    /// Fired when a campaign becomes fully completed. (minerId, campaign)
    public var onCampaignCompletedEvent: (@Sendable (String, Campaign) -> Void)?
    /// Fired when a newly seen campaign appears after the initial snapshot. (minerId, campaign)
    public var onCampaignDetectedEvent: (@Sendable (String, Campaign) -> Void)?
    /// Fired when a prioritised game is blocked due to missing account link. (minerId, gameName)
    public var onLinkWarningEvent: (@Sendable (String, String) -> Void)?
    /// Fired when a miner recovers from error to active state. (minerId)
    public var onWelcomeBackEvent: (@Sendable (String) -> Void)?
    /// Fired when a miner needs manual attention for a non-auth issue. (minerId, reason)
    public var onAccountActionRequiredEvent: (@Sendable (String, String) -> Void)?

    // MARK: - Initialization
    
    public init(
        clientId: String, 
        campaignStore: CampaignStore = CampaignStore(),
        tokenStore: any TokenStore = KeychainTokenStore()
    ) {
        self.clientId = clientId
        self.campaignStore = campaignStore
        self.tokenStore = tokenStore
        self.dataCoordinator = MiningDataCoordinator(campaignStore: campaignStore)
    }
    
    /// Update notification preference for all active engines.
    public func updateNotificationPreference(enabled: Bool) async {
        self.showClaimNotifications = enabled
        for engine in engines.values {
            await engine.updateNotificationPreference(enabled: enabled)
        }
    }

    /// Broadcast followed/subscribed streamer channel ranking to all active engines.
    public func updateFollowedStreamerPriority(enabled: Bool) async {
        self.prioritiseFollowedStreamers = enabled
        for engine in engines.values {
            await engine.updateFollowedStreamerPriority(enabled: enabled)
        }
    }

    /// Toggle conservative miner restart recovery for persistent stalls/recoverable errors.
    public func updateAntiStallRecovery(enabled: Bool) async {
        antiStallRecoveryEnabled = enabled
        if enabled {
            startAntiStallMonitorIfNeeded()
        } else {
            antiStallMonitorTask?.cancel()
            antiStallMonitorTask = nil
        }
    }

    /// Debug-only: broadcast the link-bypass flag to every engine. Stored so engines
    /// added later (new accounts during a session) pick up the current value on start.
    public func setDebugBypassLinkRequirement(_ enabled: Bool) async {
        self.debugBypassLinkRequirement = enabled
        for engine in engines.values {
            await engine.setDebugBypassLinkRequirement(enabled)
        }
    }

    /// Replace the ignored-account set used to suppress account-link-required warnings.
    /// - Parameter ignoredWarnings: Scoped warnings in "accountId:gameId:type" format.
    public func updateIgnoredAccountLinkWarnings(_ ignoredWarnings: [String]) async {
        self.ignoredAccountLinkWarnings = [:]
        for warning in ignoredWarnings {
            let parts = warning.components(separatedBy: ":")
            guard parts.count >= 2 else { continue }
            let accountId = parts[0]
            let gameId = parts[1]
            // We only care about accountLink type here for now, as that's what MinerEngine handles
            if parts.count >= 3 && parts[2] != "accountLink" { continue }
            
            var games = self.ignoredAccountLinkWarnings[accountId] ?? []
            games.insert(gameId)
            self.ignoredAccountLinkWarnings[accountId] = games
        }

        for miner in miners {
            guard let engine = engines[miner.id] else { continue }
            let ignoredGames = Array(self.ignoredAccountLinkWarnings[miner.accountId] ?? [])
            await engine.updateAccountLinkWarningPreference(games: ignoredGames)
        }
        onMinersChanged?()
    }

    /// Toggle account-link warning suppression for a specific miner and game.
    public func setAccountLinkWarningIgnored(minerId: String, gameId: String = "all", ignored: Bool) async {
        guard let miner = getMiner(id: minerId) else { return }

        var games = ignoredAccountLinkWarnings[miner.accountId] ?? []
        if ignored {
            games.insert(gameId)
        } else {
            games.remove(gameId)
        }
        ignoredAccountLinkWarnings[miner.accountId] = games

        guard let engine = engines[minerId] else {
            onMinersChanged?()
            return
        }
        await engine.updateAccountLinkWarningPreference(games: Array(games))
        onMinersChanged?()
    }
    
    /// Update the client ID (call before adding the first account if the ID wasn't available at init).
    public func updateClientId(_ newId: String) {
        guard !newId.isEmpty else { return }
        clientId = newId
    }

    // MARK: - Setup

    /// Setup the miner manager — load saved accounts from keychain.
    /// Always awaited before `AppModel.setup()` so `miners` is populated when
    /// `isAuthenticated` is first evaluated.
    public func setup() async {
        guard !isSetup else { return }
        isSetup = true

        let authService = TwitchAuthService(clientId: clientId, tokenStore: tokenStore)
        do {
            let accounts = try await authService.loadAllAccounts()
            print("[MinerManager] Loading \(accounts.count) saved accounts from store")
            for account in accounts {
                do {
                    try addAccount(account)
                } catch AccountError.duplicateAccount {
                    print("[MinerManager] Skipping duplicate saved account: \(account.username)")
                } catch {
                    print("[MinerManager] Failed to add saved account \(account.username): \(error)")
                }
            }
        } catch {
            print("[MinerManager] Failed to load saved accounts: \(error)")
        }
    }

    /// Setup and optionally auto-start all miners.
    /// Call from the app layer where `Settings` is available.
    public func setup(
        autoStart: Bool,
        priorityGames: [String],
        excludedGames: [String],
        strategy: MiningStrategy,
        enableBadgesEmotes: Bool,
        avoidDuplicateStreams: Bool = true,
        antiStallRecoveryEnabled: Bool = true,
        prioritiseFollowedStreamers: Bool = false,
        ignoredWarnings: [String] = []
    ) async {
        await updateIgnoredAccountLinkWarnings(ignoredWarnings)
        self.currentPriorityGames = priorityGames
        self.currentExcludedGames = excludedGames
        self.currentStrategy = strategy
        self.currentEnableBadgesEmotes = enableBadgesEmotes
        self.avoidDuplicateStreams = avoidDuplicateStreams
        self.antiStallRecoveryEnabled = antiStallRecoveryEnabled
        self.prioritiseFollowedStreamers = prioritiseFollowedStreamers
        startAntiStallMonitorIfNeeded()
        await setup()
        if autoStart && !miners.isEmpty {
            print("[MinerManager] Auto-starting \(miners.count) miner(s) on launch")
            await startAll(
                priorityGames: priorityGames,
                excludedGames: excludedGames,
                strategy: strategy,
                enableBadgesEmotes: enableBadgesEmotes,
                avoidDuplicateStreams: avoidDuplicateStreams,
                antiStallRecoveryEnabled: antiStallRecoveryEnabled,
                prioritiseFollowedStreamers: prioritiseFollowedStreamers
            )
        }
    }
    
    // MARK: - Account Management
    
    /// Add a new account to manage
    /// - Returns: The ID of the created miner
    @discardableResult
    public func addAccount(_ account: Account) throws -> String {
        guard !miners.contains(where: { $0.accountId == account.id }) else {
            throw AccountError.duplicateAccount(username: account.displayName)
        }

        let minerId = UUID().uuidString
        
        // Create engine for this account
        let engine = MinerEngine(clientId: clientId)
        engines[minerId] = engine
        
        let miner = ManagedMiner(
            id: minerId,
            accountId: account.id,
            username: account.username,
            nickname: account.nickname,
            ownerDiscordId: account.ownerDiscordId
        )
        miners.append(miner)
        onMinersChanged?()
        Task { [supervisor] in
            await supervisor.registerMiner(minerId)
        }

        let setupTask = Task {
            await engine.setAccount(account)
            let ignoredGames = Array(self.ignoredAccountLinkWarnings[account.id] ?? [])
            await engine.updateAccountLinkWarningPreference(games: ignoredGames)
            await setupEngineCallbacks(engine: engine, minerId: minerId)

            // Get DropsService and InventoryService from engine for data coordination
            let apiClient = await engine.getAPIClient()
            let dropsService = await engine.getDropsService()
            let inventoryService = await dropsService.getInventoryService()

            // Register with data coordinator for multi-miner aggregation
            dataCoordinator.registerMiner(
                minerId: minerId,
                accountId: account.id,
                username: account.username,
                apiClient: apiClient,
                inventoryService: inventoryService,
                engine: engine
            )
            
            // Create AccountStateStore on @MainActor (Phase 2)
            let stateStore = AccountStateStore(accountId: account.id, username: account.username, dropsService: dropsService)

            // Wire stateStore back into the miner entry
            if let idx = miners.firstIndex(where: { $0.id == minerId }) {
                miners[idx].stateStore = stateStore
            }

            // Start the state store auto-refresh (Phase 2)
            // Stagger starts to avoid thundering herd - 3s delay per account index
            let accountIndex = self.miners.firstIndex(where: { $0.id == minerId }) ?? 0
            if accountIndex > 0 {
                let staggerDelay = UInt64(accountIndex * 3 * 1_000_000_000)
                try? await Task.sleep(nanoseconds: staggerDelay)
            }
            await stateStore.start()
        }
        engineSetupTasks[minerId] = setupTask
        return minerId
    }
    
    /// Remove an account from management
    public func removeAccount(minerId: String) async {
        guard let miner = getMiner(id: minerId) else { return }
        
        // Stop the miner if running
        await stopMiner(minerId: minerId)
        
        // Unregister from data coordinator
        dataCoordinator.unregisterMiner(minerId: minerId, accountId: miner.accountId)
        
        // Remove from persistent store
        let authService = TwitchAuthService(clientId: clientId, tokenStore: tokenStore)
        try? await authService.logout(accountId: miner.accountId)
        
        // Remove from collections
        engines.removeValue(forKey: minerId)
        let removedAccountId = miner.accountId
        miners.removeAll { $0.id == minerId }
        await supervisor.unregisterMiner(minerId)
        onMinersChanged?()
        onAccountRemoved?(removedAccountId)
    }
    
    /// Get a specific miner by ID
    public func getMiner(id: String) -> ManagedMiner? {
        miners.first { $0.id == id }
    }

    /// Resolve the user-visible name for an account, preferring the miner's nickname.
    public func displayName(forAccountId accountId: String, fallback: String) -> String {
        miners.first(where: { $0.accountId == accountId })?.displayName ?? fallback
    }

    public func updateMinerNickname(minerId: String, nickname: String?) async {
        guard let index = miners.firstIndex(where: { $0.id == minerId }) else { return }
        let normalized = Account.normalizedNickname(nickname)
        miners[index].nickname = normalized

        do {
            try await tokenStore.updateNickname(twitchUserId: miners[index].accountId, nickname: normalized)
        } catch {
            print("[MinerManager] Failed to update nickname for \(miners[index].accountId): \(error)")
        }

        onMinersChanged?()
    }
    
    /// Get the engine for a specific miner
    public func getEngine(minerId: String) -> MinerEngine? {
        engines[minerId]
    }
    
    /// Get a structured activity summary for a specific miner (for UI display).
    /// This provides a clean, structured snapshot of miner state without requiring
    /// the UI to parse raw engine logs.
    public func getMinerActivitySummary(minerId: String) async -> MinerActivitySummary? {
        guard let miner = getMiner(id: minerId),
              let engine = getEngine(minerId: minerId) else {
            return nil
        }
        
        // Get stall state from engine
        let stallState = await engine.getStallState()
        
        // Build recent events from engine logs (last 10)
        let recentEvents = await engine.getRecentActivityEvents(limit: 10)
        
        return MinerActivitySummary(
            minerId: minerId,
            status: miner.status,
            currentCampaignName: miner.currentCampaign,
            currentCampaignId: miner.currentCampaignId,
            currentChannelName: stallState.currentChannelName,
            currentChannelId: stallState.currentChannelId,
            minutesSinceLastProgress: stallState.minutesSinceLastProgress,
            isStalled: stallState.isStalled,
            stallRecoveryAction: stallState.recoveryAction,
            lastSwitchReason: stallState.lastSwitchReason,
            lastSwitchAt: stallState.lastSwitchAt,
            recentEvents: recentEvents
        )
    }
    
    // MARK: - Control Operations

    /// Start a specific miner
    public func startMiner(minerId: String, priorityGames: [String], excludedGames: [String], strategy: MiningStrategy, enableBadgesEmotes: Bool = false, showClaimNotifications: Bool = false, avoidDuplicateStreams: Bool = true, antiStallRecoveryEnabled: Bool = true, prioritiseFollowedStreamers: Bool = false) async throws {
        guard let engine = engines[minerId],
              let miner = getMiner(id: minerId) else {
            throw TwitchMinerError.sessionNotStarted
        }

        // Ensure engine callbacks are registered before starting.
        // addAccount() sets up callbacks in an unstructured Task; awaiting it here
        // eliminates the race where onStatusChange fires before the handler is set.
        if let setupTask = engineSetupTasks[minerId] {
            await setupTask.value
            engineSetupTasks.removeValue(forKey: minerId)
        }

        // Update notification preference if provided
        self.currentPriorityGames = priorityGames
        self.currentExcludedGames = excludedGames
        self.currentStrategy = strategy
        self.currentEnableBadgesEmotes = enableBadgesEmotes
        self.showClaimNotifications = showClaimNotifications
        self.avoidDuplicateStreams = avoidDuplicateStreams
        self.antiStallRecoveryEnabled = antiStallRecoveryEnabled
        self.prioritiseFollowedStreamers = prioritiseFollowedStreamers
        startAntiStallMonitorIfNeeded()
        let workerTaskID = UUID().uuidString
        await supervisor.recordWorkerStart(minerId: minerId, taskID: workerTaskID)
        await applySupervisorSnapshot(for: minerId)

        // Update mining preferences
        let ignoredGames = Array(ignoredAccountLinkWarnings[miner.accountId] ?? [])
        await engine.updateMiningPreferences(
            priorityGames: priorityGames,
            excludedGames: excludedGames,
            enableBadgesEmotes: enableBadgesEmotes,
            showClaimNotifications: self.showClaimNotifications,
            avoidDuplicateStreams: self.avoidDuplicateStreams,
            prioritiseFollowedStreamers: self.prioritiseFollowedStreamers,
            ignoredAccountLinkWarningGames: ignoredGames
        )
        await engine.updateMiningStrategy(strategy)
        await engine.setDebugBypassLinkRequirement(debugBypassLinkRequirement)

        // Update status and sync priority games
        await dataCoordinator.updateAccountNeedsAuth(accountId: miner.accountId, needsAuth: false)
        updateMinerStatus(minerId: minerId, status: .authenticating, priorityGames: priorityGames, needsAuth: false)

        do {
            try await engine.start()
            await supervisor.recordWorkerRunning(minerId: minerId)
            await applySupervisorSnapshot(for: minerId)
            await dataCoordinator.updateAccountNeedsAuth(accountId: miner.accountId, needsAuth: false)
            updateMinerStatus(minerId: minerId, isRunning: true, priorityGames: priorityGames, needsAuth: false)
        } catch {
            await supervisor.recordWorkerStop(minerId: minerId, failed: true)
            await applySupervisorSnapshot(for: minerId)
            let needsAuth = Self.requiresManualReauth(for: error)
            await dataCoordinator.updateAccountNeedsAuth(accountId: miner.accountId, needsAuth: needsAuth)
            updateMinerStatus(minerId: minerId, status: .error, priorityGames: priorityGames, needsAuth: needsAuth)
            throw error
        }
    }
    
    /// Stop a specific miner
    public func stopMiner(minerId: String) async {
        guard let engine = engines[minerId],
              let miner = getMiner(id: minerId) else { return }
        
        await engine.stop()
        await supervisor.recordWorkerStop(minerId: minerId)
        await applySupervisorSnapshot(for: minerId)
        await dataCoordinator.updateAccountNeedsAuth(accountId: miner.accountId, needsAuth: false)
        updateMinerStatus(minerId: minerId, status: .idle, currentCampaignId: .some(nil), isRunning: false, needsAuth: false)
    }
    
    /// Start all miners with staggered delays to avoid API rate limiting
    public func startAll(priorityGames: [String], excludedGames: [String], strategy: MiningStrategy, enableBadgesEmotes: Bool = false, showClaimNotifications: Bool = false, avoidDuplicateStreams: Bool = true, antiStallRecoveryEnabled: Bool = true, prioritiseFollowedStreamers: Bool = false) async {
        self.currentPriorityGames = priorityGames
        self.currentExcludedGames = excludedGames
        self.currentStrategy = strategy
        self.currentEnableBadgesEmotes = enableBadgesEmotes
        self.showClaimNotifications = showClaimNotifications
        self.avoidDuplicateStreams = avoidDuplicateStreams
        self.antiStallRecoveryEnabled = antiStallRecoveryEnabled
        self.prioritiseFollowedStreamers = prioritiseFollowedStreamers
        startAntiStallMonitorIfNeeded()
        let notRunningMiners = miners.filter { !$0.isRunning }
        let totalToStart = notRunningMiners.count
        
        for (index, miner) in notRunningMiners.enumerated() {
            // Stagger starts by 3 seconds between accounts to avoid rate limit bottlenecks
            if index > 0 {
                print("[MinerManager] Staggering start for @\(miner.username): waiting 3s to avoid rate limits (\(index)/\(totalToStart))")
                try? await Task.sleep(nanoseconds: 3 * 1_000_000_000)
            }
            
            try? await startMiner(
                minerId: miner.id, 
                priorityGames: priorityGames, 
                excludedGames: excludedGames, 
                strategy: strategy,
                enableBadgesEmotes: enableBadgesEmotes,
                showClaimNotifications: showClaimNotifications,
                avoidDuplicateStreams: avoidDuplicateStreams,
                antiStallRecoveryEnabled: antiStallRecoveryEnabled,
                prioritiseFollowedStreamers: prioritiseFollowedStreamers
            )
        }
    }
    
    /// Stop all miners
    public func stopAll() async {
        for miner in miners where miner.isRunning {
            await stopMiner(minerId: miner.id)
        }
    }
    
    /// Claim all drops for a specific miner
    public func claimAllDrops(minerId: String) async throws {
        guard let engine = engines[minerId] else {
            throw TwitchMinerError.sessionNotStarted
        }
        
        try await engine.claimAllDrops()
    }
    
    /// Claim all drops across all miners
    public func claimAllDropsAllMiners() async {
        for miner in miners where miner.isRunning {
            try? await claimAllDrops(minerId: miner.id)
        }
    }

    /// Trigger an immediate campaign rescan for a specific miner
    public func forceRefreshMiner(minerId: String) async {
        guard let engine = engines[minerId] else { return }
        await engine.forceRefresh()
    }

    /// Trigger an immediate campaign rescan for all running miners
    public func forceRefreshAllMiners() async {
        for miner in miners where miner.isRunning {
            await forceRefreshMiner(minerId: miner.id)
        }
    }

    // MARK: - Progress Aggregation
    
    /// Get aggregated progress across all miners
    public func getAggregateProgress() async -> AggregateProgress {
        var totalCampaignsSet: Set<String> = []
        var totalDropsCount = 0
        var totalClaimedCount = 0
        var totalPendingCount = 0
        var activeMinersCount = 0
        
        resetDailyClaimsIfNeeded()
        
        for (minerId, engine) in engines {
            guard let miner = miners.first(where: { $0.id == minerId }),
                  miner.isRunning else { continue }
            
            do {
                let progress = try await engine.getCurrentProgress()
                
                // Add unique campaign IDs to the set for global count
                for campaign in progress.campaigns {
                    totalCampaignsSet.insert(campaign.campaignId)
                }
                
                // Sum drops and progress per account
                totalDropsCount += progress.totalDrops
                totalClaimedCount += progress.claimedDrops
                totalPendingCount += progress.pendingDrops
                activeMinersCount += 1
            } catch {
                // Skip miners that can't provide progress
            }
        }
        
        return AggregateProgress(
            activeMiners: activeMinersCount,
            totalCampaigns: totalCampaignsSet.count,
            totalDrops: totalDropsCount,
            claimedDrops: totalClaimedCount,
            claimedToday: claimedTodayIds.count,
            pendingDrops: totalPendingCount
        )
    }

    // MARK: - Per-Miner, Per-Game State Evaluation (MinerGameState Refactor)

    /// Evaluate the per-game state for a miner.
    /// Iterates over `priorityGames` to ensure every prioritised game produces a state,
    /// even when no campaigns are returned for that game.
    @MainActor
    public static func evaluateGameStates(for miner: ManagedMiner, priorityGames: [String]) -> [MinerGameState] {
        if priorityGames.isEmpty { return [] }

        var states: [MinerGameState] = []
        var seenGames = Set<String>()

        for priorityGame in priorityGames {
            let gameKey = priorityGame.lowercased()
            guard seenGames.insert(gameKey).inserted else { continue }

            // Gather all campaigns for this prioritised game (used for linkage check)
            let campaignsForGame = miner.allCampaigns.filter {
                $0.gameName.lowercased() == gameKey || $0.game.id.lowercased() == gameKey
            }

            // 1. Identify the stable game metadata
            let gameId = campaignsForGame.first?.game.id ?? gameKey
            let gameName = campaignsForGame.first?.game.name ?? priorityGame

            // 2. Filter out irrelevant campaigns (no drops, Just Chatting)
            let relevant = campaignsForGame.filter { campaign in
                if campaign.drops.isEmpty { return false }
                let name = campaign.game.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let id = campaign.game.id.trimmingCharacters(in: .whitespacesAndNewlines)
                if name.localizedCaseInsensitiveCompare("Just Chatting") == .orderedSame || id == "509658" {
                    return false
                }
                return true
            }

            if relevant.isEmpty {
                // Check if any of the EXCLUDED or NO-DROP campaigns are not linked.
                // John wants "Not linked -> .blocked(.notLinked)" to be driven by prioritised games.
                let isNotLinked = !campaignsForGame.isEmpty && campaignsForGame.contains { !$0.isAccountConnected }
                
                if isNotLinked {
                    states.append(MinerGameState(
                        minerId: miner.id,
                        gameId: gameId,
                        gameName: gameName,
                        state: .blocked,
                        reason: .notLinked
                    ))
                } else {
                    states.append(MinerGameState(
                        minerId: miner.id,
                        gameId: gameId,
                        gameName: gameName,
                        state: .idle,
                        reason: .noEligibleCampaign
                    ))
                }
                continue
            }

            var activeCampaign: Campaign?
            var blockedReason: MinerGameStateReason?
            var allClaimed = true

            for campaign in relevant {
                if !campaign.drops.allSatisfy({ $0.isClaimed }) {
                    allClaimed = false
                } else {
                    continue
                }

                // Check if campaign is actively earnable for this account.
                if campaign.isMiningEligible {
                    if activeCampaign == nil {
                        activeCampaign = campaign
                    }
                }

                // Collect blocking reasons (scan all campaigns; blocked wins)
                if campaign.isTimeActive && !campaign.isAccountConnected {
                    if blockedReason == nil { blockedReason = .notLinked }
                } else if !campaign.isActive {
                    if blockedReason == nil { blockedReason = .campaignExpired }
                }
            }

            if allClaimed {
                states.append(MinerGameState(
                    minerId: miner.id,
                    gameId: gameId,
                    gameName: gameName,
                    state: .idle,
                    reason: .noDropsAvailable
                ))
                continue
            }

            // Determine session context for this game
            let isWatchingThisGame = miner.status == .watching
                && relevant.contains(where: { $0.id == miner.currentCampaignId })
            let isWaitingForStream = miner.status == .waitingForStream
                && relevant.contains(where: { $0.id == miner.currentCampaignId })

            if isWaitingForStream, let campaignId = miner.currentCampaignId {
                states.append(MinerGameState(
                    minerId: miner.id,
                    gameId: gameId,
                    gameName: gameName,
                    state: .blocked,
                    reason: .noLiveStreams,
                    campaignId: campaignId
                ))
            } else if isWatchingThisGame, let campaign = activeCampaign ?? relevant.first {
                states.append(MinerGameState(
                    minerId: miner.id,
                    gameId: gameId,
                    gameName: gameName,
                    state: .watching,
                    reason: .none,
                    campaignId: campaign.id
                ))
            } else if let campaign = activeCampaign {
                let waitingForStream = miner.status == .waitingForStream
                states.append(MinerGameState(
                    minerId: miner.id,
                    gameId: gameId,
                    gameName: gameName,
                    state: waitingForStream ? .blocked : .idle,
                    reason: waitingForStream ? .noLiveStreams : .none,
                    campaignId: campaign.id
                ))
            } else if let reason = blockedReason {
                states.append(MinerGameState(
                    minerId: miner.id,
                    gameId: gameId,
                    gameName: gameName,
                    state: .blocked,
                    reason: reason
                ))
            } else {
                states.append(MinerGameState(
                    minerId: miner.id,
                    gameId: gameId,
                    gameName: gameName,
                    state: .idle,
                    reason: .noEligibleCampaign
                ))
            }
        }

        return states
    }

    // MARK: - Private Methods
    
    private func resetDailyClaimsIfNeeded() {
        let calendar = Calendar.current
        if !calendar.isDateInToday(lastClaimDate) {
            claimedTodayIds.removeAll()
            lastClaimDate = Date()
        }
    }
    
    private func setupEngineCallbacks(engine: MinerEngine, minerId: String) async {
        await engine.setChannelAssignmentAvoidanceProvider { [weak self] campaignId, viableChannelCount in
            guard let self else { return [] }
            return await self.assignedChannelIds(
                campaignId: campaignId,
                excluding: minerId,
                viableChannelCount: viableChannelCount
            )
        }

        await engine.setStatusChangeHandler { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let minerStatus = self.mapSessionStatus(status)
                await self.supervisor.recordStateUpdate(minerId: minerId)

                // Detect welcome-back: miner recovered from error to active
                if let miner = self.getMiner(id: minerId),
                   miner.status == .error,
                   (minerStatus == .watching || minerStatus == .fetchingCampaigns || minerStatus == .claiming) {
                    self.onWelcomeBackEvent?(minerId)
                }

                // If status changed to watching or back to idle, update campaign info too
                let currentId = await engine.currentCampaignId
                let clearsNeedsAuth = minerStatus != .authenticating && minerStatus != .error
                if clearsNeedsAuth, let miner = self.getMiner(id: minerId) {
                    await self.dataCoordinator.updateAccountNeedsAuth(accountId: miner.accountId, needsAuth: false)
                }
                self.updateMinerStatus(
                    minerId: minerId,
                    status: minerStatus,
                    currentCampaignId: .some(currentId),
                    needsAuth: clearsNeedsAuth ? false : nil
                )
                await self.applySupervisorSnapshot(for: minerId)
            }
        }
        
        await engine.setCampaignUpdateHandler { [weak self] campaigns in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                await self.supervisor.recordCampaignRefresh(minerId: minerId)

                // Get all campaigns and current ID from engine
                let previousCampaigns = self.getMiner(id: minerId)?.allCampaigns ?? []
                let previousCampaignIds = Set(previousCampaigns.map(\.id))
                let canEmitNewCampaigns = self.initializedCampaignSnapshots.contains(minerId)
                let all = await engine.allCampaigns
                let currentId = await engine.currentCampaignId

                if canEmitNewCampaigns {
                    for campaign in all where campaign.isTimeActive && !previousCampaignIds.contains(campaign.id) {
                        self.onCampaignDetectedEvent?(minerId, campaign)
                    }
                }
                self.initializedCampaignSnapshots.insert(minerId)

                // Detect newly completed campaigns
                for campaign in all where campaign.drops.allSatisfy({ $0.isClaimed }) {
                    self.onCampaignCompletedEvent?(minerId, campaign)
                }

                // Update current campaign info
                if let currentId, let current = all.first(where: { $0.id == currentId }) {
                    self.updateMinerStatus(minerId: minerId, currentCampaign: current.name, currentCampaignId: .some(currentId), allCampaigns: all)
                } else if let first = campaigns.first {
                    self.updateMinerStatus(minerId: minerId, currentCampaign: first.name, currentCampaignId: .some(currentId), allCampaigns: all)
                } else {
                    self.updateMinerStatus(minerId: minerId, currentCampaignId: .some(currentId), allCampaigns: all)
                }

                if currentId != nil {
                    await self.getMiner(id: minerId)?.stateStore?.refresh()
                    self.onMinersChanged?()
                }
                await self.applySupervisorSnapshot(for: minerId)
            }
        }

        await engine.setOperationalEventHandler { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                switch event {
                case .workerStarted(let taskID):
                    await self.supervisor.recordWorkerStart(minerId: minerId, taskID: taskID)
                case .workerStopped:
                    await self.supervisor.recordWorkerStop(minerId: minerId)
                case .successfulPoll, .inventoryRefresh:
                    await self.supervisor.recordSuccessfulPoll(minerId: minerId)
                case .campaignRefresh:
                    await self.supervisor.recordCampaignRefresh(minerId: minerId)
                case .authRefreshed:
                    await self.supervisor.recordStateUpdate(minerId: minerId, workerState: .running)
                case .heartbeat, .stateUpdate:
                    await self.supervisor.recordStateUpdate(minerId: minerId)
                case .issueDetected(let category, let detail):
                    let cause = Self.mapIssueCategoryToStallCause(category)
                    await self.supervisor.recordIssue(minerId: minerId, cause: cause, detail: detail)
                }
                await self.applySupervisorSnapshot(for: minerId)
            }
        }
        
        await engine.setDropClaimedHandler { [weak self] drop in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                await self.supervisor.recordEvent(minerId: minerId)
                self.resetDailyClaimsIfNeeded()
                self.claimedTodayIds.insert(drop.id)
                self.incrementDropsClaimed(minerId: minerId)

                // Find campaign name for the DM event
                let campaignName = self.getMiner(id: minerId)?.allCampaigns.first(where: {
                    $0.drops.contains(where: { $0.id == drop.id })
                })?.name
                self.onDropClaimedEvent?(minerId, drop, campaignName)

                await self.applySupervisorSnapshot(for: minerId)
            }
        }
        
        await engine.setLogMessageHandler { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                await self.supervisor.recordEvent(minerId: minerId)
                self.onLogMessage?(minerId, message)
                await self.applySupervisorSnapshot(for: minerId)
            }
        }

        await engine.setErrorHandler { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self = self,
                      let miner = self.getMiner(id: minerId) else { return }

                let (category, detail) = MinerEngine.classifyIssue(error)
                await self.supervisor.recordIssue(
                    minerId: minerId,
                    cause: Self.mapIssueCategoryToStallCause(category),
                    detail: detail
                )
                await self.supervisor.recordWorkerStop(minerId: minerId, failed: true)
                let needsAuth = Self.requiresManualReauth(for: error)
                if needsAuth {
                    self.onAuthRequiredEvent?(minerId)
                }
                await self.dataCoordinator.updateAccountNeedsAuth(accountId: miner.accountId, needsAuth: needsAuth)
                self.updateMinerStatus(minerId: minerId, status: .error, needsAuth: needsAuth)
                await self.applySupervisorSnapshot(for: minerId)
            }
        }

        await engine.setLinkWarningHandler { [weak self] gameName in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.onLinkWarningEvent?(minerId, gameName)
            }
        }
    }

    private static func mapIssueCategoryToStallCause(_ category: MinerEngine.IssueCategory) -> MinerSupervisor.StallCause {
        switch category {
        case .networkError: return .networkError
        case .twitchAPIFailure: return .twitchAPIFailure
        case .rateLimited: return .rateLimited
        case .authIssue: return .authIssue
        case .watchSessionFailure: return .watchSessionFailure
        case .unknown: return .unknown
        }
    }

    private func startAntiStallMonitorIfNeeded() {
        guard antiStallRecoveryEnabled, antiStallMonitorTask == nil else { return }

        antiStallMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                if Task.isCancelled { break }
                await self?.runAntiStallCheck()
            }
        }
    }

    private func runAntiStallCheck() async {
        guard antiStallRecoveryEnabled else { return }

        let metadataByMiner = await supervisor.refreshHealth(for: miners)
        for (minerId, metadata) in metadataByMiner {
            updateMinerOperationalMetadata(minerId: minerId, metadata: metadata)
        }

        while let action = await supervisor.nextRecoveryAction(for: miners) {
            await performRecoveryAction(action)
        }
    }

    private func assignedChannelIds(
        campaignId: String,
        excluding minerId: String,
        viableChannelCount: Int
    ) async -> Set<String> {
        guard avoidDuplicateStreams, viableChannelCount > 4 else { return [] }

        var assigned = Set<String>()
        for miner in miners where miner.id != minerId && miner.isRunning && miner.currentCampaignId == campaignId {
            guard let engine = engines[miner.id] else { continue }
            let state = await engine.getStallState()
            if let channelId = state.currentChannelId, !channelId.isEmpty {
                assigned.insert(channelId)
            }
        }

        return assigned
    }
    
    private func mapSessionStatus(_ status: SessionStatus) -> MinerStatus {
        switch status {
        case .idle: return .idle
        case .authenticating: return .authenticating
        case .fetchingCampaigns: return .fetchingCampaigns
        case .watching: return .watching
        case .claiming: return .claiming
        case .waitingForStream: return .waitingForStream
        case .paused: return .paused
        case .stopped: return .idle
        case .error: return .error
        case .idleNoEligibleCampaigns: return .idleNoEligibleCampaigns
        case .blockedAccountNotLinked: return .blockedAccountNotLinked
        }
    }
    
    /// Update the priority games for all miners. Call this when settings change.
    public func updatePriorityGames(_ priorityGames: [String]) {
        for index in miners.indices {
            miners[index].priorityGames = priorityGames
            
            // Sync with active engine if it exists
            if let engine = engines[miners[index].id] {
                Task {
                    await engine.updatePriorityGames(priorityGames)
                    await engine.updateAccountLinkWarningPreference(games: Array(ignoredAccountLinkWarnings[miners[index].accountId] ?? []))
                }
            }
        }
        onMinersChanged?()
    }

    /// Add an account that was just activated through the bot-driven device flow.
    /// Skips re-saving (the auth service already saved to the token store) but registers
    /// the miner with the manager and starts mining for it.
    public func attachActivatedAccount(_ account: Account) async {
        guard !miners.contains(where: { $0.accountId == account.id }) else { return }
        do {
            _ = try addAccount(account)
        } catch {
            print("[MinerManager] attachActivatedAccount failed: \(error)")
        }
    }

    /// Update the Discord owner for a miner by Twitch account ID. Pass `nil` to unlink.
    /// Persists to the token store so the link survives across restarts.
    public func setOwnerDiscordId(forAccountId accountId: String, to discordId: String?) {
        guard let index = miners.firstIndex(where: { $0.accountId == accountId }) else { return }
        miners[index].ownerDiscordId = discordId
        onMinersChanged?()

        Task { [tokenStore] in
            guard let existing = try? await tokenStore.loadAccount(twitchUserId: accountId) else { return }
            let updated = Account(
                id: existing.id,
                username: existing.username,
                nickname: existing.nickname,
                ownerDiscordId: discordId,
                accessToken: existing.accessToken,
                refreshToken: existing.refreshToken,
                tokenExpiry: existing.tokenExpiry,
                scopes: existing.scopes
            )
            try? await tokenStore.save(account: updated)
        }
    }

    private func updateMinerStatus(
        minerId: String,
        status: MinerStatus? = nil,
        currentCampaign: String? = nil,
        currentCampaignId: String?? = .none, // .none = don't touch; .some(x) = always set (x may be nil)
        allCampaigns: [Campaign]? = nil,
        isRunning: Bool? = nil,
        priorityGames: [String]? = nil,
        needsAuth: Bool? = nil,
        ownerDiscordId: String? = nil
    ) {
        guard let index = miners.firstIndex(where: { $0.id == minerId }) else { return }

        var miner = miners[index]
        if let status = status {
            if status != miner.status { miner.statusChangedAt = Date() }
            miner.status = status
        }
        if let campaign = currentCampaign { miner.currentCampaign = campaign }
        if case .some(let campaignId) = currentCampaignId {
            miner.currentCampaignId = campaignId
            if campaignId == nil { miner.currentCampaign = nil } // clear name when ID is cleared
        }
        if let campaigns = allCampaigns { miner.allCampaigns = campaigns }
        if let running = isRunning { miner.isRunning = running }
        if let needsAuth = needsAuth { miner.needsAuth = needsAuth }
        if let priorityGames = priorityGames { miner.priorityGames = priorityGames }
        if let ownerId = ownerDiscordId { miner.ownerDiscordId = ownerId }

        miners[index] = miner
        onMinersChanged?()
    }
    
    private func updateMinerStatus(minerId: String, isRunning: Bool, status: MinerStatus) {
        updateMinerStatus(minerId: minerId, status: status, isRunning: isRunning)
    }

    private func updateMinerOperationalMetadata(minerId: String, metadata: MinerOperationalMetadata) {
        guard let index = miners.firstIndex(where: { $0.id == minerId }) else { return }
        miners[index].lastEventAt = metadata.lastEventAt
        miners[index].lastSuccessfulPollAt = metadata.lastSuccessfulPollAt
        miners[index].lastCampaignRefreshAt = metadata.lastCampaignRefreshAt
        miners[index].workerState = metadata.workerState
        miners[index].workerTaskID = metadata.workerTaskID
        miners[index].isHealthy = metadata.isHealthy
        miners[index].isStalled = metadata.isStalled
        onMinersChanged?()
    }

    private func applySupervisorSnapshot(for minerId: String) async {
        guard let metadata = await supervisor.snapshot(for: minerId) else { return }
        updateMinerOperationalMetadata(minerId: minerId, metadata: metadata)
    }

    private func performRecoveryAction(_ action: MinerSupervisor.RecoveryAction) async {
        guard let engine = engines[action.minerId] else { return }

        await supervisor.markRecovering(minerId: action.minerId, stage: action.stage)
        await applySupervisorSnapshot(for: action.minerId)
        onLogMessage?(
            action.minerId,
            "[Supervisor] stall detected | reason=\(action.reason) | stage=\(action.stage.rawValue) | attempt=\(action.attempt)"
        )

        do {
            switch action.stage {
            case .refresh:
                onLogMessage?(action.minerId, "[Supervisor] recovery stage 1 | forcing campaign refresh + inventory refresh")
                try await engine.forceInventoryRefresh()
                await engine.forceRefresh()
            case .restart:
                onLogMessage?(action.minerId, "[Supervisor] recovery stage 2 | restarting worker, subscriptions, and timers")
                await stopMiner(minerId: action.minerId)
                try await startMiner(
                    minerId: action.minerId,
                    priorityGames: currentPriorityGames,
                    excludedGames: currentExcludedGames,
                    strategy: currentStrategy,
                    enableBadgesEmotes: currentEnableBadgesEmotes,
                    showClaimNotifications: showClaimNotifications,
                    avoidDuplicateStreams: avoidDuplicateStreams,
                    antiStallRecoveryEnabled: antiStallRecoveryEnabled,
                    prioritiseFollowedStreamers: prioritiseFollowedStreamers
                )
            case .authRefresh:
                onLogMessage?(action.minerId, "[Supervisor] recovery stage 3 | refreshing auth/session state")
                try await engine.refreshAuthenticationSession()
                try await engine.forceInventoryRefresh()
                await engine.forceRefresh()
            }

            await supervisor.noteRecoverySuccess(minerId: action.minerId)
            await applySupervisorSnapshot(for: action.minerId)
            onLogMessage?(action.minerId, "[Supervisor] recovery success")
        } catch {
            await supervisor.noteRecoveryFailure(minerId: action.minerId, stage: action.stage)
            await applySupervisorSnapshot(for: action.minerId)

            let needsAuth = Self.requiresManualReauth(for: error)
            if let miner = getMiner(id: action.minerId) {
                await dataCoordinator.updateAccountNeedsAuth(accountId: miner.accountId, needsAuth: needsAuth)
            }
            if needsAuth {
                updateMinerStatus(minerId: action.minerId, status: .error, needsAuth: true)
            } else {
                onAccountActionRequiredEvent?(action.minerId, action.reason)
            }
            onLogMessage?(action.minerId, "[Supervisor] recovery failed | \(error.localizedDescription)")
        }
    }

    static func requiresManualReauth(for error: Error) -> Bool {
        guard let minerError = error as? TwitchMinerError else { return false }

        switch minerError {
        case .authenticationFailed, .tokenExpired:
            return true
        default:
            return false
        }
    }
    
    private func incrementDropsClaimed(minerId: String) {
        guard let index = miners.firstIndex(where: { $0.id == minerId }) else { return }
        var miner = miners[index]
        miner.dropsClaimed += 1
        miners[index] = miner
        onMinersChanged?()
    }

    #if DEBUG
    /// Cycles a miner's state through different configurations to test UI card presentations.
    public func cycleDebugState(for minerId: String) {
        guard let index = miners.firstIndex(where: { $0.id == minerId }) else { return }
        var miner = miners[index]
        let currentStatus = miner.status
        
        switch currentStatus {
        case .idle:
            // State 1: Recovering
            miner.workerState = .recovering
            miner.isStalled = false
            miner.isRunning = true
            miner.isHealthy = true
            miner.needsAuth = false
            miner.status = .authenticating

        case .authenticating:
            // State 2: Unresponsive/Stalled
            miner.workerState = .idle
            miner.isStalled = true
            miner.isRunning = true
            miner.isHealthy = true
            miner.needsAuth = false
            miner.status = .error

        case .error where miner.isStalled:
            // State 3: No Recent Activity (Liveness Quiet)
            miner.workerState = .idle
            miner.isStalled = false
            miner.isRunning = true
            miner.isHealthy = false
            miner.needsAuth = false
            miner.status = .fetchingCampaigns

        case .fetchingCampaigns:
            // State 4: Blocked — Account Not Linked
            miner.workerState = .idle
            miner.isStalled = false
            miner.isRunning = true
            miner.isHealthy = true
            miner.needsAuth = false
            miner.status = .blockedAccountNotLinked

        case .blockedAccountNotLinked:
            // State 5: Blocked — Authentication Expired
            miner.workerState = .idle
            miner.isStalled = false
            miner.isRunning = true
            miner.isHealthy = true
            miner.needsAuth = true
            miner.status = .error

        default:
            // Reset back to normal Idle
            miner.workerState = .idle
            miner.isStalled = false
            miner.isHealthy = true
            miner.needsAuth = false
            miner.isRunning = false
            miner.status = .idle
        }
        
        miners[index] = miner
        onMinersChanged?()
        onMinerStatusChange?(miner)
    }
    #endif
}

// MARK: - Supporting Types

/// Aggregated progress across all miners
public struct AggregateProgress: Sendable {
    public let activeMiners: Int
    public let totalCampaigns: Int
    public let totalDrops: Int
    public let claimedDrops: Int
    public let claimedToday: Int
    public let pendingDrops: Int
    
    public var completionPercentage: Double {
        guard totalDrops > 0 else { return 0 }
        return Double(claimedDrops) / Double(totalDrops) * 100
    }
}
