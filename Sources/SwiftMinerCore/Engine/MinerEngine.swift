import Foundation
import AsyncAlgorithms

/// The latest account-specific result of checking a Twitch game for a stream that can
/// actually earn one of this miner's drops. A directory being non-empty is not enough:
/// the engine records success only after campaign verification has found a usable channel.
public struct GameChannelAvailability: Sendable, Equatable {
    public static let freshnessInterval: TimeInterval = 15 * 60

    public let gameKey: String
    public let hasEligibleChannel: Bool
    public let campaignId: String?
    public let channelName: String?
    public let checkedAt: Date

    public init(
        gameKey: String,
        hasEligibleChannel: Bool,
        campaignId: String? = nil,
        channelName: String? = nil,
        checkedAt: Date
    ) {
        self.gameKey = gameKey
        self.hasEligibleChannel = hasEligibleChannel
        self.campaignId = campaignId
        self.channelName = channelName
        self.checkedAt = checkedAt
    }

    public func isFresh(at now: Date = Date()) -> Bool {
        now.timeIntervalSince(checkedAt) <= Self.freshnessInterval
    }
}

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
                if status == 429 {
                    return (.rateLimited, "HTTP 429 — \(message)")
                }
                if (500...599).contains(status) {
                    return (.twitchAPIFailure, "HTTP \(status) — \(message)")
                }
                if status == 401 || status == 403 {
                    return (.authIssue, "HTTP \(status) — \(message)")
                }
                return (.twitchAPIFailure, "HTTP \(status) — \(message)")
            case .twitchAPICompatibility(let operation, let reason):
                return (.twitchAPIFailure, "Compatibility update required for \(operation) — \(reason)")
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
        case .apiError(let statusCode, _):
            return statusCode != 408
                && statusCode != 425
                && statusCode != 429
                && !(500...599).contains(statusCode)
        default:
            return true
        }
    }

    /// Authentication failures are different from ordinary fatal request failures:
    /// retrying the same saved credentials cannot repair them.  The miner must
    /// pause until the user completes the reconnect flow.
    static func requiresManualReauthentication(_ error: TwitchMinerError) -> Bool {
        switch error {
        case .authenticationFailed, .tokenExpired:
            return true
        default:
            return false
        }
    }

    // MARK: - Properties

    private let clientId: String
    var authService: TwitchAuthService
    var apiClient: TwitchAPIClient
    var dropsService: DropsService
    var watchSessionManager: WatchSessionManager
    var claimService: ClaimService
    var pubSubClient: PubSubClient
    var dropEventsService: DropEventsService
    var notificationService: NotificationService?

    var session: MiningSession?
    var isRunning = false
    private var mainTask: Task<Void, Never>?
    var maintenanceTask: Task<Void, Never>?
    /// A real watch session is user-requested work. Keep normal App Nap heuristics from
    /// deprioritising its heartbeat and recovery timers, while still allowing macOS to sleep.
    var activeWatchActivity: NSObjectProtocol?
    var currentAccount: Account?
    var shouldSwitchChannel = false
    /// Set to true to interrupt the idle wait and immediately re-check for eligible campaigns
    var shouldRescanCampaigns = false
    var consecutiveNoCandidateCycles = 0
    /// Rotating offsets keep bounded directory and approved-channel probes from repeatedly
    /// checking the same high-ranked prefix while permanently starving lower-ranked streams.
    var directoryVerificationOffsets: [String: Int] = [:]
    var approvedChannelProbeOffsets: [String: Int] = [:]

    /// Structured activity events for the diagnostics timeline, oldest first. Bounded so a
    /// long-running engine never accumulates unbounded history.
    var recentActivityEvents: [MinerManager.MinerEvent] = []
    static let maxRecentActivityEvents = 50

    /// Counter for minutes watched without a server progress update (local estimation)
    var extraMinutesWatched: Int = 0
    /// Timestamp of the last verified progress update (GQL or PubSub)
    var lastProgressUpdateAt: Date = Date()
    /// Monotonic counterpart used for runtime stall decisions. `Date` is retained for
    /// diagnostics, while this value is immune to wall-clock corrections.
    var lastProgressUpdateTick: UInt64
    let runtimeClock: RuntimeClock
    /// Maximum extra minutes allowed before assuming mining is stalled (matches TDM)
    static let maxExtraMinutes = 15

    /// Consecutive genuine stall windows (no verified progress, no external
    /// claim) per campaign. Reset whenever the campaign makes real progress.
    var consecutiveStallsByCampaign: [String: Int] = [:]
    /// Campaigns temporarily skipped after repeated non-earning stalls, keyed to
    /// the time the skip expires, so the miner moves on instead of looping the
    /// same dead campaign forever.
    var campaignStallCooldownUntil: [String: UInt64] = [:]
    /// After this many back-to-back stall windows with no verified progress and
    /// no external claim (and no failover streamer to try), a campaign is
    /// treated as non-earning and put on cooldown.
    static let nonEarningStallThreshold = 3
    /// How long a non-earning campaign is skipped before it's retried.
    static let nonEarningCooldownInterval: TimeInterval = 30 * 60

    /// An unverified emergency fallback must prove that it can earn within a few polls.
    /// Otherwise a Twitch verification outage could strand the miner on a guessed channel
    /// for the full general stall window.
    static let unverifiedSelectionPollLimit = 3
    static let unverifiedChannelCooldownInterval: TimeInterval = 10 * 60
    var unverifiedChannelCooldownUntil: [String: UInt64] = [:]

    static func shouldAbandonUnverifiedSelection(
        isUnverified: Bool,
        emptyPolls: Int,
        limit: Int = unverifiedSelectionPollLimit
    ) -> Bool {
        isUnverified && emptyPolls >= limit
    }

    static func externallyClaimedDrops(
        in drops: [Drop],
        snapshot: InventorySnapshot
    ) -> [Drop] {
        drops.filter { drop in
            let benefitIDs = drop.benefitIds.isEmpty
                ? (drop.benefitID.isEmpty ? [] : [drop.benefitID])
                : drop.benefitIds
            return !drop.isClaimed && benefitIDs.contains { snapshot.benefitIDs.contains($0) }
        }
    }

    func resetProgressStallClock(at date: Date = Date()) {
        lastProgressUpdateAt = date
        lastProgressUpdateTick = runtimeClock.nowNanoseconds()
    }

    func progressStallElapsedSeconds() -> TimeInterval {
        runtimeClock.elapsedSeconds(since: lastProgressUpdateTick)
    }

    /// Whether a campaign is currently on a non-earning cooldown.
    static func isOnStallCooldown(
        _ campaignId: String,
        cooldowns: [String: UInt64],
        now: UInt64
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
    /// How often approved channels for ACL-restricted campaigns are re-probed while waiting.
    /// `ChannelLivenessCache.ttl` must stay strictly below this so a cached miss has always
    /// expired by the next probe, and the cache can never delay noticing a channel go live.
    static let aclProbeInterval: TimeInterval = 60
    /// How long Twitch may stay silent while a miner is watching before the ordered event stream
    /// reconciles against inventory. Real-time events are authoritative when they arrive; this
    /// only spends a request when they stop, so a healthy miner never pays for it.
    static let progressReconcileInterval: TimeInterval = 5 * 60
    static let failoverCooldown: TimeInterval = 10 * 60
    static let subscriptionWarningRepeatInterval: TimeInterval = 6 * 60 * 60
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
    /// Consecutive failures of the approved-channel liveness query before it is treated as
    /// broken rather than unlucky. Three probes is well inside one 60s ACL cycle, so a genuine
    /// outage is reported within a minute or so of starting.
    static let approvedChannelProbeFailureThreshold = 3
    var consecutiveApprovedChannelProbeFailures = 0
    var lastApprovedChannelProbeFailure: (detail: String, at: Date)?

    /// How long a "no live channel" probe result keeps a game demoted before it is re-probed.
    /// Generous enough to span more than one campaign-check cycle so demotion is stable, short
    /// enough that a game coming online is picked up on the next full rescan.
    static let gameLiveProbeFreshness: TimeInterval = 15 * 60

    // Configuration
    let campaignCheckInterval: UInt64 = 300 * 1_000_000_000 // 5 minutes
    let claimCheckInterval: UInt64 = 2 * 60 * 1_000_000_000 // 2 minutes (conditional polling)
    /// The active-watch loop wakes on this cadence and fires each check on its
    /// own interval, so a 60s check actually happens every ~60s rather than
    /// being rounded up to the sum of a long sleep plus the claim wait.
    let watchLoopTickInterval: UInt64 = 10 * 1_000_000_000 // 10 seconds

    // Mining preferences (set from AppModel/Settings)
    var priorityGames: [String] = []
    var excludedGames: [String] = []
    var enableBadgesEmotes: Bool = false
    var showClaimNotifications: Bool = false
    var ignoredAccountLinkWarningGames: Set<String> = []
    var warnedUnlinkedPriorityGames: Set<String> = []
    var subscriptionWarningKeys: [String: Date] = [:]
    var failoverStreamers: [GameFailoverStreamer] = []
    var failoverCooldowns: [String: Date] = [:]
    var pendingFailoverTarget: PendingFailoverTarget?
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

    struct PendingFailoverTarget: Sendable {
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
    /// Fires with the minutes of verified drop progress each observation added.
    public var onEarnedProgress: (@Sendable (Int) -> Void)?
    public var onDropClaimed: (@Sendable (Drop) -> Void)?
    public var onError: (@Sendable (TwitchMinerError) -> Void)?
    public var onLogMessage: (@Sendable (String) -> Void)?
    public var onOperationalEvent: (@Sendable (OperationalEvent) -> Void)?
    public var onLinkWarning: (@Sendable (String) -> Void)?
    public var onStreamOverrideChange: (@Sendable (String?) -> Void)?
    public var onGameChannelAvailability: (@Sendable (GameChannelAvailability) -> Void)?
    
    /// Stored here rather than in MinerEngine+Callbacks.swift, where its setter lives,
    /// only because an extension cannot declare stored properties.
    var miningStrategy: MiningStrategy = .mineAll

    // MARK: - Initialization

    public init(
        clientId: String,
        tokenStore: any TokenStore = TokenStoreFactory.makeDefault(),
        runtimeClock: RuntimeClock = .continuous
    ) {
        self.clientId = clientId
        self.runtimeClock = runtimeClock
        self.lastProgressUpdateTick = runtimeClock.nowNanoseconds()
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

    /// A drop event as it arrives from Twitch's real-time channel.
    ///
    /// Modelled as one type so every event flows through a single ordered consumer. Each
    /// callback previously spawned its own unstructured `Task`, so events raced one another:
    /// `handleDropProgress` reads current progress, decides whether Twitch advanced, then
    /// refreshes — a read-modify-write that two concurrent events for the same drop could
    /// interleave, double-acknowledging or applying out of order.
    enum MiningEvent: Sendable {
        case dropProgress(DropProgressEvent)
        case dropClaim(DropClaimEvent)
        case streamDown(channelId: String)
        /// Current-session GQL samples share the same consumer as PubSub observations. This
        /// prevents a fresh poll and an event-triggered inventory refresh from updating the
        /// progress ledger along independent paths.
        case gqlProgress(DropProgressObservation)
        /// Periodic nudge to reconcile against Twitch's inventory, routed through the same
        /// consumer as real-time and current-session GQL progress.
        case reconcileTick
    }

    /// Serialises every drop event through one consumer.
    private var eventConsumerTask: Task<Void, Never>?
    private var eventTickTask: Task<Void, Never>?
    private var eventContinuation: AsyncStream<MiningEvent>.Continuation?

    /// Builds the ordered event stream and starts its single consumer.
    ///
    /// Real-time events, current-session GQL samples, and reconciliation ticks all use this
    /// stream rather than separate paths that have to agree. One consumer means one ordering,
    /// and cancellation is structural.
    private func startEventConsumer() {
        stopEventConsumer()

        // Mining signals must never be discarded. A dropped claim or stream-down event can
        // leave a miner watching the wrong channel or delay claiming an earned reward. The
        // producer is ordered at the PubSub receive loop, and this lossless stream keeps that
        // order until the single consumer handles each event.
        let (stream, continuation) = AsyncStream<MiningEvent>.makeStream(bufferingPolicy: .unbounded)
        eventContinuation = continuation

        eventConsumerTask = Task { [weak self] in
            for await event in stream {
                if Task.isCancelled { return }
                guard let self else { return }
                await self.handle(event)
            }
        }

        let clock = runtimeClock
        eventTickTask = Task { [weak self] in
            let ticks = AsyncTimerSequence(
                interval: .seconds(Self.progressReconcileInterval),
                clock: clock
            )
            for await _ in ticks {
                guard !Task.isCancelled, let self else { return }
                await self.enqueueMiningEvent(.reconcileTick)
            }
        }
    }

    /// Adds an event from an ordered producer. This actor hop is intentionally short: the
    /// PubSub receive loop must be able to continue reading PONGs while slow network work is
    /// performed by the separate consumer task.
    func enqueueMiningEvent(_ event: MiningEvent) {
        eventContinuation?.yield(event)
    }

    /// Handles one event. Called only from the single consumer, so these never overlap.
    private func handle(_ event: MiningEvent) async {
        switch event {
        case .dropProgress(let progress):
            await handleDropProgress(progress)
        case .dropClaim(let claim):
            await handleDropClaim(claim)
        case .streamDown(let channelId):
            await handleStreamDown(channelId)
        case .gqlProgress(let observation):
            await handleGQLProgress(observation)
        case .reconcileTick:
            // A safety net, not a poll. When PubSub is healthy this costs nothing: real-time
            // progress keeps resetting the stall clock, and the guard below never fires. It only
            // spends a request when the miner is watching and Twitch has gone quiet for longer
            // than an interval — the exact signature of the silent-PubSub failure that left the
            // whole fleet earning nothing while appearing healthy.
            guard isRunning,
                  session?.status == .watching,
                  let campaignId = session?.currentCampaignId,
                  progressStallElapsedSeconds() >= Self.progressReconcileInterval else { return }

            log("No drop progress from Twitch for \(Int(progressStallElapsedSeconds()))s while watching — reconciling against inventory.")
            await refreshCampaignProgress(campaignId: campaignId, context: "silent-progress reconcile")
        }
    }

    /// Stream-state logging. Kept off the ordered path — see `configureDropEventsService`.
    private func logStreamState(_ event: StreamStateEvent) {
        switch event.kind {
        case .up:
            log("Stream \(event.channelId) is LIVE")
        case .down:
            log("Stream \(event.channelId) went OFFLINE")
        case .viewcount(let count):
            log("Stream \(event.channelId) viewers: \(count)")
        case .commercial(let duration):
            log("Stream \(event.channelId) commercial: \(duration)s")
        }
    }

    private func stopEventConsumer() {
        eventContinuation?.finish()
        eventContinuation = nil
        eventConsumerTask?.cancel()
        eventConsumerTask = nil
        eventTickTask?.cancel()
        eventTickTask = nil
    }

    /// Configure DropEventsService callbacks. Call this after init but before start().
    private func configureDropEventsService() async {
        // `DropEventsService` awaits these short actor hops from its ordered receive loop. This
        // maintains Twitch's delivery order without making socket reading wait for a claim or
        // inventory refresh.
        await dropEventsService.setDropProgressHandler { [weak self] event in
            await self?.enqueueMiningEvent(.dropProgress(event))
        }

        await dropEventsService.setDropClaimHandler { [weak self] event in
            await self?.enqueueMiningEvent(.dropClaim(event))
        }

        await dropEventsService.setStreamDownHandler { [weak self] channelId in
            await self?.enqueueMiningEvent(.streamDown(channelId: channelId))
        }

        // Deliberately NOT routed through the event stream. `viewcount` fires repeatedly for
        // every watched channel, and this handler only logs — it touches no shared state and
        // needs no ordering. Keeping it off the mining queue prevents logging bursts from
        // delaying a claim, stream-down, or progress event.
        await dropEventsService.setStreamStateHandler { [weak self] event in
            Task { await self?.logStreamState(event) }
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

        // Startup timing is logged because the wait before the first watch is made of
        // several network round trips whose individual costs are otherwise invisible.
        let startedAt = Date()

        isRunning = true
        let workerTaskID = UUID().uuidString
        session = MiningSession()
        progressEventTracker = DropProgressEventTracker()
        resetProgressStallClock()
        warnedUnlinkedPriorityGames.removeAll()
        startEventConsumer()
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
            stopEventConsumer()
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

        // Load token into apiClient (required before any GQL requests) and PubSub.
        // Token acquisition and the PubSub connection are attempted separately: a token failure
        // used to skip the connect call *and* the client updates below it, silently leaving the
        // whole fleet on polling with no real-time drop progress and nothing surfaced to the user.
        let tokenStartedAt = Date()
        do {
            let token = try await apiClient.getAccessToken()
            log("Access credentials loaded in \(Self.elapsed(since: tokenStartedAt))")
            await apiClient.updateAccessToken(token)
            await pubSubClient.updateAccessToken(token)
        } catch {
            log("Could not load access token: \(error.localizedDescription)")
            // A rejected token cannot be recovered by retrying the watch loop; it needs the user.
            if let minerError = error as? TwitchMinerError {
                if Self.requiresManualReauthentication(minerError) {
                    onError?(minerError)
                    await pauseForManualReauthentication()
                    throw minerError
                }
            }
        }

        let pubSubStartedAt = Date()
        do {
            try await pubSubClient.connect()
            log("PubSub connected in \(Self.elapsed(since: pubSubStartedAt))")
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

        log("Engine ready in \(Self.elapsed(since: startedAt)); handing over to the mining loop")

        // Start main mining loop
        mainTask = Task { [weak self] in
            guard let self = self else { return }
            await self.runMiningLoop()
        }
        onOperationalEvent?(.stateUpdate)

        // Start maintenance loop (30 minute intervals)
        startMaintenanceLoop()
    }
    
    static func elapsed(since start: Date) -> String {
        String(format: "%.2fs", Date().timeIntervalSince(start))
    }

    /// Stops the mining engine
    public func stop() async {
        log("Stopping miner...")
        isRunning = false
        progressEventTracker = DropProgressEventTracker()
        stopEventConsumer()
        mainTask?.cancel()
        mainTask = nil
        maintenanceTask?.cancel()
        maintenanceTask = nil
        
        // Stop PubSub watching
        try? await dropEventsService.stopWatching()
        
        await watchSessionManager.stopWatching()
        endActiveWatchActivity()
        
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
    public func forceRefresh() async {
        log("Forcing immediate campaign rescan...")
        shouldRescanCampaigns = true
        // A fresh worker already has a campaign scan in flight. Interrupting its
        // first watch setup here used to race the new session against cleanup.
        // Once a session exists, switching away is safe and makes the refresh
        // immediate; otherwise the in-flight initial scan satisfies the request.
        if await watchSessionManager.currentSession != nil {
            shouldSwitchChannel = true
        }
        onOperationalEvent?(.stateUpdate)
    }

    public func forceInventoryRefresh() async throws {
        let inventoryService = await dropsService.getInventoryService()
        let snapshot = try await inventoryService.fetchInventory(forceRefresh: true)
        syncCampaigns(with: snapshot)
        recordActivityEvent(.recoveryComplete, "Forced inventory refresh completed")
        onOperationalEvent?(.inventoryRefresh)
        if let progress = try? await dropsService.getOverallProgress() {
            onProgressUpdate?(progress)
        }
    }

    /// Refreshes the token and rebuilds the session on top of it.
    ///
    /// This is supervisor recovery stage 3, so it only runs on a miner that has already been
    /// found stalled. The PubSub reconnect below used to be `try?` followed unconditionally by
    /// "refresh completed": a failed reconnect handed the miner back to the supervisor looking
    /// recovered while real-time drop progress was dead and only GraphQL polling remained. That
    /// GraphQL-healthy/PubSub-dead pairing is the shape earning losses take, and it is exactly
    /// what the startup path at `startPubSub` already refuses to hide.
    public func refreshAuthenticationSession() async throws {
        let token = try await authService.refreshTokenIfNeeded()
        await apiClient.updateAccessToken(token)
        await pubSubClient.updateAccessToken(token)
        if let account = currentAccount {
            await apiClient.setUserLogin(account.username)
            await apiClient.setAccountId(account.id)
            await authService.setAccountId(account.id)
        }

        var pubSubReconnected = true
        do {
            try await pubSubClient.connect()
            log("PubSub reconnected after authentication refresh")
        } catch {
            // Not thrown: the token refresh above did succeed, and failing the whole recovery
            // would discard that. The watch loop reconnects PubSub on its next cycle. But the
            // miner is on polling-only progress until it does, and that has to be visible.
            pubSubReconnected = false
            log("PubSub reconnect failed after authentication refresh: \(error.localizedDescription). Real-time drop progress is unavailable until the watch loop reconnects.")
            Logger.engine.error("PubSub reconnect failed during recovery for \(self.currentAccount?.username ?? "unknown"): \(error.localizedDescription)")
        }

        onOperationalEvent?(.authRefreshed)
        log(pubSubReconnected
            ? "Authentication/session refresh completed"
            : "Authentication/session refresh completed without PubSub")
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
    
    // MARK: - Private Methods

    func handleError(_ error: TwitchMinerError) {
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
        case .apiError(let statusCode, _) where statusCode == 408
            || statusCode == 425
            || statusCode == 429
            || (500...599).contains(statusCode):
            log("Temporary Twitch failure; will retry...")
        default:
            break
        }
    }

    /// Stops background work after Twitch has rejected the saved session.  This
    /// deliberately does not discard the credentials: the reconnect sheet needs
    /// the existing account identity to replace them safely.  It does, however,
    /// prevent the five-minute campaign loop from repeatedly issuing the same
    /// rejected request while the app is waiting for the user.
    func pauseForManualReauthentication() async {
        guard isRunning else { return }

        isRunning = false
        progressEventTracker = DropProgressEventTracker()
        stopEventConsumer()
        maintenanceTask?.cancel()
        maintenanceTask = nil
        try? await dropEventsService.stopWatching()
        await watchSessionManager.stopWatching()
        endActiveWatchActivity()
        session?.status = .error
        session?.endedAt = Date()
        log("Twitch rejected the saved session. Mining is paused until this account is reconnected.")
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

    func requiredMinutes(for dropId: String, campaignId: String?) -> Int? {
        findDrop(dropId: dropId, campaignId: campaignId)?.requiredMinutes
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
    
    var lastSwitchReason: MinerManager.SwitchReason?
    var lastSwitchAt: Date?
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
