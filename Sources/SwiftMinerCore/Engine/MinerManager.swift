import Foundation

/// Manages multiple MinerEngine instances for multi-account mining.
/// Each account gets its own isolated engine with separate state.
@MainActor
@Observable
public final class MinerManager {
    
    // MARK: - Types
    
    /// Represents a managed miner instance
    public struct ManagedMiner: Identifiable, Sendable {
        public let id: String
        public let accountId: String
        public let username: String
        public var ownerDiscordId: String?
        public var status: MinerStatus
        public var needsAuth: Bool
        public var currentCampaign: String?
        public var currentCampaignId: String?
        public var allCampaigns: [Campaign] = []
        public var dropsClaimed: Int
        public var isRunning: Bool
        public var priorityGames: [String]
        
        /// Ordered list of candidate campaigns from the last selection pass (Debug only).
        public var debugWinningQueue: [Campaign] = []

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
            debugWinningQueue: [Campaign] = []
        ) {
            self.id = id
            self.accountId = accountId
            self.username = username
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
            self.debugWinningQueue = debugWinningQueue
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
    
    /// Client ID for Twitch API (mutable so it can be updated before first account is added)
    private var clientId: String

    /// Persistent store for account tokens (Phase: Managed Platform)
    private let tokenStore: any TokenStore

    /// Track drop IDs claimed today (locally)
    private var claimedTodayIds: Set<String> = []
    private var lastClaimDate: Date = Date()
    
    /// Callbacks for aggregated events
    public var onMinerStatusChange: (@Sendable (ManagedMiner) -> Void)?
    public var onMinersChanged: (@Sendable () -> Void)?
    public var onAggregateProgress: (@Sendable (AggregateProgress) -> Void)?
    public var onLogMessage: (@Sendable (String, String) -> Void)? // (minerId, message)
    
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
                addAccount(account)
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
        ignoredWarnings: [String] = []
    ) async {
        await updateIgnoredAccountLinkWarnings(ignoredWarnings)
        await setup()
        if autoStart && !miners.isEmpty {
            print("[MinerManager] Auto-starting \(miners.count) miner(s) on launch")
            await startAll(
                priorityGames: priorityGames,
                excludedGames: excludedGames,
                strategy: strategy,
                enableBadgesEmotes: enableBadgesEmotes
            )
        }
    }
    
    // MARK: - Account Management
    
    /// Add a new account to manage
    /// - Returns: The ID of the created miner
    @discardableResult
    public func addAccount(_ account: Account) -> String {
        let minerId = UUID().uuidString
        
        // Create engine for this account
        let engine = MinerEngine(clientId: clientId)
        engines[minerId] = engine
        
        let miner = ManagedMiner(
            id: minerId,
            accountId: account.id,
            username: account.username,
            ownerDiscordId: account.ownerDiscordId
        )
        miners.append(miner)
        onMinersChanged?()

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
        miners.removeAll { $0.id == minerId }
        onMinersChanged?()
    }
    
