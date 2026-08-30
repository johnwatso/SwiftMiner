// GraphQL operations for TwitchAPIClient. Split from TwitchAPIClient.swift;
// same actor, same isolation.
import Foundation

extension TwitchAPIClient {
    // MARK: - GraphQL Methods

    /// Fetch drop campaigns
    public func fetchDropCampaigns() async throws -> [Campaign] {
        if let dropCampaignRefresh {
            return try await dropCampaignRefresh.task.value
        }

        let refreshID = UUID()
        let refreshTask = Task { [self] in
            try await fetchDropCampaignsUncoalesced()
        }
        dropCampaignRefresh = DropCampaignRefresh(id: refreshID, task: refreshTask)

        do {
            let campaigns = try await refreshTask.value
            if dropCampaignRefresh?.id == refreshID {
                dropCampaignRefresh = nil
            }
            return campaigns
        } catch {
            if dropCampaignRefresh?.id == refreshID {
                dropCampaignRefresh = nil
            }
            throw error
        }
    }

    /// Performs the actual dashboard/detail fan-out. Callers enter through
    /// `fetchDropCampaigns()`, which shares this work when the mining engine and the
    /// Drops projection ask for the same cold data at launch.
    private func fetchDropCampaignsUncoalesced() async throws -> [Campaign] {
        let request = GraphQLRequest(
            operationName: "ViewerDropsDashboard",
            sha256Hash: GQLHashes.viewerDropsDashboard,
            variables: ["fetchRewardCampaigns": false]
        )

        let data = try await makeGraphQLRequest(request: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        await traceGQLResponse("ViewerDropsDashboard raw", data: data, maxCharacters: 3000)

        guard let responseData = json?["data"] as? [String: Any] else {
            await traceGQLDebug { "[TwitchAPIClient] fetchDropCampaigns: missing data object" }
            throw TwitchMinerError.twitchAPICompatibility(
                operation: "ViewerDropsDashboard",
                reason: "Twitch returned no data object."
            )
        }

        // Twitch GQL response can have dropCampaigns either under currentUser or directly under root
        let currentUser = responseData["currentUser"] as? [String: Any]
        let drops = (currentUser?["dropCampaigns"] as? [[String: Any]]) ?? (responseData["dropCampaigns"] as? [[String: Any]])

        guard let drops = drops else {
            let hasCurrentUser = currentUser != nil
            await traceGQLDebug { "[TwitchAPIClient] fetchDropCampaigns: unexpected shape — currentUser=\(hasCurrentUser), drops=nil" }
            throw TwitchMinerError.twitchAPICompatibility(
                operation: "ViewerDropsDashboard",
                reason: "The response no longer contains drop campaigns."
            )
        }

        let dropsCount = drops.count
        await traceGQLDebug { "[TwitchAPIClient] fetchDropCampaigns: \(dropsCount) raw campaigns from API" }
        
        // Build basic campaigns first, then only fetch details for time-active ones
        let basicCampaigns = drops.compactMap { drop -> Campaign? in
            guard drop["id"] as? String != nil else { return nil }
            return parseBasicCampaign(from: drop)
        }

        let activeCampaigns = basicCampaigns.filter { $0.isActive }
        let inactiveCampaigns = basicCampaigns.filter { !$0.isActive }
        await traceGQLDebug { "[TwitchAPIClient] fetchDropCampaigns: \(activeCampaigns.count) active campaigns, fetching details" }

        // Fetch campaign details with a concurrency cap of 10 to avoid socket exhaustion.
        // userLogin (e.g. "john") is required — DropCampaignDetails uses user(login:) not user(id:)
        var enrichedActive = activeCampaigns
        if !activeCampaigns.isEmpty {
            let maxConcurrent = 10
            try await withThrowingTaskGroup(of: (Int, Campaign).self) { group in
                var nextIndex = 0

                func addNext() {
                    guard nextIndex < activeCampaigns.count else { return }
                    let i = nextIndex
                    var campaign = activeCampaigns[i]
                    nextIndex += 1
                    group.addTask {
                        do {
                            let details = try await self.fetchCampaignDetails(
                                campaignId: campaign.id,
                                userLogin: self.userLogin,
                                basicCampaign: campaign
                            )
                            campaign = await self.reinstatingKnownApprovedChannels(
                                Self.mergeBasicCampaign(campaign, withDetails: details)
                            )
                        } catch {
                            Logger.api.error("Failed to fetch details for campaign \(campaign.id): \(error)")
                        }
                        return (i, campaign)
                    }
                }

                // Seed initial batch
                for _ in 0..<min(maxConcurrent, activeCampaigns.count) {
                    addNext()
                }

                // As each task finishes, slot result in-place and start the next one
                for try await (i, campaign) in group {
                    enrichedActive[i] = campaign
                    addNext()
                }
            }
        }

        let campaigns = enrichedActive + inactiveCampaigns
        persistCampaignCachesIfNeeded()
        await traceGQLDebug { "[TwitchAPIClient] fetchDropCampaigns: \(campaigns.count) parsed successfully" }
        return campaigns
    }

    /// Restores the campaign-details and link-state caches from disk on first use.
    ///
    /// Without this, every cold launch re-fetched `DropCampaignDetails` for each of the
    /// ~100 time-active campaigns per account through the coordinated request gate — the
    /// bulk of the wait before mining starts.
    ///
    /// Existing in-memory entries always win: a live cycle's answer is never displaced by
    /// a file. Loading is deferred until a login is known, because the cache keys embed it.
    func loadPersistedCampaignCachesIfNeeded() {
        guard persistsCampaignCaches, !hasLoadedPersistedCampaignCaches, !userLogin.isEmpty else { return }
        hasLoadedPersistedCampaignCaches = true

        let contents = CampaignDetailsDiskCache.load(userLogin: userLogin)
        guard !contents.isEmpty else { return }

        for (key, entry) in contents.details where campaignDetailsByKey[key] == nil {
            campaignDetailsByKey[key] = CampaignDetailsCacheEntry(
                campaign: entry.campaign,
                expiresAt: entry.expiresAt
            )
        }
        for (key, entry) in contents.linkStates where campaignLinkStateByKey[key] == nil {
            campaignLinkStateByKey[key] = CampaignLinkStateEntry(
                isAccountConnected: entry.isAccountConnected,
                expiresAt: entry.expiresAt
            )
        }

        Self.pruneCache(
            &campaignDetailsByKey,
            maxEntries: maxCampaignDetailsCacheEntries,
            expiresAt: { $0.expiresAt }
        )
        Self.pruneCache(
            &campaignLinkStateByKey,
            maxEntries: maxCampaignDetailsCacheEntries,
            expiresAt: { $0.expiresAt }
        )

        let restoredDetails = campaignDetailsByKey.count
        let restoredLinkStates = campaignLinkStateByKey.count
        Logger.campaigns.info(
            "[CampaignDetailsDiskCache] Restored \(restoredDetails) campaign details, \(restoredLinkStates) link states"
        )
    }

    /// Writes both caches out when they have gained anything since the last write. Called
    /// once at the end of a campaign refresh, so a cycle costs a single write rather than
    /// one per campaign, and an all-cache-hit cycle costs nothing.
    func persistCampaignCachesIfNeeded() {
        guard persistsCampaignCaches, campaignCachesNeedPersisting, !userLogin.isEmpty else { return }
        campaignCachesNeedPersisting = false

        CampaignDetailsDiskCache.save(
            details: campaignDetailsByKey.mapValues {
                CampaignDetailsDiskCache.DetailsEntry(campaign: $0.campaign, expiresAt: $0.expiresAt)
            },
            linkStates: campaignLinkStateByKey.mapValues {
                CampaignDetailsDiskCache.LinkStateEntry(
                    isAccountConnected: $0.isAccountConnected,
                    expiresAt: $0.expiresAt
                )
            },
            userLogin: userLogin
        )
    }

    /// A successful claim changes the account-specific drop state held inside detailed
    /// campaign responses. Remove that state from memory and disk immediately so quitting
    /// before the next refresh cannot resurrect the pre-claim response on relaunch.
    func invalidateCampaignDetailsAfterClaim() async {
        campaignDetailsByKey.removeAll(keepingCapacity: true)
        if persistsCampaignCaches {
            campaignCachesNeedPersisting = true
            persistCampaignCachesIfNeeded()
        }
        await SharedTwitchLookupCache.shared.removeAllCampaignMetadata()
    }

    /// Fetch detailed campaign info including timeBasedDrops
    public func fetchCampaignDetails(
        campaignId: String,
        userLogin: String,
        basicCampaign: Campaign? = nil
    ) async throws -> Campaign {
        loadPersistedCampaignCachesIfNeeded()
        let cacheKey = Self.cacheKey("campaign-details", userLogin, campaignId)
        let now = Date()
        if let cached = campaignDetailsByKey[cacheKey], cached.expiresAt > now {
            await traceGQLDebug { "[TwitchAPIClient] DropCampaignDetails cache hit for \(campaignId)" }
            return cached.campaign
        }
        // The cross-miner cache holds only campaign-global metadata; the account-specific
        // parts are supplied here. Everything except link state comes from `basicCampaign`,
        // which is already per-account. Link state is the one field a real fetch can know
        // and the dashboard can miss — `mergeBasicCampaign` takes `details || basic` — so
        // the shared path is only safe when this account's answer for this campaign is
        // already known: either the dashboard says connected, or a previous real fetch told
        // us. Without that, serving shared metadata could silently downgrade a linked
        // campaign to unlinked and drop it out of mining.
        let sharedKey = Self.cacheKey("campaign-metadata", campaignId)
        let knownLinkState = campaignLinkStateByKey[cacheKey].flatMap { $0.expiresAt > now ? $0 : nil }
        if let basicCampaign,
           basicCampaign.isAccountConnected || knownLinkState != nil,
           let shared = await SharedTwitchLookupCache.shared.campaignMetadata(for: sharedKey, now: now) {
            // Mirrors `mergeBasicCampaign`'s `details || basic`, with the remembered fetch
            // standing in for details.
            let campaign = Self.campaign(
                fromSharedMetadata: shared,
                accountContext: basicCampaign,
                isAccountConnected: basicCampaign.isAccountConnected
                    || (knownLinkState?.isAccountConnected ?? false)
            )
            campaignDetailsByKey[cacheKey] = CampaignDetailsCacheEntry(
                campaign: campaign,
                expiresAt: Self.sharedCampaignDetailsExpiration(
                    now: now,
                    detailsTTL: detailsCacheTTL(for: campaign),
                    basicIsAccountConnected: basicCampaign.isAccountConnected,
                    knownLinkStateExpiresAt: knownLinkState?.expiresAt
                )
            )
            campaignCachesNeedPersisting = true
            await traceGQLDebug { "[TwitchAPIClient] DropCampaignDetails shared metadata hit for \(campaignId)" }
            return campaign
        }

        // A dashboard-confirmed link gives this account all of the account-specific context
        // needed to use scrubbed campaign metadata safely. Coalesce the remaining cold lookup
        // across miners: its initiator keeps the full response, while every waiter receives a
        // copy with progress, claims, and link state removed and supplies its own context here.
        if let basicCampaign, basicCampaign.isAccountConnected {
            let resolution = try await SharedTwitchLookupCache.shared.resolveCampaignMetadata(
                for: sharedKey,
                ttl: sharedCampaignMetadataTTL
            ) { [self] in
                try await fetchCampaignDetailsFromNetwork(
                    campaignId: campaignId,
                    userLogin: userLogin
                )
            }
            let campaign = resolution.loadedByCaller
                ? resolution.campaign
                : Self.campaign(
                    fromSharedMetadata: resolution.campaign,
                    accountContext: basicCampaign,
                    isAccountConnected: true
                )
            cacheCampaignDetailsForAccount(campaign, cacheKey: cacheKey)
            await traceGQLDebug {
                resolution.loadedByCaller
                    ? "[TwitchAPIClient] DropCampaignDetails populated shared metadata for \(campaignId)"
                    : "[TwitchAPIClient] DropCampaignDetails shared in-flight hit for \(campaignId)"
            }
            return campaign
        }

        let campaign = try await fetchCampaignDetailsFromNetwork(
            campaignId: campaignId,
            userLogin: userLogin
        )
        cacheCampaignDetailsForAccount(campaign, cacheKey: cacheKey)
        await SharedTwitchLookupCache.shared.storeCampaignMetadata(
            Self.sharedCampaignMetadata(from: campaign),
            key: sharedKey,
            ttl: sharedCampaignMetadataTTL
        )
        return campaign
    }

    private func fetchCampaignDetailsFromNetwork(
        campaignId: String,
        userLogin: String
    ) async throws -> Campaign {

        let request = GraphQLRequest(
            operationName: "DropCampaignDetails",
            sha256Hash: GQLHashes.dropCampaignDetails,
            variables: [
                "dropID": campaignId,
                "channelLogin": userLogin  // Login name (e.g. "john"), not numeric ID
            ]
        )
        
        let data = try await makeGraphQLRequest(request: request)

        await traceGQLResponse("DropCampaignDetails raw", data: data, maxCharacters: 3000)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        guard let jsonDict = json,
              let responseData = jsonDict["data"] as? [String: Any],
              let user = responseData["user"] as? [String: Any],
              let dropCampaign = user["dropCampaign"] as? [String: Any] else {
            throw TwitchMinerError.invalidResponse
        }

        return parseDetailedCampaign(from: dropCampaign)
    }

    private func cacheCampaignDetailsForAccount(_ campaign: Campaign, cacheKey: String) {
        Self.pruneCache(
            &campaignDetailsByKey,
            maxEntries: maxCampaignDetailsCacheEntries,
            expiresAt: { $0.expiresAt }
        )
        campaignDetailsByKey[cacheKey] = CampaignDetailsCacheEntry(
            campaign: campaign,
            expiresAt: Date().addingTimeInterval(detailsCacheTTL(for: campaign))
        )
        // Remember what this fetch established about the account's link state, so later
        // cycles can take the shared metadata path without losing that answer.
        Self.pruneCache(
            &campaignLinkStateByKey,
            maxEntries: maxCampaignDetailsCacheEntries,
            expiresAt: { $0.expiresAt }
        )
        campaignLinkStateByKey[cacheKey] = CampaignLinkStateEntry(
            isAccountConnected: campaign.isAccountConnected,
            expiresAt: Date().addingTimeInterval(campaignLinkStateTTL)
        )
        campaignCachesNeedPersisting = true
    }

    /// A shared reconstruction must never keep an account-specific answer alive beyond the
    /// authoritative link-state entry that made reconstruction safe. Dashboard-confirmed
    /// linkage is current account context and therefore uses the normal details lifetime.
    nonisolated static func sharedCampaignDetailsExpiration(
        now: Date,
        detailsTTL: TimeInterval,
        basicIsAccountConnected: Bool,
        knownLinkStateExpiresAt: Date?
    ) -> Date {
        let normalExpiration = now.addingTimeInterval(detailsTTL)
        guard !basicIsAccountConnected, let knownLinkStateExpiresAt else {
            return normalExpiration
        }
        return min(normalExpiration, knownLinkStateExpiresAt)
    }

    /// Combine ViewerDropsDashboard's broad metadata with DropCampaignDetails' richer,
    /// account-specific fields. Details is authoritative for link state, drops, ACL, and
    /// time/status data, while the dashboard can still carry artwork that details omits.
    /// Remembers a campaign's approved-channel list, and puts it back when a later fetch
    /// returns the campaign still restricted but with no channels to probe.
    ///
    /// Twitch returning an empty ACL is not a claim that the restriction was lifted: the
    /// allow flag stays set. Treating it as "no channels" leaves the campaign verifiable
    /// only through the public directory, which does not list the channels these campaigns
    /// run on — so an esports window passes with the campaign visible but unmineable.
    func reinstatingKnownApprovedChannels(_ campaign: Campaign) -> Campaign {
        if !campaign.channels.isEmpty {
            lastKnownApprovedChannels[campaign.id] = campaign.channels
            return campaign
        }

        guard campaign.hasUnresolvedChannelRestrictions,
              let remembered = lastKnownApprovedChannels[campaign.id],
              !remembered.isEmpty else { return campaign }

        Logger.api.info(
            "[CampaignDetails] \(campaign.name) came back restricted with no approved channels; reusing the \(remembered.count) last seen."
        )
        return campaign.withChannels(remembered)
    }

    private nonisolated static func mergeBasicCampaign(_ basic: Campaign, withDetails details: Campaign) -> Campaign {
        let detailedGame = details.game
        let basicGame = basic.game
        let mergedGame = Game(
            id: detailedGame.id.isEmpty ? basicGame.id : detailedGame.id,
            name: detailedGame.name.isEmpty ? basicGame.name : detailedGame.name,
            slug: detailedGame.slug ?? basicGame.slug,
            boxArtURL: detailedGame.boxArtURL ?? basicGame.boxArtURL
        )

        return Campaign(
            id: details.id.isEmpty ? basic.id : details.id,
            name: details.name.isEmpty ? basic.name : details.name,
            game: mergedGame,
            status: details.status,
            startDate: details.startDate,
            endDate: details.endDate,
            drops: details.drops.isEmpty ? basic.drops : details.drops,
            channels: details.channels,
            isAccountConnected: details.isAccountConnected || basic.isAccountConnected,
            allowIsEnabled: details.allowIsEnabled ?? basic.allowIsEnabled,
            isPrioritised: basic.isPrioritised
        )
    }

    /// Fetch inventory with drops
    public func fetchInventory() async throws -> (progress: [Progress], discoveredCampaigns: [Campaign]) {
        let request = GraphQLRequest(
            operationName: "Inventory",
            sha256Hash: GQLHashes.inventory,
            variables: ["fetchRewardCampaigns": false]
        )

        let data = try await makeGraphQLRequest(request: request)

        await traceGQLResponse("fetchInventory raw", data: data, maxCharacters: 2000)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        guard let responseData = json?["data"] as? [String: Any] else {
            throw TwitchMinerError.twitchAPICompatibility(
                operation: "Inventory",
                reason: "Twitch returned no data object."
            )
        }

        guard let currentUser = responseData["currentUser"] as? [String: Any],
              let inventory = currentUser["inventory"] as? [String: Any] else {
            await traceGQLDebug { "[TwitchAPIClient] fetchInventory: missing currentUser/inventory" }
            throw TwitchMinerError.twitchAPICompatibility(
                operation: "Inventory",
                reason: "The response no longer contains the account inventory."
            )
        }

        // Parse gameEventDrops — maps benefit ID → ClaimedBenefit.
        // Twitch omits `self.isClaimed` for fully-claimed drops in DropCampaignDetails,
        // so we use this dict as a fallback to detect claimed drops by ID or name.
        if let gameEventDrops = inventory["gameEventDrops"] as? [[String: Any]] {
            var benefits: [String: ClaimedBenefit] = [:]
            for benefit in gameEventDrops {
                guard let benefitId = benefit["id"] as? String else { continue }
                let benefitName = benefit["name"] as? String ?? "Unknown"
                let date = (benefit["lastAwardedAt"] as? String).flatMap { parseDate($0) } ?? .distantPast
                benefits[benefitId] = ClaimedBenefit(id: benefitId, name: benefitName, lastAwardedAt: date)
            }
            lastKnownClaimedBenefits = benefits
            let benefitCount = benefits.count
            await traceGQLDebug { "[TwitchAPIClient] fetchInventory: \(benefitCount) claimed benefit IDs" }
        }

        // dropCampaignsInProgress is null when no campaigns are actively in-progress (all claimed or not started)
        guard let dropProgress = inventory["dropCampaignsInProgress"] as? [[String: Any]] else {
            await traceGQLDebug { "[TwitchAPIClient] fetchInventory: dropCampaignsInProgress is null (all drops claimed or not started)" }
            return ([], [])
        }

        let dropProgressCount = dropProgress.count
        await traceGQLDebug { "[TwitchAPIClient] fetchInventory: \(dropProgressCount) campaigns in progress" }

        // Cache campaign entities for injection — handles stale "EXPIRED" status in dashboard
        lastKnownInProgressCampaigns = dropProgress.compactMap { parseCampaignFromInProgressDict($0) }
        if !lastKnownInProgressCampaigns.isEmpty {
            let campaignNames = lastKnownInProgressCampaigns.map(\.name)
            await traceGQLDebug { "[TwitchAPIClient] fetchInventory: cached \(campaignNames.count) in-progress campaign(s): \(campaignNames)" }
        }

        let progress = parseDropProgress(from: dropProgress)
        let discovered = parseDiscoveredCampaigns(from: dropProgress)
        
        return (progress, discovered)
    }

    /// Parses full Campaign objects from the Inventory response.
    /// Uses parseCampaignFromInProgressDict which correctly handles the inventory channel
    /// format ("name" field) vs the dashboard format ("login"/"displayName").
    func parseDiscoveredCampaigns(from progressDicts: [[String: Any]]) -> [Campaign] {
        return progressDicts.compactMap { parseCampaignFromInProgressDict($0) }
    }

    /// Fetch current drop progress for the watched channel.
    /// Returns (dropId, currentMinutes) if a drop is being earned, nil otherwise.
    public func fetchCurrentDrop(channelId: String) async throws -> (dropId: String, currentMinutes: Int)? {
        let request = GraphQLRequest(
            operationName: "DropCurrentSessionContext",
            sha256Hash: GQLHashes.currentDrop,
            variables: [
                "channelID": channelId,
                "channelLogin": ""
            ]
        )

        let data = try await makeGraphQLRequest(request: request)
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]

        guard let responseData = json?["data"] as? [String: Any],
              let currentUser = responseData["currentUser"] as? [String: Any],
              let session = currentUser["dropCurrentSession"] as? [String: Any] else {
            return nil
        }

        let rawDropId = session["dropID"]
        let rawCurrentMinutes = session["currentMinutesWatched"]
        guard let dropId = rawDropId as? String,
              let currentMinutes = rawCurrentMinutes as? Int else {
            traceGQL(
                "DropCurrentSessionContext parse-failed drop=\(String(describing: rawDropId)) " +
                "rawCurrent=\(String(describing: rawCurrentMinutes))"
            )
            return nil
        }

        traceGQL(
            "DropCurrentSessionContext parsed drop=\(dropId) rawCurrent=\(String(describing: rawCurrentMinutes)) " +
            "parsedCurrent=\(currentMinutes)"
        )

        return (dropId: dropId, currentMinutes: currentMinutes)
    }

