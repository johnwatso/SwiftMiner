import Foundation
import zlib

/// Twitch API Client supporting both GraphQL and REST endpoints
public actor TwitchAPIClient {
    private let clientId: String
    private let authService: TwitchAuthService
    private var accessToken: String
    private let session: URLSession
    /// Limits GQL requests to ≤5 per second to avoid Twitch rate-limiting
    private let rateLimiter = RateLimiter(maxRequests: 5, per: 1.0)

    /// Android User-Agent that matches the Android client ID. Starts as a
    /// random pick for pre-login traffic; swapped to a sticky-per-account UA
    /// from the shared pool once `setAccountId(_:)` is called.
    private var userAgent = TwitchClientFingerprint.randomAndroidUserAgent()

    /// Switches this client's UA to the sticky allocation for `accountId` so
    /// auth/api/spade traffic for the same miner share a fingerprint and
    /// concurrent miners spread across the pool.
    public func setAccountId(_ accountId: String) {
        userAgent = TwitchClientFingerprint.shared.userAgent(for: accountId)
    }

    /// Cached integrity token and its expiry
    private var integrityToken: String?
    private var integrityTokenExpiry: Date = .distantPast

    /// Authenticated user's login name — used as channelLogin in DropCampaignDetails
    private var userLogin: String = ""

    /// Broadcaster login -> numeric channel ID cache for stream directory results that
    /// only include a login. `AvailableDrops` and PubSub require the numeric ID.
    private var channelIdByLogin: [String: String] = [:]
    private var followedChannelIdsByUser: [String: (ids: Set<String>, expiresAt: Date)] = [:]
    private var subscriptionByUserAndBroadcaster: [String: (isSubscribed: Bool, expiresAt: Date)] = [:]
    private let channelRelationshipCacheTTL: TimeInterval = 10 * 60

    /// Metadata for a claimed benefit from inventory.
    /// Used as a fallback to detect claimed drops when `self` is absent from DropCampaignDetails.
    public struct ClaimedBenefit: Sendable {
        public let id: String
        public let name: String
        public let lastAwardedAt: Date
    }

    /// Benefit ID → ClaimedBenefit from the most recent inventory fetch (gameEventDrops).
    /// Used as a fallback to detect claimed drops when `self` is absent from DropCampaignDetails.
    /// Matches Python's `claimed_benefits: dict[str, datetime]` pattern.
    private var lastKnownClaimedBenefits: [String: ClaimedBenefit] = [:]

    /// Campaigns parsed from the most recent inventory `dropCampaignsInProgress` response.
    /// Twitch sometimes omits active campaigns from ViewerDropsDashboard (returns "EXPIRED" status)
    /// while they still appear here. Used to inject missing campaigns into the campaign list.
    private var lastKnownInProgressCampaigns: [Campaign] = []

    /// Set the authenticated user's login (call after successful auth)
    public func setUserLogin(_ login: String) {
        self.userLogin = login
    }

    /// Returns benefit metadata from the most recent inventory fetch.
    /// These are rewards the user has already received — used as fallback claimed detection.
    /// Matches Python's `claimed_benefits: dict[str, datetime]` pattern.
    public func getClaimedBenefits() -> [String: ClaimedBenefit] {
        lastKnownClaimedBenefits
    }

    /// Returns campaigns parsed from the most recent inventory `dropCampaignsInProgress`.
    /// These may include campaigns absent from ViewerDropsDashboard due to stale API status.
    public func inProgressCampaigns() -> [Campaign] {
        lastKnownInProgressCampaigns
    }

    /// Twitch API endpoints
    private let helixUrl = "https://api.twitch.tv/helix"
    private let gqlUrl = "https://gql.twitch.tv/gql"
    private let integrityUrl = "https://gql.twitch.tv/integrity"

    public init(authService: TwitchAuthService, clientId: String, session: URLSession? = nil) {
        self.authService = authService
        self.clientId = clientId
        self.accessToken = "" // Will be updated from auth service

        if let session = session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 60
            self.session = URLSession(configuration: config)
        }
    }

    /// Update the access token
    public func updateAccessToken(_ token: String) {
        self.accessToken = token
    }

    /// Get current access token from auth service (also used by MinerEngine for PubSub auth)
    public func getAccessToken() async throws -> String {
        let token = try await authService.refreshTokenIfNeeded()
        accessToken = token
        return token
    }

    // MARK: - REST API Methods

    /// Get current user information
    public func getCurrentUser() async throws -> TwitchUser {
        let url = "\(helixUrl)/users"
        let data = try await makeRESTRequest(url: url, method: "GET")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(TwitchUsersResponse.self, from: data)

        guard let user = response.data.first else {
            throw TwitchMinerError.authenticationFailed("No user found")
        }

        return user
    }
    
    /// Get channel information
    public func getChannels(userIds: [String]) async throws -> [Channel] {
        guard !userIds.isEmpty else { return [] }
        
        var components = URLComponents(string: "\(helixUrl)/users")!
        components.queryItems = userIds.prefix(100).map { URLQueryItem(name: "id", value: $0) }
        
        let data = try await makeRESTRequest(url: components.string!, method: "GET")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(TwitchUsersResponse.self, from: data)
        
        return response.data.map { user in
            Channel(
                id: user.id,
                login: user.login,
                displayName: user.displayName
            )
        }
    }

    /// Resolve channel information by broadcaster login.
    public func getChannel(login: String) async throws -> Channel {
        let normalizedLogin = login.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedLogin.isEmpty else {
            throw TwitchMinerError.channelNotFound
        }

        if let cachedId = channelIdByLogin[normalizedLogin] {
            return Channel(id: cachedId, login: normalizedLogin, displayName: login)
        }

        var components = URLComponents(string: "\(helixUrl)/users")!
        components.queryItems = [URLQueryItem(name: "login", value: normalizedLogin)]

        let data = try await makeRESTRequest(url: components.string!, method: "GET")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let response = try decoder.decode(TwitchUsersResponse.self, from: data)

        guard let user = response.data.first else {
            throw TwitchMinerError.channelNotFound
        }

        channelIdByLogin[normalizedLogin] = user.id
        return Channel(
            id: user.id,
            login: user.login,
            displayName: user.displayName
        )
    }

    /// Returns relationship state between the authenticated user and candidate broadcasters.
    /// Followed channels are fetched in pages once per cache window; subscriptions are checked
    /// per broadcaster because Twitch exposes that as a single-channel endpoint.
    public func getChannelRelationships(userId: String, broadcasterIds: [String]) async -> [String: ChannelRelationship] {
        let uniqueIds = Array(Set(broadcasterIds.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))
        guard !userId.isEmpty, !uniqueIds.isEmpty else { return [:] }

        let followedIds = (try? await getFollowedChannelIds(userId: userId)) ?? []
        var relationships: [String: ChannelRelationship] = [:]

        for broadcasterId in uniqueIds {
            let isSubscribed = await isUserSubscribed(userId: userId, broadcasterId: broadcasterId)
            relationships[broadcasterId] = ChannelRelationship(
                isFollowed: followedIds.contains(broadcasterId),
                isSubscribed: isSubscribed
            )
        }

        return relationships
    }

    private func getFollowedChannelIds(userId: String) async throws -> Set<String> {
        if let cached = followedChannelIdsByUser[userId], cached.expiresAt > Date() {
            return cached.ids
        }

        var followedIds = Set<String>()
        var cursor: String?
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        repeat {
            var components = URLComponents(string: "\(helixUrl)/channels/followed")!
            var queryItems = [
                URLQueryItem(name: "user_id", value: userId),
                URLQueryItem(name: "first", value: "100")
            ]
            if let cursor, !cursor.isEmpty {
                queryItems.append(URLQueryItem(name: "after", value: cursor))
            }
            components.queryItems = queryItems

            let data = try await makeRESTRequest(url: components.string!, method: "GET")
            let response = try decoder.decode(FollowedChannelsResponse.self, from: data)
            followedIds.formUnion(response.data.map(\.broadcasterId))
            cursor = response.pagination?.cursor
        } while cursor?.isEmpty == false

        followedChannelIdsByUser[userId] = (followedIds, Date().addingTimeInterval(channelRelationshipCacheTTL))
        return followedIds
    }

    private func isUserSubscribed(userId: String, broadcasterId: String) async -> Bool {
        let cacheKey = "\(userId):\(broadcasterId)"
        if let cached = subscriptionByUserAndBroadcaster[cacheKey], cached.expiresAt > Date() {
            return cached.isSubscribed
        }

        var components = URLComponents(string: "\(helixUrl)/subscriptions/user")!
        components.queryItems = [
            URLQueryItem(name: "broadcaster_id", value: broadcasterId),
            URLQueryItem(name: "user_id", value: userId)
        ]

        let isSubscribed: Bool
        do {
            let data = try await makeRESTRequest(url: components.string!, method: "GET")
            let response = try JSONDecoder().decode(UserSubscriptionResponse.self, from: data)
            isSubscribed = !response.data.isEmpty
        } catch TwitchMinerError.apiError(let statusCode, _) where statusCode == 404 || statusCode == 403 {
            isSubscribed = false
        } catch TwitchMinerError.authenticationFailed {
            isSubscribed = false
        } catch {
            isSubscribed = false
        }

        subscriptionByUserAndBroadcaster[cacheKey] = (isSubscribed, Date().addingTimeInterval(channelRelationshipCacheTTL))
        return isSubscribed
    }
    
    /// Search Twitch categories (games) by name using the Helix REST API.
    /// Returns up to `limit` matching games with their Twitch IDs and box-art URLs.
    public func searchCategories(query: String, limit: Int = 10) async throws -> [Game] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let cappedLimit = max(1, min(limit, 20))
        let primaryResults = try await fetchCategories(query: trimmed, limit: cappedLimit)
        if !primaryResults.isEmpty {
            return primaryResults
        }

        // Fallback broadening improves sequel-style searches (e.g. "battlefield 6" -> "battlefield").
        let fallbackQueries = categorySearchFallbackQueries(for: trimmed)
        if !fallbackQueries.isEmpty {
            print("[TwitchAPIClient] searchCategories: no direct matches for '\(trimmed)', trying fallbacks \(fallbackQueries)")
        }
        var collected: [Game] = []
        var seenIds = Set<String>()
        for fallbackQuery in fallbackQueries {
            let fallbackResults = try await fetchCategories(query: fallbackQuery, limit: cappedLimit)
            print("[TwitchAPIClient] searchCategories: fallback '\(fallbackQuery)' returned \(fallbackResults.count) categories")
            for game in fallbackResults where seenIds.insert(game.id).inserted {
                collected.append(game)
                if collected.count >= cappedLimit {
                    return collected
                }
            }
        }

        if collected.isEmpty {
            print("[TwitchAPIClient] searchCategories: no categories found for '\(trimmed)' after all fallbacks")
        }
        return collected
    }

    private func fetchCategories(query: String, limit: Int) async throws -> [Game] {
        var components = URLComponents(string: "\(helixUrl)/search/categories")!
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "first", value: "\(min(limit, 20))")
        ]
        let data = try await makeRESTRequest(url: components.string!, method: "GET")

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["data"] as? [[String: Any]] else {
            return []
        }

        return results.compactMap { dict -> Game? in
            guard let id = dict["id"] as? String,
                  let name = dict["name"] as? String else { return nil }
            let artURL: URL? = (dict["box_art_url"] as? String).flatMap { raw in
                URL(string: raw
                    .replacingOccurrences(of: "{width}", with: "188")
                    .replacingOccurrences(of: "{height}", with: "250"))
            }
            return Game(id: id, name: name, boxArtURL: artURL)
        }
    }

    private func categorySearchFallbackQueries(for query: String) -> [String] {
        let normalized = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()

        let tokens = normalized
            .split(separator: " ")
            .map(String.init)
        guard tokens.count > 1 else { return [] }

        var candidates: [String] = []
        let sequelTokenPattern = #"^\d+$|^[ivxlcdm]+$"#

        let baseTokens = tokens.filter { token in
            token.range(of: sequelTokenPattern, options: [.regularExpression, .caseInsensitive]) == nil
        }

        if !baseTokens.isEmpty {
            candidates.append(baseTokens.joined(separator: " "))
        }

        let dropLast = tokens.dropLast().joined(separator: " ")
        if !dropLast.isEmpty {
            candidates.append(dropLast)
        }

        if let first = tokens.first {
            candidates.append(first)
        }

        var deduped: [String] = []
        var seen = Set<String>()
        for candidate in candidates where candidate.count >= 3 && candidate != normalized {
            if seen.insert(candidate).inserted {
                deduped.append(candidate)
            }
        }
        return deduped
    }

    private static func normalizedDirectoryGameName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func sortedCategoryFallbacks(_ categories: [Game], matching game: Game) -> [Game] {
        let gameId = game.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !gameId.isEmpty else { return categories }

        return categories.enumerated().sorted { lhs, rhs in
            let lhsMatches = lhs.element.id == gameId
            let rhsMatches = rhs.element.id == gameId
            if lhsMatches != rhsMatches { return lhsMatches }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    private static func appendSlug(_ slug: String?, to slugs: inout [String], seen: inout Set<String>) {
        let trimmed = slug?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return }
        let key = trimmed.lowercased()
        guard seen.insert(key).inserted else { return }
        slugs.append(trimmed)
    }

    private static func parseGame(from gameDict: [String: Any]) -> Game {
        Game(
            id: gameDict["id"] as? String ?? "",
            name: (gameDict["displayName"] as? String) ?? (gameDict["name"] as? String) ?? "",
            slug: gameDict["slug"] as? String,
            boxArtURL: (gameDict["boxArtURL"] as? String).flatMap { URL(string: $0) }
        )
    }

    private static func directoryLookupNames(for name: String) -> [String] {
        var names: [String] = []
        var seen = Set<String>()

        func append(_ candidate: String) {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let key = normalizedDirectoryGameName(trimmed)
            guard seen.insert(key).inserted else { return }
            names.append(trimmed)
        }

        append(name)
        return names
    }

    private static func derivedGameSlug(from name: String) -> String {
        name
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ")).inverted)
            .joined()
            .replacingOccurrences(of: "\\s+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private func fetchGameSlugFromDirectoryRedirect(name: String) async throws -> String? {
        let request = GraphQLRequest(
            operationName: "DirectoryGameRedirect",
            sha256Hash: GQLHashes.directoryGameRedirect,
            variables: ["name": name]
        )

        let data = try await makeGraphQLRequest(request: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        if let responseData = json?["data"] as? [String: Any],
           let redirect = responseData["game"] as? [String: Any] {
            if let slug = redirect["name"] as? String, !slug.isEmpty {
                return slug
            }
            if let displayName = redirect["displayName"] as? String, !displayName.isEmpty {
                return Self.derivedGameSlug(from: displayName)
            }
        }

        if let raw = String(data: data, encoding: .utf8) {
            print("[TwitchAPIClient] getGameSlug: DirectoryGameRedirect returned no game for '\(name)'. Raw: \(raw.prefix(500))")
        }
        return nil
    }

    public func getGameSlugCandidates(
        for game: Game,
        includeCategorySearch: Bool = true
    ) async throws -> [String] {
        let trimmedName = game.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw TwitchMinerError.channelNotFound
        }

        var slugs: [String] = []
        var seen = Set<String>()

        Self.appendSlug(game.slug, to: &slugs, seen: &seen)

        for lookupName in Self.directoryLookupNames(for: trimmedName) {
            if let slug = try await fetchGameSlugFromDirectoryRedirect(name: lookupName) {
                Self.appendSlug(slug, to: &slugs, seen: &seen)
            }
        }

        if includeCategorySearch {
            do {
                let categories = try await searchCategories(query: trimmedName, limit: 10)
                for category in Self.sortedCategoryFallbacks(categories, matching: game) {
                    if let slug = try? await fetchGameSlugFromDirectoryRedirect(name: category.name) {
                        Self.appendSlug(slug, to: &slugs, seen: &seen)
                    }
                    Self.appendSlug(Self.derivedGameSlug(from: category.name), to: &slugs, seen: &seen)
                }
            } catch {
                print("[TwitchAPIClient] getGameSlugCandidates: category search failed for '\(trimmedName)': \(error.localizedDescription)")
            }
        }

        Self.appendSlug(Self.derivedGameSlug(from: trimmedName), to: &slugs, seen: &seen)
        return slugs
    }

    public func getCategorySearchGameSlugCandidates(for game: Game) async throws -> [String] {
        let trimmedName = game.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw TwitchMinerError.channelNotFound
        }

        var slugs: [String] = []
        var seen = Set<String>()

        do {
            let categories = try await searchCategories(query: trimmedName, limit: 10)
            for category in Self.sortedCategoryFallbacks(categories, matching: game) {
                if let slug = try? await fetchGameSlugFromDirectoryRedirect(name: category.name) {
                    Self.appendSlug(slug, to: &slugs, seen: &seen)
                }
                Self.appendSlug(Self.derivedGameSlug(from: category.name), to: &slugs, seen: &seen)
            }
        } catch {
            print("[TwitchAPIClient] getCategorySearchGameSlugCandidates: category search failed for '\(trimmedName)': \(error.localizedDescription)")
        }

        return slugs
    }

    /// Get the slug for a game name
    public func getGameSlug(name: String) async throws -> String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw TwitchMinerError.channelNotFound
        }

        if let directSlug = try await fetchGameSlugFromDirectoryRedirect(name: trimmedName) {
            return directSlug
        }

        let candidates = try await getGameSlugCandidates(for: Game(id: "", name: trimmedName))
        guard let slug = candidates.first else {
            throw TwitchMinerError.channelNotFound
        }
        return slug
    }

    // MARK: - GraphQL Methods

    /// Fetch drop campaigns
    public func fetchDropCampaigns() async throws -> [Campaign] {
        let request = GraphQLRequest(
            operationName: "ViewerDropsDashboard",
            sha256Hash: GQLHashes.viewerDropsDashboard,
            variables: ["fetchRewardCampaigns": false]
        )

        let data = try await makeGraphQLRequest(request: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // Debug: log raw response — first 3000 chars to see timeBasedDrops structure
        if let raw = String(data: data, encoding: .utf8) {
            print("[TwitchAPIClient] ViewerDropsDashboard raw (first 3000): \(raw.prefix(3000))")
        }

        guard let responseData = json?["data"] as? [String: Any] else {
            print("[TwitchAPIClient] fetchDropCampaigns: missing data object")
            return []
        }

        // Twitch GQL response can have dropCampaigns either under currentUser or directly under root
        let currentUser = responseData["currentUser"] as? [String: Any]
        let drops = (currentUser?["dropCampaigns"] as? [[String: Any]]) ?? (responseData["dropCampaigns"] as? [[String: Any]])

        guard let drops = drops else {
            print("[TwitchAPIClient] fetchDropCampaigns: unexpected shape — currentUser=\(currentUser != nil), drops=nil")
            return []
        }

        print("[TwitchAPIClient] fetchDropCampaigns: \(drops.count) raw campaigns from API")
        
        // Build basic campaigns first, then only fetch details for time-active ones
        let basicCampaigns = drops.compactMap { drop -> Campaign? in
            guard drop["id"] as? String != nil else { return nil }
            return parseBasicCampaign(from: drop)
        }

        let activeCampaigns = basicCampaigns.filter { $0.isActive }
        let inactiveCampaigns = basicCampaigns.filter { !$0.isActive }
        print("[TwitchAPIClient] fetchDropCampaigns: \(activeCampaigns.count) active campaigns, fetching details")

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
                            let details = try await self.fetchCampaignDetails(campaignId: campaign.id, userLogin: self.userLogin)
                            campaign = Self.mergeBasicCampaign(campaign, withDetails: details)
                        } catch {
                            print("[TwitchAPIClient] Failed to fetch details for campaign \(campaign.id): \(error)")
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
        print("[TwitchAPIClient] fetchDropCampaigns: \(campaigns.count) parsed successfully")
        return campaigns
    }
    
    /// Fetch detailed campaign info including timeBasedDrops
    public func fetchCampaignDetails(campaignId: String, userLogin: String) async throws -> Campaign {
        let request = GraphQLRequest(
            operationName: "DropCampaignDetails",
            sha256Hash: GQLHashes.dropCampaignDetails,
            variables: [
                "dropID": campaignId,
                "channelLogin": userLogin  // Login name (e.g. "john"), not numeric ID
            ]
        )
        
        let data = try await makeGraphQLRequest(request: request)

        // Debug: dump raw DropCampaignDetails response to confirm `self` field presence on timeBasedDrops
        if let raw = String(data: data, encoding: .utf8) {
            print("[TwitchAPIClient] DropCampaignDetails raw (first 3000): \(raw.prefix(3000))")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        guard let jsonDict = json,
              let responseData = jsonDict["data"] as? [String: Any],
              let user = responseData["user"] as? [String: Any],
              let dropCampaign = user["dropCampaign"] as? [String: Any] else {
            throw TwitchMinerError.invalidResponse
        }

        return parseDetailedCampaign(from: dropCampaign)
    }

    /// Combine ViewerDropsDashboard's broad metadata with DropCampaignDetails' richer,
    /// account-specific fields. Details is authoritative for link state, drops, ACL, and
    /// time/status data, while the dashboard can still carry artwork that details omits.
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

        if let raw = String(data: data, encoding: .utf8) {
            print("[TwitchAPIClient] fetchInventory raw (first 2000): \(raw.prefix(2000))")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        guard let responseData = json?["data"] as? [String: Any] else {
            return ([], [])
        }

        guard let currentUser = responseData["currentUser"] as? [String: Any],
              let inventory = currentUser["inventory"] as? [String: Any] else {
            print("[TwitchAPIClient] fetchInventory: missing currentUser/inventory")
            return ([], [])
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
            print("[TwitchAPIClient] fetchInventory: \(benefits.count) claimed benefit IDs")
        }

        // dropCampaignsInProgress is null when no campaigns are actively in-progress (all claimed or not started)
        guard let dropProgress = inventory["dropCampaignsInProgress"] as? [[String: Any]] else {
            print("[TwitchAPIClient] fetchInventory: dropCampaignsInProgress is null (all drops claimed or not started)")
            return ([], [])
        }

        print("[TwitchAPIClient] fetchInventory: \(dropProgress.count) campaigns in progress")

        // Cache campaign entities for injection — handles stale "EXPIRED" status in dashboard
        lastKnownInProgressCampaigns = dropProgress.compactMap { parseCampaignFromInProgressDict($0) }
        if !lastKnownInProgressCampaigns.isEmpty {
            print("[TwitchAPIClient] fetchInventory: cached \(lastKnownInProgressCampaigns.count) in-progress campaign(s): \(lastKnownInProgressCampaigns.map { $0.name })")
        }

        let progress = parseDropProgress(from: dropProgress)
        let discovered = parseDiscoveredCampaigns(from: dropProgress)
        
        return (progress, discovered)
    }

    /// Parses full Campaign objects from the Inventory response.
    /// Uses parseCampaignFromInProgressDict which correctly handles the inventory channel
    /// format ("name" field) vs the dashboard format ("login"/"displayName").
    private func parseDiscoveredCampaigns(from progressDicts: [[String: Any]]) -> [Campaign] {
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

        return campaigns.compactMap { $0["id"] as? String }
    }

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

        guard let responseData = json?["data"] as? [String: Any],
              let claim = responseData["claimDropBenefit"] as? [String: Any] else {
            throw TwitchMinerError.claimFailed("Invalid response")
        }

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

    /// Send Twitch's current watch event payload used to advance active drop sessions.
    ///
    /// TwitchDropsMiner currently uses this `sendSpadeEvents` mutation rather than only
    /// POSTing to the legacy Spade endpoint. The payload is gzip-compressed JSON, then
    /// base64 encoded inside the GraphQL input.
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

        // Log raw response for debugging
        if let raw = String(data: data, encoding: .utf8) {
            print("[TwitchAPIClient] getLiveChannels raw (first 1000): \(raw.prefix(1000))")
        }

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
            print("[TwitchAPIClient] getLiveChannels: slug '\(gameSlug)' resolved to \(directoryName) (\(directoryGameId)), expected game id \(expectedId); skipping")
            return []
        }

        // Parse streams.edges[].node.broadcaster
        // broadcaster may only have "login" (no "id"/"displayName") — use login as fallback for both
        if let streams = directory["streams"] as? [String: Any],
           let edges = streams["edges"] as? [[String: Any]], !edges.isEmpty {
            print("[TwitchAPIClient] getLiveChannels: found \(edges.count) edges")
            if let firstNode = (edges.first?["node"] as? [String: Any]) {
                print("[TwitchAPIClient] getLiveChannels: first node keys = \(firstNode.keys.sorted())")
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
            print("[TwitchAPIClient] getLiveChannels: parsed \(channels.count) channels from \(edges.count) edges")
            return channels
        }

        // Fallback: flat channelList shape
        guard let list = directory["channelList"] as? [[String: Any]] else {
            print("[TwitchAPIClient] getLiveChannels: no streams/edges or channelList in response")
            return []
        }

        return list.compactMap { dict -> Channel? in
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

    // MARK: - Private Helper Methods

    /// Force-refreshes OAuth token after a 401/tokenExpired response and syncs local caches.
    private func refreshAccessTokenAfterExpiry() async throws -> String {
        let refreshedToken = try await authService.forceRefreshToken()
        accessToken = refreshedToken
        // Integrity token is bound to auth context; force re-fetch after token rotation.
        integrityToken = nil
        integrityTokenExpiry = .distantPast
        print("[TwitchAPIClient] OAuth token refreshed after tokenExpired; integrity cache invalidated")
        return refreshedToken
    }

    /// Make a request with automatic retries for transient network errors
    private func makeRequestWithRetry(_ request: URLRequest, operationName: String, maxAttempts: Int = 3) async throws -> Data {
        var lastError: Error?
        
        for attempt in 1...maxAttempts {
            do {
                let (data, response) = try await session.data(for: request)
                
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw TwitchMinerError.invalidResponse
                }

                switch httpResponse.statusCode {
                case 200..<300:
                    // GQL errors arrive as HTTP 200 with a body-level error array.
                    // Detect PersistedQueryNotFound so callers get a clear signal.
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let errors = json["errors"] as? [[String: Any]] {
                        for gqlError in errors {
                            if let msg = gqlError["message"] as? String {
                                if msg.contains("PersistedQueryNotFound") {
                                    print("[TwitchAPIClient] [GQL] PersistedQueryNotFound for \(operationName)")
                                    throw TwitchMinerError.apiError(
                                        statusCode: 200,
                                        message: "PersistedQueryNotFound: \(operationName) - sha256 hash may be stale"
                                    )
                                }
                                // Log other GQL errors too
                                print("[TwitchAPIClient] [GQL] Error: \(msg)")
                            }
                        }
                    }
                    return data
                case 401:
                    throw TwitchMinerError.tokenExpired
                case 403:
                    throw TwitchMinerError.authenticationFailed("Forbidden")
                case 429:
                    let retryAfter = httpResponse.allHeaderFields["Retry-After"] as? String ?? "60"
                    throw TwitchMinerError.apiError(statusCode: 429, message: "Rate limited, retry after \(retryAfter)s")
                default:
                    let errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
                    throw TwitchMinerError.apiError(statusCode: httpResponse.statusCode, message: errorMessage)
                }
            } catch let error as TwitchMinerError {
                // Don't retry auth/rate limit/stale hash errors
                throw error
            } catch {
                if error is CancellationError {
                    throw error
                }
                if let urlError = error as? URLError, urlError.code == .cancelled {
                    throw error
                }
                lastError = error
                if attempt < maxAttempts {
                    let delay = Double(attempt) * 2.0 // Simple backoff: 2s, 4s
                    print("[TwitchAPIClient] Network error on attempt \(attempt) for \(operationName): \(error.localizedDescription). Retrying in \(delay)s...")
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
            }
        }
        
        throw TwitchMinerError.networkError(lastError?.localizedDescription ?? "Max retry attempts reached")
    }

    /// Make a REST API request
    private func makeRESTRequest(
        url: String,
        method: String,
        body: Data? = nil,
        allowRefreshRetry: Bool = true
    ) async throws -> Data {
        guard let requestURL = URL(string: url) else {
            throw TwitchMinerError.networkError("Invalid URL")
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(clientId, forHTTPHeaderField: "Client-Id")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let body = body {
            request.httpBody = body
        }

        let operationName = "REST \(method) \(url)"
        do {
            return try await makeRequestWithRetry(request, operationName: operationName)
        } catch TwitchMinerError.tokenExpired where allowRefreshRetry {
            print("[TwitchAPIClient] \(operationName): token expired, forcing refresh and retrying once")
            _ = try await refreshAccessTokenAfterExpiry()
            return try await makeRESTRequest(
                url: url,
                method: method,
                body: body,
                allowRefreshRetry: false
            )
        }
    }

    /// Make a GraphQL request (rate-limited to ≤5 req/s).
    /// Detects `PersistedQueryNotFound` and surfaces it as a clear error.
    private func makeGraphQLRequest(
        request: GraphQLRequest,
        allowRefreshRetry: Bool = true
    ) async throws -> Data {
        // Enforce GQL rate limit before making the request
        await rateLimiter.wait()
        traceGQL(request.operationName)

        // Debug: log token and client ID being used
        print("[TwitchAPIClient] [GQL] Request: \(request.operationName) token=\(accessToken.prefix(8))…(len:\(accessToken.count)) clientID=\(clientId.prefix(8))…")

        guard let requestURL = URL(string: gqlUrl) else {
            throw TwitchMinerError.networkError("Invalid URL")
        }

        var urlRequest = URLRequest(url: requestURL)
        urlRequest.httpMethod = "POST"
        // Twitch GQL requires "OAuth <token>", not "Bearer <token>"
        let authHeader = "OAuth \(accessToken)"
        urlRequest.setValue(authHeader, forHTTPHeaderField: "Authorization")
        urlRequest.setValue(clientId, forHTTPHeaderField: "Client-Id")
        urlRequest.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        urlRequest.setValue("*/*", forHTTPHeaderField: "Accept")
        urlRequest.setValue("en-US", forHTTPHeaderField: "Accept-Language")
        urlRequest.setValue("https://www.twitch.tv", forHTTPHeaderField: "Origin")
        urlRequest.setValue("https://www.twitch.tv", forHTTPHeaderField: "Referer")

        // Twitch requires integrity token for dropCampaigns and other protected fields
        if let integrity = try? await getIntegrityToken() {
            urlRequest.setValue(integrity, forHTTPHeaderField: "Client-Integrity")
        }

        let requestBody = request.toJSON()
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        do {
            return try await makeRequestWithRetry(urlRequest, operationName: request.operationName)
        } catch TwitchMinerError.tokenExpired where allowRefreshRetry {
            print("[TwitchAPIClient] [GQL] \(request.operationName): token expired, forcing refresh and retrying once")
            _ = try await refreshAccessTokenAfterExpiry()
            return try await makeGraphQLRequest(request: request, allowRefreshRetry: false)
        }
    }

    private func makeRawGraphQLRequest(
        body: [String: Any],
        operationName: String,
        allowRefreshRetry: Bool = true
    ) async throws -> Data {
        await rateLimiter.wait()
        traceGQL(operationName)

        guard let requestURL = URL(string: gqlUrl) else {
            throw TwitchMinerError.networkError("Invalid URL")
        }

        var urlRequest = URLRequest(url: requestURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("OAuth \(accessToken)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue(clientId, forHTTPHeaderField: "Client-Id")
        urlRequest.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        urlRequest.setValue("*/*", forHTTPHeaderField: "Accept")
        urlRequest.setValue("en-US", forHTTPHeaderField: "Accept-Language")
        urlRequest.setValue("https://www.twitch.tv", forHTTPHeaderField: "Origin")
        urlRequest.setValue("https://www.twitch.tv", forHTTPHeaderField: "Referer")

        if let integrity = try? await getIntegrityToken() {
            urlRequest.setValue(integrity, forHTTPHeaderField: "Client-Integrity")
        }

        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        do {
            return try await makeRequestWithRetry(urlRequest, operationName: operationName)
        } catch TwitchMinerError.tokenExpired where allowRefreshRetry {
            print("[TwitchAPIClient] [GQL] \(operationName): token expired, forcing refresh and retrying once")
            _ = try await refreshAccessTokenAfterExpiry()
            return try await makeRawGraphQLRequest(
                body: body,
                operationName: operationName,
                allowRefreshRetry: false
            )
        }
    }

    private func gzipCompress(_ data: Data) throws -> Data {
        var stream = z_stream()
        let status = deflateInit2_(
            &stream,
            Z_DEFAULT_COMPRESSION,
            Z_DEFLATED,
            MAX_WBITS + 16,
            8,
            Z_DEFAULT_STRATEGY,
            ZLIB_VERSION,
            Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else {
            throw TwitchMinerError.networkError("Failed to initialize gzip compressor")
        }
        defer { deflateEnd(&stream) }

        return try data.withUnsafeBytes { inputBuffer in
            guard let inputBase = inputBuffer.bindMemory(to: Bytef.self).baseAddress else {
                return Data()
            }
            stream.next_in = UnsafeMutablePointer<Bytef>(mutating: inputBase)
            stream.avail_in = uInt(data.count)

            var output = Data()
            let chunkSize = 16 * 1024
            let buffer = UnsafeMutablePointer<Bytef>.allocate(capacity: chunkSize)
            defer { buffer.deallocate() }

            repeat {
                stream.next_out = buffer
                stream.avail_out = uInt(chunkSize)

                let result = deflate(&stream, Z_FINISH)
                guard result == Z_OK || result == Z_STREAM_END else {
                    throw TwitchMinerError.networkError("Failed to gzip watch event payload")
                }

                output.append(buffer, count: chunkSize - Int(stream.avail_out))
                if result == Z_STREAM_END { break }
            } while true

            return output
        }
    }

    // MARK: - Integrity Token

    /// Fetches (or returns a cached) Twitch integrity token.
    /// Twitch requires `Client-Integrity: <token>` on GQL queries like dropCampaigns.
    private func getIntegrityToken() async throws -> String {
        // Return cached token if still valid (with 60-second buffer)
        if let token = integrityToken, Date() < integrityTokenExpiry.addingTimeInterval(-60) {
            return token
        }

        guard let url = URL(string: integrityUrl) else {
            throw TwitchMinerError.networkError("Invalid integrity URL")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("OAuth \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(clientId, forHTTPHeaderField: "Client-Id")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Use same User-Agent as GQL requests for consistency
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.twitch.tv", forHTTPHeaderField: "Origin")
        request.setValue("https://www.twitch.tv", forHTTPHeaderField: "Referer")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TwitchMinerError.networkError("Integrity token: invalid response type")
        }
        print("[TwitchAPIClient] integrity endpoint status: \(httpResponse.statusCode)")

        // Twitch returns 200 or 429, but BOTH include a valid token in the body.
        // 429 is a rate-limit signal, but the token is still usable — accept it.
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String else {
            let msg = String(data: data, encoding: .utf8) ?? "unknown"
            print("[TwitchAPIClient] integrity token response missing token field (status \(httpResponse.statusCode)): \(msg.prefix(200))")
            throw TwitchMinerError.networkError("Integrity token fetch failed")
        }

        // Expiry comes as Unix ms timestamp
        let expiryMs = json["expiration"] as? Double ?? (Date().timeIntervalSince1970 + 300) * 1000
        integrityTokenExpiry = Date(timeIntervalSince1970: expiryMs / 1000)
        integrityToken = token

        print("[TwitchAPIClient] integrity token refreshed, expires: \(integrityTokenExpiry)")
        return token
    }

    // MARK: - Trace helpers

    private func traceGQL(_ op: String) {
        Task {
            await DebugTrace.shared.emit(.graphQL, op)
        }
    }

    // MARK: - Parsing Helpers

    // Pre-configured ISO8601 formatters. Creating an ISO8601DateFormatter is very
    // expensive (it builds an ICU formatter and copies the locale/calendar), and
    // `parseDate` is called for every date on every campaign/drop on each refresh —
    // previously allocating up to three formatters per call. These are stored on
    // the actor (so access is serialized) and configured once.
    private let iso8601Fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let iso8601Internet: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private let iso8601Basic = ISO8601DateFormatter()

    /// Parse an ISO8601 date string, handling both plain and fractional-second formats.
    /// Twitch returns dates in multiple formats: with/without fractional seconds, with Z or +/-HH:MM timezone.
    private func parseDate(_ str: String) -> Date? {
        // Try fractional seconds format first (most common for Twitch API)
        if let d = iso8601Fractional.date(from: str) { return d }
        // Try standard internet date format (no fractional seconds)
        if let d = iso8601Internet.date(from: str) { return d }
        // Fallback to basic formatter
        return iso8601Basic.date(from: str)
    }

    private func parseCampaigns(from drops: [[String: Any]]) -> [Campaign] {
        return drops.compactMap { campaignDict -> Campaign? in
            guard
                let id = campaignDict["id"] as? String,
                let name = campaignDict["name"] as? String,
                let startAtStr = campaignDict["startAt"] as? String,
                let endAtStr = campaignDict["endAt"] as? String,
                let startAt = parseDate(startAtStr),
                let endAt = parseDate(endAtStr)
            else {
                let id = campaignDict["id"] as? String ?? "?"
                let name = campaignDict["name"] as? String ?? "?"
                print("[TwitchAPIClient] parseCampaigns: dropped '\(name)' (id:\(id)) — missing required field")
                return nil
            }

            let gameDict = campaignDict["game"] as? [String: Any] ?? [:]
            let game = Self.parseGame(from: gameDict)

            let statusDict = campaignDict["status"] as? String ?? "ACTIVE"
            let status = CampaignStatus(rawValue: statusDict) ?? .active

            let dropsArray = (campaignDict["timeBasedDrops"] as? [[String: Any]] ?? []).compactMap { parseDrop(from: $0) }

            return Campaign(
                id: id,
                name: name,
                game: game,
                status: status,
                startDate: startAt,
                endDate: endAt,
                drops: dropsArray,
                channels: []
            )
        }
    }

    private func parseDrop(from dropDict: [String: Any]) -> Drop? {
        guard
            let id = dropDict["id"] as? String,
            let name = dropDict["name"] as? String,
            let requiredMinutes = dropDict["requiredMinutesWatched"] as? Int
        else {
            print("[TwitchAPIClient] parseDrop failed — keys: \(dropDict.keys.sorted()), id=\(dropDict["id"] ?? "nil"), name=\(dropDict["name"] ?? "nil"), req=\(dropDict["requiredMinutesWatched"] ?? "nil")")
            return nil
        }

        let imageUrl = (dropDict["imageURL"] as? String).flatMap { URL(string: $0) }
        let description = dropDict["description"] as? String

        // Parse per-drop active window (drops can have their own window within the campaign window)
        let dropStartDate = (dropDict["startAt"] as? String).flatMap { parseDate($0) }
        let dropEndDate = (dropDict["endAt"] as? String).flatMap { parseDate($0) }

        // Parse precondition drops
        let preconditionDrops = (dropDict["preconditionDrops"] as? [[String: Any]] ?? [])
            .compactMap { $0["id"] as? String }

        // Parse subscription requirement (0 = none, >0 = number of subs required)
        let requiredSubs = dropDict["requiredSubs"] as? Int ?? 0

        // Parse ALL benefit IDs from benefitEdges — used for fallback claimed detection.
        // Python: for benefit in self.benefits — checks ALL benefit IDs against claimed_benefits.
        var benefitIds: [String] = []
        var reward: Reward? = nil
        if let benefitEdges = dropDict["benefitEdges"] as? [[String: Any]] {
            for edge in benefitEdges {
                guard let benefit = edge["benefit"] as? [String: Any],
                      let benefitId = benefit["id"] as? String else { continue }
                benefitIds.append(benefitId)
                // Use first benefit for display (reward field)
                if reward == nil, let benefitName = benefit["name"] as? String {
                    let benefitImageURL = (benefit["imageAssetURL"] as? String).flatMap { URL(string: $0) }
                    
                    // Parse distribution type (IN_GAME, BADGE, EMOTE)
                    let distributionType = benefit["distributionType"] as? String ?? "IN_GAME"
                    let type = RewardType(rawValue: distributionType) ?? .inGame
                    
                    reward = Reward(id: benefitId, type: type, name: benefitName, description: "", imageURL: benefitImageURL)
                }
            }
        }

        // Read per-drop progress from the `self` field (present in DropCampaignDetails response).
        // Tier 1: authoritative — Twitch returns this for in-progress drops.
        // For fully-claimed drops, Twitch omits `self` entirely; fallback handled in DropsService.mergeInventory.
        var progress: Progress? = nil
        if let selfDict = dropDict["self"] as? [String: Any] {
            let isClaimed = selfDict["isClaimed"] as? Bool ?? false
            let currentMinutes = selfDict["currentMinutesWatched"] as? Int ?? 0
            let dropInstanceId = selfDict["dropInstanceID"] as? String ?? id
            print("[TwitchAPIClient] parseDrop '\(name)': self.isClaimed=\(isClaimed), mins=\(currentMinutes)/\(requiredMinutes)")
            progress = Progress(
                id: dropInstanceId,
                dropId: id,
                dropName: name,
                campaignId: "",
                currentMinutes: currentMinutes,
                requiredMinutes: requiredMinutes,
                isClaimed: isClaimed
            )
        } else {
            print("[TwitchAPIClient] parseDrop '\(name)': NO self field — benefitIds=\(benefitIds)")
        }

        return Drop(
            id: id,
            name: name,
            description: description,
            imageURL: imageUrl ?? reward?.imageURL,
            requiredMinutes: requiredMinutes,
            benefitID: benefitIds.first ?? "",
            reward: reward,
            progress: progress,
            isClaimed: false,
            benefitIds: benefitIds,
            preconditionDrops: preconditionDrops,
            requiredSubs: requiredSubs,
            dropStartDate: dropStartDate,
            dropEndDate: dropEndDate
        )
    }

    /// Parse basic campaign from ViewerDropsDashboard (no drops)
    private func parseBasicCampaign(from campaignDict: [String: Any]) -> Campaign {
        let id = campaignDict["id"] as? String ?? ""
        let name = campaignDict["name"] as? String ?? ""
        
        let gameDict = campaignDict["game"] as? [String: Any] ?? [:]
        let game = Self.parseGame(from: gameDict)
        
        let statusDict = campaignDict["status"] as? String ?? "ACTIVE"
        let status = CampaignStatus(rawValue: statusDict) ?? .active
        
        let startAt = parseDate(campaignDict["startAt"] as? String ?? "") ?? Date()
        let endAt = parseDate(campaignDict["endAt"] as? String ?? "") ?? Date()
        
        // Extract isAccountConnected from self field
        let selfDict = campaignDict["self"] as? [String: Any]
        let isAccountConnected = selfDict?["isAccountConnected"] as? Bool ?? false
        
        return Campaign(
            id: id,
            name: name,
            game: game,
            status: status,
            startDate: startAt,
            endDate: endAt,
            drops: [],
            channels: [],
            isAccountConnected: isAccountConnected
        )
    }
    
    /// Parse detailed campaign from DropCampaignDetails (includes drops)
    private func parseDetailedCampaign(from campaignDict: [String: Any]) -> Campaign {
        let id = campaignDict["id"] as? String ?? ""
        let name = campaignDict["name"] as? String ?? ""
        
        let gameDict = campaignDict["game"] as? [String: Any] ?? [:]
        let game = Self.parseGame(from: gameDict)
        
        let statusDict = campaignDict["status"] as? String ?? "ACTIVE"
        let status = CampaignStatus(rawValue: statusDict) ?? .active
        
        let startAt = parseDate(campaignDict["startAt"] as? String ?? "") ?? Date()
        let endAt = parseDate(campaignDict["endAt"] as? String ?? "") ?? Date()
        
        let dropsArray = (campaignDict["timeBasedDrops"] as? [[String: Any]] ?? [])
            .compactMap { parseDrop(from: $0) }
        
        // Extract isAccountConnected from self field
        let selfDict = campaignDict["self"] as? [String: Any]
        let isAccountConnected = selfDict?["isAccountConnected"] as? Bool ?? false
        
        // Parse ACL channels from allow.channels (critical for restricted campaigns)
        let allowDict = campaignDict["allow"] as? [String: Any] ?? [:]
        let isAllowEnabled = allowDict["isEnabled"] as? Bool ?? true
        let channelsArray: [Channel] = isAllowEnabled 
            ? (allowDict["channels"] as? [[String: Any]] ?? []).compactMap { channelDict -> Channel? in
                guard 
                    let id = channelDict["id"] as? String,
                    let login = channelDict["login"] as? String,
                    let displayName = channelDict["displayName"] as? String
                else { return nil }
                
                let broadcasterType = channelDict["broadcasterType"] as? String ?? ""
                let description = channelDict["description"] as? String ?? ""
                let profileImageURL = (channelDict["profileImageURL"] as? String).flatMap { URL(string: $0) }
                
                // Mark as ACL-based for prioritization
                return Channel(
                    id: id,
                    login: login,
                    displayName: displayName,
                    description: description,
                    profileImageUrl: profileImageURL,
                    broadcasterType: broadcasterType,
                    aclBased: true
                )
              }
            : []
        
        return Campaign(
            id: id,
            name: name,
            game: game,
            status: status,
            startDate: startAt,
            endDate: endAt,
            drops: dropsArray,
            channels: channelsArray,
            isAccountConnected: isAccountConnected,
            allowIsEnabled: isAllowEnabled
        )
    }

    /// Parse a Campaign from an inventory `dropCampaignsInProgress` entry.
    /// The inventory format uses "name" (not "login"/"displayName") for ACL channels.
    /// Returns nil if the campaign's endAt is in the past (genuinely expired).
    private func parseCampaignFromInProgressDict(_ campaignDict: [String: Any]) -> Campaign? {
        guard let id = campaignDict["id"] as? String,
              let name = campaignDict["name"] as? String else { return nil }

        let gameDict = campaignDict["game"] as? [String: Any] ?? [:]
        let game = Self.parseGame(from: gameDict)

        let statusDict = campaignDict["status"] as? String ?? "ACTIVE"
        let status = CampaignStatus(rawValue: statusDict) ?? .active
        let startAt = parseDate(campaignDict["startAt"] as? String ?? "") ?? Date()
        let endAt = parseDate(campaignDict["endAt"] as? String ?? "") ?? Date()

        // Skip genuinely expired campaigns (endAt in the past)
        guard endAt > Date() else { return nil }

        let dropsArray = (campaignDict["timeBasedDrops"] as? [[String: Any]] ?? [])
            .compactMap { parseDrop(from: $0) }

        let selfDict = campaignDict["self"] as? [String: Any]
        let isAccountConnected = selfDict?["isAccountConnected"] as? Bool ?? false

        // Inventory ACL channels use "name" field instead of "login"/"displayName"
        let allowDict = campaignDict["allow"] as? [String: Any] ?? [:]
        let isAllowEnabled = allowDict["isEnabled"] as? Bool ?? true
        let channelsArray = isAllowEnabled
            ? (allowDict["channels"] as? [[String: Any]] ?? []).compactMap { ch -> Channel? in
                guard let chId = ch["id"] as? String,
                      let chName = ch["name"] as? String else { return nil }
                return Channel(id: chId, login: chName, displayName: chName, aclBased: true)
              }
            : []

        return Campaign(
            id: id,
            name: name,
            game: game,
            status: status,
            startDate: startAt,
            endDate: endAt,
            drops: dropsArray,
            channels: channelsArray,
            isAccountConnected: isAccountConnected,
            allowIsEnabled: isAllowEnabled
        )
    }

    /// Parse drop progress from Inventory GQL response.
    /// Actual Twitch structure:
    ///   dropCampaignsInProgress[]: { id: campaignId, timeBasedDrops[]: { id, name, requiredMinutesWatched, self: { currentMinutesWatched, isClaimed, dropInstanceID } } }
    private func parseDropProgress(from progressDicts: [[String: Any]]) -> [Progress] {
        var results: [Progress] = []

        for campaignEntry in progressDicts {
            let campaignId = campaignEntry["id"] as? String ?? ""
            let timeBasedDrops = campaignEntry["timeBasedDrops"] as? [[String: Any]] ?? []

            for drop in timeBasedDrops {
                guard
                    let dropId = drop["id"] as? String,
                    let dropName = drop["name"] as? String,
                    let requiredMinutes = drop["requiredMinutesWatched"] as? Int,
                    let selfDict = drop["self"] as? [String: Any]
                else { continue }

                let currentMinutes = selfDict["currentMinutesWatched"] as? Int ?? 0
                let isClaimed = selfDict["isClaimed"] as? Bool ?? false
                let dropInstanceId = selfDict["dropInstanceID"] as? String

                // Twitch can omit dropInstanceID while a drop is still earning. Keep those
                // rows for progress display, but avoid creating a synthetic claim target
                // once a drop is complete.
                if dropInstanceId == nil && currentMinutes >= requiredMinutes {
                    print("[TwitchAPIClient] parseDropProgress: skipping claimable '\(dropName)' — dropInstanceID missing from self dict")
                    continue
                }

                results.append(Progress(
                    id: dropInstanceId ?? "\(campaignId)_\(dropId)",
                    dropId: dropId,
                    dropName: dropName,
                    campaignId: campaignId,
                    currentMinutes: currentMinutes,
                    requiredMinutes: requiredMinutes,
                    isClaimed: isClaimed
                ))
            }
        }

        print("[TwitchAPIClient] parseDropProgress: \(results.count) drops parsed from \(progressDicts.count) campaigns in progress")
        return results
    }

    // Legacy single-item parser kept for reference but no longer used by fetchInventory
    private func parseDropProgressLegacy(from progressDicts: [[String: Any]]) -> [Progress] {
        return progressDicts.compactMap { dict -> Progress? in
            guard
                let id = dict["id"] as? String,
                let drop = dict["drop"] as? [String: Any],
                let dropId = drop["id"] as? String,
                let dropName = drop["name"] as? String,
                let requiredMinutes = drop["requiredMinutesWatched"] as? Int,
                let campaign = dict["campaign"] as? [String: Any],
                let campaignId = campaign["id"] as? String,
                let progress = dict["progress"] as? [String: Any],
                let currentMinutes = progress["currentMinutesWatched"] as? Int
            else {
                return nil
            }

            let isClaimed = progress["isClaimed"] as? Bool ?? false

            return Progress(
                id: id,
                dropId: dropId,
                dropName: dropName,
                campaignId: campaignId,
                currentMinutes: currentMinutes,
                requiredMinutes: requiredMinutes,
                isClaimed: isClaimed
            )
        }
    }
}

// MARK: - Supporting Types

public struct GraphQLRequest {
    public let operationName: String
    public let sha256Hash: String
    public let variables: [String: Any]

    public init(
        operationName: String,
        sha256Hash: String,
        variables: [String: Any]
    ) {
        self.operationName = operationName
        self.sha256Hash = sha256Hash
        self.variables = variables
    }

    /// Convert to JSON dictionary for request body
    public func toJSON() -> [String: Any] {
        let result: [String: Any] = [
            "operationName": operationName,
            "variables": variables,
            "extensions": [
                "persistedQuery": [
                    "version": 1,
                    "sha256Hash": sha256Hash
                ]
            ]
        ]
        return result
    }
}
