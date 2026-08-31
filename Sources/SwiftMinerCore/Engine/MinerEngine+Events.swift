import AsyncAlgorithms
import Foundation

// The ordered consumer for real-time drop events, and the periodic maintenance task.
//
// Every event flows through one consumer on purpose: each callback used to spawn its own
// unstructured task, so two events for the same drop could interleave a read-modify-write and
// double-acknowledge or apply out of order.
//
// Split out of MinerEngine.swift, which had grown past the point where one file could be read.

extension MinerEngine {
    // MARK: - Event Handlers

    func handleDropProgress(_ event: DropProgressEvent) async {
        let campaignId = session?.currentCampaignId
        let observation = DropProgressObservation(
            campaignId: campaignId,
            dropId: event.dropId,
            dropLabel: dropLabel(for: event.dropId, campaignId: campaignId),
            currentMinutes: event.currentMinutes,
            requiredMinutes: event.requiredMinutes,
            source: .pubSub
        )
        let result = observeDropProgress(observation)
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
        resetProgressStallClock()
        noteCampaignProgress(campaignId)

        await refreshCampaignProgress(
            campaignId: campaignId,
            context: "PubSub progress"
        )
    }

    /// Applies a current-session GQL sample on the same ordered consumer as PubSub. The network
    /// request that obtained it may run concurrently with watching, but the stateful observation
    /// and campaign-wide refresh must not.
    func handleGQLProgress(_ observation: DropProgressObservation) async {
        let result = observeDropProgress(observation)
        traceGQL(
            "DropCurrentSessionContext drop=\(observation.dropId) parsedCurrent=\(observation.currentMinutes) " +
            "previous=\(result.previousMinutes.map(String.init) ?? "nil") transition=\(result.transition.traceDescription)"
        )

        guard result.shouldAcknowledgeServerProgress else { return }

        if let message = formatProgressTransition(result.transition) {
            log(message)
        }

        extraMinutesWatched = 0
        resetProgressStallClock()
        noteCampaignProgress(observation.campaignId)
        await refreshCampaignProgress(
            campaignId: observation.campaignId,
            context: "current-session progress"
        )
    }