    /// Fetch drops available for a specific channel.
    /// Returns a list of campaign IDs that this channel can progress.
    public func fetchAvailableDrops(channelId: String) async throws -> [String] {
        let cacheKey = Self.normalizedLookupKey(channelId)
        let now = Date()
        if let cached = availableDropsByChannel[cacheKey], cached.expiresAt > now {
            await traceGQLDebug { "[TwitchAPIClient] AvailableDrops cache hit for channel \(channelId)" }
            return cached.campaignIds
        }
        if let shared = await SharedTwitchLookupCache.shared.availableDrops(for: cacheKey, now: now) {
            availableDropsByChannel[cacheKey] = AvailableDropsCacheEntry(
                campaignIds: shared,
                expiresAt: now.addingTimeInterval(availableDropsCacheTTL)
            )
            await traceGQLDebug { "[TwitchAPIClient] AvailableDrops shared cache hit for channel \(channelId)" }
            return shared
        }

        let request = GraphQLRequest(
            operationName: "DropsHighlightService_AvailableDrops",
            sha256Hash: GQLHashes.availableDrops,
            variables: ["channelID": channelId]
        )

        let data = try await makeGraphQLRequest(request: request)
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]

        guard let responseData = json?["data"] as? [String: Any],
              let channel = responseData["channel"] as? [String: Any],
              let campaigns = channel["viewerDropCampaigns"] as? [[String: Any]] else {
            return []
        }

