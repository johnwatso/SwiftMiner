import Foundation

// The watch loop: the cycle that picks a channel, keeps a watch session alive, and reacts to
// what Twitch reports back. This is the single longest piece of the engine and the one most
// often read on its own, so it lives apart from the lifecycle and event plumbing.
//
// Split out of MinerEngine.swift, which had grown past the point where one file could be read.

extension MinerEngine {
    func runMiningLoop() async {
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

                // What this miner was working before the refresh, so a campaign that stops
                // being a candidate can be named rather than just lowering a count.
                let previouslyMinedCampaignId = session?.currentCampaignId

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

                // Claiming forces a details refetch, and a degraded response there is how a
                // campaign we were earning in disappears mid-window. Say so out loud.
                if let abandoned = Self.abandonedCampaignSummary(
                    previousCampaignId: previouslyMinedCampaignId,
                    in: allEnriched,
                    candidates: candidates
                ) {
                    log("Warning: \(abandoned)")
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
                        if Task.isCancelled || shouldRescanCampaigns { break }
                        do {
                            try await runtimeClock.sleep(nanoseconds: tickNs)
                        } catch {
                            break
                        }
                    }
                    shouldRescanCampaigns = false
                    continue
                }
                consecutiveNoCandidateCycles = 0

                var selectedCampaign: Campaign?
                var selectedChannel: Channel?
                var selectedChannelWasUnverified = false

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
                        let selectionSignpost = MiningSignpost.begin(.channelSelection)
                        let selection = await selectBestChannel(
                            forGameCandidates: verificationCandidates,
                            knownSameGameCampaigns: sameGameCampaigns
                        )
                        MiningSignpost.end(.channelSelection, selectionSignpost)
                        if let selection {
                            recordGameLiveProbe(
                                gameKey,
                                hasLiveChannel: true,
                                campaignId: selection.campaign.id,
                                channelName: selection.channel.displayName
                            )
                            selectedCampaign = selection.campaign
                            selectedChannel = selection.channel
                            selectedChannelWasUnverified = !selection.wasVerified
                            break
                        }
                        // Carry the campaign we were unable to find a channel for. The watch
                        // session's target is cleared before the wait, so this is the only
                        // durable record of what the miner is actually waiting on — without it
                        // the miner describes itself from games it has already finished.
                        recordGameLiveProbe(
                            gameKey,
                            hasLiveChannel: false,
                            campaignId: gameCandidates[0].id
                        )
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
                    let waitSignpost = MiningSignpost.begin(.idleWait)
                    await waitForNextScan(restrictedCandidates: restrictedWaitCandidates)
                    MiningSignpost.end(.idleWait, waitSignpost)
                    shouldRescanCampaigns = false
                    continue
                }

                // Channel confirmed — commit campaign as active target
                let previousChannelId = session?.currentChannelId
                let previousCampaignId = session?.currentCampaignId
                session?.currentCampaignId = campaign.id
                log("Selected channel: \(channel.displayName)")
                session?.currentChannelId = channel.id
                shouldSwitchChannel = false

                if previousCampaignId != campaign.id {
                    recordActivityEvent(.campaignSelected, "Selected campaign \(campaign.name)")
                }
                if previousChannelId != channel.id {
                    recordActivityEvent(.channelSwitched, "Watching \(channel.displayName)")
                }

                // 5. Start PubSub watching for this user+channel
                if let userId = currentAccount?.id {
                    await startDropEventsWatching(userId: userId, channelId: channel.id)
                }

                do {
                    // 6. Start watching
                    if shouldRescanCampaigns {
                        // The selected target was produced by the scan currently
                        // in flight, so consuming the queued request here avoids
                        // immediately tearing down a brand-new watch session.
                        shouldRescanCampaigns = false
                    }
                    if await watchSessionManager.currentSession != nil {
                        log("Cleaning up a residual watch session before starting the selected channel.")
                        await cleanupActiveWatchSession(clearTarget: false)
                    }
                    extraMinutesWatched = 0
                    resetProgressStallClock()
                    perfStartedAt = Date()
                    _ = try await watchSessionManager.startWatching(
                        channel: channel,
                        campaignId: campaign.id,
                        gameName: campaign.game.name,
                        gameId: campaign.game.id
                    )
                    beginActiveWatchActivity(for: channel)
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
                var lastGqlPoll = runtimeClock.nowNanoseconds()
                var lastCampaignReevaluation = runtimeClock.nowNanoseconds()
                var lastOverrideLiveCheck = runtimeClock.nowNanoseconds()
                var lastClaimCheck = runtimeClock.nowNanoseconds()
                var emptyCurrentDropPolls = 0
                let claimCheckSeconds = Double(claimCheckInterval) / 1_000_000_000
                while await watchSessionManager.isWatching && !shouldSwitchChannel {
                    do {
                        try await runtimeClock.sleep(nanoseconds: watchLoopTickInterval)
                    } catch {
                        break
                    }
                    if Task.isCancelled || shouldSwitchChannel { break }

                    if let overrideLogin = streamOverrideLogin,
                       runtimeClock.elapsedSeconds(since: lastOverrideLiveCheck) >= 60 {
                        lastOverrideLiveCheck = runtimeClock.nowNanoseconds()
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
                       runtimeClock.elapsedSeconds(since: lastGqlPoll) >= 60 {
                        lastGqlPoll = runtimeClock.nowNanoseconds()
                        do {
                            if let current = try await apiClient.fetchCurrentDrop(channelId: channel.id) {
                                emptyCurrentDropPolls = 0
                                selectedChannelWasUnverified = false
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
                                enqueueMiningEvent(.gqlProgress(observation))
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
                                    selectedChannelWasUnverified = false
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

                        if Self.shouldAbandonUnverifiedSelection(
                            isUnverified: selectedChannelWasUnverified,
                            emptyPolls: emptyCurrentDropPolls
                        ) {
                            let key = Self.unverifiedChannelKey(campaignId: campaign.id, channel: channel)
                            unverifiedChannelCooldownUntil[key] = runtimeClock.deadline(
                                after: Self.unverifiedChannelCooldownInterval
                            )
                            let minutes = Int(Self.unverifiedChannelCooldownInterval / 60)
                            log("Unverified fallback \(channel.displayName) produced no drop confirmation after \(emptyCurrentDropPolls) checks; cooling it down for \(minutes)m and selecting another channel.")
                            recordActivityEvent(
                                .stallDetected,
                                "Unverified channel produced no drop confirmation: \(channel.displayName)"
                            )
                            shouldSwitchChannel = true
                            break
                        }
                    }

                    // Stuck detection (matches TDM logic)
                    // We calculate minutes elapsed since last verified progress (GQL/PubSub)
                    let elapsed = progressStallElapsedSeconds()
                    extraMinutesWatched = Int(elapsed / 60)

                    // While a stream override is active we deliberately stay on the chosen
                    // streamer until they go offline, so progress stalls must not switch channels.
                    if streamOverrideLogin == nil, extraMinutesWatched >= Self.maxExtraMinutes {
                        log("Progress stalled for \(extraMinutesWatched) mins. Refreshing inventory to check for external claims...")
                        recordActivityEvent(
                            .stallDetected,
                            "No verified progress for \(extraMinutesWatched) min on \(campaign.name)"
                        )

                        // ENHANCEMENT: Force inventory refresh before switching channels
                        // This catches drops claimed on other devices or via Twitch UI
                        do {
                            // Force fresh inventory snapshot fetch (includes benefitIDs)
                            let inventoryService = await dropsService.getInventoryService()
                            let inventoryResult = try await inventoryService.fetchInventoryResult(forceRefresh: true)
                            let freshInventory = inventoryResult.snapshot
                            onOperationalEvent?(.successfulPoll)
                            onOperationalEvent?(.inventoryRefresh)
                            
                            log("Inventory refreshed: \(freshInventory.benefitIDs.count) claimed benefits, \(freshInventory.progress.count) in-progress drops")
                            recordActivityEvent(
                                .inventoryRefreshed,
                                "Refreshed inventory: \(freshInventory.benefitIDs.count) claimed, \(freshInventory.progress.count) in progress"
                            )
                            
                            // Check if ANY drop in current campaign was recently claimed
                            // This handles the case where user claimed via Twitch UI or another device
                            let campaignDrops = allCampaigns.first { $0.id == session?.currentCampaignId }?.drops ?? []
                            let newlyClaimedDrops = Self.externallyClaimedDrops(
                                in: campaignDrops,
                                snapshot: freshInventory
                            )

                            // Merge the authoritative snapshot before making any recovery decision.
                            // Without this, the same external claim is rediscovered every stall window.
                            let progressAcknowledged = await acknowledgeInventoryProgress(
                                freshInventory,
                                campaignId: campaign.id,
                                context: "stall recovery"
                            )
                            
                            if !newlyClaimedDrops.isEmpty {
                                log("\(newlyClaimedDrops.count) drop(s) were claimed externally. Updating local state, resetting stall counter.")
                                for drop in newlyClaimedDrops {
                                    _ = progressEventTracker.markClaimed(
                                        campaignId: campaign.id,
                                        dropId: drop.id,
                                        dropLabel: drop.name
                                    )
                                }
                                extraMinutesWatched = 0 // Reset stall counter
                                resetProgressStallClock()
                                noteCampaignProgress(campaign.id)
                                // Don't switch channel - continue mining remaining drops in campaign
                            } else if progressAcknowledged {
                                log("Inventory confirmed new progress during stall recovery. Keeping the current channel.")
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
                                    campaignStallCooldownUntil[campaign.id] = runtimeClock.deadline(
                                        after: Self.nonEarningCooldownInterval
                                    )
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
                       runtimeClock.elapsedSeconds(since: lastCampaignReevaluation) >= campaignReevalInterval {
                        lastCampaignReevaluation = runtimeClock.nowNanoseconds()
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
                    if runtimeClock.elapsedSeconds(since: lastClaimCheck) >= claimCheckSeconds {
                        lastClaimCheck = runtimeClock.nowNanoseconds()
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

            } catch is CancellationError {
                await cleanupActiveWatchSession(clearTarget: true)
                break
            } catch let error as TwitchMinerError {
                await cleanupActiveWatchSession(clearTarget: true)
                emitIssue(error)
                handleError(error)
                if Self.requiresManualReauthentication(error) {
                    await pauseForManualReauthentication()
                    return
                }
                do {
                    try await runtimeClock.sleep(nanoseconds: campaignCheckInterval)
                } catch {
                    break
                }
            } catch {
                if Task.isCancelled {
                    await cleanupActiveWatchSession(clearTarget: true)
                    break
                }
                await cleanupActiveWatchSession(clearTarget: true)
                emitIssue(error)
                handleError(.unknown(error.localizedDescription))
                do {
                    try await runtimeClock.sleep(nanoseconds: campaignCheckInterval)
                } catch {
                    break
                }
            }
        }
    }
}
