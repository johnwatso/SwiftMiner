// Engine callback wiring, anti-stall monitoring, status/health plumbing,
// and priority updates for MinerManager. Split from MinerManager.swift;
// same class, same @MainActor isolation.
import Foundation

extension MinerManager {
    // MARK: - Private Methods
    
    func resetDailyClaimsIfNeeded() {
        let calendar = Calendar.current
        if !calendar.isDateInToday(lastClaimDate) {
            claimedTodayIds.removeAll()
            lastClaimDate = Date()
        }
    }
    
    func setupEngineCallbacks(engine: MinerEngine, minerId: String) async {
        await engine.setChannelAssignmentAvoidanceProvider { [weak self] campaignId, viableChannelCount in
            guard let self else { return [] }
            return await self.assignedChannelIds(
                campaignId: campaignId,
                excluding: minerId,
                viableChannelCount: viableChannelCount
            )
        }

        await engine.setStreamOverrideChangeHandler { [weak self] login in
            Task { @MainActor [weak self] in
                guard let self,
                      let index = self.miners.firstIndex(where: { $0.id == minerId }) else { return }
                self.miners[index].streamOverrideLogin = ManagedMiner.normalizedStreamOverrideLogin(login)
                self.onMinersChanged?()
            }
        }

        await engine.setGameChannelAvailabilityHandler { [weak self] availability in
            Task { @MainActor [weak self] in
                guard let self,
                      let index = self.miners.firstIndex(where: { $0.id == minerId }) else { return }
                self.miners[index].gameChannelAvailability[availability.gameKey] = availability
                self.onMinersChanged?()
            }
        }

        await engine.setStatusChangeHandler { [weak self] status in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                let minerStatus = self.mapSessionStatus(status)
                await self.supervisor.recordStateUpdate(minerId: minerId)

                // Detect welcome-back: miner recovered from error to active
                if let miner = self.getMiner(id: minerId),
                   miner.status == .error,
                   (minerStatus == .watching || minerStatus == .fetchingCampaigns || minerStatus == .claiming) {
                    self.onWelcomeBackEvent?(minerId)
                }

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
                await self.applySupervisorSnapshot(for: minerId)
                self.recordCurrentHealthState(minerID: minerId)
            }
        }

        // Verified per-drop progress. This is the authoritative earning signal for both the
        // not-earning health check and the ledger: the aggregate totals carried by
        // `onProgressUpdate` are a snapshot of in-flight progress, not a counter, so they
        // fall when a drop is claimed or a campaign leaves the set and jump when one with
        // existing progress joins it.
        await engine.setEarnedProgressHandler { [weak self] minutes in
            Task { @MainActor [weak self] in
                guard let self, minutes > 0 else { return }
                self.recordHealth(.miningProgressObserved(minerID: minerId, at: Date()))
                await self.supervisor.recordDropProgress(minerId: minerId)
                await self.applySupervisorSnapshot(for: minerId)
                if let accountId = self.getMiner(id: minerId)?.accountId {
                    await self.earningLedgerStore?.recordEarned(accountID: accountId, minutes: minutes)
                }
            }
        }
        
