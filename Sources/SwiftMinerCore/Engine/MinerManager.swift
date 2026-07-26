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
        public var streamOverrideLogin: String?
        public var allCampaigns: [Campaign] = []
        public var dropsClaimed: Int
        public var isRunning: Bool
        public var priorityGames: [String]
        public var lastEventAt: Date?
        public var lastSuccessfulPollAt: Date?
        public var lastCampaignRefreshAt: Date?
        /// When this miner last banked verified drop progress. `nil` until it earns anything.
        public var lastDropProgressAt: Date?
        /// When the current worker started. Survives the routine status churn of mining.
        public var workerStartedAt: Date?
        public var workerState: MinerWorkerState = .idle
        public var workerTaskID: String?
        public var isHealthy: Bool = true
        public var isStalled: Bool = false
        public var isOperator: Bool = false
        
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

        /// True when the miner is in an active work state but supervisor liveness has gone quiet.
        /// Refreshing, idle, blocked, and auth states already communicate a clearer user-facing reason.
        public var showsNoRecentActivityAttention: Bool {
            guard isRunning,
                  !needsAuth,
                  !isHealthy,
                  !isStalled,
                  !workerState.isRecovering else {
                return false
            }

            switch status {
            case .watching, .claiming:
                return true
            case .idle,
                 .authenticating,
                 .fetchingCampaigns,
                 .waitingForStream,
                 .paused,
                 .error,
                 .idleNoEligibleCampaigns,
                 .blockedAccountNotLinked:
                return false
            }
        }

        /// How long a miner may sit in `.watching` without banking any drop progress
        /// before it is treated as not earning. Deliberately longer than the engine's own
        /// 15-minute anti-stall window so in-engine recovery (inventory refresh, channel
        /// switch, non-earning cooldown) gets a chance to fix it before the user is told.
        public static let notEarningThreshold: TimeInterval = 20 * 60

        /// The point from which time-without-earning is measured: the last banked progress,
        /// or the worker start for a miner that has never earned. `nil` when neither is
        /// known, in which case nothing can honestly be concluded.
        public var earningReferenceDate: Date? {
            [lastDropProgressAt, workerStartedAt].compactMap { $0 }.max()
        }

        /// True when the miner looks alive but is not banking any drop progress.
        ///
        /// This is the failure mode every liveness check misses: polls succeed, events keep
        /// flowing, the supervisor sees a healthy miner, and the account sits on a stream for
        /// hours earning nothing. Watching without progress is the only symptom.
        public func isNotEarning(now: Date = Date()) -> Bool {
            guard isRunning,
                  !needsAuth,
                  !isStalled,
                  !workerState.isRecovering,
                  status == .watching,
                  // A pinned stream is expected to sit on a channel that may not earn.
                  streamOverrideLogin == nil else {
                return false
            }

            // Deliberately NOT `statusChangedAt`: normal mining cycles through
            // watching -> refreshing -> watching every few minutes, which resets that
            // timestamp and means the threshold can never be reached.
            guard let reference = earningReferenceDate else { return false }
            return now.timeIntervalSince(reference) >= Self.notEarningThreshold
        }

        /// `isNotEarning` evaluated against the current time, for UI use.
        public var showsNotEarningAttention: Bool {
            isNotEarning()
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
            if showsNoRecentActivityAttention {
                return "No Recent Activity"
            }
            if showsNotEarningAttention {
                return "Watching — Not Earning"
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
            streamOverrideLogin: String? = nil,
            allCampaigns: [Campaign] = [],
            dropsClaimed: Int = 0,
            isRunning: Bool = false,
            priorityGames: [String] = [],
            lastEventAt: Date? = nil,
            lastSuccessfulPollAt: Date? = nil,
            lastCampaignRefreshAt: Date? = nil,
            lastDropProgressAt: Date? = nil,
            workerStartedAt: Date? = nil,
            workerState: MinerWorkerState = .idle,
            workerTaskID: String? = nil,
            isHealthy: Bool = true,
            isStalled: Bool = false,
            isOperator: Bool = false
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
            self.streamOverrideLogin = Self.normalizedStreamOverrideLogin(streamOverrideLogin)
            self.allCampaigns = allCampaigns
            self.dropsClaimed = dropsClaimed
            self.isRunning = isRunning
            self.priorityGames = priorityGames
            self.lastEventAt = lastEventAt
            self.lastSuccessfulPollAt = lastSuccessfulPollAt
            self.lastCampaignRefreshAt = lastCampaignRefreshAt
            self.lastDropProgressAt = lastDropProgressAt
            self.workerStartedAt = workerStartedAt
            self.workerState = workerState
            self.workerTaskID = workerTaskID
            self.isHealthy = isHealthy
            self.isStalled = isStalled
            self.isOperator = isOperator
        }

        public var displayName: String {
            nickname ?? username
        }

        /// Normalize a user-entered channel reference into a bare Twitch login.
        /// Accepts a plain username, an `@handle`, or a full/partial stream URL
        /// (e.g. `https://www.twitch.tv/Flats?foo=bar`, `twitch.tv/flats/`).
        public static func normalizedStreamOverrideLogin(_ login: String?) -> String? {
            guard let login else { return nil }
            var value = login.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }

            // If it's a Twitch URL, keep only what follows the host.
            if let hostRange = value.range(of: "twitch.tv/", options: [.caseInsensitive]) {
                value = String(value[hostRange.upperBound...])
            }

            // Keep just the first path component, dropping any /sub-path, ?query, or #fragment.
            if let stop = value.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) {
                value = String(value[..<stop])
            }

            let cleaned = value
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "@"))
                .lowercased()
            return cleaned.isEmpty ? nil : cleaned
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
    public internal(set) var miners: [ManagedMiner] = []
    
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
    public var failoverStreamers: [GameFailoverStreamer] = []
    /// Debug-only: broadcast to every engine to bypass link/eligibility gates. Stored here
    /// so engines attached later (e.g. newly added accounts) pick up the current value.
    public var debugBypassLinkRequirement: Bool = false
    /// Scoped warnings: [accountId: Set<gameId>]
    var ignoredAccountLinkWarnings: [String: Set<String>] = [:]

    /// The actual engine instances (by miner ID)
    var engines: [String: MinerEngine] = [:]

    /// Tracks in-flight engine setup tasks (setAccount + callback registration).
    /// `startMiner()` awaits these before starting the engine, eliminating the
    /// race condition where status callbacks were not yet registered on autostart.
    private var engineSetupTasks: [String: Task<Void, Never>] = [:]

    /// Background recovery loop for miners that get wedged after network or progress stalls.
    var antiStallMonitorTask: Task<Void, Never>?
    let supervisor = MinerSupervisor()
    let unattendedHealthStore: UnattendedHealthStore?
    public let earningLedgerStore: EarningLedgerStore?
    var initializedCampaignSnapshots: Set<String> = []
    /// When each miner was last seen watching, so elapsed watch time can be credited to the
    /// ledger without standing up another timer.
    var lastWatchSampleAt: [String: Date] = [:]
    /// Smallest stretch credited in one go, so a burst of snapshots costs one ledger write
    /// rather than dozens. Hourly buckets do not care about sub-15s precision.
    static let minWatchSampleInterval: TimeInterval = 15
    /// Longest gap credited as watch time. Supervisor snapshots arrive every few seconds
    /// while a miner is watching, so a longer gap means the app was asleep or the miner was
    /// wedged — time we cannot honestly claim was spent watching.
    static let maxWatchSampleGap: TimeInterval = 120
    /// Miners currently flagged as watching-but-not-earning, so the health store is only
    /// written when a miner crosses the threshold rather than on every supervisor snapshot.
    var earningStalledMinerIds: Set<String> = []

    /// Last start options, used when anti-stall recovery restarts an individual miner.
    var currentPriorityGames: [String] = []
    var currentExcludedGames: [String] = []
    var currentStrategy: MiningStrategy = .mineAll
    var currentEnableBadgesEmotes: Bool = false
    var currentFailoverStreamers: [GameFailoverStreamer] = []
    
    /// Client ID for Twitch API (mutable so it can be updated before first account is added)
    private var clientId: String

    /// Persistent store for account tokens (Phase: Managed Platform)
    public let tokenStore: any TokenStore

    /// Track drop IDs claimed today (locally)
    var claimedTodayIds: Set<String> = []
    var lastClaimDate: Date = Date()
    
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
        tokenStore: any TokenStore = TokenStoreFactory.makeDefault(),
        unattendedHealthStore: UnattendedHealthStore? = nil,
        earningLedgerStore: EarningLedgerStore? = nil
    ) {
        self.clientId = clientId
        self.campaignStore = campaignStore
        self.tokenStore = tokenStore
        self.unattendedHealthStore = unattendedHealthStore
        self.earningLedgerStore = earningLedgerStore
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

    /// Broadcast current mining preferences to engines without restarting them.
    public func updateMiningPreferences(
        priorityGamesForMiner: (ManagedMiner) -> [String],
        excludedGames: [String],
        strategy: MiningStrategy,
        enableBadgesEmotes: Bool,
        showClaimNotifications: Bool,
        avoidDuplicateStreams: Bool,
        prioritiseFollowedStreamers: Bool,
        failoverStreamers: [GameFailoverStreamer]
    ) async {
        self.currentExcludedGames = excludedGames
        self.currentStrategy = strategy
        self.currentEnableBadgesEmotes = enableBadgesEmotes
        self.showClaimNotifications = showClaimNotifications
        self.avoidDuplicateStreams = avoidDuplicateStreams
        self.prioritiseFollowedStreamers = prioritiseFollowedStreamers
        self.failoverStreamers = failoverStreamers
        self.currentFailoverStreamers = failoverStreamers

        for miner in miners {
            let priorityGames = priorityGamesForMiner(miner)
            if miner.id == miners.first?.id {
                self.currentPriorityGames = priorityGames
            }
            guard let engine = engines[miner.id] else { continue }
            let ignoredGames = Array(ignoredAccountLinkWarnings[miner.accountId] ?? [])
            await engine.updateMiningPreferences(
                priorityGames: priorityGames,
                excludedGames: excludedGames,
                enableBadgesEmotes: enableBadgesEmotes,
                showClaimNotifications: showClaimNotifications,
                avoidDuplicateStreams: avoidDuplicateStreams,
                prioritiseFollowedStreamers: prioritiseFollowedStreamers,
                failoverStreamers: failoverStreamers,
                ignoredAccountLinkWarningGames: ignoredGames
            )
            await engine.updateMiningStrategy(strategy)
            if miner.isRunning {
                await engine.forceRefresh()
            }
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
            Logger.engine.info("Loading \(accounts.count) saved accounts from store")
            for account in accounts {
                do {
                    try addAccount(account)
                } catch AccountError.duplicateAccount {
                    Logger.engine.warning("Skipping duplicate saved account: \(account.username)")
                } catch {
                    Logger.engine.error("Failed to add saved account \(account.username): \(error)")
                }
            }
        } catch {
            Logger.engine.error("Failed to load saved accounts: \(error)")
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
        failoverStreamers: [GameFailoverStreamer] = [],
        ignoredWarnings: [String] = [],
        priorityGamesForMiner: ((ManagedMiner) -> [String])? = nil
    ) async {
        await updateIgnoredAccountLinkWarnings(ignoredWarnings)
        self.currentPriorityGames = priorityGames
        self.currentExcludedGames = excludedGames
        self.currentStrategy = strategy
        self.currentEnableBadgesEmotes = enableBadgesEmotes
        self.avoidDuplicateStreams = avoidDuplicateStreams
        self.antiStallRecoveryEnabled = antiStallRecoveryEnabled
        self.prioritiseFollowedStreamers = prioritiseFollowedStreamers
        self.failoverStreamers = failoverStreamers
        self.currentFailoverStreamers = failoverStreamers
        startAntiStallMonitorIfNeeded()
        await setup()
        if autoStart && !miners.isEmpty {
            Logger.engine.info("Auto-starting \(miners.count) miner(s) on launch")
            for miner in miners {
                try? await startMiner(
                    minerId: miner.id,
                    priorityGames: priorityGamesForMiner?(miner) ?? priorityGames,
                    excludedGames: excludedGames,
                    strategy: strategy,
                    enableBadgesEmotes: enableBadgesEmotes,
                    avoidDuplicateStreams: avoidDuplicateStreams,
                    antiStallRecoveryEnabled: antiStallRecoveryEnabled,
                    prioritiseFollowedStreamers: prioritiseFollowedStreamers,
                    failoverStreamers: failoverStreamers
                )
            }
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
            ownerDiscordId: account.ownerDiscordId,
            isOperator: account.isOperator
        )
        miners.append(miner)
        recordHealth(.minerObserved(minerID: minerId, displayName: miner.displayName, at: Date()))
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

            // Hosted unit tests create fake accounts for state assertions. Do not
            // turn those fixtures into background Twitch sessions.
            if !SwiftMinerRuntime.isRunningTests {
                // Start the state store auto-refresh (Phase 2)
                // Stagger starts to avoid thundering herd - 3s delay per account index
                let accountIndex = self.miners.firstIndex(where: { $0.id == minerId }) ?? 0
                if accountIndex > 0 {
                    let staggerDelay = UInt64(accountIndex * 3 * 1_000_000_000)
                    do {
                        try await RuntimeClock.continuous.sleep(nanoseconds: staggerDelay)
                    } catch {
                        return
                    }
                }
                await stateStore.start()
            }
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
            Logger.engine.error("Failed to update nickname for \(miners[index].accountId): \(error)")
        }

        onMinersChanged?()
    }

    public func setStreamOverride(minerId: String, login: String?) async {
        guard let index = miners.firstIndex(where: { $0.id == minerId }) else { return }
        let normalized = ManagedMiner.normalizedStreamOverrideLogin(login)
        miners[index].streamOverrideLogin = normalized
        if let engine = engines[minerId] {
            await engine.setStreamOverride(login: normalized)
        }
        onMinersChanged?()
    }

    public func clearStreamOverride(minerId: String) async {
        await setStreamOverride(minerId: minerId, login: nil)
    }

    public func updateMinerOperatorStatus(minerId: String, isOperator: Bool) async {
        guard let index = miners.firstIndex(where: { $0.id == minerId }) else { return }
        
        if isOperator {
            for idx in miners.indices {
                if miners[idx].id != minerId && miners[idx].isOperator {
                    miners[idx].isOperator = false
                    try? await tokenStore.updateOperatorStatus(twitchUserId: miners[idx].accountId, isOperator: false)
                }
            }
        }
        
        miners[index].isOperator = isOperator
        do {
            try await tokenStore.updateOperatorStatus(twitchUserId: miners[index].accountId, isOperator: isOperator)
        } catch {
            Logger.engine.error("Failed to update operator status for \(miners[index].accountId): \(error)")
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
    public func startMiner(minerId: String, priorityGames: [String], excludedGames: [String], strategy: MiningStrategy, enableBadgesEmotes: Bool = false, showClaimNotifications: Bool = false, avoidDuplicateStreams: Bool = true, antiStallRecoveryEnabled: Bool = true, prioritiseFollowedStreamers: Bool = false, failoverStreamers: [GameFailoverStreamer] = []) async throws {
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
        self.failoverStreamers = failoverStreamers
        self.currentFailoverStreamers = failoverStreamers
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
            failoverStreamers: self.failoverStreamers,
            ignoredAccountLinkWarningGames: ignoredGames
        )
        await engine.setStreamOverride(login: miner.streamOverrideLogin)
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
    public func startAll(priorityGames: [String], excludedGames: [String], strategy: MiningStrategy, enableBadgesEmotes: Bool = false, showClaimNotifications: Bool = false, avoidDuplicateStreams: Bool = true, antiStallRecoveryEnabled: Bool = true, prioritiseFollowedStreamers: Bool = false, failoverStreamers: [GameFailoverStreamer] = []) async {
        self.currentPriorityGames = priorityGames
        self.currentExcludedGames = excludedGames
        self.currentStrategy = strategy
        self.currentEnableBadgesEmotes = enableBadgesEmotes
        self.showClaimNotifications = showClaimNotifications
        self.avoidDuplicateStreams = avoidDuplicateStreams
        self.antiStallRecoveryEnabled = antiStallRecoveryEnabled
        self.prioritiseFollowedStreamers = prioritiseFollowedStreamers
        self.failoverStreamers = failoverStreamers
        self.currentFailoverStreamers = failoverStreamers
        startAntiStallMonitorIfNeeded()
        let notRunningMiners = miners.filter { !$0.isRunning }
        let totalToStart = notRunningMiners.count
        
        for (index, miner) in notRunningMiners.enumerated() {
            // Stagger starts by 3 seconds between accounts to avoid rate limit bottlenecks
            if index > 0 {
                Logger.engine.info("Staggering start for @\(miner.username): waiting 3s to avoid rate limits (\(index)/\(totalToStart))")
                do {
                    try await RuntimeClock.continuous.sleep(nanoseconds: 3 * 1_000_000_000)
                } catch {
                    return
                }
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
                prioritiseFollowedStreamers: prioritiseFollowedStreamers,
                failoverStreamers: failoverStreamers
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