    /// Get a specific miner by ID
    public func getMiner(id: String) -> ManagedMiner? {
        miners.first { $0.id == id }
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
    public func startMiner(minerId: String, priorityGames: [String], excludedGames: [String], strategy: MiningStrategy, enableBadgesEmotes: Bool = false, showClaimNotifications: Bool = false) async throws {
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
        self.showClaimNotifications = showClaimNotifications

        // Update mining preferences
        let ignoredGames = Array(ignoredAccountLinkWarnings[miner.accountId] ?? [])
        await engine.updateMiningPreferences(
            priorityGames: priorityGames,
            excludedGames: excludedGames,
            enableBadgesEmotes: enableBadgesEmotes,
            showClaimNotifications: self.showClaimNotifications,
            ignoredAccountLinkWarningGames: ignoredGames
        )
        await engine.updateMiningStrategy(strategy)
        await engine.setDebugBypassLinkRequirement(debugBypassLinkRequirement)

        // Update status and sync priority games
        await dataCoordinator.updateAccountNeedsAuth(accountId: miner.accountId, needsAuth: false)
        updateMinerStatus(minerId: minerId, status: .authenticating, priorityGames: priorityGames, needsAuth: false)

        do {
            try await engine.start()
            await dataCoordinator.updateAccountNeedsAuth(accountId: miner.accountId, needsAuth: false)
            updateMinerStatus(minerId: minerId, isRunning: true, priorityGames: priorityGames, needsAuth: false)
        } catch {
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
        await dataCoordinator.updateAccountNeedsAuth(accountId: miner.accountId, needsAuth: false)
        updateMinerStatus(minerId: minerId, status: .idle, currentCampaignId: .some(nil), isRunning: false, needsAuth: false)
    }
    
    /// Start all miners with staggered delays to avoid API rate limiting
    public func startAll(priorityGames: [String], excludedGames: [String], strategy: MiningStrategy, enableBadgesEmotes: Bool = false, showClaimNotifications: Bool = false) async {
        self.showClaimNotifications = showClaimNotifications
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
                enableBadgesEmotes: enableBadgesEmotes
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
        await engine.setStatusChangeHandler { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let minerStatus = self.mapSessionStatus(status)
                
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
            }
        }
        
        await engine.setCampaignUpdateHandler { [weak self] campaigns in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                
                // Get all campaigns and current ID from engine
                let all = await engine.allCampaigns
                let currentId = await engine.currentCampaignId
                
                // Update current campaign info
                if let currentId, let current = all.first(where: { $0.id == currentId }) {
                    self.updateMinerStatus(minerId: minerId, currentCampaign: current.name, currentCampaignId: .some(currentId), allCampaigns: all)
                } else if let first = campaigns.first {
                    self.updateMinerStatus(minerId: minerId, currentCampaign: first.name, currentCampaignId: .some(currentId), allCampaigns: all)
                } else {
                    self.updateMinerStatus(minerId: minerId, currentCampaignId: .some(currentId), allCampaigns: all)
                }
            }
        }
        
        await engine.setDebugWinningQueueHandler { [weak self] winningQueue in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.updateMinerStatus(minerId: minerId, debugWinningQueue: winningQueue)
            }
        }
        
        await engine.setDropClaimedHandler { [weak self] drop in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.resetDailyClaimsIfNeeded()
                self.claimedTodayIds.insert(drop.id)
                self.incrementDropsClaimed(minerId: minerId)
            }
        }
        
        await engine.setLogMessageHandler { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.onLogMessage?(minerId, message)
            }
        }

        await engine.setErrorHandler { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self = self,
                      let miner = self.getMiner(id: minerId) else { return }

                let needsAuth = Self.requiresManualReauth(for: error)
                await self.dataCoordinator.updateAccountNeedsAuth(accountId: miner.accountId, needsAuth: needsAuth)
                self.updateMinerStatus(minerId: minerId, status: .error, needsAuth: needsAuth)
            }
        }
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

    private func updateMinerStatus(
        minerId: String,
        status: MinerStatus? = nil,
        currentCampaign: String? = nil,
        currentCampaignId: String?? = .none, // .none = don't touch; .some(x) = always set (x may be nil)
        allCampaigns: [Campaign]? = nil,
        isRunning: Bool? = nil,
        priorityGames: [String]? = nil,
        needsAuth: Bool? = nil,
        debugWinningQueue: [Campaign]? = nil,
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
        if let winningQueue = debugWinningQueue { miner.debugWinningQueue = winningQueue }
        if let ownerId = ownerDiscordId { miner.ownerDiscordId = ownerId }

        miners[index] = miner
        onMinersChanged?()
    }
    
    private func updateMinerStatus(minerId: String, isRunning: Bool, status: MinerStatus) {
        updateMinerStatus(minerId: minerId, status: status, isRunning: isRunning)
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
