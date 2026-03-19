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
    private var enableBadgesEmotes: Bool = false

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
    public func updateMiningPreferences(priorityGames: [String], excludedGames: [String], enableBadgesEmotes: Bool = false) {
        self.priorityGames = priorityGames
        self.excludedGames = excludedGames
        self.enableBadgesEmotes = enableBadgesEmotes
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
                var lastGqlPoll = Date()
                while await watchSessionManager.isWatching && !shouldSwitchChannel {
                    // Check every 10 seconds for interrupts or polls
                    try? await Task.sleep(nanoseconds: 10 * 1_000_000_000)
                    
                    // TDM PARITY: GQL Fallback Poll
                    // If it's been >20s since last PubSub/Poll and we haven't hit 100%
                    if Date().timeIntervalSince(lastGqlPoll) >= 20 {
                        lastGqlPoll = Date()
                        if let current = try? await apiClient.fetchCurrentDrop(channelId: channel.id) {
                            log("Drop progress (GQL poll): \(current.dropId) - \(current.currentMinutes) min")
                            extraMinutesWatched = 0 // Reset stall timer on GQL success
                            
                            // Trigger UI update
                            if let progress = try? await dropsService.getOverallProgress() {
                                onProgressUpdate?(progress)
                            }
                        }
                    }

                    // Standard 1-minute increment for stall detection (local estimation).
                    // The outer loop sleeps 60s per iteration, so one increment per wakeup is correct.
                    extraMinutesWatched += 1

                    // Stuck detection (matches TDM logic)
                    if extraMinutesWatched >= Self.maxExtraMinutes {
                        log("⚠️ Progress stalled for \(extraMinutesWatched) mins. Triggering channel switch.")
                        shouldSwitchChannel = true
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
                    
                    // TDM PARITY: Delete notification after successful claim
                    try? await apiClient.deleteNotification(id: progress.id)

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

            // Status check (prefer IN_PROGRESS over AVAILABLE)
            let aStatus = a.miningStatus
            let bStatus = b.miningStatus
            if aStatus != bStatus {
                return aStatus == .inProgress // IN_PROGRESS (true) comes before AVAILABLE (false)
            }

            // Unclaimed drops check (prefer more drops available)
            let aUnclaimed = a.earnableDrops.count
            let bUnclaimed = b.earnableDrops.count
            if aUnclaimed != bUnclaimed {
                return aUnclaimed > bUnclaimed
            }

            // Ending soonest check
            return a.endDate < b.endDate
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
            for ch in sortedChannels.prefix(5) {
                log("[ChannelSelect]   Verifying \(ch.displayName) (viewers: \(ch.viewerCount ?? 0))...")
                
                // If it's not a Special Event, we can filter by campaign restrictions early
                if campaign.hasChannelRestrictions && !campaign.channels.contains(where: { $0.id == ch.id }) {
                    log("[ChannelSelect]     ✗ Skipping: not in campaign ACL")
                    continue
                }

                do {
                    // TDM PARITY: Strict drops-enabled verification via GQL
                    let activeCampaignIds = try await apiClient.fetchAvailableDrops(channelId: ch.id)
                    if activeCampaignIds.contains(campaign.id) {
                        log("[ChannelSelect]     ✓ Verified! Campaign \(campaign.id) is active on \(ch.displayName)")
                        return ch
                    } else {
                        log("[ChannelSelect]     ✗ Campaign mismatch. Active IDs: \(activeCampaignIds.joined(separator: ", "))")
                    }
                } catch {
                    log("[ChannelSelect]     ⚠️ Verification failed for \(ch.displayName): \(error.localizedDescription)")
                }
            }

            // Fallback: If no channel could be verified, pick the best candidate anyway (best effort)
            if let best = sortedChannels.first {
                log("[ChannelSelect]   ! No channel fully verified via GQL. Falling back to best candidate: \(best.displayName)")
                return best
            }
            
            return nil
        } catch {
            log("Failed to fetch live channels for '\(campaign.gameName)': \(error.localizedDescription)")
            return campaign.channels.first
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
