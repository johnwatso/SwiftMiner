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
    private var apiClient: TwitchAPIClient
    private var dropsService: DropsService
    private var watchSessionManager: WatchSessionManager
    private var claimService: ClaimService
    private var pubSubClient: PubSubClient
    private var dropEventsService: DropEventsService
    private var notificationService: NotificationService?

    private var session: MiningSession?
    private var isRunning = false
    private var mainTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?
    private var currentAccount: Account?
    private var shouldSwitchChannel = false
    /// Set to true to interrupt the idle wait and immediately re-check for eligible campaigns
    private var shouldRescanCampaigns = false
    private var consecutiveNoCandidateCycles = 0

    /// Counter for minutes watched without a server progress update (local estimation)
    private var extraMinutesWatched: Int = 0
    /// Timestamp of the last verified progress update (GQL or PubSub)
    private var lastProgressUpdateAt: Date = Date()
    /// Maximum extra minutes allowed before assuming mining is stalled (matches TDM)
    private static let maxExtraMinutes = 15
    private static let failoverCooldown: TimeInterval = 10 * 60
    private static let subscriptionWarningRepeatInterval: TimeInterval = 6 * 60 * 60
    private static let noCandidateBackoffBaseInterval: UInt64 = 300 * 1_000_000_000
    private static let noCandidateBackoffMaxInterval: UInt64 = 15 * 60 * 1_000_000_000

    /// Cache of all campaigns fetched during the last check
    public private(set) var allCampaigns: [Campaign] = []
    private var progressEventTracker = DropProgressEventTracker()

    /// Per-game live-channel probe results recorded as a side effect of channel selection,
    /// keyed by normalized game key. Used to keep campaigns whose game currently has no live,
    /// watch-mineable channel from out-ranking ones that do. Without this, a soon-to-expire
    /// limited-time campaign with no live stream can repeatedly preempt or starve an active
    /// game (e.g. Overwatch) under the end-date-first `.mineAll` ordering.
    private var gameLiveProbes: [String: (hasLiveChannel: Bool, checkedAt: Date)] = [:]
    /// How long a "no live channel" probe result keeps a game demoted before it is re-probed.
    /// Generous enough to span more than one campaign-check cycle so demotion is stable, short
    /// enough that a game coming online is picked up on the next full rescan.
    private static let gameLiveProbeFreshness: TimeInterval = 15 * 60

    // Configuration
    private let campaignCheckInterval: UInt64 = 300 * 1_000_000_000 // 5 minutes
    private let claimCheckInterval: UInt64 = 2 * 60 * 1_000_000_000 // 2 minutes (conditional polling)

    // Mining preferences (set from AppModel/Settings)
    private var priorityGames: [String] = []
    private var excludedGames: [String] = []
    private var enableBadgesEmotes: Bool = false
    private var showClaimNotifications: Bool = false
    private var ignoredAccountLinkWarningGames: Set<String> = []
    private var warnedUnlinkedPriorityGames: Set<String> = []
    private var subscriptionWarningKeys: [String: Date] = [:]
    private var failoverStreamers: [GameFailoverStreamer] = []
    private var failoverCooldowns: [String: Date] = [:]
    private var pendingFailoverTarget: PendingFailoverTarget?
    private var avoidDuplicateStreams: Bool = false
    private var prioritiseFollowedStreamers: Bool = false
    private var streamOverrideLogin: String?
    /// True while watching the override streamer even though none of this miner's eligible
    /// drop campaigns are active on their channel (pure "watch them anyway" session).
    private var streamOverrideWatchOnly: Bool = false
    private var channelAssignmentAvoidanceProvider: (@Sendable (_ campaignId: String, _ viableChannelCount: Int) async -> Set<String>)?
    /// Debug-only: when true, accepts any time-active campaign and picks any live channel
    /// without requiring account linkage or GQL drop verification. Exercises the watch
    /// pipeline for testing; drops won't credit for unlinked accounts.
    private var debugBypassLinkRequirement: Bool = false

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

    private var miningStrategy: MiningStrategy = .mineAll
    
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

    private func emitIssue(_ error: Error) {
        let (category, detail) = Self.classifyIssue(error)
        onOperationalEvent?(.issueDetected(category: category, detail: detail))
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
                    let restrictedWaitCandidates = candidates.filter { $0.hasChannelRestrictions }
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
                    do {
                        try await dropEventsService.startWatching(
                            userId: userId,
                            channelId: channel.id
                        )
                        log("PubSub watching started for user:\(userId) channel:\(channel.id)")
                    } catch {
                        log("Failed to start PubSub watching: \(error.localizedDescription)")
                    }
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

                // Wait for watch session while periodically checking progress
                var lastGqlPoll = Date()
                var lastCampaignReevaluation = Date()
                var lastOverrideLiveCheck = Date()
                var emptyCurrentDropPolls = 0
                while await watchSessionManager.isWatching && !shouldSwitchChannel {
                    // Check every 30 seconds for interrupts or polls
                    try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)

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
                                // Don't switch channel - continue mining remaining drops in campaign
                            } else if let failoverChannel = await selectFailoverChannel(for: campaign, currentChannel: channel) {
                                log("Progress genuinely stalled. Switching to failover streamer @\(failoverChannel.login) for \(campaign.gameName).")
                                pendingFailoverTarget = PendingFailoverTarget(
                                    campaignId: campaign.id,
                                    streamerLogin: failoverChannel.login
                                )
                                lastSwitchReason = .stallDetected(minutes: extraMinutesWatched)
                                lastSwitchAt = Date()
                                shouldSwitchChannel = true
                            } else {
                                log("Progress genuinely stalled (no external claims detected). Switching channel.")
                                lastSwitchReason = .stallDetected(minutes: extraMinutesWatched)
                                lastSwitchAt = Date()
                                shouldSwitchChannel = true
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
                                    log("Higher-ranked campaign \(bestCampaign.name) (\(bestCampaign.gameName)) is live now. Switching from \(campaign.name).")
                                    shouldSwitchChannel = true
                                } else {
                                    log("Higher-ranked campaign \(bestCampaign.name) (\(bestCampaign.gameName)) has no live channel right now; staying on \(campaign.name).")
                                }
                            }
                        }
                    }

                    // Check if we should claim any drops. If claiming or inventory sync
                    // removes the current campaign from the mineable set, rescan now.
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
                    
                    // Conditional claim polling: Check every 2 minutes when actively mining
                    // This reduces claim latency without adding background churn when idle
                    let ticksPerClaimCheck = Int(claimCheckInterval / 10_000_000_000) // 10s ticks
                    for _ in 0..<ticksPerClaimCheck {
                        if shouldSwitchChannel { break }
                        try? await Task.sleep(nanoseconds: 10_000_000_000)
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

    private func candidateCampaigns(
        from campaigns: [Campaign],
        priorityGames: [String],
        excludedGames: [String],
        strategy: MiningStrategy
    ) -> [Campaign] {
        let priorityKeys = priorityGames.map { normalizedGameKey($0) }.filter { !$0.isEmpty }
        let prioritySet = Set(priorityKeys)
        let excludedSet = Set(excludedGames.map { normalizedGameKey($0) }.filter { !$0.isEmpty })
        var filteredOutReasons: [String: Int] = [:]

        let eligible = campaigns.filter { campaign in
            let gameName = normalizedGameKey(campaign.gameName)
            let gameId = normalizedGameKey(campaign.game.id)

            // 1. Core Eligibility
            // Mine if Twitch exposes usable drops. Missing game-account linkage
            // remains a user warning, but it should not stop a prioritised game
            // from being attempted if Twitch will still track inventory progress.
            guard campaign.isTimeActive && campaign.status != .disabled else {
                filteredOutReasons["inactive", default: 0] += 1
                return false
            }

            guard !campaign.isLikelyInternalTestCampaign else {
                filteredOutReasons["internal_test", default: 0] += 1
                return false
            }

            guard campaign.canAttemptMining else {
                if !campaign.subscriptionRequiredDrops.isEmpty && campaign.eligibleDrops.isEmpty {
                    filteredOutReasons["subscription_required", default: 0] += 1
                } else {
                    filteredOutReasons["no_eligible_drops", default: 0] += 1
                }
                return false
            }

            // Nothing left to EARN by watching: every remaining unclaimed drop is
            // already fully earned (claimable). Such a campaign must not pin the
            // miner in "Waiting for an eligible live stream" — there is no progress
            // to make. This is common for unlinked accounts, whose earned drops
            // can't be claimed through and otherwise stay claimable forever.
            // The claim step (claimReadyDrops) handles delivering these drops
            // independently of this stream-watching candidate set.
            guard !campaign.earnableDrops.isEmpty else {
                filteredOutReasons["no_earnable_drops", default: 0] += 1
                return false
            }

            // Linkage gate: a campaign whose game account is not linked may only
            // be attempted when its game is prioritised for THIS miner. Otherwise an
            // unlinked, non-prioritised campaign would leak into mining (e.g. another
            // miner's prioritised game appearing here). Linked campaigns are unaffected.
            if !campaign.isAccountConnected
                && !prioritySet.contains(gameName)
                && !prioritySet.contains(gameId) {
                filteredOutReasons["unlinked_not_prioritised", default: 0] += 1
                return false
            }

            // 2. User Preferences
            if excludedSet.contains(gameName) || excludedSet.contains(gameId) {
                filteredOutReasons["excluded_game", default: 0] += 1
                return false
            }

            if strategy == .onlyPriority && !prioritySet.contains(gameName) && !prioritySet.contains(gameId) {
                filteredOutReasons["not_prioritised", default: 0] += 1
                return false
            }

            if !enableBadgesEmotes && campaign.hasOnlyBadgesOrEmotes {
                filteredOutReasons["badge_emote_only", default: 0] += 1
                return false
            }

            // Final safety check on mining status
            let status = campaign.miningStatus
            guard status == .available || status == .inProgress || status == .claimable else {
                filteredOutReasons["status_\(status.rawValue)", default: 0] += 1
                return false
            }

            return true
        }

        let sorted = sortedCandidates(eligible, priorityKeys: priorityKeys, strategy: strategy)
        let filterSummary = filteredOutReasons
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
        let bestSummary = sorted.first
            .map { ", best=\($0.name) (\($0.gameName), \($0.miningStatus.rawValue))" }
            ?? ""
        let filterSuffix = filterSummary.isEmpty ? "" : ", filtered=[\(filterSummary)]"
        log("[CampaignSelect] \(strategy.displayName): \(campaigns.count) total, \(sorted.count) eligible, excludedGames=\(excludedGames.count), priorityGames=\(priorityGames.count), badgeEmotes=\(enableBadgesEmotes)\(filterSuffix)\(bestSummary)")
        return sorted
    }

    /// Resolves the appropriate session status when no candidate campaigns remain after
    /// filtering. Missing game-account linkage is only presented as blocked when it
    /// belongs to a game this miner has explicitly prioritised; unrelated public
    /// unlinked campaigns are normal "no eligible work" noise.
    internal static func resolveEmptyCandidateState(
        from campaigns: [Campaign],
        priorityGames: [String],
        excludedGames: [String],
        strategy: MiningStrategy,
        includesBadgeAndEmoteCampaigns: Bool
    ) -> SessionStatus {
        let priorityKeys = priorityGames.map { normalizedGameSelectionKey($0) }.filter { !$0.isEmpty }
        let prioritySet = Set(priorityKeys)
        let excludedSet = Set(excludedGames.map { normalizedGameSelectionKey($0) }.filter { !$0.isEmpty })

        // 1. Define the "Universe" (Active, Enabled, Preferred)
        // We only care about campaigns that the user hasn't explicitly excluded or filtered out by strategy.
        let universe = campaigns.filter { campaign in
            let gameName = normalizedGameSelectionKey(campaign.gameName)
            let gameId = normalizedGameSelectionKey(campaign.game.id)

            // Basic availability
            guard campaign.isTimeActive && campaign.status != .disabled else { return false }
            guard !campaign.isLikelyInternalTestCampaign else { return false }
            
            // User preferences
            if excludedSet.contains(gameName) || excludedSet.contains(gameId) { return false }
            if strategy == .onlyPriority && !prioritySet.contains(gameName) && !prioritySet.contains(gameId) { return false }
            if !includesBadgeAndEmoteCampaigns && campaign.hasOnlyBadgesOrEmotes { return false }
            
            return true
        }

        guard !universe.isEmpty else {
            // Nothing in the user's preferred/available universe exists to mine.
            return .idleNoEligibleCampaigns
        }

        let priorityUniverse = universe.filter { campaign in
            let gameName = normalizedGameSelectionKey(campaign.gameName)
            let gameId = normalizedGameSelectionKey(campaign.game.id)
            return prioritySet.contains(gameName) || prioritySet.contains(gameId)
        }

        let unlinkedAttemptablePriorityCampaigns = priorityUniverse.filter { campaign in
            !campaign.isAccountConnected && campaign.canAttemptMining
        }
        guard !unlinkedAttemptablePriorityCampaigns.isEmpty else {
            return .idleNoEligibleCampaigns
        }

        let hasLinkedPriorityCampaign = priorityUniverse.contains { campaign in
            campaign.isAccountConnected && campaign.canAttemptMining
        }
        return hasLinkedPriorityCampaign ? .idleNoEligibleCampaigns : .blockedAccountNotLinked
    }

    /// Record the outcome of a live-channel probe for a game so later ranking and the
    /// mid-session re-evaluation can avoid preferring games that currently have no live stream.
    private func recordGameLiveProbe(_ gameKey: String, hasLiveChannel: Bool) {
        gameLiveProbes[gameKey] = (hasLiveChannel, Date())
    }

    /// True when the game was probed recently and confirmed to have NO live, watch-mineable
    /// channel. Stale results (older than `gameLiveProbeFreshness`) are ignored so a game that
    /// has since come online is not demoted forever.
    private func isGameFreshlyKnownEmpty(_ gameKey: String) -> Bool {
        guard let probe = gameLiveProbes[gameKey] else { return false }
        guard Date().timeIntervalSince(probe.checkedAt) <= Self.gameLiveProbeFreshness else { return false }
        return !probe.hasLiveChannel
    }

    private func sortedCandidates(
        _ campaigns: [Campaign],
        priorityKeys: [String],
        strategy: MiningStrategy
    ) -> [Campaign] {
        let emptyGameKeys = Set(
            campaigns
                .map { normalizedGameKey($0.gameName) }
                .filter { isGameFreshlyKnownEmpty($0) }
        )
        return Self.rankCandidates(
            campaigns,
            priorityKeys: priorityKeys,
            strategy: strategy,
            emptyGameKeys: emptyGameKeys
        )
    }

    /// Pure ranking used by `sortedCandidates`. Campaigns whose game is freshly known to have no
    /// live channel sink below ones that do — this is the primary key so a limited-time campaign
    /// with no live stream can't out-rank (and thereby starve or thrash) an active game. End-date
    /// and priority ordering are preserved within each live/empty bucket.
    static func rankCandidates(
        _ campaigns: [Campaign],
        priorityKeys: [String],
        strategy: MiningStrategy,
        emptyGameKeys: Set<String>
    ) -> [Campaign] {
        func isEmptyGame(_ campaign: Campaign) -> Bool {
            emptyGameKeys.contains(normalizedGameSelectionKey(campaign.gameName))
        }
        return campaigns.enumerated().sorted { lhs, rhs in
            let left = lhs.element
            let right = rhs.element

            // Live games before games with no live channel, regardless of strategy.
            let leftEmpty = isEmptyGame(left)
            let rightEmpty = isEmptyGame(right)
            if leftEmpty != rightEmpty { return !leftEmpty }

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
        }.map(\.element)
    }

    internal static func sameGameVerificationCandidates(
        primaryCandidates: [Campaign],
        allCampaigns: [Campaign],
        priorityGames: [String],
        excludedGames: [String],
        strategy: MiningStrategy,
        includesBadgeAndEmoteCampaigns: Bool
    ) -> [Campaign] {
        guard let primary = primaryCandidates.first else { return [] }

        let gameKey = normalizedGameSelectionKey(primary.gameName)
        let gameId = normalizedGameSelectionKey(primary.game.id)
        let prioritySet = Set(priorityGames.map { normalizedGameSelectionKey($0) }.filter { !$0.isEmpty })
        let excludedSet = Set(excludedGames.map { normalizedGameSelectionKey($0) }.filter { !$0.isEmpty })
        let selectedGameIsPrioritised = prioritySet.contains(gameKey) || prioritySet.contains(gameId)

        var seen = Set(primaryCandidates.map(\.id))
        var expanded = primaryCandidates

        for campaign in allCampaigns {
            guard !seen.contains(campaign.id) else { continue }

            let candidateGameKey = normalizedGameSelectionKey(campaign.gameName)
            let candidateGameId = normalizedGameSelectionKey(campaign.game.id)
            guard candidateGameKey == gameKey || candidateGameId == gameId else { continue }
            guard campaign.isTimeActive && campaign.status != .disabled else { continue }
            guard !campaign.isLikelyInternalTestCampaign else { continue }
            guard campaign.canAttemptMining else { continue }
            guard campaign.miningStatus == .available || campaign.miningStatus == .inProgress || campaign.miningStatus == .claimable else { continue }

            if excludedSet.contains(candidateGameKey) || excludedSet.contains(candidateGameId) { continue }
            if strategy == .onlyPriority && !selectedGameIsPrioritised { continue }
            if !includesBadgeAndEmoteCampaigns && campaign.hasOnlyBadgesOrEmotes { continue }

            // Preserve the original leakage guard: unlinked campaigns are only attemptable when
            // this miner explicitly prioritises the game.
            if !campaign.isAccountConnected && !selectedGameIsPrioritised { continue }

            seen.insert(campaign.id)
            expanded.append(campaign)
        }

        return expanded
    }

    internal static func sameGameCampaigns(matching primary: Campaign, in allCampaigns: [Campaign]) -> [Campaign] {
        let gameKey = normalizedGameSelectionKey(primary.gameName)
        let gameId = normalizedGameSelectionKey(primary.game.id)

        return allCampaigns.filter { campaign in
            normalizedGameSelectionKey(campaign.gameName) == gameKey
                || normalizedGameSelectionKey(campaign.game.id) == gameId
        }
    }

    private static func priorityIndex(for campaign: Campaign, priorityKeys: [String]) -> Int {
        let gameName = normalizedGameSelectionKey(campaign.gameName)
        let gameId = normalizedGameSelectionKey(campaign.game.id)
        return priorityKeys.firstIndex { $0 == gameName || $0 == gameId } ?? Int.max
    }

    private func normalizedGameKey(_ value: String) -> String {
        Self.normalizedGameSelectionKey(value)
    }

    private static func normalizedGameSelectionKey(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    
    /// Select the best live channel across all same-game candidate campaigns.
    ///
    /// Each live channel's active-drops list is fetched once and matched against every
    /// candidate for the game. This pivots to whichever candidate a channel is actively
    /// running, so the miner isn't stuck when the "active" campaign on live streams is a
    /// lower-priority (but still eligible) candidate.
    private func selectBestChannel(
        forGameCandidates candidates: [Campaign],
        knownSameGameCampaigns: [Campaign] = []
    ) async -> (Campaign, Channel)? {
        guard let primary = candidates.first else { return nil }
        let gameName = primary.gameName
        log("[ChannelSelect] Game: \(gameName) — candidates: \(candidates.map(\.name).joined(separator: ", "))")

        let liveChannels: [Channel]
        do {
            var fetched = try await dropsService.findLiveChannels(forGame: primary.game)
            if fetched.isEmpty, candidates.contains(where: { $0.game.isSpecialEvents }) {
                log("[ChannelSelect]   Special Event bypass: no directory channels for '\(gameName)', using ACL list")
                fetched = candidates.flatMap(\.channels)
            }
            liveChannels = fetched
        } catch {
            log("[ChannelSelect]   Failed to fetch live channels for '\(gameName)': \(error.localizedDescription)")
            // Fallback: if any candidate has approved channels, use the first.
            for candidate in candidates {
                if let fallback = candidate.channels.first {
                    currentChannelName = fallback.displayName
                    currentChannelId = fallback.id
                    return (candidate, fallback)
                }
            }
            return nil
        }

        log("[ChannelSelect]   Found \(liveChannels.count) live candidate channel(s)")
        // Even when the public game directory returns nothing, an ACL-restricted campaign may
        // have approved channels that are live but not surfaced by the directory query (common
        // for esports/official broadcasts). Only bail early when there is no directory result
        // AND nothing to probe directly; otherwise fall through to the ACL probe below.
        guard Self.shouldContinueChannelSelection(liveChannelCount: liveChannels.count, candidates: candidates) else {
            return nil
        }

        // Debug bypass: skip GQL verification and grab the top live channel paired with a
        // random candidate. Purely for exercising the watch pipeline in testing.
        if debugBypassLinkRequirement, !liveChannels.isEmpty {
            let bestLive = liveChannels
                .sorted { ($0.viewerCount ?? 0) > ($1.viewerCount ?? 0) }
                .first!
            let resolved = await resolveChannelIdIfNeeded(bestLive)
            let randomCandidate = candidates.randomElement() ?? primary
            log("[ChannelSelect]   Debug bypass: picking \(resolved.displayName) for random candidate \(randomCandidate.name)")
            currentChannelName = resolved.displayName
            currentChannelId = resolved.id
            return (randomCandidate, resolved)
        }

        let relationshipRanks = await followedStreamerRanks(for: liveChannels)

        // Note: every channel here belongs to the same game (this function is called per game),
        // so there is no cross-game priority to break ties on — rank purely by followed-streamer
        // relationship, ACL specificity, then viewer count. Game priority is already applied by
        // the caller, which iterates games in priority order.
        let sortedChannels = liveChannels.sorted { a, b in
            let aRelationshipRank = streamerRelationshipRank(for: a, ranks: relationshipRanks)
            let bRelationshipRank = streamerRelationshipRank(for: b, ranks: relationshipRanks)
            if aRelationshipRank != bRelationshipRank { return aRelationshipRank > bRelationshipRank }
            if a.aclBased != b.aclBased { return a.aclBased && !b.aclBased }
            return (a.viewerCount ?? 0) > (b.viewerCount ?? 0)
        }
        let verificationLimit = Self.adaptiveChannelVerificationLimit(
            liveChannelCount: sortedChannels.count,
            candidateCount: candidates.count,
            hasRestrictedCampaign: candidates.contains { $0.hasChannelRestrictions },
            hasPriorityCampaign: candidates.contains {
                Self.priorityIndex(for: $0, priorityKeys: priorityGames) != Int.max
            },
            avoidDuplicateStreams: avoidDuplicateStreams
        )
        let channelsToVerify = Array(sortedChannels.prefix(verificationLimit))
        if verificationLimit < sortedChannels.count {
            log("[ChannelSelect]   Verification limited to top \(verificationLimit) of \(sortedChannels.count) live channel(s)")
        }

        // Pre-compute which candidates each channel could serve (by ACL).
        let candidateIds = Set(candidates.map(\.id))
        let subscriptionBlockedCampaigns = Dictionary(
            uniqueKeysWithValues: knownSameGameCampaigns.compactMap { campaign -> (String, Campaign)? in
                guard !candidateIds.contains(campaign.id),
                      !campaign.subscriptionRequiredDrops.isEmpty,
                      campaign.eligibleDrops.isEmpty else {
                    return nil
                }
                return (campaign.id, campaign)
            }
        )

        var anyVerificationSucceeded = false
        var fallbackPair: (Campaign, Channel)? = nil
        var verifiedMatches: [(campaign: Campaign, channel: Channel)] = []
        var liveSubscriptionBlockedCampaignIds: Set<String> = []
        var verifiedChannelCount = 0
        var noCandidateMatchCount = 0
        var aclBlockedMatchCount = 0
        var subscriptionOnlyMatchCount = 0
        var verificationErrorCount = 0
        var aclProbeCount = 0

        for ch in channelsToVerify {
            let eligibleForChannel = candidates.filter { candidate in
                !candidate.hasChannelRestrictions
                    || Self.channelMatchesCampaignACL(ch, campaign: candidate)
            }
            guard !eligibleForChannel.isEmpty else { continue }

            let channel = await resolveChannelIdIfNeeded(ch)

            do {
                let activeCampaignIds = try await apiClient.fetchAvailableDrops(channelId: channel.id)
                anyVerificationSucceeded = true
                verifiedChannelCount += 1

                // Record all matching candidates for this channel, then choose by campaign
                // priority after the directory scan. This prevents restricted side campaigns
                // from preempting a broader same-game campaign just because their channels
                // appear earlier in the live directory.
                let matches = eligibleForChannel.filter { activeCampaignIds.contains($0.id) }
                if !matches.isEmpty {
                    let names = matches.map(\.name).joined(separator: ", ")
                    log("[ChannelSelect]     Verified: \(names) active on \(channel.displayName)")
                    for match in matches {
                        let alreadyRecorded = verifiedMatches.contains {
                            $0.campaign.id == match.id &&
                                Self.normalizedChannelIdentity($0.channel.id) == Self.normalizedChannelIdentity(channel.id)
                        }
                        let campaignAlreadyRecorded = verifiedMatches.contains { $0.campaign.id == match.id }
                        if !alreadyRecorded && (avoidDuplicateStreams || !campaignAlreadyRecorded) {
                            verifiedMatches.append((campaign: match, channel: channel))
                        }
                    }
                    if !avoidDuplicateStreams,
                       let best = await bestVerifiedCampaignMatch(candidates: candidates, matches: verifiedMatches, relationshipRanks: relationshipRanks),
                       best.campaign.id == candidates.first?.id {
                        log("[ChannelSelect]   Selected \(best.campaign.name) on \(best.channel.displayName)")
                        currentChannelName = best.channel.displayName
                        currentChannelId = best.channel.id
                        return (best.campaign, best.channel)
                    }
                    continue
                }

                let activeKnown = activeCampaignIds.filter { candidateIds.contains($0) }
                if activeKnown.isEmpty {
                    let subscriptionBlocked = activeCampaignIds.compactMap { subscriptionBlockedCampaigns[$0] }
                    if subscriptionBlocked.isEmpty {
                        noCandidateMatchCount += 1
                    } else {
                        subscriptionOnlyMatchCount += 1
                        subscriptionBlocked.forEach { liveSubscriptionBlockedCampaignIds.insert($0.id) }
                    }
                } else {
                    aclBlockedMatchCount += 1
                }
            } catch {
                verificationErrorCount += 1
                log("[ChannelSelect]     Warning: Verification failed for \(channel.displayName): \(error.localizedDescription)")
                if fallbackPair == nil, let best = eligibleForChannel.first {
                    fallbackPair = (best, channel)
                }
            }
        }

        // ACL approved-channel probe: for any candidate with restrictions where the directory
        // didn't surface a matching channel, probe approved channels directly.
        for candidate in candidates where candidate.hasChannelRestrictions {
            let directoryHadMatch = sortedChannels.contains { Self.channelMatchesCampaignACL($0, campaign: candidate) }
            if directoryHadMatch { continue }
            let probed = await liveACLChannels(for: candidate)
            for ch in probed {
                let channel = await resolveChannelIdIfNeeded(ch)
                aclProbeCount += 1
                do {
                    let activeCampaignIds = try await apiClient.fetchAvailableDrops(channelId: channel.id)
                    anyVerificationSucceeded = true
                    verifiedChannelCount += 1
                    if activeCampaignIds.contains(candidate.id) {
                        log("[ChannelSelect]     Verified: \(candidate.name) active on approved channel \(channel.displayName)")
                        let alreadyRecorded = verifiedMatches.contains {
                            $0.campaign.id == candidate.id &&
                                Self.normalizedChannelIdentity($0.channel.id) == Self.normalizedChannelIdentity(channel.id)
                        }
                        let campaignAlreadyRecorded = verifiedMatches.contains { $0.campaign.id == candidate.id }
                        if !alreadyRecorded && (avoidDuplicateStreams || !campaignAlreadyRecorded) {
                            verifiedMatches.append((campaign: candidate, channel: channel))
                        }
                    }
                } catch {
                    verificationErrorCount += 1
                    log("[ChannelSelect]     Warning: Approved-channel verification failed: \(error.localizedDescription)")
                    if fallbackPair == nil { fallbackPair = (candidate, channel) }
                }
            }
        }

        let verificationSummary = [
            "checked=\(verifiedChannelCount)",
            noCandidateMatchCount > 0 ? "noMatch=\(noCandidateMatchCount)" : nil,
            aclBlockedMatchCount > 0 ? "aclBlocked=\(aclBlockedMatchCount)" : nil,
            subscriptionOnlyMatchCount > 0 ? "subscriptionOnly=\(subscriptionOnlyMatchCount)" : nil,
            aclProbeCount > 0 ? "aclProbes=\(aclProbeCount)" : nil,
            verificationErrorCount > 0 ? "errors=\(verificationErrorCount)" : nil
        ].compactMap { $0 }.joined(separator: ", ")
        if verifiedChannelCount > 0 || aclProbeCount > 0 || verificationErrorCount > 0 {
            log("[ChannelSelect]   Verification summary: \(verificationSummary)")
        }

        if let best = await bestVerifiedCampaignMatch(candidates: candidates, matches: verifiedMatches, relationshipRanks: relationshipRanks) {
            log("[ChannelSelect]   Selected \(best.campaign.name) on \(best.channel.displayName)")
            currentChannelName = best.channel.displayName
            currentChannelId = best.channel.id
            return (best.campaign, best.channel)
        }

        // Only fall back to an unverified channel when the verification itself errored for
        // every candidate. If GQL responded cleanly and just didn't match, the campaigns are
        // genuinely not active on any live stream — return nil so the miner waits.
        if !anyVerificationSucceeded, let fallback = fallbackPair {
            log("[ChannelSelect]   ! All verifications errored. Falling back to \(fallback.1.displayName) for \(fallback.0.name)")
            currentChannelName = fallback.1.displayName
            currentChannelId = fallback.1.id
            return fallback
        }

        if !liveSubscriptionBlockedCampaignIds.isEmpty {
            let names = liveSubscriptionBlockedCampaignIds
                .compactMap { subscriptionBlockedCampaigns[$0]?.name }
                .sorted()
                .joined(separator: ", ")
            log("[ChannelSelect]   Live \(gameName) channels are running subscription-required campaign(s), not watch-mineable drops: \(names)")
        }

        return nil
    }

    /// Decides whether channel selection should proceed past the directory lookup.
    ///
    /// We continue when the directory surfaced at least one live channel, OR when any candidate
    /// is ACL-restricted — restricted campaigns get their approved channels probed directly, and
    /// those channels are frequently absent from the public game directory (e.g. esports/official
    /// broadcasts). Returning `false` here means there is genuinely nothing left to try.
    internal static func shouldContinueChannelSelection(liveChannelCount: Int, candidates: [Campaign]) -> Bool {
        liveChannelCount > 0 || candidates.contains { $0.hasChannelRestrictions }
    }

    internal static func adaptiveChannelVerificationLimit(
        liveChannelCount: Int,
        candidateCount: Int,
        hasRestrictedCampaign: Bool,
        hasPriorityCampaign: Bool,
        avoidDuplicateStreams: Bool
    ) -> Int {
        guard liveChannelCount > 0 else { return 0 }

        if hasRestrictedCampaign {
            return min(liveChannelCount, 50)
        }

        if liveChannelCount <= 16 {
            return liveChannelCount
        }

        if hasPriorityCampaign || candidateCount > 1 || avoidDuplicateStreams {
            return min(liveChannelCount, 30)
        }

        return min(liveChannelCount, 16)
    }

    internal static func noCandidateBackoffInterval(for consecutiveCycles: Int) -> UInt64 {
        guard consecutiveCycles > 1 else { return noCandidateBackoffBaseInterval }
        let multiplier = UInt64(min(consecutiveCycles, 3))
        return min(noCandidateBackoffBaseInterval * multiplier, noCandidateBackoffMaxInterval)
    }

    internal static func bestVerifiedCampaignMatch(
        candidates: [Campaign],
        matches: [(campaign: Campaign, channel: Channel)]
    ) -> (campaign: Campaign, channel: Channel)? {
        for candidate in candidates {
            if let match = matches.first(where: { $0.campaign.id == candidate.id }) {
                return match
            }
        }

        return nil
    }

    private func bestVerifiedCampaignMatch(
        candidates: [Campaign],
        matches: [(campaign: Campaign, channel: Channel)],
        relationshipRanks: [String: Int]
    ) async -> (campaign: Campaign, channel: Channel)? {
        let rankedMatches = matches.sorted { left, right in
            let leftRank = streamerRelationshipRank(for: left.channel, ranks: relationshipRanks)
            let rightRank = streamerRelationshipRank(for: right.channel, ranks: relationshipRanks)
            if leftRank != rightRank { return leftRank > rightRank }
            return (left.channel.viewerCount ?? 0) > (right.channel.viewerCount ?? 0)
        }

        guard avoidDuplicateStreams, let provider = channelAssignmentAvoidanceProvider else {
            return Self.bestVerifiedCampaignMatch(candidates: candidates, matches: rankedMatches)
        }

        for candidate in candidates {
            let candidateMatches = rankedMatches.filter { $0.campaign.id == candidate.id }
            guard !candidateMatches.isEmpty else { continue }

            let uniqueChannelCount = Set(candidateMatches.map { Self.normalizedChannelIdentity($0.channel.id) }).count
            let assignedChannelIds = await provider(candidate.id, uniqueChannelCount)
            let avoided = Set(assignedChannelIds.map { Self.normalizedChannelIdentity($0) })

            if uniqueChannelCount <= 4 {
                log("[ChannelSelect]   Stream spreading bypassed for \(candidate.name): only \(uniqueChannelCount) viable channel(s)")
                return candidateMatches[0]
            }

            if let unassigned = candidateMatches.first(where: {
                !avoided.contains(Self.normalizedChannelIdentity($0.channel.id))
            }) {
                if !avoided.isEmpty {
                    log("[ChannelSelect]   Stream spreading: avoiding \(avoided.count) occupied channel(s) for \(candidate.name)")
                }
                return unassigned
            }

            log("[ChannelSelect]   Stream spreading: all \(uniqueChannelCount) viable channel(s) occupied for \(candidate.name); reusing best channel")
            return candidateMatches[0]
        }

        return nil
    }

    private func followedStreamerRanks(for channels: [Channel]) async -> [String: Int] {
        guard prioritiseFollowedStreamers, let userId = currentAccount?.id else { return [:] }
        let broadcasterIds = channels.map(\.id).filter { !$0.isEmpty }
        let relationships = await apiClient.getChannelRelationships(userId: userId, broadcasterIds: broadcasterIds)
        return relationships.reduce(into: [String: Int]()) { ranks, pair in
            ranks[Self.normalizedChannelIdentity(pair.key)] = pair.value.rank
        }
    }

    private func streamerRelationshipRank(for channel: Channel, ranks: [String: Int]) -> Int {
        guard prioritiseFollowedStreamers, !ranks.isEmpty else { return 0 }
        return Self.identityKeys(for: channel)
            .compactMap { ranks[$0] }
            .max() ?? 0
    }

    private func selectBestChannel(from campaign: Campaign) async -> Channel? {
        log("[ChannelSelect] Campaign: \(campaign.name) (game: \(campaign.gameName))")
        log("[ChannelSelect]   ACL restrictions: \(campaign.hasChannelRestrictions ? "YES (\(campaign.channels.count) channels)" : "NO")")
        log("[ChannelSelect]   Special Event: \(campaign.game.isSpecialEvents ? "YES" : "NO")")
        
        do {
            var liveChannels = try await dropsService.findLiveChannels(forGame: campaign.game)
            
            // SPECIAL EVENTS BYPASS: If no channels found for the specific game,
            // but it's a Special Event campaign, we try the ACL channels.
            if liveChannels.isEmpty && campaign.game.isSpecialEvents {
                log("[ChannelSelect]   Special Event bypass: no game-matched channels, trying ACL...")
                // In TDM, we check if any ACL channel is actually live.
                // For now, let's just use the ACL list from the campaign.
                liveChannels = campaign.channels
            }

            log("[ChannelSelect]   Found \(liveChannels.count) live candidate channels")
            
            guard !liveChannels.isEmpty else {
                log("[ChannelSelect]   No live channels found for '\(campaign.gameName)'")
                return nil
            }

            // STEP 1: Sort by priority, ACL, and viewer count (HIGHEST FIRST for TDM parity)
            // TDM PARITY: twitch.py line 758 uses reverse=True which sorts descending (highest first)
            let sortedChannels = liveChannels.sorted { a, b in
                // Priority games check (highest priority first)
                let aPriorityIndex = priorityGames.firstIndex(of: a.gameName ?? "")
                let bPriorityIndex = priorityGames.firstIndex(of: b.gameName ?? "")
                if aPriorityIndex != bPriorityIndex {
                    let aRank = aPriorityIndex ?? Int.max
                    let bRank = bPriorityIndex ?? Int.max
                    return aRank < bRank
                }

                // ACL-based check (ACL channels first)
                if a.aclBased != b.aclBased {
                    return a.aclBased && !b.aclBased
                }

                // Viewer count: HIGHEST FIRST (matching TDM's reverse=True)
                return (a.viewerCount ?? 0) > (b.viewerCount ?? 0)
            }

            var verificationCandidates = Self.verificationCandidates(from: sortedChannels, campaign: campaign)
            if campaign.hasChannelRestrictions {
                log("[ChannelSelect]   ACL-matched live directory candidates: \(verificationCandidates.count)")
                if verificationCandidates.isEmpty {
                    log("[ChannelSelect]   No directory candidates matched the campaign ACL; probing approved channels directly...")
                    verificationCandidates = await liveACLChannels(for: campaign)
                    log("[ChannelSelect]   Live approved-channel fallback candidates: \(verificationCandidates.count)")
                }
            }

            guard !verificationCandidates.isEmpty else {
                log("[ChannelSelect]   No candidate channels matched campaign requirements")
                return nil
            }

            // STEP 2: Filter and Verify (GQL-based verification)
            // We iterate through the top candidates and verify they ACTUALLY have drops for this campaign.
            // This prevents "stuck" sessions on channels that only have the tag but no active campaign.
            var allVerificationsFailed = true  // true only if every attempt threw a network error
            for ch in verificationCandidates {
                let channel = await resolveChannelIdIfNeeded(ch)
                log("[ChannelSelect]   Verifying \(channel.displayName) (viewers: \(channel.viewerCount ?? 0), id: \(channel.id))...")

                // If it's not a Special Event, we can filter by campaign restrictions early
                if campaign.hasChannelRestrictions && !Self.channelMatchesCampaignACL(channel, campaign: campaign) {
                    log("[ChannelSelect]     Skipping: not in campaign ACL")
                    allVerificationsFailed = false  // not an error — campaign restriction mismatch
                    continue
                }

                do {
                    // TDM PARITY: Strict drops-enabled verification via GQL
                    let activeCampaignIds = try await apiClient.fetchAvailableDrops(channelId: channel.id)
                    allVerificationsFailed = false  // GQL responded — campaign simply not active here
                    if activeCampaignIds.contains(campaign.id) {
                        log("[ChannelSelect]     Verified: Campaign \(campaign.id) is active on \(channel.displayName)")
                        // Track selected channel for UI
                        currentChannelName = channel.displayName
                        currentChannelId = channel.id
                        return channel
                    } else {
                        log("[ChannelSelect]     Campaign mismatch. Active IDs: \(activeCampaignIds.joined(separator: ", "))")
                    }
                } catch {
                    log("[ChannelSelect]     Warning: Verification failed for \(channel.displayName): \(error.localizedDescription)")
                    // allVerificationsFailed remains true for this channel — it errored
                }
            }

            // Only fall back to best-guess channel if ALL verification attempts failed due to
            // network/GQL errors (not because the campaign simply wasn't active on those channels).
            // This prevents watching unverified channels when the campaign is genuinely expired.
            if allVerificationsFailed, let best = verificationCandidates.first {
                log("[ChannelSelect]   ! All GQL verifications errored. Falling back to best candidate: \(best.displayName)")
                // Track selected channel for UI
                currentChannelName = best.displayName
                currentChannelId = best.id
                return best
            }

            return nil
        } catch {
            log("Failed to fetch live channels for '\(campaign.gameName)': \(error.localizedDescription)")
            // Only use ACL fallback if the whole live-channel fetch failed (network error).
            // Do not fall back when the campaign has no eligible channels.
            if let fallback = campaign.channels.first {
                // Track selected channel for UI
                currentChannelName = fallback.displayName
                currentChannelId = fallback.id
                return fallback
            }
            return nil
        }
    }

    private func resolveChannelIdIfNeeded(_ channel: Channel) async -> Channel {
        guard channel.id == channel.login else { return channel }

        do {
            let resolved = try await apiClient.getChannel(login: channel.login)
            log("[ChannelSelect]   Resolved \(channel.login) → channel ID \(resolved.id)")
            return Channel(
                id: resolved.id,
                login: resolved.login,
                displayName: resolved.displayName,
                description: channel.description,
                profileImageUrl: channel.profileImageUrl,
                isLive: channel.isLive,
                viewerCount: channel.viewerCount,
                gameId: channel.gameId,
                gameName: channel.gameName,
                tags: channel.tags,
                hasDropsEnabled: channel.hasDropsEnabled,
                broadcasterType: channel.broadcasterType,
                aclBased: channel.aclBased
            )
        } catch {
            log("[ChannelSelect]   Could not resolve channel ID for \(channel.login): \(error.localizedDescription)")
            return channel
        }
    }

    /// Lightweight liveness probe used while waiting for a stream. Returns true as soon as any
    /// approved channel for the given ACL-restricted campaigns is live, so the engine can wake
    /// from the idle wait and re-run channel selection without burning a full campaign interval.
    private func anyApprovedChannelLive(in candidates: [Campaign]) async -> Bool {
        for candidate in candidates where candidate.hasChannelRestrictions {
            if !(await liveACLChannels(for: candidate).isEmpty) {
                return true
            }
        }
        return false
    }

    private func liveACLChannels(for campaign: Campaign, limit: Int = 30) async -> [Channel] {
        guard campaign.hasChannelRestrictions else { return [] }

        // Probe approved channels concurrently — for restricted campaigns this can be up to
        // `limit` independent live-state checks, and doing them serially adds seconds of latency
        // to channel selection. Each result carries its source index so we can restore the
        // campaign's original channel ordering after the parallel fan-out.
        let candidates = Array(campaign.channels.prefix(limit).enumerated())
        let resolvedByIndex = await withTaskGroup(of: (Int, Channel)?.self) { group -> [Int: Channel] in
            for (index, channel) in candidates {
                let login = channel.login.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !login.isEmpty else { continue }

                group.addTask {
                    do {
                        guard try await self.apiClient.fetchBroadcastId(channelLogin: login) != nil else {
                            return nil
                        }
                        let resolved = await self.resolveChannelIdIfNeeded(channel)
                        return (index, Channel(
                            id: resolved.id,
                            login: resolved.login,
                            displayName: resolved.displayName,
                            description: channel.description,
                            profileImageUrl: channel.profileImageUrl,
                            isLive: true,
                            viewerCount: channel.viewerCount,
                            gameId: channel.gameId,
                            gameName: channel.gameName,
                            tags: channel.tags,
                            hasDropsEnabled: true,
                            broadcasterType: channel.broadcasterType,
                            aclBased: true
                        ))
                    } catch {
                        await self.log("[ChannelSelect]   Could not check live state for approved channel \(channel.displayName): \(error.localizedDescription)")
                        return nil
                    }
                }
            }

            var collected: [Int: Channel] = [:]
            for await result in group {
                if let (index, channel) = result {
                    collected[index] = channel
                }
            }
            return collected
        }

        return candidates.compactMap { resolvedByIndex[$0.offset] }
    }

    internal static func verificationCandidates(from sortedChannels: [Channel], campaign: Campaign) -> [Channel] {
        guard campaign.hasChannelRestrictions else {
            return Array(sortedChannels.prefix(50))
        }

        return sortedChannels.filter { channel in
            channelMatchesCampaignACL(channel, campaign: campaign)
        }
    }

    internal static func channelMatchesCampaignACL(_ channel: Channel, campaign: Campaign) -> Bool {
        let channelKeys = identityKeys(for: channel)
        guard !channelKeys.isEmpty else { return false }

        return campaign.channels.contains { aclChannel in
            !channelKeys.isDisjoint(with: identityKeys(for: aclChannel))
        }
    }

    private static func identityKeys(for channel: Channel) -> Set<String> {
        [channel.id, channel.login, channel.displayName].reduce(into: Set<String>()) { keys, value in
            let normalized = normalizedChannelIdentity(value)
            if !normalized.isEmpty {
                keys.insert(normalized)
            }
        }
    }

    private static func normalizedChannelIdentity(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func selectFailoverChannel(for campaign: Campaign, currentChannel: Channel) async -> Channel? {
        guard let rule = failoverRule(for: campaign) else { return nil }
        let login = rule.streamerLogin
        let key = failoverCooldownKey(campaignId: campaign.id, streamerLogin: login)
        let now = Date()

        failoverCooldowns = failoverCooldowns.filter { $0.value > now }
        if let cooldownUntil = failoverCooldowns[key], cooldownUntil > now {
            let remaining = max(1, Int(cooldownUntil.timeIntervalSince(now) / 60))
            log("[ChannelSelect] Failover @\(login) for \(campaign.gameName) is cooling down for \(remaining)m after a stalled attempt.")
            return nil
        }

        let currentKeys = [
            currentChannel.id,
            currentChannel.login,
            currentChannel.displayName
        ].map(Self.normalizedChannelIdentity)
        if currentKeys.contains(Self.normalizedChannelIdentity(login)) {
            failoverCooldowns[key] = now.addingTimeInterval(Self.failoverCooldown)
            log("[ChannelSelect] Failover @\(login) also stalled for \(campaign.gameName); cooling it down.")
            return nil
        }

        return await verifiedFailoverChannel(for: campaign, streamerLogin: login, context: "stall failover")
    }

    private func failoverRule(for campaign: Campaign) -> GameFailoverStreamer? {
        let gameId = normalizedGameKey(campaign.game.id)
        let gameName = normalizedGameKey(campaign.gameName)

        return failoverStreamers.first { rule in
            guard rule.enabled, !rule.streamerLogin.isEmpty else { return false }
            let ruleGameId = normalizedGameKey(rule.gameId)
            let ruleGameName = normalizedGameKey(rule.gameName)
            return (!ruleGameId.isEmpty && ruleGameId == gameId)
                || (!ruleGameName.isEmpty && ruleGameName == gameName)
        }
    }

    private func verifiedFailoverChannel(
        for campaign: Campaign,
        streamerLogin: String,
        context: String
    ) async -> Channel? {
        let login = GameFailoverStreamer.normalizedStreamerLogin(streamerLogin) ?? streamerLogin
        guard !login.isEmpty else { return nil }

        log("[ChannelSelect] Checking \(context) @\(login) for \(campaign.name)")
        do {
            guard try await apiClient.fetchBroadcastId(channelLogin: login) != nil else {
                log("[ChannelSelect] Failover @\(login) is offline.")
                return nil
            }

            let resolved = await resolveChannelIdIfNeeded(Channel(id: login, login: login, displayName: login))
            let activeCampaignIds = try await apiClient.fetchAvailableDrops(channelId: resolved.id)
            guard activeCampaignIds.contains(campaign.id) else {
                log("[ChannelSelect] Failover @\(login) is live but not running \(campaign.name).")
                return nil
            }

            return Channel(
                id: resolved.id,
                login: resolved.login,
                displayName: resolved.displayName,
                description: resolved.description,
                profileImageUrl: resolved.profileImageUrl,
                isLive: true,
                viewerCount: resolved.viewerCount,
                gameId: campaign.game.id,
                gameName: campaign.gameName,
                tags: resolved.tags,
                hasDropsEnabled: true,
                broadcasterType: resolved.broadcasterType,
                aclBased: resolved.aclBased
            )
        } catch {
            log("[ChannelSelect] Failover @\(login) check failed: \(error.localizedDescription)")
            return nil
        }
    }

    private func failoverCooldownKey(campaignId: String, streamerLogin: String) -> String {
        "\(campaignId):\(Self.normalizedChannelIdentity(streamerLogin))"
    }

    private enum StreamOverrideSelection {
        case selected(Campaign, Channel)
        case waiting
        case cleared
    }

    private func selectStreamOverrideChannel(for candidates: [Campaign]) async -> StreamOverrideSelection {
        guard let login = streamOverrideLogin else { return .cleared }
        log("[ChannelSelect] Stream override: checking @\(login)")

        do {
            guard try await apiClient.fetchBroadcastId(channelLogin: login) != nil else {
                log("[ChannelSelect] Stream override @\(login) is offline. Clearing override.")
                clearStreamOverrideAfterOffline()
                return .cleared
            }

            let channel = await resolveChannelIdIfNeeded(Channel(id: login, login: login, displayName: login))
            let activeCampaignIds = try await apiClient.fetchAvailableDrops(channelId: channel.id)
            let matches = candidates.filter { activeCampaignIds.contains($0.id) }

            // Prefer a drop campaign this miner can actually mine on the override channel.
            // If none is active, watch the streamer anyway (no drop progress) until they go offline.
            let matchedCampaign = Self.bestVerifiedCampaignMatch(
                candidates: candidates,
                matches: matches.map { (campaign: $0, channel: channel) }
            )?.campaign

            let campaign = matchedCampaign ?? Self.watchOnlyOverrideCampaign(login: login)
            streamOverrideWatchOnly = (matchedCampaign == nil)

            let overrideChannel = Channel(
                id: channel.id,
                login: channel.login,
                displayName: channel.displayName,
                description: channel.description,
                profileImageUrl: channel.profileImageUrl,
                isLive: true,
                viewerCount: channel.viewerCount,
                gameId: channel.gameId,
                gameName: matchedCampaign?.gameName ?? channel.gameName,
                tags: channel.tags,
                hasDropsEnabled: matchedCampaign != nil,
                broadcasterType: channel.broadcasterType,
                aclBased: channel.aclBased
            )

            if streamOverrideWatchOnly {
                log("[ChannelSelect] Stream override @\(login) is live with no mineable drop — watching anyway until they go offline.")
            } else {
                log("[ChannelSelect] Stream override selected \(campaign.name) on \(overrideChannel.displayName)")
            }
            currentChannelName = overrideChannel.displayName
            currentChannelId = overrideChannel.id
            return .selected(campaign, overrideChannel)
        } catch {
            log("[ChannelSelect] Stream override @\(login) check failed: \(error.localizedDescription)")
            return .waiting
        }
    }

    private static func normalizedStreamOverrideLogin(_ login: String?) -> String? {
        MinerManager.ManagedMiner.normalizedStreamOverrideLogin(login)
    }

    /// Placeholder campaign used to drive a "watch only" override session when the streamer
    /// has no drop this miner can earn. Carries no game/drops, so the watch loop sends view
    /// heartbeats without trying to track or switch on drop progress.
    private static func watchOnlyOverrideCampaign(login: String) -> Campaign {
        Campaign(
            id: "stream-override:\(login)",
            name: "Watching @\(login)",
            game: Game(id: "", name: ""),
            status: .active,
            startDate: Date().addingTimeInterval(-3600),
            endDate: Date().addingTimeInterval(60 * 60 * 24 * 365),
            drops: [],
            channels: [],
            isAccountConnected: true
        )
    }

    private func clearStreamOverrideAfterOffline() {
        streamOverrideLogin = nil
        streamOverrideWatchOnly = false
        onStreamOverrideChange?(nil)
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

    private func log(_ message: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestamp = formatter.string(from: Date())
        onLogMessage?("[\(timestamp)] \(message)")
    }

    private func dropLabel(for dropId: String, campaignId: String?) -> String {
        findDrop(dropId: dropId, campaignId: campaignId)?.name ?? dropId
    }

    private func requiredMinutes(for dropId: String, campaignId: String?) -> Int? {
        findDrop(dropId: dropId, campaignId: campaignId)?.requiredMinutes
    }

    private func acknowledgeInventoryProgress(
        _ snapshot: InventorySnapshot,
        campaignId: String,
        context: String,
        publishProgressUpdate: Bool = true
    ) async -> Bool {
        let mergedCampaigns = DropsService.mergeInventory(snapshot, into: allCampaigns)
        allCampaigns = mergedCampaigns

        let updatedCandidates = candidateCampaigns(
            from: mergedCampaigns,
            priorityGames: priorityGames,
            excludedGames: excludedGames,
            strategy: miningStrategy
        )
        onCampaignUpdate?(updatedCandidates)

        let currentCampaignProgress = snapshot.progress.filter { progress in
            progress.campaignId == campaignId && !progress.isClaimed
        }

        var acknowledged = false
        for progress in currentCampaignProgress {
            let observation = DropProgressObservation(
                campaignId: progress.campaignId,
                dropId: progress.dropId,
                dropLabel: progress.dropName.isEmpty ? dropLabel(for: progress.dropId, campaignId: progress.campaignId) : progress.dropName,
                currentMinutes: progress.currentMinutes,
                requiredMinutes: progress.requiredMinutes,
                source: .inventory
            )
            let result = progressEventTracker.observe(observation)
            traceGQL(
                "Inventory progress \(context) drop=\(progress.dropId) parsedCurrent=\(progress.currentMinutes) " +
                "previous=\(result.previousMinutes.map(String.init) ?? "nil") transition=\(result.transition.traceDescription)"
            )

            guard result.shouldAcknowledgeServerProgress else { continue }

            if let message = formatProgressTransition(result.transition) {
                log("\(message) from Twitch inventory")
            }

            acknowledged = true
        }

        if acknowledged {
            extraMinutesWatched = 0
            lastProgressUpdateAt = Date()

            if publishProgressUpdate,
               let progress = try? await dropsService.getOverallProgress() {
                onProgressUpdate?(progress)
            }
        }

        return acknowledged
    }

    /// Refresh all server-confirmed progress for the active campaign after any individual
    /// progress signal advances. Twitch can advance multiple drops in parallel, so updating
    /// only the drop named by PubSub/current-session GQL can leave the rest of the UI stale.
    private func refreshCampaignProgress(campaignId: String?, context: String) async {
        if let campaignId, !campaignId.isEmpty {
            do {
                let inventoryService = await dropsService.getInventoryService()
                let snapshot = try await inventoryService.fetchInventory(forceRefresh: true)
                onOperationalEvent?(.successfulPoll)
                onOperationalEvent?(.inventoryRefresh)
                _ = await acknowledgeInventoryProgress(
                    snapshot,
                    campaignId: campaignId,
                    context: context,
                    publishProgressUpdate: false
                )
            } catch {
                emitIssue(error)
                log("Could not refresh campaign-wide drop progress: \(error.localizedDescription)")
            }
        }

        // Publish once after the merge. This also preserves the prior single-drop update
        // behavior if no campaign ID is available or the forced refresh fails.
        if let progress = try? await dropsService.getOverallProgress() {
            onProgressUpdate?(progress)
        }
    }

    private func findDrop(dropId: String, campaignId: String?) -> Drop? {
        if let campaignId,
           let campaign = allCampaigns.first(where: { $0.id == campaignId }),
           let drop = campaign.drops.first(where: { $0.id == dropId }) {
            return drop
        }

        return allCampaigns
            .lazy
            .flatMap(\.drops)
            .first(where: { $0.id == dropId })
    }

    private func formatProgressTransition(_ transition: DropProgressTransition) -> String? {
        switch transition {
        case .none, .regression:
            return nil
        case .progress(let dropLabel, let deltaMinutes, let currentMinutes, let requiredMinutes):
            if let requiredMinutes {
                return "Progress +\(deltaMinutes) min on \(dropLabel) (\(currentMinutes)/\(requiredMinutes) min)"
            }
            return "Progress +\(deltaMinutes) min on \(dropLabel) (\(currentMinutes) min)"
        case .claimable(let dropLabel, let currentMinutes, let requiredMinutes):
            return "Drop claimable: \(dropLabel) (\(currentMinutes)/\(requiredMinutes) min)"
        case .claimed(let dropLabel):
            return "Drop claimed: \(dropLabel)"
        }
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
    private var currentChannelName: String?
    private var currentChannelId: String?
}

// MARK: - Supporting Types

struct DropProgressCacheKey: Hashable, Sendable {
    let campaignId: String?
    let dropId: String
}

enum DropProgressSource: String, Sendable {
    case pubSub
    case gqlPoll
    case inventory
}

struct DropProgressObservation: Sendable {
    let campaignId: String?
    let dropId: String
    let dropLabel: String
    let currentMinutes: Int
    let requiredMinutes: Int?
    let source: DropProgressSource
}

struct TrackedDropProgress: Sendable, Equatable {
    let dropLabel: String
    let currentMinutes: Int
    let requiredMinutes: Int?
    let isClaimed: Bool
}

enum DropProgressTransition: Sendable, Equatable {
    case none
    case progress(dropLabel: String, deltaMinutes: Int, currentMinutes: Int, requiredMinutes: Int?)
    case claimable(dropLabel: String, currentMinutes: Int, requiredMinutes: Int)
    case claimed(dropLabel: String)
    case regression(previousMinutes: Int, observedMinutes: Int)

    var traceDescription: String {
        switch self {
        case .none:
            return "none"
        case .progress(let dropLabel, let deltaMinutes, let currentMinutes, let requiredMinutes):
            if let requiredMinutes {
                return "progress[\(dropLabel)] delta=\(deltaMinutes) current=\(currentMinutes)/\(requiredMinutes)"
            }
            return "progress[\(dropLabel)] delta=\(deltaMinutes) current=\(currentMinutes)"
        case .claimable(let dropLabel, let currentMinutes, let requiredMinutes):
            return "claimable[\(dropLabel)] current=\(currentMinutes)/\(requiredMinutes)"
        case .claimed(let dropLabel):
            return "claimed[\(dropLabel)]"
        case .regression(let previousMinutes, let observedMinutes):
            return "regression previous=\(previousMinutes) observed=\(observedMinutes)"
        }
    }
}

struct DropProgressUpdateResult: Sendable, Equatable {
    let key: DropProgressCacheKey
    let source: DropProgressSource
    let previousMinutes: Int?
    let transition: DropProgressTransition

    var shouldAcknowledgeServerProgress: Bool {
        switch transition {
        case .progress, .claimable, .claimed:
            return true
        case .none, .regression:
            return false
        }
    }
}

struct DropProgressEventTracker: Sendable {
    private(set) var cache: [DropProgressCacheKey: TrackedDropProgress] = [:]

    mutating func observe(_ observation: DropProgressObservation) -> DropProgressUpdateResult {
        let key = DropProgressCacheKey(campaignId: observation.campaignId, dropId: observation.dropId)
        let previous = cache[key]
        let mergedRequired = observation.requiredMinutes ?? previous?.requiredMinutes

        if let previous, previous.isClaimed {
            cache[key] = TrackedDropProgress(
                dropLabel: observation.dropLabel,
                currentMinutes: previous.currentMinutes,
                requiredMinutes: mergedRequired,
                isClaimed: true
            )
            return DropProgressUpdateResult(
                key: key,
                source: observation.source,
                previousMinutes: previous.currentMinutes,
                transition: .none
            )
        }

        if let previous, observation.currentMinutes < previous.currentMinutes {
            cache[key] = TrackedDropProgress(
                dropLabel: observation.dropLabel,
                currentMinutes: previous.currentMinutes,
                requiredMinutes: mergedRequired,
                isClaimed: previous.isClaimed
            )
            return DropProgressUpdateResult(
                key: key,
                source: observation.source,
                previousMinutes: previous.currentMinutes,
                transition: .regression(previousMinutes: previous.currentMinutes, observedMinutes: observation.currentMinutes)
            )
        }

        let currentMinutes = max(observation.currentMinutes, previous?.currentMinutes ?? 0)
        let current = TrackedDropProgress(
            dropLabel: observation.dropLabel,
            currentMinutes: currentMinutes,
            requiredMinutes: mergedRequired,
            isClaimed: false
        )
        cache[key] = current

        let previousClaimable = previous.map { isClaimable(minutes: $0.currentMinutes, requiredMinutes: $0.requiredMinutes, isClaimed: $0.isClaimed) } ?? false
        let currentClaimable = isClaimable(minutes: currentMinutes, requiredMinutes: mergedRequired, isClaimed: false)
        if currentClaimable && !previousClaimable {
            return DropProgressUpdateResult(
                key: key,
                source: observation.source,
                previousMinutes: previous?.currentMinutes,
                transition: .claimable(
                    dropLabel: observation.dropLabel,
                    currentMinutes: currentMinutes,
                    requiredMinutes: mergedRequired ?? currentMinutes
                )
            )
        }

        let delta = currentMinutes - (previous?.currentMinutes ?? 0)
        if delta > 0 {
            return DropProgressUpdateResult(
                key: key,
                source: observation.source,
                previousMinutes: previous?.currentMinutes,
                transition: .progress(
                    dropLabel: observation.dropLabel,
                    deltaMinutes: delta,
                    currentMinutes: currentMinutes,
                    requiredMinutes: mergedRequired
                )
            )
        }

        return DropProgressUpdateResult(
            key: key,
            source: observation.source,
            previousMinutes: previous?.currentMinutes,
            transition: .none
        )
    }

    mutating func markClaimed(campaignId: String?, dropId: String, dropLabel: String) -> DropProgressUpdateResult {
        let key = DropProgressCacheKey(campaignId: campaignId, dropId: dropId)
        let previous = cache[key]
        let alreadyClaimed = previous?.isClaimed ?? false
        cache[key] = TrackedDropProgress(
            dropLabel: dropLabel,
            currentMinutes: previous?.currentMinutes ?? 0,
            requiredMinutes: previous?.requiredMinutes,
            isClaimed: true
        )

        return DropProgressUpdateResult(
            key: key,
            source: .pubSub,
            previousMinutes: previous?.currentMinutes,
            transition: alreadyClaimed ? .none : .claimed(dropLabel: dropLabel)
        )
    }

    private func isClaimable(minutes: Int, requiredMinutes: Int?, isClaimed: Bool) -> Bool {
        guard !isClaimed, let requiredMinutes else { return false }
        return minutes >= requiredMinutes
    }
}

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