        await engine.setCampaignUpdateHandler { [weak self] campaigns in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                await self.supervisor.recordCampaignRefresh(minerId: minerId)

                // Get all campaigns and current ID from engine
                let previousCampaigns = self.getMiner(id: minerId)?.allCampaigns ?? []
                let previousCampaignIds = Set(previousCampaigns.map(\.id))
                let canEmitNewCampaigns = self.initializedCampaignSnapshots.contains(minerId)
                let all = await engine.allCampaigns
                let currentId = await engine.currentCampaignId

                if canEmitNewCampaigns {
                    for campaign in all where campaign.isTimeActive && !previousCampaignIds.contains(campaign.id) {
                        self.onCampaignDetectedEvent?(minerId, campaign)
                    }
                }
                self.initializedCampaignSnapshots.insert(minerId)

                // Detect newly completed campaigns
                for campaign in all where campaign.drops.allSatisfy({ $0.isClaimed }) {
                    self.onCampaignCompletedEvent?(minerId, campaign)
                }

                // Update current campaign info
                if let currentId, let current = all.first(where: { $0.id == currentId }) {
                    self.updateMinerStatus(minerId: minerId, currentCampaign: current.name, currentCampaignId: .some(currentId), allCampaigns: all)
                } else if let override = self.getMiner(id: minerId)?.streamOverrideLogin {
                    // Override watching a streamer with no mineable drop — surface the streamer,
                    // not an unrelated campaign name.
                    self.updateMinerStatus(minerId: minerId, currentCampaign: "Watching @\(override)", currentCampaignId: .some(currentId), allCampaigns: all)
                } else if let first = campaigns.first {
                    self.updateMinerStatus(minerId: minerId, currentCampaign: first.name, currentCampaignId: .some(currentId), allCampaigns: all)
                } else {
                    self.updateMinerStatus(minerId: minerId, currentCampaignId: .some(currentId), allCampaigns: all)
                }

                if currentId != nil {
                    await self.getMiner(id: minerId)?.stateStore?.refresh()
                    self.onMinersChanged?()
                }
                await self.applySupervisorSnapshot(for: minerId)
            }
        }

        await engine.setOperationalEventHandler { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                switch event {
                case .workerStarted(let taskID):
                    await self.supervisor.recordWorkerStart(minerId: minerId, taskID: taskID)
                case .workerStopped:
                    await self.supervisor.recordWorkerStop(minerId: minerId)
                case .successfulPoll, .inventoryRefresh:
                    await self.supervisor.recordSuccessfulPoll(minerId: minerId)
                    self.recordHealth(.twitchResponseSucceeded(minerID: minerId, at: Date()))
                case .campaignRefresh:
                    await self.supervisor.recordCampaignRefresh(minerId: minerId)
                case .authRefreshed:
                    await self.supervisor.recordStateUpdate(minerId: minerId, workerState: .running)
                case .heartbeat, .stateUpdate:
                    await self.supervisor.recordStateUpdate(minerId: minerId)
                case .approvedChannelChecksFailing(let detail, let isCompatibility):
                    // Only a compatibility failure earns the notification: it will not clear
                    // on its own, and while it lasts restricted campaigns — esports windows
                    // above all — cannot be detected at all. A network failure is recorded by
                    // the issue below and shown in Needs attention, without waking anyone.
                    guard isCompatibility, let miner = self.getMiner(id: minerId) else { break }
                    self.recordHealth(.incidentObserved(
                        minerID: miner.id,
                        kind: .channelChecksIncompatible,
                        severity: .critical,
                        summary: detail,
                        recommendedAction: "Update SwiftMiner so it can check restricted campaigns again",
                        at: Date()
                    ))
                case .approvedChannelChecksRecovered:
                    guard let miner = self.getMiner(id: minerId) else { break }
                    self.recordHealth(.incidentResolved(
                        minerID: miner.id,
                        kind: .channelChecksIncompatible,
                        at: Date()
                    ))
                case .issueDetected(let category, let detail):
                    let cause = Self.mapIssueCategoryToStallCause(category)
                    await self.supervisor.recordIssue(minerId: minerId, cause: cause, detail: detail)
                }
                await self.applySupervisorSnapshot(for: minerId)
            }
        }
        
        await engine.setDropClaimedHandler { [weak self] drop in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                await self.supervisor.recordEvent(minerId: minerId)
                self.resetDailyClaimsIfNeeded()
                self.claimedTodayIds.insert(drop.id)
                self.incrementDropsClaimed(minerId: minerId)
                if let accountId = self.getMiner(id: minerId)?.accountId {
                    await self.earningLedgerStore?.recordEarned(accountID: accountId, claims: 1)
                }

                // Find campaign name for the DM event
                let campaignName = self.getMiner(id: minerId)?.allCampaigns.first(where: {
                    $0.drops.contains(where: { $0.id == drop.id })
                })?.name
                self.onDropClaimedEvent?(minerId, drop, campaignName)

                await self.applySupervisorSnapshot(for: minerId)
            }
        }
        
        await engine.setLogMessageHandler { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                await self.supervisor.recordEvent(minerId: minerId)
                self.onLogMessage?(minerId, message)
                await self.applySupervisorSnapshot(for: minerId)
            }
        }

        await engine.setErrorHandler { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self = self,
                      let miner = self.getMiner(id: minerId) else { return }

                let (category, detail) = MinerEngine.classifyIssue(error)
                await self.supervisor.recordIssue(
                    minerId: minerId,
                    cause: Self.mapIssueCategoryToStallCause(category),
                    detail: detail
                )
                await self.supervisor.recordWorkerStop(minerId: minerId, failed: true)
                let needsAuth = Self.requiresManualReauth(for: error)
                if needsAuth {
                    self.onAuthRequiredEvent?(minerId)
                }
                await self.dataCoordinator.updateAccountNeedsAuth(accountId: miner.accountId, needsAuth: needsAuth)
                self.updateMinerStatus(
                    minerId: minerId,
                    status: .error,
                    isRunning: needsAuth ? false : nil,
                    needsAuth: needsAuth
                )
                await self.applySupervisorSnapshot(for: minerId)
            }
        }

        await engine.setLinkWarningHandler { [weak self] gameName in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                self.onLinkWarningEvent?(minerId, gameName)
            }
        }
    }

    private static func mapIssueCategoryToStallCause(_ category: MinerEngine.IssueCategory) -> MinerSupervisor.StallCause {
        switch category {
        case .networkError: return .networkError
        case .twitchAPIFailure: return .twitchAPIFailure
        case .rateLimited: return .rateLimited
        case .authIssue: return .authIssue
        case .watchSessionFailure: return .watchSessionFailure
        case .unknown: return .unknown
        }
    }

    func startAntiStallMonitorIfNeeded() {
        guard antiStallRecoveryEnabled, antiStallMonitorTask == nil else { return }

        antiStallMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await RuntimeClock.continuous.sleep(nanoseconds: 30 * 1_000_000_000)
                } catch {
                    break
                }
                if Task.isCancelled { break }
                await self?.runAntiStallCheck()
            }
        }
    }

    func runAntiStallCheck() async {
        guard antiStallRecoveryEnabled else { return }

        let metadataByMiner = await supervisor.refreshHealth(for: miners)
        for (minerId, metadata) in metadataByMiner {
            updateMinerOperationalMetadata(minerId: minerId, metadata: metadata)
        }

        while let action = await supervisor.nextRecoveryAction(for: miners) {
            await performRecoveryAction(action)
        }
    }

    func assignedChannelIds(
        campaignId: String,
        excluding minerId: String,
        viableChannelCount: Int
    ) async -> Set<String> {
        guard avoidDuplicateStreams, viableChannelCount > 4 else { return [] }

        var assigned = Set<String>()
        for miner in miners where miner.id != minerId && miner.isRunning && miner.currentCampaignId == campaignId {
            guard let engine = engines[miner.id] else { continue }
            let state = await engine.getStallState()
            if let channelId = state.currentChannelId, !channelId.isEmpty {
                assigned.insert(channelId)
            }
        }

        return assigned
    }
    
    func mapSessionStatus(_ status: SessionStatus) -> MinerStatus {
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
    
    /// Update the priority games for all miners, resolving each miner's effective
    /// list individually. Call this when global settings change: the resolver returns
    /// a miner's personal override when it has one, otherwise the global list. This
    /// preserves per-miner prioritisation instead of flattening everyone to the global
    /// list (which previously wiped DM-set priorities on launch and on global reorders).
    public func updatePriorityGames(resolving resolver: (ManagedMiner) -> [String]) {
        for index in miners.indices {
            let resolved = resolver(miners[index])
            miners[index].priorityGames = resolved

            // Sync with active engine if it exists
            if let engine = engines[miners[index].id] {
                let accountId = miners[index].accountId
                Task {
                    await engine.updatePriorityGames(resolved)
                    await engine.updateAccountLinkWarningPreference(games: Array(ignoredAccountLinkWarnings[accountId] ?? []))
                }
            }
        }
        onMinersChanged?()
    }

    /// Update the priority games for one miner without changing the other miners.
    public func updatePriorityGames(_ priorityGames: [String], forMinerId minerId: String) {
        guard let index = miners.firstIndex(where: { $0.id == minerId }) else { return }
        miners[index].priorityGames = priorityGames
        if let engine = engines[minerId] {
            let accountId = miners[index].accountId
            Task {
                await engine.updatePriorityGames(priorityGames)
                await engine.updateAccountLinkWarningPreference(games: Array(ignoredAccountLinkWarnings[accountId] ?? []))
            }
        }
        onMinersChanged?()
    }

    /// Update one miner's effective exclusion list without affecting anyone else.
    public func updateExcludedGames(_ excludedGames: [String], forMinerId minerId: String) {
        guard let index = miners.firstIndex(where: { $0.id == minerId }) else { return }
        let miner = miners[index]
        currentExcludedGamesByAccount[miner.accountId] = excludedGames
        if let engine = engines[minerId] {
            let ignoredGames = Array(ignoredAccountLinkWarnings[miner.accountId] ?? [])
            Task {
                await engine.updateMiningPreferences(
                    priorityGames: miner.priorityGames,
                    excludedGames: excludedGames,
                    enableBadgesEmotes: currentEnableBadgesEmotes,
                    showClaimNotifications: showClaimNotifications,
                    avoidDuplicateStreams: avoidDuplicateStreams,
                    prioritiseFollowedStreamers: prioritiseFollowedStreamers,
                    failoverStreamers: currentFailoverStreamers,
                    ignoredAccountLinkWarningGames: ignoredGames
                )
                await engine.forceRefresh()
            }
        }
        onMinersChanged?()
    }

    /// Pushes a new failover list to every engine.
    ///
    /// Each engine used to get its own detached task, so two saves in quick succession could
    /// reach a given engine out of order — and, worse, reach different engines in different
    /// orders, leaving the fleet running on two different failover lists with the manager
    /// holding a third. Delivering them in a group the caller awaits keeps every engine on the
    /// list that was saved last.
    public func updateFailoverStreamers(_ streamers: [GameFailoverStreamer]) async {
        failoverStreamers = streamers
        currentFailoverStreamers = streamers
        let targets = Array(engines.values)
        await withTaskGroup(of: Void.self) { group in
            for engine in targets {
                group.addTask { await engine.updateFailoverStreamers(streamers) }
            }
        }
    }

    /// Add an account that was just activated through the bot-driven device flow.
    /// Skips re-saving (the auth service already saved to the token store) but registers
    /// the miner with the manager and starts mining for it.
    public func attachActivatedAccount(_ account: Account) async {
        guard !miners.contains(where: { $0.accountId == account.id }) else { return }
        do {
            _ = try addAccount(account)
        } catch {
            Logger.engine.error("attachActivatedAccount failed: \(error)")
        }
    }

    /// Update the Discord owner for a miner by Twitch account ID. Pass `nil` to unlink.
    /// Persists to the token store so the link survives across restarts.
    public func setOwnerDiscordId(forAccountId accountId: String, to discordId: String?) {
        guard let index = miners.firstIndex(where: { $0.accountId == accountId }) else { return }
        miners[index].ownerDiscordId = discordId
        onMinersChanged?()

        // The in-memory change above is already visible in the UI. If the write below fails the
        // link is gone after the next launch with nothing to explain it — and `ownerDiscordId` is
        // what resolves the account's Discord profile picture — so neither half stays silent.
        Task { [tokenStore] in
            let existing: Account?
            do {
                existing = try await tokenStore.loadAccount(twitchUserId: accountId)
            } catch {
                Logger.storage.error("Could not read account \(accountId) to set its Discord owner: \(error.localizedDescription). The link is not persisted.")
                return
            }
            guard let existing else {
                Logger.storage.error("No stored account \(accountId) to set a Discord owner on; the link is not persisted.")
                return
            }
            let updated = Account(
                id: existing.id,
                username: existing.username,
                nickname: existing.nickname,
                ownerDiscordId: discordId,
                accessToken: existing.accessToken,
                refreshToken: existing.refreshToken,
                tokenExpiry: existing.tokenExpiry,
                scopes: existing.scopes,
                isOperator: existing.isOperator
            )
            do {
                try await tokenStore.save(account: updated)
            } catch {
                Logger.storage.error("Could not persist the Discord owner for account \(accountId): \(error.localizedDescription). The link will be gone after a restart.")
            }
        }
    }

    func updateMinerStatus(
        minerId: String,
        status: MinerStatus? = nil,
        currentCampaign: String? = nil,
        currentCampaignId: String?? = .none, // .none = don't touch; .some(x) = always set (x may be nil)
        allCampaigns: [Campaign]? = nil,
        isRunning: Bool? = nil,
        priorityGames: [String]? = nil,
        needsAuth: Bool? = nil,
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
        if let campaigns = allCampaigns {
            // Anything arriving here came from a live engine fetch, so the
            // launch-time disk seed is no longer what's on screen.
            miner.allCampaigns = campaigns
            miner.campaignsAreProvisional = false
        }
        if let running = isRunning { miner.isRunning = running }
        if let needsAuth = needsAuth { miner.needsAuth = needsAuth }
        if let priorityGames = priorityGames { miner.priorityGames = priorityGames }
        if let ownerId = ownerDiscordId { miner.ownerDiscordId = ownerId }

        miners[index] = miner
        onMinersChanged?()
    }
    
    func updateMinerStatus(minerId: String, isRunning: Bool, status: MinerStatus) {
        updateMinerStatus(minerId: minerId, status: status, isRunning: isRunning)
    }

    func updateMinerOperationalMetadata(minerId: String, metadata: MinerOperationalMetadata) {
        guard let index = miners.firstIndex(where: { $0.id == minerId }) else { return }
        let miner = miners[index]
        let durablePresentationChanged =
            miner.lastSuccessfulPollAt != metadata.lastSuccessfulPollAt
            || miner.lastCampaignRefreshAt != metadata.lastCampaignRefreshAt
            || miner.lastDropProgressAt != metadata.lastDropProgressAt
            || miner.workerStartedAt != metadata.workerStartedAt
            || miner.workerState != metadata.workerState
            || miner.workerTaskID != metadata.workerTaskID
            || miner.isHealthy != metadata.isHealthy
            || miner.isStalled != metadata.isStalled
        let now = Date()
        if !durablePresentationChanged,
           let lastPresentation = lastOperationalPresentationAt[minerId],
           now.timeIntervalSince(lastPresentation) < Self.operationalPresentationInterval {
            return
        }
        lastOperationalPresentationAt[minerId] = now

        miners[index].lastEventAt = metadata.lastEventAt
        miners[index].lastSuccessfulPollAt = metadata.lastSuccessfulPollAt
        miners[index].lastCampaignRefreshAt = metadata.lastCampaignRefreshAt
        miners[index].lastDropProgressAt = metadata.lastDropProgressAt
        miners[index].workerStartedAt = metadata.workerStartedAt
        miners[index].workerState = metadata.workerState
        miners[index].workerTaskID = metadata.workerTaskID
        miners[index].isHealthy = metadata.isHealthy
        miners[index].isStalled = metadata.isStalled
        accumulateWatchTime(for: miners[index])
        evaluateEarningHealth(for: miners[index])
        onMinersChanged?()
    }

    /// Credits time spent watching to the earning ledger.
    ///
    /// Sampled from supervisor snapshots rather than a timer: they already arrive every few
    /// seconds for a running miner, and a miner that stops producing them is one whose watch
    /// time we should stop crediting anyway.
    func accumulateWatchTime(for miner: ManagedMiner, now: Date = Date()) {
        guard miner.status == .watching else {
            lastWatchSampleAt[miner.id] = nil
            return
        }
        guard let previousSample = lastWatchSampleAt[miner.id] else {
            lastWatchSampleAt[miner.id] = now
            return
        }

        // Snapshots can arrive several times a second, so time is credited in chunks rather
        // than once per snapshot — same total, far fewer hops onto the ledger actor.
        let elapsed = now.timeIntervalSince(previousSample)
        guard elapsed >= Self.minWatchSampleInterval else { return }
        lastWatchSampleAt[miner.id] = now

        // A gap this long means the app slept or the miner went quiet; the clock restarts
        // but the gap itself is not credited as watching.
        guard elapsed <= Self.maxWatchSampleGap, let earningLedgerStore else { return }
        let accountID = miner.accountId
        Task {
            await earningLedgerStore.recordWatching(accountID: accountID, seconds: elapsed, at: now)
        }
    }

    /// Opens or clears the not-earning incident as the miner crosses the threshold.
    ///
    /// A miner that is watching but earning nothing never changes status, so the
    /// status-change path that normally records health state never fires for it. This runs
    /// on every supervisor snapshot instead — which keeps arriving, because liveness is
    /// exactly what stays healthy in this failure mode — but only writes on a transition so
    /// the health store isn't rewritten on every poll.
    func evaluateEarningHealth(for miner: ManagedMiner) {
        let isNotEarning = miner.isNotEarning()
        let wasNotEarning = earningStalledMinerIds.contains(miner.id)
        guard isNotEarning != wasNotEarning else { return }

        if isNotEarning {
            earningStalledMinerIds.insert(miner.id)
        } else {
            earningStalledMinerIds.remove(miner.id)
        }
        recordCurrentHealthState(minerID: miner.id)
    }

    func applySupervisorSnapshot(for minerId: String) async {
        guard let metadata = await supervisor.snapshot(for: minerId) else { return }
        updateMinerOperationalMetadata(minerId: minerId, metadata: metadata)
    }

    func performRecoveryAction(_ action: MinerSupervisor.RecoveryAction) async {
        guard let engine = engines[action.minerId] else { return }

        let healthStage = Self.healthRecoveryStage(action.stage)
        recordHealth(.recoveryStarted(
            minerID: action.minerId,
            stage: healthStage,
            detail: action.reason,
            at: Date()
        ))
        await supervisor.markRecovering(minerId: action.minerId, stage: action.stage)
        await applySupervisorSnapshot(for: action.minerId)
        onLogMessage?(
            action.minerId,
            "[Supervisor] stall detected | reason=\(action.reason) | stage=\(action.stage.rawValue) | attempt=\(action.attempt)"
        )

        do {
            try await withRuntimeTimeout(
                operationName: "Mining recovery stage \(action.stage.rawValue)",
                seconds: Self.recoveryTimeoutSeconds(for: action.stage)
            ) { [self] in
                try await executeRecoveryStage(action, engine: engine)
            }

            await supervisor.noteRecoverySuccess(minerId: action.minerId)
            await applySupervisorSnapshot(for: action.minerId)
            recordHealth(.recoveryFinished(
                minerID: action.minerId,
                stage: healthStage,
                succeeded: true,
                detail: "Recovery completed",
                at: Date()
            ))
            recordCurrentHealthState(minerID: action.minerId)
            onLogMessage?(action.minerId, "[Supervisor] recovery success")
        } catch {
            await supervisor.noteRecoveryFailure(minerId: action.minerId, stage: action.stage)
            await applySupervisorSnapshot(for: action.minerId)

            let needsAuth = Self.requiresManualReauth(for: error)
            if let miner = getMiner(id: action.minerId) {
                await dataCoordinator.updateAccountNeedsAuth(accountId: miner.accountId, needsAuth: needsAuth)
            }
            if needsAuth {
                updateMinerStatus(minerId: action.minerId, status: .error, needsAuth: true)
            } else {
                onAccountActionRequiredEvent?(action.minerId, action.reason)
            }
            recordHealth(.recoveryFinished(
                minerID: action.minerId,
                stage: healthStage,
                succeeded: false,
                detail: error.localizedDescription,
                at: Date()
            ))
            if action.stage == .authRefresh, !needsAuth {
                recordHealth(.incidentObserved(
                    minerID: action.minerId,
                    kind: .recoveryExhausted,
                    severity: .critical,
                    summary: "Automatic recovery could not restore mining",
                    recommendedAction: "Open SwiftMiner and review the Activity Log",
                    at: Date()
                ))
            } else {
                recordCurrentHealthState(minerID: action.minerId)
            }
            onLogMessage?(action.minerId, "[Supervisor] recovery failed | \(error.localizedDescription)")
        }
    }

    static func recoveryTimeoutSeconds(for stage: MinerSupervisor.RecoveryStage) -> TimeInterval {
        switch stage {
        case .refresh: return 90
        case .restart, .authRefresh: return 120
        }
    }

    private func executeRecoveryStage(
        _ action: MinerSupervisor.RecoveryAction,
        engine: MinerEngine
    ) async throws {
        switch action.stage {
        case .refresh:
            onLogMessage?(action.minerId, "[Supervisor] recovery stage 1 | forcing campaign refresh + inventory refresh")
            try await engine.forceInventoryRefresh()
            await engine.forceRefresh()
        case .restart:
            onLogMessage?(action.minerId, "[Supervisor] recovery stage 2 | restarting worker, subscriptions, and timers")
            await stopMiner(minerId: action.minerId)
            try Task.checkCancellation()
            try await startMiner(
                minerId: action.minerId,
                priorityGames: currentPriorityGames,
                excludedGames: miners.first(where: { $0.id == action.minerId })
                    .flatMap { currentExcludedGamesByAccount[$0.accountId] } ?? currentExcludedGames,
                strategy: currentStrategy,
                enableBadgesEmotes: currentEnableBadgesEmotes,
                showClaimNotifications: showClaimNotifications,
                avoidDuplicateStreams: avoidDuplicateStreams,
                antiStallRecoveryEnabled: antiStallRecoveryEnabled,
                prioritiseFollowedStreamers: prioritiseFollowedStreamers,
                failoverStreamers: currentFailoverStreamers
            )
        case .authRefresh:
            onLogMessage?(action.minerId, "[Supervisor] recovery stage 3 | refreshing auth/session state")
            try await engine.refreshAuthenticationSession()
            try Task.checkCancellation()
            try await engine.forceInventoryRefresh()
            await engine.forceRefresh()
        }
    }

    func recordCurrentHealthState(minerID: String, at: Date = Date()) {
        guard let miner = getMiner(id: minerID) else { return }
        recordHealth(.minerObserved(minerID: miner.id, displayName: miner.displayName, at: at))

        if miner.needsAuth {
            recordHealth(.incidentObserved(
                minerID: miner.id,
                kind: .authenticationExpired,
                severity: .critical,
                summary: "Twitch authentication expired",
                recommendedAction: "Sign in to Twitch again",
                at: at
            ))
        } else if miner.isStalled {
            recordHealth(.incidentObserved(
                minerID: miner.id,
                kind: .progressStalled,
                severity: .warning,
                summary: "The miner has stopped reporting healthy activity",
                recommendedAction: "Review miner diagnostics",
                at: at
            ))
        } else if miner.isNotEarning(now: at) {
            let minutes = Int(at.timeIntervalSince(miner.earningReferenceDate ?? at) / 60)
            recordHealth(.incidentObserved(
                minerID: miner.id,
                kind: .notEarning,
                severity: .warning,
                summary: "Watching for \(minutes) minutes without earning any drop progress",
                recommendedAction: "Check the campaign is still eligible for this account",
                at: at
            ))
        } else if miner.status == .blockedAccountNotLinked {
            recordHealth(.incidentObserved(
                minerID: miner.id,
                kind: .accountLinkRequired,
                severity: .warning,
                summary: "A game account link is required",
                recommendedAction: "Link the game account from Twitch Drops Inventory",
                at: at
            ))
        } else if miner.status == .error {
            recordHealth(.incidentObserved(
                minerID: miner.id,
                kind: .other,
                severity: .critical,
                summary: "The miner needs attention",
                recommendedAction: "Review the Activity Log",
                at: at
            ))
        } else if miner.isHealthy {
            recordHealth(.activeIncidentResolved(minerID: miner.id, at: at))
        }
    }

    /// Queues one health event for the unattended store.
    ///
    /// Fire-and-forget by design — recording health must never block the engine — but a storage
    /// failure still has to leave a trace. Discarding it silently meant the incident history
    /// could stop accumulating while everything upstream carried on as if it were being written.
    func recordHealth(_ event: UnattendedHealthEvent) {
        guard let unattendedHealthStore else { return }
        Task {
            do {
                try await unattendedHealthStore.record(event)
            } catch {
                Logger.storage.error("Could not record unattended health event: \(error.localizedDescription)")
            }
        }
    }

    private static func healthRecoveryStage(_ stage: MinerSupervisor.RecoveryStage) -> RecoveryRecord.Stage {
        switch stage {
        case .refresh:
            return .campaignRefresh
        case .restart:
            return .workerRestart
        case .authRefresh:
            return .authenticationRefresh
        }
    }

    static func requiresManualReauth(for error: Error) -> Bool {
        guard let minerError = error as? TwitchMinerError else { return false }

        return MinerEngine.requiresManualReauthentication(minerError)
    }
    
    func incrementDropsClaimed(minerId: String) {
        guard let index = miners.firstIndex(where: { $0.id == minerId }) else { return }
        var miner = miners[index]
        miner.dropsClaimed += 1
        miners[index] = miner
        onMinersChanged?()
    }

}
