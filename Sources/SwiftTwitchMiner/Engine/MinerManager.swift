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
        public var status: MinerStatus
        public var currentCampaign: String?
        public var currentCampaignId: String?
        public var allCampaigns: [Campaign] = []
        public var dropsClaimed: Int
        public var isRunning: Bool
        
        /// Account-specific drop state store (Phase 2). Set asynchronously after engine is ready.
        public var stateStore: AccountStateStore?

        public init(
            id: String,
            accountId: String,
            username: String,
            stateStore: AccountStateStore? = nil,
            status: MinerStatus = .idle,
            currentCampaign: String? = nil,
            currentCampaignId: String? = nil,
            allCampaigns: [Campaign] = [],
            dropsClaimed: Int = 0,
            isRunning: Bool = false
        ) {
            self.id = id
            self.accountId = accountId
            self.username = username
            self.stateStore = stateStore
            self.status = status
            self.currentCampaign = currentCampaign
            self.currentCampaignId = currentCampaignId
            self.allCampaigns = allCampaigns
            self.dropsClaimed = dropsClaimed
            self.isRunning = isRunning
        }
    }    
    public enum MinerStatus: String, Sendable, Equatable {
        case idle = "IDLE"
        case authenticating = "AUTHENTICATING"
        case fetchingCampaigns = "FETCHING_CAMPAIGNS"
        case watching = "WATCHING"
        case claiming = "CLAIMING"
        case paused = "PAUSED"
        case error = "ERROR"

        public var displayName: String {
            switch self {
            case .idle: return "Waiting"
            case .authenticating: return "Authenticating"
            case .fetchingCampaigns: return "Fetching Campaigns"
            case .watching: return "Watching"
            case .claiming: return "Claiming"
            case .paused: return "Paused"
            case .error: return "Error"
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
    
    /// The actual engine instances (by miner ID)
    private var engines: [String: MinerEngine] = [:]
    
    /// Client ID for Twitch API (mutable so it can be updated before first account is added)
    private var clientId: String
    
    /// Track drop IDs claimed today (locally)
    private var claimedTodayIds: Set<String> = []
    private var lastClaimDate: Date = Date()
    
    /// Callbacks for aggregated events
    public var onMinerStatusChange: (@Sendable (ManagedMiner) -> Void)?
    public var onAggregateProgress: (@Sendable (AggregateProgress) -> Void)?
    public var onLogMessage: (@Sendable (String, String) -> Void)? // (minerId, message)
    
    // MARK: - Initialization
    
    public init(clientId: String, campaignStore: CampaignStore = CampaignStore()) {
        self.clientId = clientId
        self.campaignStore = campaignStore
        self.dataCoordinator = MiningDataCoordinator(campaignStore: campaignStore)
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

        let authService = TwitchAuthService(clientId: clientId)
        do {
            let accounts = try await authService.loadAllAccounts()
            print("[MinerManager] Loading \(accounts.count) saved accounts from keychain")
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
        enableBadgesEmotes: Bool
    ) async {
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
            username: account.username
        )
        miners.append(miner)

        Task {
            await engine.setAccount(account)
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
            await stateStore.start()
            }        
        return minerId
    }
    
    /// Remove an account from management
    public func removeAccount(minerId: String) async {
        guard let miner = getMiner(id: minerId) else { return }
        
        // Stop the miner if running
        await stopMiner(minerId: minerId)
        
        // Unregister from data coordinator
        dataCoordinator.unregisterMiner(minerId: minerId, accountId: miner.accountId)
        
        // Remove from keychain
        let authService = TwitchAuthService(clientId: clientId)
        try? await authService.logout(accountId: miner.accountId)
        
        // Remove from collections
        engines.removeValue(forKey: minerId)
        miners.removeAll { $0.id == minerId }
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
    public func startMiner(minerId: String, priorityGames: [String], excludedGames: [String], strategy: MiningStrategy, enableBadgesEmotes: Bool = false) async throws {
        guard let engine = engines[minerId] else {
            throw TwitchMinerError.sessionNotStarted
        }

        // Update mining preferences
        await engine.updateMiningPreferences(
            priorityGames: priorityGames,
            excludedGames: excludedGames,
            enableBadgesEmotes: enableBadgesEmotes
        )
        await engine.updateMiningStrategy(strategy)

        // Update status
        updateMinerStatus(minerId: minerId, status: .authenticating)

        do {
            try await engine.start()
            updateMinerStatus(minerId: minerId, isRunning: true)
        } catch {
            updateMinerStatus(minerId: minerId, status: .error)
            throw error
        }
    }
    
    /// Stop a specific miner
    public func stopMiner(minerId: String) async {
        guard let engine = engines[minerId] else { return }
        
        await engine.stop()
        updateMinerStatus(minerId: minerId, isRunning: false, status: .idle)
    }
    
    /// Start all miners
    public func startAll(priorityGames: [String], excludedGames: [String], strategy: MiningStrategy, enableBadgesEmotes: Bool = false) async {
        for miner in miners where !miner.isRunning {
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
                self.updateMinerStatus(minerId: minerId, status: minerStatus, currentCampaignId: currentId)
            }
        }
        
        await engine.setCampaignUpdateHandler { [weak self] campaigns in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                
                // Get all campaigns and current ID from engine
                let all = await engine.allCampaigns
                let currentId = await engine.currentCampaignId
                
                // Update current campaign info
                if let first = campaigns.first {
                    self.updateMinerStatus(minerId: minerId, currentCampaign: first.name, currentCampaignId: currentId, allCampaigns: all)
                } else {
                    self.updateMinerStatus(minerId: minerId, currentCampaignId: currentId, allCampaigns: all)
                }
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
    }
    
    private func mapSessionStatus(_ status: SessionStatus) -> MinerStatus {
        switch status {
        case .idle: return .idle
        case .authenticating: return .authenticating
        case .fetchingCampaigns: return .fetchingCampaigns
        case .watching: return .watching
        case .claiming: return .claiming
        case .paused: return .paused
        case .stopped: return .idle
        case .error: return .error
        }
    }
    
    private func updateMinerStatus(
        minerId: String,
        status: MinerStatus? = nil,
        currentCampaign: String? = nil,
        currentCampaignId: String? = nil,
        allCampaigns: [Campaign]? = nil,
        isRunning: Bool? = nil
    ) {
        guard let index = miners.firstIndex(where: { $0.id == minerId }) else { return }
        
        var miner = miners[index]
        if let status = status { miner.status = status }
        if let campaign = currentCampaign { miner.currentCampaign = campaign }
        if let campaignId = currentCampaignId { miner.currentCampaignId = campaignId }
        if let campaigns = allCampaigns { miner.allCampaigns = campaigns }
        if let running = isRunning { miner.isRunning = running }
        miners[index] = miner
        
        onMinerStatusChange?(miner)
    }
    
    private func updateMinerStatus(minerId: String, isRunning: Bool, status: MinerStatus) {
        updateMinerStatus(minerId: minerId, status: status, isRunning: isRunning)
    }
    
    private func incrementDropsClaimed(minerId: String) {
        guard let index = miners.firstIndex(where: { $0.id == minerId }) else { return }
        var miner = miners[index]
        miner.dropsClaimed += 1
        miners[index] = miner
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
