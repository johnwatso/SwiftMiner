import Foundation

// Setters for the engine's callbacks. The engine reports outwards entirely through these, so
// they are collected here rather than interleaved with the logic that fires them.
//
// Split out of MinerEngine.swift, which had grown past the point where one file could be read.

extension MinerEngine {
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

    public func setEarnedProgressHandler(_ handler: (@Sendable (Int) -> Void)?) {
        self.onEarnedProgress = handler
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

    public func setGameChannelAvailabilityHandler(_ handler: (@Sendable (GameChannelAvailability) -> Void)?) {
        self.onGameChannelAvailability = handler
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
    ) async {
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
        
        // Awaited rather than detached: two preference saves in quick succession could otherwise
        // deliver their `configure` calls out of order and leave the service on the older setting.
        await notificationService?.configure(enabled: showClaimNotifications)
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
}
