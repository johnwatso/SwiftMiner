// Candidate campaign ordering, channel selection, failover, and stream overrides
// for MinerEngine. Split from MinerEngine.swift; same actor, same isolation.
import Foundation

extension MinerEngine {
    func candidateCampaigns(
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
    func recordGameLiveProbe(_ gameKey: String, hasLiveChannel: Bool) {
        gameLiveProbes[gameKey] = (hasLiveChannel, Date())
    }

    /// True when the game was probed recently and confirmed to have NO live, watch-mineable
    /// channel. Stale results (older than `gameLiveProbeFreshness`) are ignored so a game that
    /// has since come online is not demoted forever.
    func isGameFreshlyKnownEmpty(_ gameKey: String) -> Bool {
        guard let probe = gameLiveProbes[gameKey] else { return false }
        guard Date().timeIntervalSince(probe.checkedAt) <= Self.gameLiveProbeFreshness else { return false }
        return !probe.hasLiveChannel
    }

    func sortedCandidates(
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

            // Prefer finishing partially-earned drops: banked minutes are lost
            // if the campaign's streams dry up later, so a campaign whose next
            // drop is closer to completion outranks an untouched peer.
            let leftRemaining = minutesToNearestClaim(left)
            let rightRemaining = minutesToNearestClaim(right)
            if leftRemaining != rightRemaining { return leftRemaining < rightRemaining }

            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// Minutes left on the campaign's most-advanced unclaimed drop, or
    /// `Int.max` when no drop has any recorded progress.
    static func minutesToNearestClaim(_ campaign: Campaign) -> Int {
        campaign.drops.compactMap { drop -> Int? in
            guard !drop.isClaimed,
                  let current = drop.progress?.currentMinutes,
                  current > 0 else { return nil }
            return max(0, drop.requiredMinutes - current)
        }.min() ?? Int.max
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

    func normalizedGameKey(_ value: String) -> String {
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
    func selectBestChannel(
        forGameCandidates candidates: [Campaign],
        knownSameGameCampaigns: [Campaign] = []
    ) async -> (Campaign, Channel)? {
        guard let primary = candidates.first else { return nil }
        let gameName = primary.gameName
        log("[ChannelSelect] Game: \(gameName) — candidates: \(candidates.map(\.name).joined(separator: ", "))")

        for candidate in candidates where candidate.hasUnresolvedChannelRestrictions {
            log("[ChannelSelect]   Warning: \(candidate.name) is restricted, but Twitch returned no usable approved-channel list; directory verification is best-effort.")
        }

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
            // Continue with an empty directory result. Restricted campaigns still get their
            // approved channels checked for liveness and verified below; never start watching
            // an arbitrary ACL entry that may be offline or running a different campaign.
            liveChannels = []
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
        // Known approved channels are the most precise candidates we have. Move every directory
        // ACL match ahead of the bounded general scan so a low-viewer official stream cannot land
        // below the verification cap.
        let orderedChannels = Self.prioritizingKnownApprovedChannels(
            sortedChannels,
            campaigns: candidates
        )
        let verificationLimit = Self.adaptiveChannelVerificationLimit(
            liveChannelCount: orderedChannels.count,
            candidateCount: candidates.count,
            hasRestrictedCampaign: candidates.contains { $0.hasChannelRestrictions },
            hasPriorityCampaign: candidates.contains {
                Self.priorityIndex(for: $0, priorityKeys: priorityGames) != Int.max
            },
            avoidDuplicateStreams: avoidDuplicateStreams
        )
        let directoryProbeKey = normalizedGameKey(primary.game.id.isEmpty ? primary.gameName : primary.game.id)
        let directoryBatch = Self.rotatingVerificationBatch(
            from: orderedChannels,
            limit: verificationLimit,
            offset: directoryVerificationOffsets[directoryProbeKey, default: 0]
        )
        directoryVerificationOffsets[directoryProbeKey] = directoryBatch.nextOffset
        let channelsToVerify = directoryBatch.channels
        if verificationLimit < orderedChannels.count {
            log("[ChannelSelect]   Verification bounded to \(verificationLimit) of \(orderedChannels.count) live channel(s); rotating the overflow across scans")
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
        var attemptedChannelIdentities: Set<String> = []

        for ch in channelsToVerify {
            let eligibleForChannel = candidates.filter { candidate in
                !candidate.hasKnownChannelRestrictions
                    || Self.channelMatchesCampaignACL(ch, campaign: candidate)
            }
            guard !eligibleForChannel.isEmpty else { continue }

            let channel = await resolveChannelIdIfNeeded(ch)
            attemptedChannelIdentities.formUnion(Self.identityKeys(for: channel))

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

        // ACL approved-channel probe: when directory verification did not find a campaign,
        // probe its approved channels directly. This is deliberately based on what was actually
        // verified, not whether an approved channel happened to exist somewhere in the unscanned
        // directory tail.
        for candidate in candidates where candidate.hasKnownChannelRestrictions {
            let alreadyMatched = verifiedMatches.contains { $0.campaign.id == candidate.id }
            if alreadyMatched && !avoidDuplicateStreams { continue }
            let probed = await liveACLChannels(for: candidate)
            for ch in probed {
                let channel = await resolveChannelIdIfNeeded(ch)
                let channelIdentities = Self.identityKeys(for: channel)
                guard attemptedChannelIdentities.isDisjoint(with: channelIdentities) else { continue }
                attemptedChannelIdentities.formUnion(channelIdentities)
                aclProbeCount += 1
                do {
                    let activeCampaignIds = try await apiClient.fetchAvailableDrops(channelId: channel.id)
                    anyVerificationSucceeded = true
                    verifiedChannelCount += 1
                    let matches = candidates.filter { possibleMatch in
                        activeCampaignIds.contains(possibleMatch.id)
                            && (!possibleMatch.hasKnownChannelRestrictions
                                || Self.channelMatchesCampaignACL(channel, campaign: possibleMatch))
                    }
                    if !matches.isEmpty {
                        let names = matches.map(\.name).joined(separator: ", ")
                        log("[ChannelSelect]     Verified: \(names) active on approved channel \(channel.displayName)")
                    }
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
        liveChannelCount > 0 || candidates.contains { $0.hasKnownChannelRestrictions }
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

    /// Stable-partitions directory results so known approved channels are always considered
    /// before the bounded general stream scan, regardless of viewer count.
    internal static func prioritizingKnownApprovedChannels(
        _ channels: [Channel],
        campaigns: [Campaign]
    ) -> [Channel] {
        let restricted = campaigns.filter(\.hasKnownChannelRestrictions)
        guard !restricted.isEmpty else { return channels }

        let approved = channels.filter { channel in
            restricted.contains { channelMatchesCampaignACL(channel, campaign: $0) }
        }
        let general = channels.filter { channel in
            !restricted.contains { channelMatchesCampaignACL(channel, campaign: $0) }
        }
        return approved + general
    }

    /// Keeps the most valuable half of a bounded channel batch on every scan and rotates the
    /// remaining half through the tail. The first scan remains the normal top-N ordering, while
    /// repeated misses eventually inspect every returned channel without increasing request load.
    internal static func rotatingVerificationBatch(
        from channels: [Channel],
        limit: Int,
        offset: Int
    ) -> (channels: [Channel], nextOffset: Int) {
        guard !channels.isEmpty, limit > 0 else { return ([], 0) }
        guard channels.count > limit else { return (channels, 0) }

        let headCount = min(channels.count, limit / 2)
        let head = Array(channels.prefix(headCount))
        let tail = Array(channels.dropFirst(headCount))
        let rotatingCapacity = max(1, limit - head.count)
        let normalizedOffset = ((offset % tail.count) + tail.count) % tail.count
        let rotating = (0..<min(rotatingCapacity, tail.count)).map { step in
            tail[(normalizedOffset + step) % tail.count]
        }
        let nextOffset = (normalizedOffset + rotating.count) % tail.count
        return (head + rotating, nextOffset)
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

    func bestVerifiedCampaignMatch(
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

    func followedStreamerRanks(for channels: [Channel]) async -> [String: Int] {
        guard prioritiseFollowedStreamers, let userId = currentAccount?.id else { return [:] }
        let broadcasterIds = channels.map(\.id).filter { !$0.isEmpty }
        let relationships = await apiClient.getChannelRelationships(userId: userId, broadcasterIds: broadcasterIds)
        return relationships.reduce(into: [String: Int]()) { ranks, pair in
            ranks[Self.normalizedChannelIdentity(pair.key)] = pair.value.rank
        }
    }

    func streamerRelationshipRank(for channel: Channel, ranks: [String: Int]) -> Int {
        guard prioritiseFollowedStreamers, !ranks.isEmpty else { return 0 }
        return Self.identityKeys(for: channel)
            .compactMap { ranks[$0] }
            .max() ?? 0
    }

    func selectBestChannel(from campaign: Campaign) async -> Channel? {
        log("[ChannelSelect] Campaign: \(campaign.name) (game: \(campaign.gameName))")
        let aclSummary = campaign.hasUnresolvedChannelRestrictions
            ? "YES (channel list unavailable)"
            : campaign.hasKnownChannelRestrictions ? "YES (\(campaign.channels.count) channels)" : "NO"
        log("[ChannelSelect]   ACL restrictions: \(aclSummary)")
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
            if campaign.hasKnownChannelRestrictions {
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
                if campaign.hasKnownChannelRestrictions && !Self.channelMatchesCampaignACL(channel, campaign: campaign) {
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

    func resolveChannelIdIfNeeded(_ channel: Channel) async -> Channel {
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
    func anyApprovedChannelLive(in candidates: [Campaign]) async -> Bool {
        for candidate in candidates where candidate.hasKnownChannelRestrictions {
            if !(await liveACLChannels(for: candidate).isEmpty) {
                return true
            }
        }
        return false
    }

    func liveACLChannels(for campaign: Campaign, limit: Int = 30) async -> [Channel] {
        guard campaign.hasKnownChannelRestrictions else { return [] }

        // Probe approved channels concurrently — for restricted campaigns this can be up to
        // `limit` independent live-state checks, and doing them serially adds seconds of latency
        // to channel selection. Each result carries its source index so we can restore the
        // campaign's original channel ordering after the parallel fan-out.
        let batch = Self.rotatingVerificationBatch(
            from: campaign.channels,
            limit: limit,
            offset: approvedChannelProbeOffsets[campaign.id, default: 0]
        )
        approvedChannelProbeOffsets[campaign.id] = batch.nextOffset
        let candidates = Array(batch.channels.enumerated())
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
        guard campaign.hasKnownChannelRestrictions else {
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

    static func normalizedChannelIdentity(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func selectFailoverChannel(for campaign: Campaign, currentChannel: Channel) async -> Channel? {
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

    func failoverRule(for campaign: Campaign) -> GameFailoverStreamer? {
        Self.matchingFailoverRule(
            in: failoverStreamers,
            campaignGameId: campaign.game.id,
            campaignGameName: campaign.gameName
        )
    }

    /// The first enabled rule whose game id (preferred) or game name matches the
    /// campaign, compared case- and whitespace-insensitively. Rules with no
    /// streamer login never match.
    static func matchingFailoverRule(
        in streamers: [GameFailoverStreamer],
        campaignGameId: String,
        campaignGameName: String
    ) -> GameFailoverStreamer? {
        let gameId = normalizedGameSelectionKey(campaignGameId)
        let gameName = normalizedGameSelectionKey(campaignGameName)

        return streamers.first { rule in
            guard rule.enabled, !rule.streamerLogin.isEmpty else { return false }
            let ruleGameId = normalizedGameSelectionKey(rule.gameId)
            let ruleGameName = normalizedGameSelectionKey(rule.gameName)
            return (!ruleGameId.isEmpty && ruleGameId == gameId)
                || (!ruleGameName.isEmpty && ruleGameName == gameName)
        }
    }

    func verifiedFailoverChannel(
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

    func failoverCooldownKey(campaignId: String, streamerLogin: String) -> String {
        "\(campaignId):\(Self.normalizedChannelIdentity(streamerLogin))"
    }

    enum StreamOverrideSelection {
        case selected(Campaign, Channel)
        case waiting
        case cleared
    }

    func selectStreamOverrideChannel(for candidates: [Campaign]) async -> StreamOverrideSelection {
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

    static func normalizedStreamOverrideLogin(_ login: String?) -> String? {
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

    func clearStreamOverrideAfterOffline() {
        streamOverrideLogin = nil
        streamOverrideWatchOnly = false
        onStreamOverrideChange?(nil)
    }
    
}
