import Foundation

/// Main actor that orchestrates the Twitch drops mining lifecycle
public actor MinerEngine {
    public enum IssueCategory: String, Sendable, Equatable {
        case networkError
        case twitchAPIFailure
        case rateLimited
        case authIssue
        case watchSessionFailure
        case unknown
    }

    public enum OperationalEvent: Sendable, Equatable {
        case workerStarted(taskID: String)
        case workerStopped
        case successfulPoll
        case campaignRefresh
        case inventoryRefresh
        case authRefreshed
        case heartbeat
        case stateUpdate
        case issueDetected(category: IssueCategory, detail: String)
    }

    static func classifyIssue(_ error: Error) -> (IssueCategory, String) {
        let detail = error.localizedDescription
        if let twitchError = error as? TwitchMinerError {
            switch twitchError {
            case .networkError(let message):
                return (.networkError, message)
            case .apiError(let status, let message):
                if (500...599).contains(status) {
                    return (.twitchAPIFailure, "HTTP \(status) — \(message)")
                }
                if status == 401 || status == 403 {
                    return (.authIssue, "HTTP \(status) — \(message)")
                }
                return (.twitchAPIFailure, "HTTP \(status) — \(message)")
            case .authenticationFailed(let message), .keychainError(let message):
                return (.authIssue, message)
            case .tokenExpired:
                return (.authIssue, "Twitch token expired")
            case .rateLimited(let retryAfter):
                return (.rateLimited, "Retry after \(Int(retryAfter))s")
            case .watchSessionFailed(let message):
                return (.watchSessionFailure, message)
            case .invalidResponse:
                return (.twitchAPIFailure, "Invalid response from Twitch")
            default:
                return (.unknown, detail)
            }
        }
        let lower = detail.lowercased()
        if lower.contains("offline") || lower.contains("network") || lower.contains("timed out")
            || lower.contains("could not connect") || lower.contains("internet")
            || lower.contains("hostname") || lower.contains("dns") {
            return (.networkError, detail)
        }
        return (.unknown, detail)
    }

    static func shouldReportFatalError(_ error: TwitchMinerError) -> Bool {
        switch error {
        case .networkError, .rateLimited:
            return false
        default:
            return true
        }
    }

    // MARK: - Properties

    private let clientId: String
    private var authService: TwitchAuthService
    var apiClient: TwitchAPIClient
    var dropsService: DropsService
    private var watchSessionManager: WatchSessionManager
    private var claimService: ClaimService
    private var pubSubClient: PubSubClient
    private var dropEventsService: DropEventsService
    private var notificationService: NotificationService?

    private var session: MiningSession?
    private var isRunning = false
    private var mainTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?
    var currentAccount: Account?
    private var shouldSwitchChannel = false
    /// Set to true to interrupt the idle wait and immediately re-check for eligible campaigns
    private var shouldRescanCampaigns = false
    private var consecutiveNoCandidateCycles = 0
    /// Rotating offsets keep bounded directory and approved-channel probes from repeatedly
    /// checking the same high-ranked prefix while permanently starving lower-ranked streams.
    var directoryVerificationOffsets: [String: Int] = [:]
    var approvedChannelProbeOffsets: [String: Int] = [:]

    /// Counter for minutes watched without a server progress update (local estimation)
    var extraMinutesWatched: Int = 0
    /// Timestamp of the last verified progress update (GQL or PubSub)
    var lastProgressUpdateAt: Date = Date()
    /// Maximum extra minutes allowed before assuming mining is stalled (matches TDM)
    private static let maxExtraMinutes = 15

    /// Consecutive genuine stall windows (no verified progress, no external
    /// claim) per campaign. Reset whenever the campaign makes real progress.
    var consecutiveStallsByCampaign: [String: Int] = [:]
    /// Campaigns temporarily skipped after repeated non-earning stalls, keyed to
    /// the time the skip expires, so the miner moves on instead of looping the
    /// same dead campaign forever.
    var campaignStallCooldownUntil: [String: Date] = [:]
    /// After this many back-to-back stall windows with no verified progress and
    /// no external claim (and no failover streamer to try), a campaign is
    /// treated as non-earning and put on cooldown.
    static let nonEarningStallThreshold = 3
    /// How long a non-earning campaign is skipped before it's retried.
    static let nonEarningCooldownInterval: TimeInterval = 30 * 60

    /// Whether a campaign is currently on a non-earning cooldown.
    static func isOnStallCooldown(
        _ campaignId: String,
        cooldowns: [String: Date],
        now: Date = Date()
    ) -> Bool {
        guard let until = cooldowns[campaignId] else { return false }
        return until > now
    }

    /// Registers one genuine stall window for a campaign and reports whether it
    /// has now stalled enough times to be treated as non-earning.
    static func registerGenuineStall(
        consecutiveStalls: Int,
        threshold: Int = nonEarningStallThreshold
    ) -> (updatedCount: Int, reachedThreshold: Bool) {
        let updated = consecutiveStalls + 1
        return (updated, updated >= threshold)
    }

    /// Clears any stall streak and cooldown for a campaign that just made
    /// server-verified progress, so it is treated as earning again.
    func noteCampaignProgress(_ campaignId: String?) {
        guard let campaignId else { return }
        if consecutiveStallsByCampaign[campaignId] != nil {
            consecutiveStallsByCampaign[campaignId] = 0
        }
        campaignStallCooldownUntil[campaignId] = nil
    }

    /// A higher-ranked campaign normally preempts the current session, but not
    /// while the active drop is within this many minutes of completing —
    /// abandoning it would strand the banked watch time (drop progress is
    /// per-campaign and is lost on switch).
    static let preemptionHoldMinutes = 10
    /// Unless the preempting campaign itself ends within this window; a scarce
    /// closing window (e.g. an esports broadcast) is worth the strand.
    static let preemptionImminentEndWindow: TimeInterval = 60 * 60

    static func shouldDeferPreemption(
        remainingMinutesOnActiveDrop: Int?,
        preemptorEndDate: Date,
        now: Date = Date()
    ) -> Bool {
        guard let remaining = remainingMinutesOnActiveDrop,
              remaining <= preemptionHoldMinutes else { return false }
        return preemptorEndDate.timeIntervalSince(now) > preemptionImminentEndWindow
    }
    static let failoverCooldown: TimeInterval = 10 * 60
    private static let subscriptionWarningRepeatInterval: TimeInterval = 6 * 60 * 60
    static let noCandidateBackoffBaseInterval: UInt64 = 300 * 1_000_000_000
    // Reliability takes precedence over idle request reduction: a newly-started short campaign
    // must never wait 10–15 minutes to be discovered just because earlier scans were empty.
    static let noCandidateBackoffMaxInterval: UInt64 = 5 * 60 * 1_000_000_000

    /// Cache of all campaigns fetched during the last check
    public internal(set) var allCampaigns: [Campaign] = []
    var progressEventTracker = DropProgressEventTracker()

    /// Per-game live-channel probe results recorded as a side effect of channel selection,
    /// keyed by normalized game key. Used to keep campaigns whose game currently has no live,
    /// watch-mineable channel from out-ranking ones that do. Without this, a soon-to-expire
    /// limited-time campaign with no live stream can repeatedly preempt or starve an active
    /// game (e.g. Overwatch) under the end-date-first `.mineAll` ordering.
    var gameLiveProbes: [String: (hasLiveChannel: Bool, checkedAt: Date)] = [:]
    /// How long a "no live channel" probe result keeps a game demoted before it is re-probed.
    /// Generous enough to span more than one campaign-check cycle so demotion is stable, short
    /// enough that a game coming online is picked up on the next full rescan.
    static let gameLiveProbeFreshness: TimeInterval = 15 * 60

    // Configuration
    private let campaignCheckInterval: UInt64 = 300 * 1_000_000_000 // 5 minutes
    private let claimCheckInterval: UInt64 = 2 * 60 * 1_000_000_000 // 2 minutes (conditional polling)
    /// The active-watch loop wakes on this cadence and fires each check on its
    /// own interval, so a 60s check actually happens every ~60s rather than
    /// being rounded up to the sum of a long sleep plus the claim wait.
    private let watchLoopTickInterval: UInt64 = 10 * 1_000_000_000 // 10 seconds

    // Mining preferences (set from AppModel/Settings)
    var priorityGames: [String] = []
    var excludedGames: [String] = []
    var enableBadgesEmotes: Bool = false
    private var showClaimNotifications: Bool = false
    private var ignoredAccountLinkWarningGames: Set<String> = []
    private var warnedUnlinkedPriorityGames: Set<String> = []
    private var subscriptionWarningKeys: [String: Date] = [:]
    var failoverStreamers: [GameFailoverStreamer] = []
    var failoverCooldowns: [String: Date] = [:]
    private var pendingFailoverTarget: PendingFailoverTarget?
    var avoidDuplicateStreams: Bool = false
    var prioritiseFollowedStreamers: Bool = false
    var streamOverrideLogin: String?
    /// True while watching the override streamer even though none of this miner's eligible
    /// drop campaigns are active on their channel (pure "watch them anyway" session).
    var streamOverrideWatchOnly: Bool = false
    var channelAssignmentAvoidanceProvider: (@Sendable (_ campaignId: String, _ viableChannelCount: Int) async -> Set<String>)?
    /// Debug-only: when true, accepts any time-active campaign and picks any live channel
    /// without requiring account linkage or GQL drop verification. Exercises the watch
    /// pipeline for testing; drops won't credit for unlinked accounts.
    var debugBypassLinkRequirement: Bool = false

    private struct PendingFailoverTarget: Sendable {
        let campaignId: String
        let streamerLogin: String
    }

    /// Returns this engine's DropsService so callers on other actors can create an AccountStateStore.
    func getDropsService() -> DropsService { dropsService }

    /// Returns this engine's API client for coordinator registration.
    func getAPIClient() -> TwitchAPIClient { apiClient }

    // MARK: - Callbacks
    
    public var onStatusChange: (@Sendable (SessionStatus) -> Void)?
    public var onCampaignUpdate: (@Sendable ([Campaign]) -> Void)?
    public var onProgressUpdate: (@Sendable (OverallProgress) -> Void)?
    public var onDropClaimed: (@Sendable (Drop) -> Void)?
    public var onError: (@Sendable (TwitchMinerError) -> Void)?
    public var onLogMessage: (@Sendable (String) -> Void)?
    public var onOperationalEvent: (@Sendable (OperationalEvent) -> Void)?
    public var onLinkWarning: (@Sendable (String) -> Void)?
    public var onStreamOverrideChange: (@Sendable (String?) -> Void)?
    
    // MARK: - Callback Setters

    public func setStatusChangeHandler(_ handler: (@Sendable (SessionStatus) -> Void)?) {
        self.onStatusChange = handler
    }

    public func setCampaignUpdateHandler(_ handler: (@Sendable ([Campaign]) -> Void)?) {
        self.onCampaignUpdate = handler
    }

    public func setProgressUpdateHandler(_ handler: (@Sendable (OverallProgress) -> Void)?) {
        self.onProgressUpdate = handler
    }

    public func setOperationalEventHandler(_ handler: (@Sendable (OperationalEvent) -> Void)?) {
        self.onOperationalEvent = handler
    }

    public func setLinkWarningHandler(_ handler: (@Sendable (String) -> Void)?) {
        self.onLinkWarning = handler
    }

    public func setStreamOverrideChangeHandler(_ handler: (@Sendable (String?) -> Void)?) {
        self.onStreamOverrideChange = handler
    }

    /// Update mining preferences (priority/excluded games)
    public func updateMiningPreferences(
        priorityGames: [String],
        excludedGames: [String],
        enableBadgesEmotes: Bool = false,
        showClaimNotifications: Bool = false,
        avoidDuplicateStreams: Bool = false,
        prioritiseFollowedStreamers: Bool = false,
        failoverStreamers: [GameFailoverStreamer] = [],
        ignoredAccountLinkWarningGames: [String] = []
    ) {
        self.priorityGames = priorityGames
        self.excludedGames = excludedGames
        self.enableBadgesEmotes = enableBadgesEmotes
        self.showClaimNotifications = showClaimNotifications
        self.avoidDuplicateStreams = avoidDuplicateStreams
        self.prioritiseFollowedStreamers = prioritiseFollowedStreamers
        self.failoverStreamers = failoverStreamers
        self.ignoredAccountLinkWarningGames = Set(ignoredAccountLinkWarningGames)
        
        // Configure notification service if enabled
        if showClaimNotifications && notificationService == nil {
            self.notificationService = NotificationService()
        }
        
        Task {
            await notificationService?.configure(enabled: showClaimNotifications)
        }
    }

    /// Debug-only toggle. When enabled, the miner ignores account-link/eligibility gates
    /// and picks a random live channel for any time-active campaign. For testing only.
    public func setDebugBypassLinkRequirement(_ enabled: Bool) {
        if debugBypassLinkRequirement != enabled {
            log(enabled ? "Debug: bypassing link requirement — will watch any live channel" : "Debug: link requirement re-enabled")
        }
        debugBypassLinkRequirement = enabled
        shouldRescanCampaigns = true
    }

    /// Update the prioritised games list.
    public func updatePriorityGames(_ priorityGames: [String]) {
        self.priorityGames = priorityGames
        // Waking the engine might be desired, but periodic refresh will handle it too.
    }

    /// Update followed/subscribed streamer channel ranking without restarting the engine.
    public func updateFollowedStreamerPriority(enabled: Bool) {
        self.prioritiseFollowedStreamers = enabled
        shouldRescanCampaigns = true
    }

    public func updateFailoverStreamers(_ streamers: [GameFailoverStreamer]) {
        self.failoverStreamers = streamers
        failoverCooldowns = failoverCooldowns.filter { $0.value > Date() }
        shouldRescanCampaigns = true
    }

    public func setStreamOverride(login: String?) {
        let normalized = Self.normalizedStreamOverrideLogin(login)
        guard normalized != streamOverrideLogin else { return }
        streamOverrideLogin = normalized
        streamOverrideWatchOnly = false
        onStreamOverrideChange?(normalized)
        log(normalized.map { "Stream override set to @\($0)" } ?? "Stream override cleared")
        shouldSwitchChannel = true
        shouldRescanCampaigns = true
    }

    /// Update which games should have account-link warnings suppressed for this miner.
    /// - Parameter games: Array of game names or IDs, or ["all"] for global suppression.
    public func updateAccountLinkWarningPreference(games: [String]) {
        self.ignoredAccountLinkWarningGames = Set(games)
        if games.contains("all") {
            warnedUnlinkedPriorityGames.removeAll()
        } else {
            // Remove games that are no longer ignored from the "already warned" set
            // so they can be warned about again if they reappear.
            // Actually, warnedUnlinkedPriorityGames is just to avoid spamming the log.
            // If we un-ignore a game, we want to warn about it again.
            warnedUnlinkedPriorityGames.subtract(Set(games))
        }
    }

    /// Update notification preference
    public func updateNotificationPreference(enabled: Bool) async {
        self.showClaimNotifications = enabled
        
        if enabled && notificationService == nil {
            self.notificationService = NotificationService()
        }
        
        await notificationService?.configure(enabled: enabled)
    }

    /// Update mining strategy
    public func updateMiningStrategy(_ strategy: MiningStrategy) {
        self.miningStrategy = strategy
    }

    public func setChannelAssignmentAvoidanceProvider(
        _ provider: (@Sendable (_ campaignId: String, _ viableChannelCount: Int) async -> Set<String>)?
    ) {
        channelAssignmentAvoidanceProvider = provider
    }

    var miningStrategy: MiningStrategy = .mineAll
    
    public func setDropClaimedHandler(_ handler: (@Sendable (Drop) -> Void)?) {
        self.onDropClaimed = handler
    }
    
    public func setErrorHandler(_ handler: (@Sendable (TwitchMinerError) -> Void)?) {
        self.onError = handler
    }
    
    public func setLogMessageHandler(_ handler: (@Sendable (String) -> Void)?) {
        self.onLogMessage = handler
    }

    /// Enable/disable debug trace mode.
    /// When enabled, `[GraphQL]`, `[PubSub]`, `[Spade]`, `[Claim]` lines
    /// are forwarded to the same `onLogMessage` callback.
    public func setDebugTraceEnabled(_ enabled: Bool) async {
        await DebugTrace.shared.setHandler(enabled ? onLogMessage : nil)
        if enabled {
            await DebugTrace.shared.enable()
        } else {
            await DebugTrace.shared.disable()
        }
    }

    // MARK: - Initialization

    public init(clientId: String, tokenStore: any TokenStore = TokenStoreFactory.makeDefault()) {
        self.clientId = clientId
        self.authService = TwitchAuthService(clientId: clientId, tokenStore: tokenStore)
        self.apiClient = TwitchAPIClient(authService: authService, clientId: clientId)
        self.dropsService = DropsService(apiClient: apiClient)
        self.watchSessionManager = WatchSessionManager(apiClient: apiClient)
        self.claimService = ClaimService(apiClient: apiClient)
        self.pubSubClient = PubSubClient()
        self.dropEventsService = DropEventsService(pubSubClient: pubSubClient)

        // Handle token refresh automatically for PubSub and API Client
        Task {
            await authService.setTokenRefreshHandler { [weak self] newToken in
                guard let self = self else { return }
                Task {
                    await self.apiClient.updateAccessToken(newToken)
                    await self.pubSubClient.updateAccessToken(newToken)
                    await self.log("Clients access token updated after refresh")
                }
            }
        }
    }

    /// Configure DropEventsService callbacks. Call this after init but before start().
    private func configureDropEventsService() async {
        // Set up drop progress handler
        await dropEventsService.setDropProgressHandler { [weak self] event in
            guard let self = self else { return }
            Task {
                await self.handleDropProgress(event)
            }
        }

        // Set up drop claim handler
        await dropEventsService.setDropClaimHandler { [weak self] event in
            guard let self = self else { return }
            Task {
                await self.handleDropClaim(event)
            }
        }

        // Set up stream down handler
        await dropEventsService.setStreamDownHandler { [weak self] channelId in
            guard let self = self else { return }
            Task {
                await self.handleStreamDown(channelId)
            }
        }

        // Set up stream state handler for logging
        await dropEventsService.setStreamStateHandler { [weak self] event in
            guard let self = self else { return }
            Task {
                switch event.kind {
                case .up:
                    await self.log("Stream \(event.channelId) is LIVE")
                case .down:
                    await self.log("Stream \(event.channelId) went OFFLINE")
                case .viewcount(let count):
                    await self.log("Stream \(event.channelId) viewers: \(count)")
                case .commercial(let duration):
                    await self.log("Stream \(event.channelId) commercial: \(duration)s")
                }
            }
        }

        // Configure the service to receive messages
        await dropEventsService.configure()
    }
    
    // MARK: - Public API
    
    /// Pre-load an already-authenticated account (call before start() when account is known).
    /// This bypasses the keychain reload in start() and avoids the isTokenValid check.
    public func setAccount(_ account: Account) async {
        self.currentAccount = account
        await authService.setCurrentAccount(account)
        await authService.setAccountId(account.id)
        await apiClient.setAccountId(account.id)
        await dropsService.setAccountId(account.id)
        await apiClient.updateAccessToken(account.accessToken)
        await apiClient.setUserLogin(account.username)
        await pubSubClient.updateAccessToken(account.accessToken)
        await watchSessionManager.setUserId(account.id)
    }

    /// Starts the mining engine
    public func start() async throws {
        guard !isRunning else {
            throw TwitchMinerError.watchSessionFailed("Engine already running")
        }

        isRunning = true
        let workerTaskID = UUID().uuidString
        session = MiningSession()
        progressEventTracker = DropProgressEventTracker()
        warnedUnlinkedPriorityGames.removeAll()
        onOperationalEvent?(.workerStarted(taskID: workerTaskID))

        onStatusChange?(.authenticating)
        log("Starting SwiftMinerCore...")

        // Use pre-loaded account if available, otherwise try keychain.
        // Load even if the token appears expired — refreshTokenIfNeeded() will
        // transparently refresh it when getAccessToken() is called below.
        if currentAccount == nil {
            currentAccount = try? await authService.loadSavedAccount()
        }

        guard let account = currentAccount else {
            log("No valid authentication found. Please authenticate first.")
            isRunning = false
            throw TwitchMinerError.authenticationFailed("No valid credentials. Please call authenticate() first.")
        }
        log("Authenticated as \(account.username)")
        
        await watchSessionManager.setErrorHandler { [weak self] error in
            guard let self else { return }
            Task {
                await self.handleWatchSessionError(error)
            }
        }
        await watchSessionManager.setHeartbeatSentHandler { [weak self] session in
            guard let self else { return }
            Task {
                await self.handleWatchHeartbeatSent(session)
            }
        }

        // Configure PubSub/DropEventsService
        await configureDropEventsService()

        // Load token into apiClient (required before any GQL requests) and PubSub
        do {
            let token = try await apiClient.getAccessToken()
            log("Access token loaded (\(token.prefix(8))…, length: \(token.count))")
            await apiClient.updateAccessToken(token)
            await pubSubClient.updateAccessToken(token)
            try await pubSubClient.connect()
            log("PubSub connected")
        } catch {
            log("PubSub connection failed (will retry during watch loop): \(error.localizedDescription)")
        }

        // Pass user info to services
        if let account = currentAccount {
            await watchSessionManager.setUserId(account.id)
            await apiClient.setUserLogin(account.username)
            await apiClient.setAccountId(account.id)
            await authService.setAccountId(account.id)
        }

        // Start main mining loop
        mainTask = Task { [weak self] in
            guard let self = self else { return }
            await self.runMiningLoop()
        }
        onOperationalEvent?(.stateUpdate)

        // Start maintenance loop (30 minute intervals)
        startMaintenanceLoop()
    }
    
    /// Stops the mining engine
    public func stop() async {
        log("Stopping miner...")
        isRunning = false
        progressEventTracker = DropProgressEventTracker()
        mainTask?.cancel()
        mainTask = nil
        maintenanceTask?.cancel()
        maintenanceTask = nil
        
        // Stop PubSub watching
        try? await dropEventsService.stopWatching()
        
        await watchSessionManager.stopWatching()
        
        session?.status = .stopped
        session?.endedAt = Date()
        
        onStatusChange?(.stopped)
        onOperationalEvent?(.workerStopped)
    }
    
    /// Initiates device code authentication flow
    public func authenticate() async throws -> DeviceAuthInfo {
        let deviceResponse = try await authService.initiateDeviceFlow()
        
        // Start polling in background
        Task {
            do {
                let account = try await authService.pollForToken(
                    deviceCode: deviceResponse.deviceCode,
                    interval: deviceResponse.interval
                )
                currentAccount = account
                log("Successfully authenticated as \(account.username)")
            } catch {
                handleError(error as? TwitchMinerError ?? .unknown(error.localizedDescription))
            }
        }
        
        return DeviceAuthInfo(
            userCode: deviceResponse.userCode,
            verificationURL: deviceResponse.verificationURI,
            expiresIn: deviceResponse.expiresIn
        )
    }
    
    /// Triggers an immediate campaign rescan and potential channel switch.
    /// Wakes the engine from idle sleep or breaks the current watch session.
    public func forceRefresh() {
        log("Forcing immediate campaign rescan...")
        shouldRescanCampaigns = true
        shouldSwitchChannel = true
        onOperationalEvent?(.stateUpdate)
    }

    public func forceInventoryRefresh() async throws {
        let inventoryService = await dropsService.getInventoryService()
        let snapshot = try await inventoryService.fetchInventory(forceRefresh: true)
        syncCampaigns(with: snapshot)
        onOperationalEvent?(.inventoryRefresh)
        if let progress = try? await dropsService.getOverallProgress() {
            onProgressUpdate?(progress)
        }
    }

    public func refreshAuthenticationSession() async throws {
        let token = try await authService.refreshTokenIfNeeded()
        await apiClient.updateAccessToken(token)
        await pubSubClient.updateAccessToken(token)
        if let account = currentAccount {
            await apiClient.setUserLogin(account.username)
            await apiClient.setAccountId(account.id)
            await authService.setAccountId(account.id)
        }
        try? await pubSubClient.connect()
        onOperationalEvent?(.authRefreshed)
        log("Authentication/session refresh completed")
    }

    /// Claims all ready drops immediately
    public func claimAllDrops() async throws {
        guard isRunning else {
            throw TwitchMinerError.sessionNotStarted
        }

        _ = await claimReadyDrops()
    }

    /// Gets current overall progress
    public func getCurrentProgress() async throws -> OverallProgress {
        guard isRunning else {
            throw TwitchMinerError.sessionNotStarted
        }

        let rawProgress = try await dropsService.getOverallProgress()
        
        // Strict prioritisation contract: Filter progress to prioritised games only.
        let prioritySet = Set(priorityGames.map { $0.lowercased() })
        let filteredCampaigns = rawProgress.campaigns.filter { cp in
            prioritySet.contains(cp.gameName.lowercased())
        }
        
        // Re-calculate totals based on filtered set
        let totalDrops = filteredCampaigns.reduce(0) { $0 + $1.totalDrops }
        let claimedDrops = filteredCampaigns.reduce(0) { $0 + $1.claimedDrops }
        let totalWatchTime = filteredCampaigns.reduce(0) { total, cp in
            total + cp.dropProgress.reduce(0) { $0 + $1.currentMinutes }
        }
        
        return OverallProgress(
            totalCampaigns: filteredCampaigns.count,
            activeCampaigns: filteredCampaigns.count,
            totalDrops: totalDrops,
            claimedDrops: claimedDrops,
            pendingDrops: max(0, totalDrops - claimedDrops),
            totalWatchTimeMinutes: totalWatchTime,
            campaigns: filteredCampaigns
        )
    }
    /// Current mining session info
    public var currentSession: MiningSession? {
        get async { session }
    }
    
    /// The ID of the campaign currently being watched
    public var currentCampaignId: String? {
        get async { session?.currentCampaignId }
    }
    
    public var isActive: Bool {
        isRunning
    }
    
    // MARK: - Event Handlers

    private func handleDropProgress(_ event: DropProgressEvent) async {
        let campaignId = session?.currentCampaignId
        let observation = DropProgressObservation(
            campaignId: campaignId,
            dropId: event.dropId,
            dropLabel: dropLabel(for: event.dropId, campaignId: campaignId),
            currentMinutes: event.currentMinutes,
            requiredMinutes: event.requiredMinutes,
            source: .pubSub
        )
        let result = progressEventTracker.observe(observation)
        tracePubSub(
            "drop-progress drop=\(event.dropId) rawCurrent=\(event.currentMinutes) parsedCurrent=\(event.currentMinutes) " +
            "previous=\(result.previousMinutes.map(String.init) ?? "nil") transition=\(result.transition.traceDescription)"
        )

        guard result.shouldAcknowledgeServerProgress else {
            return
        }

        if let message = formatProgressTransition(result.transition) {
            log(message)
        }

        // Reset local estimation only when server progress actually advanced.
        extraMinutesWatched = 0
        lastProgressUpdateAt = Date()
        noteCampaignProgress(campaignId)

        await refreshCampaignProgress(
            campaignId: campaignId,
            context: "PubSub progress"
        )
    }

    private func handleDropClaim(_ event: DropClaimEvent) async {
        let campaignId = session?.currentCampaignId
        log("Drop claim event received: dropInstanceId=\(event.dropInstanceId)")

        guard !isLikelyInternalTestDropEvent(dropId: event.dropId, campaignId: campaignId) else {
            log("Skipped auto-claim for internal/test drop event: \(event.dropId)")
            return
        }

        // Use the dropInstanceId directly from PubSub event for claiming
        do {
            let response = try await apiClient.claimDrop(dropInstanceId: event.dropInstanceId)

            if response.status == "CLAIMED" || response.status == "SUCCESS" {
                let dropName = dropLabel(for: event.dropId, campaignId: campaignId)
                let trackerResult = progressEventTracker.markClaimed(
                    campaignId: campaignId,
                    dropId: event.dropId,
                    dropLabel: dropName
                )
                log("Auto-claimed drop from PubSub: \(event.dropInstanceId)")
                if let message = formatProgressTransition(trackerResult.transition) {
                    log(message)
                }

                // Try to find drop info for the callback
                let inventory = try? await dropsService.fetchInventory()
                if let progress = inventory?.first(where: { $0.dropId == event.dropId }) {
                    let drop = Drop(
                        id: event.dropId,
                        name: progress.dropName,
                        requiredMinutes: progress.requiredMinutes
                    )
                    onDropClaimed?(drop)

                    // Send local notification if enabled
                    if showClaimNotifications, let notificationService = notificationService {
                        // Find campaign name for notification
                        let campaign = try? await dropsService.getCampaign(id: progress.campaignId)
                        await notificationService.notifyDropClaimed(
                            campaignName: campaign?.name ?? "Unknown Campaign",
                            dropName: progress.dropName
                        )
                    }
                }

                session?.dropsClaimed += 1
            } else {                log("Warning: Drop claim returned status: \(response.status)")
            }
        } catch {
            log("Failed to auto-claim drop: \(error.localizedDescription)")
        }
    }

    private func handleStreamDown(_ channelId: String) async {
        log("Stream went down: \(channelId)")

        // Check if we're watching this channel
        if session?.currentChannelId == channelId {
            log("Current channel went offline, will switch...")
            lastSwitchReason = .channelWentOffline
            lastSwitchAt = Date()
            shouldSwitchChannel = true

            // Stop current watch session
            await cleanupActiveWatchSession(clearTarget: false)
        }
    }

    private func handleWatchSessionError(_ error: TwitchMinerError) async {
        log("Watch session warning: \(error.localizedDescription)")
        let (category, detail) = Self.classifyIssue(error)
        onOperationalEvent?(.issueDetected(category: category, detail: detail))
    }

    func emitIssue(_ error: Error) {
        let (category, detail) = Self.classifyIssue(error)
        onOperationalEvent?(.issueDetected(category: category, detail: detail))
    }

    /// Subscribes to real-time drop/stream events for the current channel.
    ///
    /// PubSub is connected at miner startup and on auth refresh, but nothing
    /// else re-establishes it: if that socket drops (or its initial connect
    /// failed) the miner would spend the rest of the session blind to real-time
    /// progress, relying on polling only. So if subscribing fails, attempt one
    /// reconnect and retry before giving up for this cycle.
    private func startDropEventsWatching(userId: String, channelId: String) async {
        do {
            try await dropEventsService.startWatching(userId: userId, channelId: channelId)
            log("PubSub watching started for user:\(userId) channel:\(channelId)")
            return
        } catch {
            log("Failed to start PubSub watching: \(error.localizedDescription). Reconnecting PubSub…")
        }

        do {
            try await pubSubClient.connect()
            try await dropEventsService.startWatching(userId: userId, channelId: channelId)
            log("PubSub reconnected; watching started for user:\(userId) channel:\(channelId)")
        } catch {
            log("PubSub reconnect failed: \(error.localizedDescription). Continuing with polling-only progress detection this cycle.")
        }
    }

    private func handleWatchHeartbeatSent(_ session: WatchSession) async {
        if let transport = session.lastHeartbeatTransport {
            log("Watch heartbeat sent for \(session.channelName) via \(transport)")
        } else {
            log("Watch heartbeat sent for \(session.channelName)")
        }
        onOperationalEvent?(.heartbeat)
    }

    private func cleanupActiveWatchSession(clearTarget: Bool) async {
        let channelId = session?.currentChannelId

        await watchSessionManager.stopWatching()
        if let channelId, !channelId.isEmpty {
            try? await dropEventsService.stopWatchingChannel(channelId)
        }

        if clearTarget {
            session?.currentCampaignId = nil
            session?.currentChannelId = nil
            currentChannelName = nil
            currentChannelId = nil
        }
    }
    
    // MARK: - Maintenance Loop

    private func startMaintenanceLoop() {
        maintenanceTask?.cancel()
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                // Wait for 30 minutes
                try? await Task.sleep(nanoseconds: 30 * 60 * 1_000_000_000)
                if Task.isCancelled { break }
                
                guard let self = self else { break }
                await self.performMaintenance()
            }
        }
    }

    private func performMaintenance() async {
        log("Running background maintenance task...")
        do {
            // 1. Validate / Refresh token
            // authService.refreshTokenIfNeeded() is safe to call even if token is valid
            let token = try await authService.refreshTokenIfNeeded()
            
            // 2. Ensure API Client is in sync
            await apiClient.updateAccessToken(token)
            
            log("Maintenance: Token validated/refreshed")
            onOperationalEvent?(.authRefreshed)
            
            // 3. Check for major campaign updates (TDM parity)
            // If we've been running for a long time, it's good to force a full inventory refresh
            // every few maintenance cycles. For now, we rely on the 5m loop in runMiningLoop.
            
        } catch {
            log("Maintenance task warning: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Private Methods

    private func runMiningLoop() async {
        while isRunning && !Task.isCancelled {
            do {
                let perfCycleStartedAt = Date()
                var perfCampaignFetchSeconds: TimeInterval = 0
                var perfClaimCheckSeconds: TimeInterval = 0
                var perfChannelSelectionSeconds: TimeInterval = 0
                var perfWatchStartupSeconds: TimeInterval = 0
                var perfCandidateCount = 0

                func finishPerformanceCycle(
                    outcome: String,
                    campaign: Campaign? = nil,
                    channel: Channel? = nil
                ) async {
                    let finishedAt = Date()
                    let timing = PerformanceDiagnostics.MiningCycleTiming(
                        minerId: currentAccount?.id ?? "unknown",
                        minerLabel: currentAccount?.username ?? "unknown",
                        startedAt: perfCycleStartedAt,
                        finishedAt: finishedAt,
                        outcome: outcome,
                        totalSeconds: finishedAt.timeIntervalSince(perfCycleStartedAt),
                        campaignFetchSeconds: perfCampaignFetchSeconds,
                        claimCheckSeconds: perfClaimCheckSeconds,
                        channelSelectionSeconds: perfChannelSelectionSeconds,
                        watchStartupSeconds: perfWatchStartupSeconds,
                        candidateCount: perfCandidateCount,
                        selectedCampaign: campaign?.name,
                        selectedChannel: channel?.displayName
                    )
                    await PerformanceDiagnostics.shared.recordMiningCycle(timing)
                    log(Self.performanceCycleSummary(timing))
                }

                onStatusChange?(.fetchingCampaigns)
                log("Fetching active campaigns...")

                // 1. Fetch all campaigns (single call — avoids double API hit).
                var perfStartedAt = Date()
                var allEnriched = try await dropsService.fetchCampaigns()
                perfCampaignFetchSeconds += Date().timeIntervalSince(perfStartedAt)
                onOperationalEvent?(.successfulPoll)
                onOperationalEvent?(.campaignRefresh)
                
                self.allCampaigns = allEnriched
                var candidates = candidateCampaigns(
                    from: allEnriched,
                    priorityGames: priorityGames,
                    excludedGames: excludedGames,
                    strategy: miningStrategy
                )
                perfCandidateCount = candidates.count
                
                log(Self.campaignRefreshSummary(totalCampaigns: allEnriched.count, candidates: candidates))

                await warnForUnlinkedPriorityCampaigns(in: allEnriched)
                await warnForSubscriptionRequiredCampaigns(in: allEnriched)

                // Log expired campaigns that might be incorrectly marked as eligible.
                let expiredButEligible = allEnriched.filter { $0.miningStatus == .expired && $0.isMiningEligible }
                if !expiredButEligible.isEmpty {
                    log("Warning: \(expiredButEligible.count) expired campaigns incorrectly marked as mining-eligible:")
                    for c in expiredButEligible {
                        log("   - \(c.name) (endDate: \(c.endDate), isTimeActive: \(c.isTimeActive), isAccountConnected: \(c.isAccountConnected))")
                    }
                }
                
                onCampaignUpdate?(candidates)

                // 2. Claim any ready drops first (Claimable status handled here)
                perfStartedAt = Date()
                let didClaimDrops = await claimReadyDrops()
                perfClaimCheckSeconds += Date().timeIntervalSince(perfStartedAt)
                if didClaimDrops {
                    perfStartedAt = Date()
                    allEnriched = try await dropsService.fetchCampaigns(forceRefresh: true)
                    perfCampaignFetchSeconds += Date().timeIntervalSince(perfStartedAt)
                    onOperationalEvent?(.successfulPoll)
                    onOperationalEvent?(.campaignRefresh)
                    self.allCampaigns = allEnriched
                    candidates = candidateCampaigns(
                        from: allEnriched,
                        priorityGames: priorityGames,
                        excludedGames: excludedGames,
                        strategy: miningStrategy
                    )
                    perfCandidateCount = candidates.count
                    onCampaignUpdate?(candidates)
                }

                // 3. Find the best account-eligible campaign that also has a live channel.
                // An active stream override can still watch its streamer with no eligible
                // campaign, so only short-circuit on empty candidates when no override is set.
                if candidates.isEmpty, streamOverrideLogin == nil {
                    consecutiveNoCandidateCycles += 1
                    log("No account-eligible campaigns matching strategy '\(miningStrategy.displayName)'")
                    await cleanupActiveWatchSession(clearTarget: true)
                    let emptyState = Self.resolveEmptyCandidateState(
                        from: allEnriched,
                        priorityGames: priorityGames,
                        excludedGames: excludedGames,
                        strategy: miningStrategy,
                        includesBadgeAndEmoteCampaigns: enableBadgesEmotes
                    )
                    onStatusChange?(emptyState)
                    await finishPerformanceCycle(outcome: "no-candidates")
                    // Wait up to campaignCheckInterval in 10s ticks, breaking early on triggerRescan()
                    let waitInterval = Self.noCandidateBackoffInterval(for: consecutiveNoCandidateCycles)
                    if waitInterval > campaignCheckInterval {
                        let minutes = Int(waitInterval / 60_000_000_000)
                        log("No-candidate backoff active after \(consecutiveNoCandidateCycles) empty scans; next check in \(minutes)m.")
                    }
                    shouldRescanCampaigns = false
                    let tickNs: UInt64 = 10 * 1_000_000_000
                    let ticks = Int(waitInterval / tickNs)
                    for _ in 0..<ticks {
                        if shouldRescanCampaigns { break }
                        try await Task.sleep(nanoseconds: tickNs)
                    }
                    shouldRescanCampaigns = false
                    continue
                }
                consecutiveNoCandidateCycles = 0

                var selectedCampaign: Campaign?
                var selectedChannel: Channel?

                perfStartedAt = Date()
                if streamOverrideLogin != nil {
                    switch await selectStreamOverrideChannel(for: candidates) {
                    case .selected(let campaign, let channel):
                        selectedCampaign = campaign
                        selectedChannel = channel
                    case .waiting:
                        log("Stream override is active; could not verify the override stream right now — will retry shortly.")
                    case .cleared:
                        break
                    }
                }

                if selectedCampaign == nil,
                   selectedChannel == nil,
                   streamOverrideLogin == nil,
                   let pending = pendingFailoverTarget {
                    pendingFailoverTarget = nil
                    if let campaign = candidates.first(where: { $0.id == pending.campaignId }),
                       let channel = await verifiedFailoverChannel(
                           for: campaign,
                           streamerLogin: pending.streamerLogin,
                           context: "pending failover"
                       ) {
                        selectedCampaign = campaign
                        selectedChannel = channel
                    }
                }

                if selectedCampaign == nil, selectedChannel == nil, streamOverrideLogin == nil {
                    // Group candidates by game so a single live-channel fetch and GQL probe per
                    // channel can be matched against every candidate for that game. Preserves the
                    // order established by `candidateCampaigns` so priority games are tried first.
                    var gameOrder: [String] = []
                    var candidatesByGame: [String: [Campaign]] = [:]
                    for candidate in candidates {
                        let key = normalizedGameKey(candidate.gameName)
                        if candidatesByGame[key] == nil { gameOrder.append(key) }
                        candidatesByGame[key, default: []].append(candidate)
                    }

                    for gameKey in gameOrder {
                        guard let gameCandidates = candidatesByGame[gameKey], !gameCandidates.isEmpty else { continue }
                        let verificationCandidates = Self.sameGameVerificationCandidates(
                            primaryCandidates: gameCandidates,
                            allCampaigns: allEnriched,
                            priorityGames: priorityGames,
                            excludedGames: excludedGames,
                            strategy: miningStrategy,
                            includesBadgeAndEmoteCampaigns: enableBadgesEmotes
                        )
                        let gameName = gameCandidates[0].gameName
                        if verificationCandidates.count > gameCandidates.count {
                            let added = verificationCandidates.count - gameCandidates.count
                            log("Checking game: \(gameName) (\(gameCandidates.count) candidate campaign(s), \(added) same-game fallback campaign(s))")
                        } else {
                            log("Checking game: \(gameName) (\(gameCandidates.count) candidate campaign(s))")
                        }
                        let sameGameCampaigns = Self.sameGameCampaigns(matching: gameCandidates[0], in: allEnriched)
                        if let (campaign, channel) = await selectBestChannel(
                            forGameCandidates: verificationCandidates,
                            knownSameGameCampaigns: sameGameCampaigns
                        ) {
                            recordGameLiveProbe(gameKey, hasLiveChannel: true)
                            selectedCampaign = campaign
                            selectedChannel = channel
                            break
                        }
                        recordGameLiveProbe(gameKey, hasLiveChannel: false)
                        log("No eligible channels available for \(gameName); trying next game.")
                    }
                }
                perfChannelSelectionSeconds += Date().timeIntervalSince(perfStartedAt)

                guard let campaign = selectedCampaign, let channel = selectedChannel else {
                    log("No eligible channels available for \(candidates.count) account-eligible campaign(s)")
                    await cleanupActiveWatchSession(clearTarget: true)
                    onStatusChange?(.waitingForStream)
                    await finishPerformanceCycle(outcome: "no-channel")
                    shouldRescanCampaigns = false

                    // Restricted (ACL) campaigns — e.g. esports drops — often have approved
                    // channels that aren't surfaced by the public directory and can go live for
                    // short windows. Re-probe them on a short interval so we don't lose up to a
                    // full campaignCheckInterval before noticing one came online.
                    let restrictedWaitCandidates = candidates.filter { $0.hasKnownChannelRestrictions }
                    let tickNs: UInt64 = 10 * 1_000_000_000
                    let ticks = Int(campaignCheckInterval / tickNs)
                    let aclProbeEveryTicks = 6 // ~60s
                    for tick in 0..<ticks {
                        if shouldRescanCampaigns { break }
                        try await Task.sleep(nanoseconds: tickNs)
                        if !restrictedWaitCandidates.isEmpty,
                           (tick + 1) % aclProbeEveryTicks == 0,
                           await anyApprovedChannelLive(in: restrictedWaitCandidates) {
                            log("An approved channel for a restricted campaign just went live — re-checking immediately.")
                            break
                        }
                    }
                    shouldRescanCampaigns = false
                    continue
                }

                // Channel confirmed — commit campaign as active target
                session?.currentCampaignId = campaign.id
                log("Selected channel: \(channel.displayName)")
                session?.currentChannelId = channel.id
                shouldSwitchChannel = false

                // 5. Start PubSub watching for this user+channel
                if let userId = currentAccount?.id {
                    await startDropEventsWatching(userId: userId, channelId: channel.id)
                }

                do {
                    // 6. Start watching
                    extraMinutesWatched = 0
                    lastProgressUpdateAt = Date()
                    perfStartedAt = Date()
                    _ = try await watchSessionManager.startWatching(
                        channel: channel,
                        campaignId: campaign.id,
                        gameName: campaign.game.name,
                        gameId: campaign.game.id
                    )
                    perfWatchStartupSeconds += Date().timeIntervalSince(perfStartedAt)
                    onStatusChange?(.watching)
                    await finishPerformanceCycle(outcome: "watching", campaign: campaign, channel: channel)
                } catch {
                    perfWatchStartupSeconds += Date().timeIntervalSince(perfStartedAt)
                    await finishPerformanceCycle(outcome: "watch-start-failed", campaign: campaign, channel: channel)
                    await cleanupActiveWatchSession(clearTarget: true)
                    throw error
                }

                // Wait for watch session while periodically checking progress.
                // The loop wakes every `watchLoopTickInterval` (10s) and runs each
                // check on its own cadence via the timestamps below.
                var lastGqlPoll = Date()
                var lastCampaignReevaluation = Date()
                var lastOverrideLiveCheck = Date()
                var lastClaimCheck = Date()
                var emptyCurrentDropPolls = 0
                let claimCheckSeconds = Double(claimCheckInterval) / 1_000_000_000
                while await watchSessionManager.isWatching && !shouldSwitchChannel {
                    try? await Task.sleep(nanoseconds: watchLoopTickInterval)
                    if shouldSwitchChannel { break }

                    if let overrideLogin = streamOverrideLogin,
                       Date().timeIntervalSince(lastOverrideLiveCheck) >= 60 {
                        lastOverrideLiveCheck = Date()
                        do {
                            if try await apiClient.fetchBroadcastId(channelLogin: overrideLogin) == nil {
                                log("Stream override @\(overrideLogin) went offline. Clearing override and resuming normal mining.")
                                clearStreamOverrideAfterOffline()
                                lastSwitchReason = .channelWentOffline
                                lastSwitchAt = Date()
                                shouldSwitchChannel = true
                                break
                            } else if streamOverrideWatchOnly {
                                // Watching with no mineable drop — re-check whether an eligible
                                // campaign has since gone live on this channel so we can upgrade
                                // from watch-only to actually mining a drop.
                                let activeCampaignIds = (try? await apiClient.fetchAvailableDrops(channelId: channel.id)) ?? []
                                if candidates.contains(where: { activeCampaignIds.contains($0.id) }) {
                                    log("Stream override @\(overrideLogin) now has a mineable drop — switching to mine it.")
                                    shouldSwitchChannel = true
                                    break
                                }
                            }
                        } catch {
                            log("Could not verify stream override live state for @\(overrideLogin): \(error.localizedDescription)")
                        }
                    }

                    // TDM PARITY: GQL Fallback Poll
                    // If it's been >60s since last PubSub/Poll and we haven't hit 100%.
                    // Skipped for a watch-only override session — there is no drop to track.
                    if !streamOverrideWatchOnly,
                       Date().timeIntervalSince(lastGqlPoll) >= 60 {
                        lastGqlPoll = Date()
                        do {
                            if let current = try await apiClient.fetchCurrentDrop(channelId: channel.id) {
                                emptyCurrentDropPolls = 0
                                onOperationalEvent?(.successfulPoll)
                                let campaignId = session?.currentCampaignId
                                let observation = DropProgressObservation(
                                    campaignId: campaignId,
                                    dropId: current.dropId,
                                    dropLabel: dropLabel(for: current.dropId, campaignId: campaignId),
                                    currentMinutes: current.currentMinutes,
                                    requiredMinutes: requiredMinutes(for: current.dropId, campaignId: campaignId),
                                    source: .gqlPoll
                                )
                                let result = progressEventTracker.observe(observation)
                                traceGQL(
                                    "DropCurrentSessionContext drop=\(current.dropId) parsedCurrent=\(current.currentMinutes) " +
                                    "previous=\(result.previousMinutes.map(String.init) ?? "nil") transition=\(result.transition.traceDescription)"
                                )

                                if result.shouldAcknowledgeServerProgress {
                                    if let message = formatProgressTransition(result.transition) {
                                        log(message)
                                    }

                                    // Only treat changed server state as verified progress.
                                    extraMinutesWatched = 0
                                    lastProgressUpdateAt = Date()
                                    noteCampaignProgress(campaignId)

                                    await refreshCampaignProgress(
                                        campaignId: campaignId,
                                        context: "current-session progress"
                                    )
                                }
                            } else {
                                let inventoryService = await dropsService.getInventoryService()
                                let snapshot = try await inventoryService.fetchInventory(forceRefresh: true)
                                onOperationalEvent?(.successfulPoll)
                                onOperationalEvent?(.inventoryRefresh)
                                let acknowledged = await acknowledgeInventoryProgress(
                                    snapshot,
                                    campaignId: campaign.id,
                                    context: "current-session fallback"
                                )

                                if acknowledged {
                                    emptyCurrentDropPolls = 0
                                } else {
                                    emptyCurrentDropPolls += 1
                                    if emptyCurrentDropPolls == 1 {
                                        log("Awaiting Twitch drop progress confirmation for \(campaign.name) on \(channel.displayName)")
                                    } else if emptyCurrentDropPolls % 5 == 0 {
                                        log("Warning: Twitch still has not reported an active drop session after \(emptyCurrentDropPolls) progress checks")
                                    }
                                }
                            }
                        } catch {
                            emptyCurrentDropPolls += 1
                            emitIssue(error)
                            log("Could not verify current drop progress: \(error.localizedDescription)")
                        }
                    }

                    // Stuck detection (matches TDM logic)
                    // We calculate minutes elapsed since last verified progress (GQL/PubSub)
                    let elapsed = Date().timeIntervalSince(lastProgressUpdateAt)
                    extraMinutesWatched = Int(elapsed / 60)

                    // While a stream override is active we deliberately stay on the chosen
                    // streamer until they go offline, so progress stalls must not switch channels.
                    if streamOverrideLogin == nil, extraMinutesWatched >= Self.maxExtraMinutes {
                        log("Progress stalled for \(extraMinutesWatched) mins. Refreshing inventory to check for external claims...")
                        
                        // ENHANCEMENT: Force inventory refresh before switching channels
                        // This catches drops claimed on other devices or via Twitch UI
                        do {
                            // Force fresh inventory snapshot fetch (includes benefitIDs)
                            let inventoryService = await dropsService.getInventoryService()
                            let freshInventory = try await inventoryService.fetchInventory(forceRefresh: true)
                            onOperationalEvent?(.successfulPoll)
                            onOperationalEvent?(.inventoryRefresh)
                            
                            log("Inventory refreshed: \(freshInventory.benefitIDs.count) claimed benefits, \(freshInventory.progress.count) in-progress drops")
                            
                            // Check if ANY drop in current campaign was recently claimed
                            // This handles the case where user claimed via Twitch UI or another device
                            let campaignDrops = allCampaigns.first { $0.id == session?.currentCampaignId }?.drops ?? []
                            let newlyClaimedDrops = campaignDrops.filter { drop in
                                freshInventory.benefitIDs.contains(drop.benefitID) && !drop.isClaimed
                            }
                            
                            if !newlyClaimedDrops.isEmpty {
                                log("\(newlyClaimedDrops.count) drop(s) were claimed externally. Updating local state, resetting stall counter.")
                                extraMinutesWatched = 0 // Reset stall counter
                                lastProgressUpdateAt = Date()
                                noteCampaignProgress(campaign.id)
                                // Don't switch channel - continue mining remaining drops in campaign
                            } else {
                                // Genuine stall for this campaign this window — record it so a
                                // campaign that can never earn (nothing left, unlinked, or a
                                // Twitch-side crediting outage) is eventually skipped instead of
                                // being re-selected forever.
                                let stall = Self.registerGenuineStall(
                                    consecutiveStalls: consecutiveStallsByCampaign[campaign.id, default: 0]
                                )
                                consecutiveStallsByCampaign[campaign.id] = stall.updatedCount
                                lastSwitchReason = .stallDetected(minutes: extraMinutesWatched)
                                lastSwitchAt = Date()

                                if let failoverChannel = await selectFailoverChannel(for: campaign, currentChannel: channel) {
                                    log("Progress genuinely stalled. Switching to failover streamer @\(failoverChannel.login) for \(campaign.gameName).")
                                    pendingFailoverTarget = PendingFailoverTarget(
                                        campaignId: campaign.id,
                                        streamerLogin: failoverChannel.login
                                    )
                                    shouldSwitchChannel = true
                                } else if stall.reachedThreshold {
                                    // No better channel and it keeps not earning: cool the
                                    // campaign down so candidateCampaigns skips it, letting the
                                    // miner pick other work or go idle instead of looping here.
                                    let minutes = Int(Self.nonEarningCooldownInterval / 60)
                                    campaignStallCooldownUntil[campaign.id] = Date().addingTimeInterval(Self.nonEarningCooldownInterval)
                                    consecutiveStallsByCampaign[campaign.id] = 0
                                    session?.currentCampaignId = nil
                                    log("Campaign \"\(campaign.name)\" stalled \(Self.nonEarningStallThreshold)× with no progress and no external claims; skipping it for \(minutes)m and looking for other work.")
                                    shouldSwitchChannel = true
                                } else {
                                    log("Progress genuinely stalled (no external claims detected). Switching channel.")
                                    shouldSwitchChannel = true
                                }
                            }
                        } catch {
                            emitIssue(error)
                            log("Warning: Inventory refresh failed: \(error.localizedDescription). Switching channel as fallback.")
                            shouldSwitchChannel = true
                        }
                    }

                    // Periodic campaign re-evaluation: detect if a better campaign becomes available
                    // mid-session (e.g. a priority campaign goes live after we started watching).
                    let campaignReevalInterval: TimeInterval = 300 // Align with outer campaign loop (5 min)
                    if streamOverrideLogin == nil,
                       Date().timeIntervalSince(lastCampaignReevaluation) >= campaignReevalInterval {
                        lastCampaignReevaluation = Date()
                        if let fetched = try? await dropsService.fetchCampaigns() {
                            onOperationalEvent?(.successfulPoll)
                            onOperationalEvent?(.campaignRefresh)
                            self.allCampaigns = fetched

                            // If the current campaign no longer exists in the API response,
                            // clear it from session state and rescan immediately.
                            if !fetched.contains(where: { $0.id == campaign.id }) {
                                log("Warning: Campaign '\(campaign.name)' no longer returned by API — clearing and rescanning.")
                                session?.currentCampaignId = nil
                                shouldSwitchChannel = true
                            } else if let bestCampaign = candidateCampaigns(
                                from: fetched,
                                priorityGames: priorityGames,
                                excludedGames: excludedGames,
                                strategy: miningStrategy
                            ).first, bestCampaign.id != campaign.id {
                                // Only abandon a working session for a higher-ranked campaign we
                                // can actually mine right now. Verify reachability with a targeted
                                // probe rather than trusting the end-date ranking:
                                //  - A campaign that ranks higher only by end date but has no live
                                //    channel must not preempt us (this was the 5-minute thrash).
                                //  - A restricted esports campaign (e.g. OWCS on ow_esports) is
                                //    only mineable during its scarce live windows, so when a match
                                //    goes live mid-session we DO want to grab it — even though the
                                //    stream we're on (e.g. Reign of Talon) is broadly available.
                                let sameGameCampaigns = Self.sameGameCampaigns(matching: bestCampaign, in: fetched)
                                if await selectBestChannel(
                                    forGameCandidates: [bestCampaign],
                                    knownSameGameCampaigns: sameGameCampaigns
                                ) != nil {
                                    let remainingOnActiveDrop = progressEventTracker
                                        .remainingMinutesToNextClaim(campaignId: campaign.id)
                                    if Self.shouldDeferPreemption(
                                        remainingMinutesOnActiveDrop: remainingOnActiveDrop,
                                        preemptorEndDate: bestCampaign.endDate
                                    ) {
                                        log("Higher-ranked campaign \(bestCampaign.name) (\(bestCampaign.gameName)) is live, but the current drop is \(remainingOnActiveDrop ?? 0) minute(s) from completing — finishing it before switching.")
                                    } else {
                                        log("Higher-ranked campaign \(bestCampaign.name) (\(bestCampaign.gameName)) is live now. Switching from \(campaign.name).")
                                        shouldSwitchChannel = true
                                    }
                                } else {
                                    log("Higher-ranked campaign \(bestCampaign.name) (\(bestCampaign.gameName)) has no live channel right now; staying on \(campaign.name).")
                                }
                            }
                        }
                    }

                    // Conditional claim polling: every ~2 minutes while actively
                    // mining. If claiming or inventory sync removes the current
                    // campaign from the mineable set, rescan now.
                    if Date().timeIntervalSince(lastClaimCheck) >= claimCheckSeconds {
                        lastClaimCheck = Date()
                        _ = await claimReadyDrops()
                        if streamOverrideLogin == nil, let currentCampaignId = session?.currentCampaignId {
                            let currentStillMineable = candidateCampaigns(
                                from: allCampaigns,
                                priorityGames: priorityGames,
                                excludedGames: excludedGames,
                                strategy: miningStrategy
                            ).contains { $0.id == currentCampaignId }

                            if !currentStillMineable {
                                log("Current campaign is no longer mineable after claim sync. Switching target.")
                                shouldSwitchChannel = true
                            }
                        }
                    }
                }

                // Update session stats
                let watchTime = await watchSessionManager.totalWatchTime
                session?.totalWatchTime += watchTime
                await cleanupActiveWatchSession(clearTarget: shouldSwitchChannel)

            } catch let error as TwitchMinerError {
                await cleanupActiveWatchSession(clearTarget: true)
                emitIssue(error)
                handleError(error)
                try? await Task.sleep(nanoseconds: campaignCheckInterval)
            } catch {
                await cleanupActiveWatchSession(clearTarget: true)
                emitIssue(error)
                handleError(.unknown(error.localizedDescription))
                try? await Task.sleep(nanoseconds: campaignCheckInterval)
            }
        }
    }
    
    private func claimReadyDrops() async -> Bool {
        // Always ask inventory for claimable drops. Twitch can expose a ready claim there
        // after the campaign disappears from dashboard data or local campaign state.
        var didClaimAnyDrop = false
        do {
            let inventoryService = await dropsService.getInventoryService()
            let snapshot = try await inventoryService.fetchInventory(forceRefresh: true)
            onOperationalEvent?(.successfulPoll)
            onOperationalEvent?(.inventoryRefresh)
            syncCampaigns(with: snapshot)

            let claimedDropIds = Set(
                allCampaigns
                    .flatMap(\.drops)
                    .filter(\.isClaimed)
                    .map(\.id)
            )
            let claimable = snapshot.progress.filter {
                $0.isComplete
                    && !$0.isClaimed
                    && !claimedDropIds.contains($0.dropId)
                    && !isLikelyInternalTestProgress($0)
            }
            let skippedInternalTestDrops = snapshot.progress.filter {
                $0.isComplete
                    && !$0.isClaimed
                    && !claimedDropIds.contains($0.dropId)
                    && isLikelyInternalTestProgress($0)
            }.count

            if claimable.isEmpty {
                log("No claimable drops found in inventory")
            } else {
                log("Found \(claimable.count) claimable drop(s): \(claimable.map { $0.dropName }.joined(separator: ", "))")
            }
            if skippedInternalTestDrops > 0 {
                log("Skipped \(skippedInternalTestDrops) internal/test claimable drop(s)")
            }

            for progress in claimable {
                let result = await claimService.claimDrop(progress)
                if result.success {
                    log("Claimed drop: \(result.dropName)")

                    // TDM PARITY: Delete notification after successful claim
                    try? await apiClient.deleteNotification(id: progress.id)

                    let drop = Drop(
                        id: progress.dropId,
                        name: progress.dropName,
                        requiredMinutes: progress.requiredMinutes
                    )
                    _ = progressEventTracker.markClaimed(
                        campaignId: progress.campaignId,
                        dropId: progress.dropId,
                        dropLabel: progress.dropName.isEmpty ? dropLabel(for: progress.dropId, campaignId: progress.campaignId) : progress.dropName
                    )
                    onDropClaimed?(drop)
                    session?.dropsClaimed += 1
                    didClaimAnyDrop = true

                    // Send local notification if enabled
                    if showClaimNotifications, let notificationService = notificationService {
                        await notificationService.notifyDropClaimed(
                            campaignName: result.campaignName,
                            dropName: result.dropName
                        )
                    }
                } else {
                    let reason = result.error.map { " (\($0))" } ?? ""
                    log("Warning: Drop claim returned not-success for \(progress.dropName)\(reason)")
                }

                // Small delay between claims
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }

            if didClaimAnyDrop {
                let refreshedSnapshot = try await inventoryService.fetchInventory(forceRefresh: true)
                onOperationalEvent?(.successfulPoll)
                onOperationalEvent?(.inventoryRefresh)
                syncCampaigns(with: refreshedSnapshot)
            }
        } catch {
            log("Error fetching claimable drops: \(error.localizedDescription)")
        }

        return didClaimAnyDrop
    }

    private func isLikelyInternalTestProgress(_ progress: Progress) -> Bool {
        if progress.isLikelyInternalTestProgress {
            return true
        }

        guard let campaign = allCampaigns.first(where: { $0.id == progress.campaignId }) else {
            return false
        }

        if campaign.isLikelyInternalTestCampaign {
            return true
        }

        return campaign.drops.first(where: { $0.id == progress.dropId })?.isLikelyInternalTestDrop ?? false
    }

    private func isLikelyInternalTestDropEvent(dropId: String, campaignId: String?) -> Bool {
        guard let campaignId,
              let campaign = allCampaigns.first(where: { $0.id == campaignId }) else {
            return false
        }

        if campaign.isLikelyInternalTestCampaign {
            return true
        }

        return campaign.drops.first(where: { $0.id == dropId })?.isLikelyInternalTestDrop ?? false
    }

    private func syncCampaigns(with snapshot: InventorySnapshot) {
        let mergedCampaigns = DropsService.mergeInventory(snapshot, into: allCampaigns)
        guard mergedCampaigns != allCampaigns else { return }

        allCampaigns = mergedCampaigns
        let updatedCandidates = candidateCampaigns(
            from: mergedCampaigns,
            priorityGames: priorityGames,
            excludedGames: excludedGames,
            strategy: miningStrategy
        )
        onCampaignUpdate?(updatedCandidates)
    }

    private func warnForUnlinkedPriorityCampaigns(in campaigns: [Campaign]) async {
        let isGlobalIgnore = ignoredAccountLinkWarningGames.contains("all")
        
        let priorityGamesLower = Set(priorityGames.map { $0.lowercased() })
        guard !priorityGamesLower.isEmpty else {
            warnedUnlinkedPriorityGames.removeAll()
            return
        }

        let blockedCampaigns = campaigns.filter { campaign in
            // Filter only to priority games that aren't linked and have active, uncollected drops
            campaign.isTimeActive
                && !campaign.isLikelyInternalTestCampaign
                && !campaign.isAccountConnected
                && priorityGamesLower.contains(campaign.gameName.lowercased())
                && campaign.drops.contains(where: { !$0.isClaimed })
        }

        let blockedGamesNow = Set(blockedCampaigns.map { $0.gameName.lowercased() })
        warnedUnlinkedPriorityGames.formIntersection(blockedGamesNow)

        let blockedByGame = Dictionary(grouping: blockedCampaigns, by: { $0.gameName.lowercased() })
        
        // Filter out games that are explicitly suppressed for this miner
        let suppressibleGames = blockedByGame.keys.filter { gameName in
            if isGlobalIgnore { return true }
            // Check by name or potentially ID (though ignoredAccountLinkWarningGames currently uses lowercased names usually)
            return ignoredAccountLinkWarningGames.contains(gameName) ||
                   ignoredAccountLinkWarningGames.contains(blockedByGame[gameName]?.first?.game.id ?? "")
        }
        
        let newBlockedGames = blockedByGame.keys
            .filter { !warnedUnlinkedPriorityGames.contains($0) }
            .filter { !suppressibleGames.contains($0) }
            .sorted()

        for key in newBlockedGames {
            guard let campaignsForGame = blockedByGame[key], let sample = campaignsForGame.first else {
                continue
            }

            warnedUnlinkedPriorityGames.insert(key)

            let campaignSummary = campaignsForGame
                .map(\.name)
                .prefix(2)
                .joined(separator: ", ")
            let suffix = campaignsForGame.count > 2 ? ", and more" : ""

            log("Priority game may need linking: \(sample.gameName) is prioritised. SwiftMiner will still try to mine it if Twitch allows progress, but link the game account if rewards do not appear in-game. Active campaign(s): \(campaignSummary)\(suffix).")

            if notificationService == nil {
                notificationService = NotificationService()
            }
            if let notificationService {
                await notificationService.configure(enabled: true)
                await notificationService.notifyAccountLinkRequired(
                    gameName: sample.gameName
                )
            }

            onLinkWarning?(sample.gameName)
        }
    }

    /// Detects campaigns with subscription-required drops and logs warnings.
    /// These drops are filtered from eligibleDrops, so they won't cause endless retry loops,
    /// but we want to inform the user why some drops are unavailable.
    private func warnForSubscriptionRequiredCampaigns(in campaigns: [Campaign]) async {
        let subscriptionCampaigns = campaigns.filter { campaign in
            campaign.isTimeActive
                && !campaign.isLikelyInternalTestCampaign
                && campaign.subscriptionRequiredDrops.contains(where: { !$0.isClaimed })
        }

        guard !subscriptionCampaigns.isEmpty else { return }

        let now = Date()
        for campaign in subscriptionCampaigns {
            let drops = campaign.subscriptionRequiredDrops.filter { !$0.isClaimed }
            let key = ([campaign.id] + drops.map(\.id).sorted()).joined(separator: "|")
            if let lastWarnedAt = subscriptionWarningKeys[key],
               now.timeIntervalSince(lastWarnedAt) < Self.subscriptionWarningRepeatInterval {
                continue
            }
            subscriptionWarningKeys[key] = now
            let dropNames = drops.map(\.name).joined(separator: ", ")
            log("Subscription required: \(campaign.name) has drops that require purchasing Twitch subscriptions: \(dropNames). These drops are being skipped.")
        }
    }

    private static func campaignRefreshSummary(totalCampaigns: Int, candidates: [Campaign]) -> String {
        var statusCounts: [MiningCampaignStatus: Int] = [:]
        for candidate in candidates {
            statusCounts[candidate.miningStatus, default: 0] += 1
        }

        let statusSummary = [
            MiningCampaignStatus.available,
            .inProgress,
            .claimable,
            .claimed,
            .expired
        ].compactMap { status -> String? in
            guard let count = statusCounts[status], count > 0 else { return nil }
            return "\(status.rawValue)=\(count)"
        }.joined(separator: ", ")

        let suffix = statusSummary.isEmpty ? "" : " (\(statusSummary))"
        return "Campaigns: \(totalCampaigns) total, \(candidates.count) account-eligible\(suffix)"
    }

    private static func performanceCycleSummary(_ timing: PerformanceDiagnostics.MiningCycleTiming) -> String {
        var parts = [
            "[Perf] cycle \(timing.outcome):",
            "total=\(formatPerfDuration(timing.totalSeconds))",
            "campaigns=\(formatPerfDuration(timing.campaignFetchSeconds))",
            "claims=\(formatPerfDuration(timing.claimCheckSeconds))",
            "channels=\(formatPerfDuration(timing.channelSelectionSeconds))",
            "watchStart=\(formatPerfDuration(timing.watchStartupSeconds))",
            "candidates=\(timing.candidateCount)"
        ]
        if let campaign = timing.selectedCampaign, !campaign.isEmpty {
            parts.append("campaign=\"\(campaign)\"")
        }
        if let channel = timing.selectedChannel, !channel.isEmpty {
            parts.append("channel=\"\(channel)\"")
        }
        return parts.joined(separator: " ")
    }

    private static func formatPerfDuration(_ seconds: TimeInterval) -> String {
        let bounded = max(0, seconds)
        if bounded < 1 {
            return "\(Int((bounded * 1_000).rounded()))ms"
        }
        return String(format: "%.2fs", bounded)
    }

    private func handleError(_ error: TwitchMinerError) {
        log("Error: \(error.localizedDescription)")
        let isFatal = Self.shouldReportFatalError(error)
        if isFatal {
            onError?(error)
            session?.status = .error
        }

        // Don't stop for recoverable errors
        switch error {
        case .networkError, .rateLimited:
            log("Will retry...")
        default:
            break
        }
    }

    func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        onLogMessage?("[\(timestamp)] \(message)")
    }

    func dropLabel(for dropId: String, campaignId: String?) -> String {
        findDrop(dropId: dropId, campaignId: campaignId)?.name ?? dropId
    }

    private func requiredMinutes(for dropId: String, campaignId: String?) -> Int? {
        findDrop(dropId: dropId, campaignId: campaignId)?.requiredMinutes
    }

    // MARK: - UI Helper APIs
    
    /// Get current stall state for UI display.
    public func getStallState() async -> StallState {
        let elapsed = Date().timeIntervalSince(lastProgressUpdateAt)
        let minutes = Int(elapsed / 60)
        // An active override intentionally stays put, so a lack of drop progress is not a stall.
        let isStalled = streamOverrideLogin == nil && minutes >= Self.maxExtraMinutes
        
        // Determine recovery action based on current state
        let recoveryAction: MinerManager.StallRecoveryAction?
        if isStalled && shouldSwitchChannel {
            recoveryAction = .switchingChannel
        } else if isStalled {
            recoveryAction = .refreshingInventory
        } else {
            recoveryAction = nil
        }
        
        return StallState(
            minutesSinceLastProgress: minutes,
            isStalled: isStalled,
            recoveryAction: recoveryAction,
            lastSwitchReason: lastSwitchReason,
            lastSwitchAt: lastSwitchAt,
            currentChannelName: currentChannelName,
            currentChannelId: currentChannelId
        )
    }
    
    /// Get recent activity events for UI display (last N events).
    public func getRecentActivityEvents(limit: Int) async -> [MinerManager.MinerEvent] {
        // Return recent log messages parsed into structured events
        // For now, return empty array - full implementation would buffer structured events
        return []
    }
    
    // MARK: - Stall Tracking
    
    public struct StallState: Sendable {
        public let minutesSinceLastProgress: Int
        public let isStalled: Bool
        public let recoveryAction: MinerManager.StallRecoveryAction?
        public let lastSwitchReason: MinerManager.SwitchReason?
        public let lastSwitchAt: Date?
        public let currentChannelName: String?
        public let currentChannelId: String?
    }
    
    private var lastSwitchReason: MinerManager.SwitchReason?
    private var lastSwitchAt: Date?
    var currentChannelName: String?
    var currentChannelId: String?
}

// MARK: - Supporting Types

public struct DeviceAuthInfo: Sendable {
    public let userCode: String
    public let verificationURL: URL
    public let expiresIn: Int
    
    public var displayMessage: String {
        """
        Please visit: \(verificationURL.absoluteString)
        Enter code: \(userCode)
        Code expires in \(expiresIn / 60) minutes
        """
    }
}