        let campaignIds = campaigns.compactMap { $0["id"] as? String }
        Self.pruneCache(
            &availableDropsByChannel,
            maxEntries: maxAvailableDropsCacheEntries,
            expiresAt: { $0.expiresAt }
        )
        availableDropsByChannel[cacheKey] = AvailableDropsCacheEntry(
            campaignIds: campaignIds,
            expiresAt: Date().addingTimeInterval(availableDropsCacheTTL)
        )
        await SharedTwitchLookupCache.shared.storeAvailableDrops(
            campaignIds,
            key: cacheKey,
            ttl: availableDropsCacheTTL
        )
        return campaignIds
    }

    /// Response field for the `DropsPage_ClaimDropRewards` mutation.
    static let claimRewardsKey = "claimDropRewards"
    /// Older field name, still accepted so a mixed rollout can't break claims.
    static let legacyClaimBenefitKey = "claimDropBenefit"

    /// Claim a drop
    public func claimDrop(dropInstanceId: String) async throws -> ClaimDropResponse {
        let request = GraphQLRequest(
            operationName: "DropsPage_ClaimDropRewards",
            sha256Hash: GQLHashes.dropsPage_ClaimDropRewards,
            variables: [
                "input": [
                    "dropInstanceID": dropInstanceId
                ]
            ]
        )

        let data = try await makeGraphQLRequest(request: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // Twitch returns GraphQL-level failures as HTTP 200 with an `errors`
        // array and no usable `data`, so they have to be read here or the
        // reason is lost. A retired persisted-query hash
        // ("PersistedQueryNotFound"), a renamed field, and a genuinely
        // unclaimable instance are otherwise indistinguishable — they all used
        // to collapse into a bare "Invalid response".
        if let errors = json?["errors"] as? [[String: Any]], !errors.isEmpty {
            let messages = errors.compactMap { $0["message"] as? String }.filter { !$0.isEmpty }
            let detail = messages.isEmpty
                ? "\(errors.count) unnamed GraphQL error(s)"
                : messages.joined(separator: "; ")
            traceClaim("claim mutation GraphQL error: \(detail)")
            throw TwitchMinerError.claimFailed("Twitch GraphQL error: \(detail)")
        }

        guard let responseData = json?["data"] as? [String: Any] else {
            traceClaim("claim mutation response had no data object")
            throw TwitchMinerError.claimFailed("Response contained no data object")
        }

        // The `DropsPage_ClaimDropRewards` mutation answers with
        // `claimDropRewards`. This previously read `claimDropBenefit` — a
        // different, older mutation field that is never present in this
        // response — so every claim threw, even though Twitch had recorded it.
        // `claimDropBenefit` is still accepted in case Twitch serves the older
        // shape to some clients.
        let claimPayload = responseData[Self.claimRewardsKey] as? [String: Any]
            ?? responseData[Self.legacyClaimBenefitKey] as? [String: Any]

        guard let claim = claimPayload else {
            // An explicit null is Twitch saying this instance isn't claimable —
            // already claimed, expired, or not owned by this account.
            let isExplicitNull = responseData[Self.claimRewardsKey] is NSNull
                || responseData[Self.legacyClaimBenefitKey] is NSNull
            if isExplicitNull {
                traceClaim("claim mutation returned null for \(dropInstanceId)")
                throw TwitchMinerError.claimFailed("Claim payload was null — drop instance not claimable")
            }
            // Data came back without either known field, which points at another
            // response-shape change. Name the keys so the new shape is
            // identifiable straight from the log.
            let keys = responseData.keys.sorted().joined(separator: ", ")
            traceClaim("claim payload key absent; data keys: [\(keys)]")
            throw TwitchMinerError.claimFailed(
                "Response missing \(Self.claimRewardsKey) (data keys: [\(keys)])"
            )
        }

        await invalidateCampaignDetailsAfterClaim()

        return ClaimDropResponse(
            id: claim["id"] as? String ?? "",
            status: claim["status"] as? String ?? "unknown"
        )
    }

    /// Delete a notification from the user's Twitch inbox
    public func deleteNotification(id: String) async throws {
        let request = GraphQLRequest(
            operationName: "NotificationsDelete",
            sha256Hash: GQLHashes.notificationsDelete,
            variables: ["input": ["id": id]]
        )
        _ = try await makeGraphQLRequest(request: request)
    }

    /// Fetches a playback access token for a channel.
    /// This is used to verify that the session is valid and the user can earn drops.
    public func fetchPlaybackAccessToken(channelLogin: String) async throws -> (value: String, signature: String) {
        let request = GraphQLRequest(
            operationName: "PlaybackAccessToken",
            sha256Hash: GQLHashes.playbackAccessToken,
            variables: [
                "isLive": true,
                "isVod": false,
                "login": channelLogin,
                "platform": "web",
                "playerType": "site",
                "vodID": ""
            ]
        )

        let data = try await makeGraphQLRequest(request: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        guard let responseData = json?["data"] as? [String: Any],
              let tokenData = responseData["streamPlaybackAccessToken"] as? [String: Any],
              let value = tokenData["value"] as? String,
              let signature = tokenData["signature"] as? String else {
            throw TwitchMinerError.networkError("Failed to fetch playback access token")
        }

        return (value: value, signature: signature)
    }

    /// Watch stream heartbeat (maintains watch session)
    public func sendWatchHeartbeat(channelId: String, channelLogin: String) async throws {
        let request = GraphQLRequest(
            operationName: "PlaybackAccessToken",
            sha256Hash: GQLHashes.playbackAccessToken,
            variables: [
                "isLive": true,
                "isVod": false,
                "login": channelLogin,
                "platform": "web",
                "playerType": "site",
                "vodID": ""
            ]
        )

        _ = try await makeGraphQLRequest(request: request)
    }

    /// Send Twitch's GQL watch event payload used to advance active drop sessions.
    ///
    /// This is retained as a fallback when posting directly to Spade fails. The payload
    /// is gzip-compressed JSON, then base64 encoded inside the GraphQL input.
    public func sendSpadeEvents(
        channelLogin: String,
        channelId: String,
        broadcastId: String,
        userId: String,
        gameName: String,
        gameId: String
    ) async throws {
        let event: [String: Any] = [
            "event": "minute-watched",
            "properties": [
                "broadcast_id": broadcastId,
                "channel_id": channelId,
                "channel": channelLogin,
                "client_time": iso8601Internet.string(from: Date()),
                "game": gameName,
                "game_id": gameId,
                "hidden": false,
                "is_live": true,
                "live": true,
                "logged_in": true,
                "minutes_logged": 1,
                "muted": false,
                "user_id": userId
            ]
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: [event], options: [])
        let gzipped = try gzipCompress(jsonData)
        let encoded = gzipped.base64EncodedString()
        let body: [String: Any] = [
            "query": """
             mutation SendEvents($input: SendSpadeEventsInput!) {
              sendSpadeEvents(input: $input) {
               statusCode
              }
             }
            """,
            "variables": [
                "input": [
                    "data": encoded,
                    "repository": "twilight",
                    "encoding": "GZIP_B64"
                ]
            ]
        ]

        let data = try await makeRawGraphQLRequest(body: body, operationName: "SendSpadeEvents")
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let statusCode = (((json?["data"] as? [String: Any])?["sendSpadeEvents"] as? [String: Any])?["statusCode"] as? Int)
        guard statusCode == 204 || statusCode == 200 else {
            let raw = String(data: data, encoding: .utf8) ?? "unknown response"
            throw TwitchMinerError.apiError(statusCode: statusCode ?? -1, message: "SendSpadeEvents failed: \(raw)")
        }
    }
    
    /// Get live channels for a specific game
    public func getLiveChannels(
        gameSlug: String,
        limit: Int = 100,
        expectedGameId: String? = nil
    ) async throws -> [Channel] {
        let lookupKey = Self.cacheKey("live-channels", gameSlug, "\(limit)", expectedGameId ?? "")
        let now = Date()
        if let cached = liveChannelsByLookup[lookupKey], cached.expiresAt > now {
            await traceGQLDebug { "[TwitchAPIClient] getLiveChannels cache hit for slug '\(gameSlug)'" }
            return cached.channels
        }
        if let shared = await SharedTwitchLookupCache.shared.liveChannels(for: lookupKey, now: now) {
            liveChannelsByLookup[lookupKey] = LiveChannelsCacheEntry(
                channels: shared,
                expiresAt: now.addingTimeInterval(liveChannelsCacheTTL)
            )
            await traceGQLDebug { "[TwitchAPIClient] getLiveChannels shared cache hit for slug '\(gameSlug)'" }
            return shared
        }

        let request = GraphQLRequest(
            operationName: "DirectoryPage_Game",
            sha256Hash: GQLHashes.directoryPage_Game,
            variables: [
                "limit": limit,
                "slug": gameSlug,
                "imageWidth": 50,
                "includeCostreaming": false,
                "options": [
                    "broadcasterLanguages": [],
                    "freeformTags": nil,
                    "includeRestricted": ["SUB_ONLY_LIVE"],
                    "recommendationsContext": ["platform": "web"],
                    "sort": "RELEVANCE",
                    "systemFilters": ["DROPS_ENABLED"],
                    "tags": [],
                    "requestID": "JIRA-VXP-2397"
                ],
                "sortTypeIsRecency": false
            ]
        )
        
        let data = try await makeGraphQLRequest(request: request)

        await traceGQLResponse("getLiveChannels raw", data: data, maxCharacters: 1000)

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let responseData = json?["data"] as? [String: Any] else { return [] }

        // Response key is "game" (not "directoryPageGame") — confirmed from live response
        let directory = (responseData["game"] as? [String: Any])
            ?? (responseData["directoryPageGame"] as? [String: Any])
            ?? [:]

        let expectedId = expectedGameId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !expectedId.isEmpty,
           let directoryGameId = directory["id"] as? String,
           !directoryGameId.isEmpty,
           directoryGameId != expectedId {
            let directoryName = (directory["displayName"] as? String) ?? (directory["name"] as? String) ?? gameSlug
            await traceGQLDebug { "[TwitchAPIClient] getLiveChannels: slug '\(gameSlug)' resolved to \(directoryName) (\(directoryGameId)), expected game id \(expectedId); skipping" }
            return await storeLiveChannels([], lookupKey: lookupKey)
        }

        // Parse streams.edges[].node.broadcaster
        // broadcaster may only have "login" (no "id"/"displayName") — use login as fallback for both
        if let streams = directory["streams"] as? [String: Any],
           let edges = streams["edges"] as? [[String: Any]], !edges.isEmpty {
            let edgeCount = edges.count
            await traceGQLDebug { "[TwitchAPIClient] getLiveChannels: found \(edgeCount) edges" }
            if let firstNode = (edges.first?["node"] as? [String: Any]) {
                let firstNodeKeys = firstNode.keys.sorted()
                await traceGQLDebug { "[TwitchAPIClient] getLiveChannels: first node keys = \(firstNodeKeys)" }
            }
            let channels = edges.compactMap { edge -> Channel? in
                guard let node = edge["node"] as? [String: Any] else { return nil }
                let person = (node["broadcaster"] as? [String: Any])
                    ?? (node["user"] as? [String: Any])
                    ?? (node["channel"] as? [String: Any])
                guard let person = person,
                      let login = person["login"] as? String else { return nil }
                // "id" and "displayName" may be absent — fall back to login
                let id = (person["id"] as? String) ?? login
                let displayName = (person["displayName"] as? String) ?? login
                // Parse viewer count for channel quality sorting
                let viewerCount = node["viewersCount"] as? Int
                let gameDict = node["game"] as? [String: Any]
                let streamGameId = (gameDict?["id"] as? String) ?? (directory["id"] as? String)
                if !expectedId.isEmpty,
                   let streamGameId,
                   !streamGameId.isEmpty,
                   streamGameId != expectedId {
                    return nil
                }
                let streamGameName = (gameDict?["displayName"] as? String)
                    ?? (gameDict?["name"] as? String)
                    ?? (directory["displayName"] as? String)
                    ?? (directory["name"] as? String)
                return Channel(
                    id: id, 
                    login: login, 
                    displayName: displayName,
                    isLive: true,
                    viewerCount: viewerCount,
                    gameId: streamGameId,
                    gameName: streamGameName,
                    hasDropsEnabled: true
                )
            }
            let channelCount = channels.count
            await traceGQLDebug { "[TwitchAPIClient] getLiveChannels: parsed \(channelCount) channels from \(edgeCount) edges" }
            return await storeLiveChannels(channels, lookupKey: lookupKey)
        }

        // Fallback: flat channelList shape
        guard let list = directory["channelList"] as? [[String: Any]] else {
            await traceGQLDebug { "[TwitchAPIClient] getLiveChannels: no streams/edges or channelList in response" }
            return await storeLiveChannels([], lookupKey: lookupKey)
        }

        let channels = list.compactMap { dict -> Channel? in
            guard let id = dict["id"] as? String,
                  let login = dict["login"] as? String,
                  let displayName = dict["displayName"] as? String else {
                return nil
            }
            return Channel(
                id: id,
                login: login,
                displayName: displayName,
                gameId: directory["id"] as? String,
                gameName: (directory["displayName"] as? String) ?? (directory["name"] as? String)
            )
        }
        return await storeLiveChannels(channels, lookupKey: lookupKey)
    }
    
    /// Fetch the live broadcast ID (stream ID) for a channel.
    /// Returns nil if the channel is offline or the query fails.
    /// Used to populate `WatchSession.broadcastId` for accurate Spade beacons.
    public func fetchBroadcastId(channelLogin: String) async throws -> String? {
        let request = GraphQLRequest(
            operationName: "VideoPlayerStreamInfoOverlayChannel",
            sha256Hash: GQLHashes.videoPlayerStreamInfoOverlayChannel,
            variables: [
                "channel": channelLogin,
                "platform": "web",
                "playerType": "site"
            ]
        )

        let data = try await makeGraphQLRequest(request: request)
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]

        guard
            let responseData = json?["data"] as? [String: Any],
            let user = responseData["user"] as? [String: Any],
            let stream = user["stream"] as? [String: Any],
            let broadcastId = stream["id"] as? String,
            !broadcastId.isEmpty
        else { return nil }

        return broadcastId
    }


    /// Get channel points context for a channel.
    /// Returns the available claim ID if a bonus is ready, nil otherwise.
    public func getChannelPointsContext(channelLogin: String) async throws -> ChannelPointsContext? {
        let request = GraphQLRequest(
            operationName: "ChannelPointsContext",
            sha256Hash: GQLHashes.channelPointsContext,
            variables: ["channelLogin": channelLogin]
        )

        let data = try await makeGraphQLRequest(request: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        guard
            let responseData = json?["data"] as? [String: Any],
            let community = responseData["community"] as? [String: Any],
            let channel = community["channel"] as? [String: Any],
            let points = channel["communityPoints"] as? [String: Any],
            let balance = points["balance"] as? Int
        else { return nil }

        let claimId: String?
        if let self_ = (points["user"] as? [String: Any])?["self"] as? [String: Any],
           let availableClaim = self_["communityPointsAvailableClaim"] as? [String: Any] {
            claimId = availableClaim["id"] as? String
        } else {
            claimId = nil
        }

        return ChannelPointsContext(balance: balance, availableClaimId: claimId)
    }
    
    /// Claim channel points bonus
    public func claimCommunityPoints(channelId: String, claimId: String) async throws {
        let request = GraphQLRequest(
            operationName: "ClaimCommunityPoints",
            sha256Hash: GQLHashes.claimCommunityPoints,
            variables: [
                "input": [
                    "channelID": channelId,
                    "claimID": claimId
                ]
            ]
        )
        
        _ = try await makeGraphQLRequest(request: request)
    }
}