    func handleDropClaim(_ event: DropClaimEvent) async {
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
                    recordActivityEvent(.dropClaimed, "Claimed \(drop.name)")
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

    func handleStreamDown(_ channelId: String) async {
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

    func handleWatchSessionError(_ error: TwitchMinerError) async {
        log("Watch session warning: \(error.localizedDescription)")
        let (category, detail) = Self.classifyIssue(error)
        onOperationalEvent?(.issueDetected(category: category, detail: detail))

        if case .watchSessionFailed(let message) = error,
           message.hasPrefix("Repeated heartbeat delivery failure") {
            shouldSwitchChannel = true
        }
    }

    func emitIssue(_ error: Error) {
        let (category, detail) = Self.classifyIssue(error)
        recordActivityEvent(.error, detail)
        onOperationalEvent?(.issueDetected(category: category, detail: detail))
    }

    /// Subscribes to real-time drop/stream events for the current channel.
    ///
    /// PubSub is connected at miner startup and on auth refresh, but nothing
    /// else re-establishes it: if that socket drops (or its initial connect
    /// failed) the miner would spend the rest of the session blind to real-time
    /// progress, relying on polling only. So if subscribing fails, attempt one
    /// reconnect and retry before giving up for this cycle.
    func startDropEventsWatching(userId: String, channelId: String) async {
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

    func handleWatchHeartbeatSent(_ session: WatchSession) async {
        if let transport = session.lastHeartbeatTransport {
            log("Watch heartbeat sent for \(session.channelName) via \(transport)")
        } else {
            log("Watch heartbeat sent for \(session.channelName)")
        }
        onOperationalEvent?(.heartbeat)
    }

    /// Waits out the gap between scans, waking early when there is a reason to.
    ///
    /// Expressed as a timer sequence over the engine's injectable clock rather than a hand-rolled
    /// loop of sleeps and modulo arithmetic, so cancellation propagates at the await point and
    /// the cadence is stated once. `RuntimeClock` conforms to `Clock`, which keeps the reliability
    /// tests in control of time here instead of waiting in real seconds.
    ///
    /// Restricted (ACL) campaigns — esports drops, typically — have approved channels the public
    /// directory never lists, and they go live for short windows. Re-probing them every
    /// `aclProbeInterval` means a broadcast starting mid-wait is picked up promptly instead of
    /// losing up to a full `campaignCheckInterval`.
    func waitForNextScan(restrictedCandidates: [Campaign]) async {
        // Twitch pushes stream-up on these channels. Listening for the wait means a match
        // starting is known in seconds rather than on the next probe — and it still works
        // when the liveness query is failing, because nothing has to be asked.
        await startMonitoringRestrictedChannels(in: restrictedCandidates)

        let tick = Duration.seconds(10)
        let totalTicks = max(1, Int(campaignCheckInterval / (10 * 1_000_000_000)))
        let ticksPerACLProbe = max(1, Int(Self.aclProbeInterval / 10))

        var elapsedTicks = 0
        let timer = AsyncTimerSequence(interval: tick, clock: runtimeClock)

        for await _ in timer {
            if Task.isCancelled || shouldRescanCampaigns { break }

            elapsedTicks += 1
            if elapsedTicks >= totalTicks { break }

            guard !restrictedCandidates.isEmpty,
                  elapsedTicks % ticksPerACLProbe == 0 else { continue }

            if await anyApprovedChannelLive(in: restrictedCandidates) {
                log("An approved channel for a restricted campaign just went live — re-checking immediately.")
                break
            }
        }

        // This is part of the wait's state transition, not background housekeeping. Awaiting
        // it prevents an old wait from unsubscribing topics installed by the next wait.
        await stopMonitoringRestrictedChannels()
    }

    /// Subscribes to stream state for the approved channels of the restricted campaigns
    /// being waited on, most urgent first.
    ///
    /// The connection carries a topic budget shared with the drop and watch subscriptions,
    /// so the campaigns closest to ending are subscribed first: those are the windows that
    /// cannot be caught later.
    func startMonitoringRestrictedChannels(in candidates: [Campaign]) async {
        guard !candidates.isEmpty else { return }

        var channelIds: [String] = []
        var seen = Set<String>()
        for campaign in candidates.sorted(by: { $0.endDate < $1.endDate }) {
            for channel in campaign.channels where !channel.id.isEmpty {
                guard seen.insert(channel.id).inserted else { continue }
                channelIds.append(channel.id)
            }
        }
        guard !channelIds.isEmpty else { return }

        do {
            let monitored = try await dropEventsService.startMonitoringChannels(
                channelIds,
                limit: Self.monitoredRestrictedChannelLimit
            )
            monitoredRestrictedChannelIds.formUnion(monitored)
            if !monitored.isEmpty {
                log("[ChannelSelect]   Listening for stream-up on \(monitored.count) approved channel(s) while waiting.")
            }
        } catch {
            // Losing the push signal costs promptness, not correctness: the 60s probe still
            // runs, so the wait carries on rather than failing.
            log("[ChannelSelect]   Could not listen for approved-channel stream-up: \(error.localizedDescription)")
        }
    }

    func stopMonitoringRestrictedChannels() async {
        monitoredRestrictedChannelIds.removeAll()
        do {
            try await dropEventsService.stopMonitoringChannels(except: session?.currentChannelId)
        } catch {
            log("[ChannelSelect]   Could not stop listening for approved-channel stream-up: \(error.localizedDescription)")
        }
    }

    func cleanupActiveWatchSession(clearTarget: Bool) async {
        let channelId = session?.currentChannelId

        await watchSessionManager.stopWatching()
        endActiveWatchActivity()
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

    func beginActiveWatchActivity(for channel: Channel) {
        guard activeWatchActivity == nil else { return }
        activeWatchActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Mining Twitch Drops on \(channel.displayName)"
        )
    }

    func endActiveWatchActivity() {
        guard let activeWatchActivity else { return }
        ProcessInfo.processInfo.endActivity(activeWatchActivity)
        self.activeWatchActivity = nil
    }
    
    // MARK: - Maintenance Loop

    func startMaintenanceLoop() {
        maintenanceTask?.cancel()
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                // Wait for 30 minutes
                do {
                    try await RuntimeClock.continuous.sleep(nanoseconds: 30 * 60 * 1_000_000_000)
                } catch {
                    break
                }
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
}
