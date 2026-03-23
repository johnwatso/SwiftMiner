import Foundation

/// Main actor that orchestrates the Twitch drops mining lifecycle
public actor MinerEngine {
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
    private var currentAccount: Account?
    private var shouldSwitchChannel = false
    /// Set to true to interrupt the idle wait and immediately re-check for eligible campaigns
    private var shouldRescanCampaigns = false

    /// Counter for minutes watched without a server progress update (local estimation)
    private var extraMinutesWatched: Int = 0
    /// Timestamp of the last verified progress update (GQL or PubSub)
    private var lastProgressUpdateAt: Date = Date()
    /// Maximum extra minutes allowed before assuming mining is stalled (matches TDM)
    private static let maxExtraMinutes = 15

    /// Cache of all campaigns fetched during the last check
    public private(set) var allCampaigns: [Campaign] = []
    private var progressEventTracker = DropProgressEventTracker()

    // Configuration
    private let campaignCheckInterval: UInt64 = 300 * 1_000_000_000 // 5 minutes
    private let claimCheckInterval: UInt64 = 2 * 60 * 1_000_000_000 // 2 minutes (conditional polling)

    // Mining preferences (set from AppModel/Settings)
    private var priorityGames: [String] = []
    private var excludedGames: [String] = []
    private var enableBadgesEmotes: Bool = false
    private var showClaimNotifications: Bool = false

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

    /// Update mining preferences (priority/excluded games)
    public func updateMiningPreferences(
        priorityGames: [String],
        excludedGames: [String],
        enableBadgesEmotes: Bool = false,
        showClaimNotifications: Bool = false
    ) {
        self.priorityGames = priorityGames
        self.excludedGames = excludedGames
        self.enableBadgesEmotes = enableBadgesEmotes
        self.showClaimNotifications = showClaimNotifications
        
        // Configure notification service if enabled
        if showClaimNotifications && notificationService == nil {
            self.notificationService = NotificationService()
        }
        
        Task {
            await notificationService?.configure(enabled: showClaimNotifications)
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

    public init(clientId: String) {
        self.clientId = clientId
        self.authService = TwitchAuthService(clientId: clientId)
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
        await dropsService.setAccountId(account.id)
    }

    /// Starts the mining engine
    public func start() async throws {
        guard !isRunning else {
            throw TwitchMinerError.watchSessionFailed("Engine already running")
        }

        isRunning = true
        session = MiningSession()
        progressEventTracker = DropProgressEventTracker()

        onStatusChange?(.authenticating)
        log("Starting SwiftTwitchMiner...")

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
        }

        // Start main mining loop
        mainTask = Task { [weak self] in
            guard let self = self else { return }
            await self.runMiningLoop()
        }

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
    }

    /// Claims all ready drops immediately
    public func claimAllDrops() async throws {
        guard isRunning else {
            throw TwitchMinerError.sessionNotStarted
        }

        await claimReadyDrops()
    }

    /// Gets current overall progress
    public func getCurrentProgress() async throws -> OverallProgress {
        guard isRunning else {
            throw TwitchMinerError.sessionNotStarted
        }
        
        return try await dropsService.getOverallProgress()
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

        if let progress = try? await dropsService.getOverallProgress() {
            onProgressUpdate?(progress)
        }
    }

    private func handleDropClaim(_ event: DropClaimEvent) async {
        let campaignId = session?.currentCampaignId
        log("Drop claim event received: dropInstanceId=\(event.dropInstanceId)")

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
                log("✅ Auto-claimed drop from PubSub: \(event.dropInstanceId)")
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
            } else {                log("⚠️ Drop claim returned status: \(response.status)")
            }
        } catch {
            log("❌ Failed to auto-claim drop: \(error.localizedDescription)")
        }
    }

    private func handleStreamDown(_ channelId: String) async {
        log("Stream went down: \(channelId)")

        // Check if we're watching this channel
        if session?.currentChannelId == channelId {
            log("Current channel went offline, will switch...")
            shouldSwitchChannel = true

            // Stop current watch session
            await watchSessionManager.stopWatching()
            try? await dropEventsService.stopWatchingChannel(channelId)
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
            
            log("✅ Maintenance: Token validated/refreshed")
            
            // 3. Check for major campaign updates (TDM parity)
            // If we've been running for a long time, it's good to force a full inventory refresh
            // every few maintenance cycles. For now, we rely on the 5m loop in runMiningLoop.
            
        } catch {
            log("⚠️ Maintenance task warning: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Private Methods

    private func runMiningLoop() async {
        while isRunning && !Task.isCancelled {
            do {
                onStatusChange?(.fetchingCampaigns)
                log("Fetching active campaigns...")

                // 1. Fetch all campaigns (single call — avoids double API hit).
                // Previously called getActiveCampaigns() + fetchCampaigns() which was redundant
                // since getActiveCampaigns internally calls fetchCampaigns.
                let allEnriched = try await dropsService.fetchCampaigns()
                self.allCampaigns = allEnriched
                let campaigns = allEnriched.filter { $0.isMiningEligible }

                log("Campaigns: \(allCampaigns.count) total, \(campaigns.count) mining-eligible")
                for c in allEnriched {
                    // IMPLEMENTATION OF DOMAIN LOGGING REQUIREMENT
                    log("  · \(c.name) (\(c.gameName)) → Status: \(c.miningStatus.rawValue) → Relevance: \(c.relevance.rawValue)")
                }
                
                // Log expired campaigns that might be incorrectly marked as eligible
                let expiredButEligible = allEnriched.filter { $0.miningStatus == .expired && $0.isMiningEligible }
                if !expiredButEligible.isEmpty {
                    log("⚠️ WARNING: \(expiredButEligible.count) expired campaigns incorrectly marked as mining-eligible:")
                    for c in expiredButEligible {
                        log("   - \(c.name) (endDate: \(c.endDate), isTimeActive: \(c.isTimeActive), isAccountConnected: \(c.isAccountConnected))")
                    }
                }
                
                onCampaignUpdate?(campaigns)

                // 2. Claim any ready drops first (Claimable status handled here)
                await claimReadyDrops()

                // 3. Find best campaign to mine based on strategy
                // SELECTION RULE: Must be AVAILABLE or IN_PROGRESS. Never CLAIMED or EXPIRED.
                guard let campaign = selectBestCampaign(from: allEnriched, priorityGames: priorityGames, excludedGames: excludedGames, strategy: miningStrategy) else {
                    log("No mineable campaigns matching strategy '\(miningStrategy.displayName)'")
                    onStatusChange?(.idle)
                    // Wait up to campaignCheckInterval in 10s ticks, breaking early on triggerRescan()
                    shouldRescanCampaigns = false
                    let tickNs: UInt64 = 10 * 1_000_000_000
                    let ticks = Int(campaignCheckInterval / tickNs)
                    for _ in 0..<ticks {
                        if shouldRescanCampaigns { break }
                        try await Task.sleep(nanoseconds: tickNs)
                    }
                    shouldRescanCampaigns = false
                    continue
                }

                log("Selected campaign: \(campaign.name) (\(campaign.gameName))")

                // 4. Find eligible channel
                guard let channel = await selectBestChannel(from: campaign) else {
                    log("No eligible channels available for \(campaign.name)")
                    // Keep campaign ID so the UI shows it as queued/waiting (not being mined —
                    // watchingMiners() requires .watching status, not just a currentCampaignId match)
                    session?.currentCampaignId = campaign.id
                    onStatusChange?(.waitingForStream)
                    shouldRescanCampaigns = false
                    let tickNs: UInt64 = 10 * 1_000_000_000
                    let ticks = Int(campaignCheckInterval / tickNs)
                    for _ in 0..<ticks {
                        if shouldRescanCampaigns { break }
                        try await Task.sleep(nanoseconds: tickNs)
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

                // 6. Start watching
                onStatusChange?(.watching)
                extraMinutesWatched = 0
                lastProgressUpdateAt = Date()
                _ = try await watchSessionManager.startWatching(
                    channel: channel,
                    campaignId: campaign.id
                )

                // Wait for watch session while periodically checking progress
                var lastGqlPoll = Date()
                var lastCampaignReevaluation = Date()
                while await watchSessionManager.isWatching && !shouldSwitchChannel {
                    // Check every 10 seconds for interrupts or polls
                    try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
                    
                    // TDM PARITY: GQL Fallback Poll
                    // If it's been >20s since last PubSub/Poll and we haven't hit 100%
                    if Date().timeIntervalSince(lastGqlPoll) >= 20 {
                        lastGqlPoll = Date()
                        if let current = try? await apiClient.fetchCurrentDrop(channelId: channel.id) {
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

                                if let progress = try? await dropsService.getOverallProgress() {
                                    onProgressUpdate?(progress)
                                }
                            }
                        }
                    }

                    // Stuck detection (matches TDM logic)
                    // We calculate minutes elapsed since last verified progress (GQL/PubSub)
                    let elapsed = Date().timeIntervalSince(lastProgressUpdateAt)
                    extraMinutesWatched = Int(elapsed / 60)

                    if extraMinutesWatched >= Self.maxExtraMinutes {
                        log("⚠️ Progress stalled for \(extraMinutesWatched) mins. Refreshing inventory to check for external claims...")
                        
                        // ENHANCEMENT: Force inventory refresh before switching channels
                        // This catches drops claimed on other devices or via Twitch UI
                        do {
                            // Force fresh inventory snapshot fetch (includes benefitIDs)
                            let inventoryService = await dropsService.getInventoryService()
                            let freshInventory = try await inventoryService.fetchInventory(forceRefresh: true)
                            
                            log("📋 Inventory refreshed: \(freshInventory.benefitIDs.count) claimed benefits, \(freshInventory.progress.count) in-progress drops")
                            
                            // Check if ANY drop in current campaign was recently claimed
                            // This handles the case where user claimed via Twitch UI or another device
                            let campaignDrops = allCampaigns.first { $0.id == session?.currentCampaignId }?.drops ?? []
                            let newlyClaimedDrops = campaignDrops.filter { drop in
                                freshInventory.benefitIDs.contains(drop.benefitID) && !drop.isClaimed
                            }
                            
                            if !newlyClaimedDrops.isEmpty {
                                log("✅ \(newlyClaimedDrops.count) drop(s) were claimed externally. Updating local state, resetting stall counter.")
                                extraMinutesWatched = 0 // Reset stall counter
                                lastProgressUpdateAt = Date()
                                // Don't switch channel - continue mining remaining drops in campaign
                            } else {
                                log("🔄 Progress genuinely stalled (no external claims detected). Switching channel.")
                                lastSwitchReason = .stallDetected(minutes: extraMinutesWatched)
                                lastSwitchAt = Date()
                                shouldSwitchChannel = true
                            }
                        } catch {
                            log("⚠️ Inventory refresh failed: \(error.localizedDescription). Switching channel as fallback.")
                            shouldSwitchChannel = true
                        }
                    }

                    // Periodic campaign re-evaluation: detect if a better campaign becomes available
                    // mid-session (e.g. a priority campaign goes live after we started watching).
                    let campaignReevalInterval: TimeInterval = 60 // Check every 60 seconds for better responsiveness
                    if Date().timeIntervalSince(lastCampaignReevaluation) >= campaignReevalInterval {
                        lastCampaignReevaluation = Date()
                        if let freshCampaigns = try? await dropsService.fetchCampaigns() {
                            self.allCampaigns = freshCampaigns

                            // If the current campaign no longer exists in the API response,
                            // clear it from session state and rescan immediately.
                            if !freshCampaigns.contains(where: { $0.id == campaign.id }) {
                                log("⚠️ Campaign '\(campaign.name)' no longer returned by API — clearing and rescanning.")
                                session?.currentCampaignId = nil
                                shouldSwitchChannel = true
                            } else if let bestCampaign = selectBestCampaign(
                                from: freshCampaigns,
                                priorityGames: priorityGames,
                                excludedGames: excludedGames,
                                strategy: miningStrategy
                            ), bestCampaign.id != campaign.id {
                                log("🔄 Better campaign now available: \(bestCampaign.name) (\(bestCampaign.gameName)). Switching from \(campaign.name).")
                                shouldSwitchChannel = true
                            }
                        }
                    }

                    // Check if we should claim any drops
                    await claimReadyDrops()
                    
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

            } catch let error as TwitchMinerError {
                handleError(error)
                try? await Task.sleep(nanoseconds: campaignCheckInterval)
            } catch {
                handleError(.unknown(error.localizedDescription))
                try? await Task.sleep(nanoseconds: campaignCheckInterval)
            }
        }
    }
    
    private func claimReadyDrops() async {
        // Conditional check: Only poll for claims when there are potentially claimable drops
        // This avoids unnecessary API calls when all campaigns are either empty or fully claimed
        let hasClaimableCampaigns = allCampaigns.contains { campaign in
            campaign.drops.contains { drop in !drop.isClaimed }
        }
        
        guard hasClaimableCampaigns || session?.currentCampaignId != nil else {
            return // No claimable campaigns, skip polling to reduce churn
        }
        
        do {
            let claimable = try await dropsService.getClaimableDrops()

            for progress in claimable {
                let result = await claimService.claimDrop(progress)
                if result.success {
                    log("✅ Claimed drop: \(result.dropName)")

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
                    
                    // Send local notification if enabled
                    if showClaimNotifications, let notificationService = notificationService {
                        await notificationService.notifyDropClaimed(
                            campaignName: result.campaignName,
                            dropName: result.dropName
                        )
                    }
                } else {
                    log("⚠️ Drop claim returned not-success for \(progress.dropName)")
                }

                // Small delay between claims
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        } catch {
            log("Error fetching claimable drops: \(error.localizedDescription)")
        }
    }
    
    private func selectBestCampaign(from campaigns: [Campaign], priorityGames: [String], excludedGames: [String], strategy: MiningStrategy) -> Campaign? {
        log("[CampaignSelect] Strategy: \(strategy.displayName), Total campaigns: \(campaigns.count)")
        log("[CampaignSelect]   Excluded games: \(excludedGames.count), Priority games: \(priorityGames.count)")
        log("[CampaignSelect]   Badge/Emotes enabled: \(enableBadgesEmotes)")
        
        let priorityGamesLower = priorityGames.map { $0.lowercased() }
        let excludedGamesLower = excludedGames.map { $0.lowercased() }

        // 1. Filter out excluded games (highest priority rule - always applied)
        let nonExcluded = campaigns.filter {
            !excludedGamesLower.contains($0.gameName.lowercased())
        }
        let excludedCount = campaigns.count - nonExcluded.count
        if excludedCount > 0 {
            log("[CampaignSelect]   Excluded \(excludedCount) campaigns by game filter")
        }

        // 2. Filter to mineable campaigns (Truth Layer check)
        var filteredOutReasons: [String: Int] = [:]
        let eligible = nonExcluded.filter { c in
            guard c.isAccountConnected else {
                filteredOutReasons["not_connected", default: 0] += 1
                return false
            }
            
            // Filter out non-drop rewards (badges/emotes) if setting is disabled
            if !enableBadgesEmotes && c.hasOnlyBadgesOrEmotes {
                filteredOutReasons["badge_emote_only", default: 0] += 1
                return false
            }
            
            let s = c.miningStatus
            let isEligible = s == .available || s == .inProgress || s == .claimable
            if !isEligible {
                filteredOutReasons["status_\(s.rawValue)", default: 0] += 1
            }
            return isEligible
        }
        
        // Log filtered out reasons
        for (reason, count) in filteredOutReasons {
            log("[CampaignSelect]   Filtered out \(count) campaigns: \(reason)")
        }
        log("[CampaignSelect]   Eligible campaigns: \(eligible.count)")

        // 3. Apply mining strategy
        switch strategy {
        case .mineAll:
            let result = selectBestFrom(eligible, priorityGamesLower: priorityGamesLower)
            if let campaign = result {
                log("[CampaignSelect]   ✓ Selected (mineAll): \(campaign.name) (\(campaign.gameName), status: \(campaign.miningStatus.rawValue))")
            }
            return result

        case .prioritiseSelected:
            let priorityMatches = eligible.filter {
                priorityGamesLower.contains($0.gameName.lowercased())
            }
            log("[CampaignSelect]   Priority matches: \(priorityMatches.count)/\(eligible.count)")
            
            if let best = selectBestFrom(priorityMatches, priorityGamesLower: priorityGamesLower) {
                log("[CampaignSelect]   ✓ Selected (priority): \(best.name) (\(best.gameName))")
                return best
            }
            // Fallback to any eligible
            let fallback = selectBestFrom(eligible, priorityGamesLower: priorityGamesLower)
            if let campaign = fallback {
                log("[CampaignSelect]   ✓ Selected (fallback): \(campaign.name) (\(campaign.gameName))")
            }
            return fallback

        case .onlyPriority:
            let priorityOnly = eligible.filter {
                priorityGamesLower.contains($0.gameName.lowercased())
            }
            log("[CampaignSelect]   Priority only: \(priorityOnly.count)/\(eligible.count)")
            
            let result = selectBestFrom(priorityOnly, priorityGamesLower: priorityGamesLower)
            if let campaign = result {
                log("[CampaignSelect]   ✓ Selected (priority only): \(campaign.name) (\(campaign.gameName))")
            } else if !eligible.isEmpty {
                log("[CampaignSelect]   ✗ No priority campaigns available (strategy: onlyPriority)")
            }
            return result
        }
    }

    /// Select best campaign from a filtered list using priority, progress, and end date
    private func selectBestFrom(_ campaigns: [Campaign], priorityGamesLower: [String]) -> Campaign? {
        guard !campaigns.isEmpty else { return nil }

        return campaigns.sorted { a, b in
            let aName = a.gameName.lowercased()
            let bName = b.gameName.lowercased()

            // Priority check
            let aPriority = priorityGamesLower.firstIndex(of: aName) ?? Int.max
            let bPriority = priorityGamesLower.firstIndex(of: bName) ?? Int.max

            if aPriority != bPriority {
                return aPriority < bPriority
            }

            // Urgency check: prefer campaigns ending sooner (time-limited events like CDL qualifiers)
            // This runs before status so a newly-live short event beats an in-progress long campaign.
            if a.endDate != b.endDate {
                return a.endDate < b.endDate
            }

            // Status check (prefer IN_PROGRESS over AVAILABLE — momentum tie-breaker within same end date)
            let aStatus = a.miningStatus
            let bStatus = b.miningStatus
            if aStatus != bStatus {
                return aStatus == .inProgress
            }

            // Unclaimed drops check (prefer more drops available)
            let aUnclaimed = a.earnableDrops.count
            let bUnclaimed = b.earnableDrops.count
            return aUnclaimed > bUnclaimed
        }.first
    }
    
    private func selectBestChannel(from campaign: Campaign) async -> Channel? {
        log("[ChannelSelect] Campaign: \(campaign.name) (game: \(campaign.gameName))")
        log("[ChannelSelect]   ACL restrictions: \(campaign.hasChannelRestrictions ? "YES (\(campaign.channels.count) channels)" : "NO")")
        log("[ChannelSelect]   Special Event: \(campaign.game.isSpecialEvents ? "YES" : "NO")")
        
        do {
            var liveChannels = try await dropsService.findLiveChannels(forGame: campaign.gameName)
            
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
                log("[ChannelSelect]   ✗ No live channels found for '\(campaign.gameName)'")
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

            // STEP 2: Filter and Verify (GQL-based verification)
            // We iterate through the top candidates and verify they ACTUALLY have drops for this campaign.
            // This prevents "stuck" sessions on channels that only have the tag but no active campaign.
            var allVerificationsFailed = true  // true only if every attempt threw a network error
            for ch in sortedChannels.prefix(5) {
                log("[ChannelSelect]   Verifying \(ch.displayName) (viewers: \(ch.viewerCount ?? 0))...")

                // If it's not a Special Event, we can filter by campaign restrictions early
                if campaign.hasChannelRestrictions && !campaign.channels.contains(where: { $0.id == ch.id }) {
                    log("[ChannelSelect]     ✗ Skipping: not in campaign ACL")
                    allVerificationsFailed = false  // not an error — campaign restriction mismatch
                    continue
                }

                do {
                    // TDM PARITY: Strict drops-enabled verification via GQL
                    let activeCampaignIds = try await apiClient.fetchAvailableDrops(channelId: ch.id)
                    allVerificationsFailed = false  // GQL responded — campaign simply not active here
                    if activeCampaignIds.contains(campaign.id) {
                        log("[ChannelSelect]     ✓ Verified! Campaign \(campaign.id) is active on \(ch.displayName)")
                        // Track selected channel for UI
                        currentChannelName = ch.displayName
                        currentChannelId = ch.id
                        return ch
                    } else {
                        log("[ChannelSelect]     ✗ Campaign mismatch. Active IDs: \(activeCampaignIds.joined(separator: ", "))")
                    }
                } catch {
                    log("[ChannelSelect]     ⚠️ Verification failed for \(ch.displayName): \(error.localizedDescription)")
                    // allVerificationsFailed remains true for this channel — it errored
                }
            }

            // Only fall back to best-guess channel if ALL verification attempts failed due to
            // network/GQL errors (not because the campaign simply wasn't active on those channels).
            // This prevents watching unverified channels when the campaign is genuinely expired.
            if allVerificationsFailed, let best = sortedChannels.first {
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
    
    private func handleError(_ error: TwitchMinerError) {
        log("Error: \(error.localizedDescription)")
        onError?(error)

        session?.status = .error

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
        let isStalled = minutes >= Self.maxExtraMinutes
        
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
