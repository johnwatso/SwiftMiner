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
    
    private var session: MiningSession?
    private var isRunning = false
    private var mainTask: Task<Void, Never>?
    private var currentAccount: Account?
    private var shouldSwitchChannel = false
    /// Set to true to interrupt the idle wait and immediately re-check for eligible campaigns
    private var shouldRescanCampaigns = false
    
    /// Counter for minutes watched without a server progress update (local estimation)
    private var extraMinutesWatched: Int = 0
    /// Maximum extra minutes allowed before assuming mining is stalled (matches TDM)
    private static let maxExtraMinutes = 15
    
    /// Cache of all campaigns fetched during the last check
    public private(set) var allCampaigns: [Campaign] = []

    // Configuration
    private let campaignCheckInterval: UInt64 = 300 * 1_000_000_000 // 5 minutes
    
    // Mining preferences (set from AppModel/Settings)
    private var priorityGames: [String] = []
    private var excludedGames: [String] = []

    /// Returns this engine's DropsService so callers on other actors can create an AccountStateStore.
    func getDropsService() -> DropsService { dropsService }

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
    public func updateMiningPreferences(priorityGames: [String], excludedGames: [String]) {
        self.priorityGames = priorityGames
        self.excludedGames = excludedGames
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

        // Handle token refresh automatically for PubSub
        Task {
            await authService.setTokenRefreshHandler { [weak self] newToken in
                guard let self = self else { return }
                Task {
                    await self.pubSubClient.updateAccessToken(newToken)
                    await self.log("PubSub access token updated after refresh")
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
    public func setAccount(_ account: Account) {
        self.currentAccount = account
        Task {
            await authService.setCurrentAccount(account)
        }
    }

    /// Starts the mining engine
    public func start() async throws {
        guard !isRunning else {
            throw TwitchMinerError.watchSessionFailed("Engine already running")
        }

        isRunning = true
        session = MiningSession()

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
    }
    
    /// Stops the mining engine
    public func stop() async {
        log("Stopping miner...")
        isRunning = false
        mainTask?.cancel()
        
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
        log("Drop progress: \(event.dropId) - \(event.currentMinutes)/\(event.requiredMinutes) min")
        
        // Reset local estimation on server update
        extraMinutesWatched = 0

        // Update overall progress
        if let progress = try? await dropsService.getOverallProgress() {
            onProgressUpdate?(progress)
        }
    }

    private func handleDropClaim(_ event: DropClaimEvent) async {
        log("Drop claim event received: dropInstanceId=\(event.dropInstanceId)")

        // Use the dropInstanceId directly from PubSub event for claiming
        do {
            let response = try await apiClient.claimDrop(dropInstanceId: event.dropInstanceId)

            if response.status == "CLAIMED" || response.status == "SUCCESS" {
                log("✅ Auto-claimed drop from PubSub: \(event.dropInstanceId)")

                // Try to find drop info for the callback
                let inventory = try? await dropsService.fetchInventory()
                if let progress = inventory?.first(where: { $0.dropId == event.dropId }) {
                    let drop = Drop(
                        id: event.dropId,
                        name: progress.dropName,
                        requiredMinutes: progress.requiredMinutes
                    )
                    onDropClaimed?(drop)
                }

                session?.dropsClaimed += 1
            } else {
                log("⚠️ Drop claim returned status: \(response.status)")
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
    
    // MARK: - Private Methods

    private func runMiningLoop() async {
        while isRunning && !Task.isCancelled {
            do {
                onStatusChange?(.fetchingCampaigns)
                log("Fetching active campaigns...")

                // 1. Fetch active campaigns with inventory merged
                // getActiveCampaigns() merges inventory into campaigns and updates the cache.
                // fetchCampaigns() is then called to get ALL campaigns (not just active) from
                // the now-enriched cache, so allCampaigns reflects real progress.
                let campaigns = try await dropsService.getActiveCampaigns()
                let allEnriched = try await dropsService.fetchCampaigns()
                self.allCampaigns = allEnriched
                log("Campaigns: \(allCampaigns.count) total, \(campaigns.count) active with drops")
                for c in allCampaigns {
                    log("  · \(c.name) status=\(c.status.rawValue) drops=\(c.drops.count) active=\(c.isTimeActive)")
                }
                onCampaignUpdate?(campaigns)

                // 2. Claim any ready drops first
                await claimReadyDrops()

                // 3. Find best campaign to mine based on strategy
                guard let campaign = selectBestCampaign(from: campaigns, priorityGames: priorityGames, excludedGames: excludedGames, strategy: miningStrategy) else {
                    log("No eligible campaigns matching strategy '\(miningStrategy.displayName)'")
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
                session?.currentCampaignId = campaign.id

                // 4. Find eligible channel
                guard let channel = await selectBestChannel(from: campaign) else {
                    log("No eligible channels available for \(campaign.name)")
                    try await Task.sleep(nanoseconds: campaignCheckInterval)
                    continue
                }

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
                _ = try await watchSessionManager.startWatching(
                    channel: channel,
                    campaignId: campaign.id
                )

                // Wait for watch session while periodically checking progress
                while await watchSessionManager.isWatching && !shouldSwitchChannel {
                    try? await Task.sleep(nanoseconds: 60 * 1_000_000_000) // 1 minute
                    
                    // Increment local minute count
                    extraMinutesWatched += 1
                    
                    // Stuck detection (matches TDM logic)
                    if extraMinutesWatched >= Self.maxExtraMinutes {
                        log("⚠️ Progress stalled for \(extraMinutesWatched) mins. Triggering channel switch.")
                        shouldSwitchChannel = true
                    }

                    // Update overall progress
                    if let progress = try? await dropsService.getOverallProgress() {
                        onProgressUpdate?(progress)
                    }

                    // Check if we should claim any drops
                    await claimReadyDrops()
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
        do {
            let claimable = try await dropsService.getClaimableDrops()

            for progress in claimable {
                let result = await claimService.claimDrop(progress)
                if result.success {
                    log("✅ Claimed drop: \(result.dropName)")

                    let drop = Drop(
                        id: progress.dropId,
                        name: progress.dropName,
                        requiredMinutes: progress.requiredMinutes
                    )
                    onDropClaimed?(drop)
                    session?.dropsClaimed += 1
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
        let priorityGamesLower = priorityGames.map { $0.lowercased() }
        let excludedGamesLower = excludedGames.map { $0.lowercased() }

        // 1. Filter out excluded games (highest priority rule - always applied)
        let nonExcluded = campaigns.filter {
            !excludedGamesLower.contains($0.gameName.lowercased())
        }

        // 2. Filter to eligible campaigns (time active, linked, and has earnable drops)
        let eligible = nonExcluded.filter { $0.isMiningEligible }

        // 3. Apply mining strategy
        switch strategy {
        case .mineAll:
            // Pick any eligible campaign
            return selectBestFrom(eligible, priorityGamesLower: priorityGamesLower)

        case .prioritiseSelected:
            // Try priority games first, fallback to any eligible
            let priorityMatches = eligible.filter {
                priorityGamesLower.contains($0.gameName.lowercased())
            }
            if let best = selectBestFrom(priorityMatches, priorityGamesLower: priorityGamesLower) {
                return best
            }
            // Fallback to any eligible
            return selectBestFrom(eligible, priorityGamesLower: priorityGamesLower)

        case .onlyPriority:
            // ONLY priority games, no fallback
            let priorityOnly = eligible.filter {
                priorityGamesLower.contains($0.gameName.lowercased())
            }
            return selectBestFrom(priorityOnly, priorityGamesLower: priorityGamesLower)
        }
    }

    /// Select best campaign from a filtered list using priority, unclaimed count, and end date
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

            // Unclaimed drops check (prefer more drops available)
            let aUnclaimed = a.earnableDrops.count
            let bUnclaimed = b.earnableDrops.count
            if aUnclaimed != bUnclaimed {
                return aUnclaimed > bUnclaimed
            }

            // Ending soonest check
            return a.endAt < b.endAt
        }.first
    }
    
    private func selectBestChannel(from campaign: Campaign) async -> Channel? {
        log("Searching for live channels for \(campaign.gameName)...")
        do {
            let liveChannels = try await dropsService.findLiveChannels(forGame: campaign.gameName)
            log("Found \(liveChannels.count) live channels for \(campaign.gameName)")
            
            guard !liveChannels.isEmpty else {
                log("No live channels found for '\(campaign.gameName)' on Twitch")
                // Fallback to static channel list if available
                if let staticChannel = campaign.channels.first {
                    log("Falling back to static channel: \(staticChannel.displayName)")
                    return staticChannel
                }
                return nil
            }

            // Prioritize channels that match campaign restrictions
            if campaign.hasChannelRestrictions {
                let restricted = liveChannels.filter { live in 
                    campaign.channels.contains { $0.id == live.id } 
                }
                if let best = restricted.first {
                    log("Selected restricted channel: \(best.displayName)")
                    return best
                }
                log("⚠️ No live channels match campaign restrictions for \(campaign.name). Cannot mine this campaign.")
                return nil // Cannot mine if no ACL channels are live
            }
            
            // If no restrictions, pick the first live channel
            let best = liveChannels.first!
            log("Selected live channel: \(best.displayName)")
            return best
        } catch {
            log("Failed to fetch live channels for '\(campaign.gameName)': \(error.localizedDescription)")
            // Fallback to static channel list if available
            if let staticChannel = campaign.channels.first {
                log("Falling back to static channel: \(staticChannel.displayName)")
                return staticChannel
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
