import SwiftUI
import SwiftMinerCore
import SwiftMinerService

/// Navigation model for the multi-miner dashboard
/// Manages sidebar selection and view routing
@MainActor
@Observable
public final class NavigationModel {
    public struct CompletedUpdate: Equatable, Sendable {
        public let previousVersion: String
        public let currentVersion: String
        public let currentBuild: String
    }
    
    // MARK: - Navigation State
    public enum SidebarItem: Hashable, Identifiable {
        case overview
        case miners
        case drops
        case events

        public var id: String {
            switch self {
            case .overview: return "overview"
            case .miners: return "miners"
            case .drops: return "drops"
            case .events: return "events"
            }
        }

        public var displayName: String {
            switch self {
            case .overview: return "Overview"
            case .miners: return "miners"
            case .drops: return "Drops"
            case .events: return "Activity Log"
            }
        }
    }

    public enum DropsFilterIntent: Hashable {
        case upcoming
    }

    public enum OnboardingAccountState: Equatable {
        case noAccounts
        case hasAccounts(count: Int)
    }

    public enum OnboardingSetupStage: String, CaseIterable {
        case connecting
        case campaigns
        case inventory
        case finalising

        public var title: String {
            switch self {
            case .connecting: return "Connecting your account..."
            case .campaigns: return "Fetching active campaigns..."
            case .inventory: return "Syncing your inventory..."
            case .finalising: return "Preparing your dashboard..."
            }
        }
    }

    public struct OnboardingPresentation: Equatable {
        public let title: String
        public let subtitle: String
        public let accountState: OnboardingAccountState
        public let showsGamePreferences: Bool
        public let showsPreferences: Bool
        public let setupStage: OnboardingSetupStage?
    }
    
    public var selectedItem: SidebarItem? = .overview
    public var columnVisibility: NavigationSplitViewVisibility = .all
    public var requestedDropsFilter: DropsFilterIntent?


    // MARK: - Onboarding State

    /// Whether the optional onboarding surface should be visible.
    public var showOnboarding = false
    public private(set) var onboardingPresentation: OnboardingPresentation?
    public var onboardingSetupStage: OnboardingSetupStage = .connecting
    public var isRunningOnboardingSetup = false

    // MARK: - Sheet State

    /// Present the Add Account sheet from any view by setting this to true.
    public var showAddAccountSheet = false
    /// The existing miner whose Twitch credentials are being refreshed. `nil`
    /// means the account sheet is adding a separate account.
    public var reconnectingMinerId: String?

    public func reconnectTwitchAccount(for minerId: String) {
        reconnectingMinerId = minerId
        showAddAccountSheet = true
    }

    // MARK: - Content State

    public var selectedMinerId: String?
    public var selectedCampaignId: String?
    public private(set) var isDropsBackgroundRefreshRunning = false
    public var unownedAccounts: [Account] = []
    public var registeredUsers: [MinerUser] = []
    public var swiftBotState: SwiftBotConnectionState = .notConfigured
    public var pendingIntegrationsSettingsRequest = false
    public var onWebDashboardAvailabilityChanged: ((Bool, String?) -> Void)?

    public func requestDropsFilter(_ intent: DropsFilterIntent) {
        requestedDropsFilter = intent
    }

    public func consumeDropsFilterIntent() -> DropsFilterIntent? {
        defer { requestedDropsFilter = nil }
        return requestedDropsFilter
    }

    public func requestSwiftBotPairing() {
        Settings.shared.swiftBotEnabled = true
        pendingIntegrationsSettingsRequest = true
    }

    /// Ask the Settings window to open on Integrations, without changing any
    /// setting — the miner's Discord section links here rather than repeating
    /// the notification configuration inline.
    public func requestDiscordSettings() {
        pendingIntegrationsSettingsRequest = true
    }

    public func consumeIntegrationsSettingsRequest() -> Bool {
        defer { pendingIntegrationsSettingsRequest = false }
        return pendingIntegrationsSettingsRequest
    }

    /// Start the in-process HTTP server that exposes the SwiftMiner REST API to SwiftBot.
    /// Without this, SwiftBot's `/miner` command and pairing health checks have nothing to talk to.
    private func startSwiftMinerHTTPServerIfNeeded() async {
        guard httpAPIServer == nil else { return }
        Settings.shared.ensureSwiftBotSecrets()
        let apiKey = Settings.shared.swiftMinerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard apiKey.count >= 32 else {
            logEvent(message: "API server not started — API key missing", level: .warning)
            if Settings.shared.webDashboardConfigured {
                onWebDashboardAvailabilityChanged?(false, "The local API key is missing")
            }
            return
        }
        let endpoint = Settings.shared.swiftMinerAPIEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = URL(string: endpoint)?.port.flatMap { UInt16(exactly: $0) } ?? 8080

        // Populate the WebUI's avatar data before registering its routes. This
        // avoids serving the first authenticated projection with the Twitch
        // glyph while the asynchronous profile-image lookup is still running.
        await refreshDiscordDisplayNames()
        await TwitchAvatarStore.shared.refreshIfNeeded(
            miners: minerManager.miners,
            manager: minerManager
        )

        let projectionBuilder = DiscordProjectionBuilder(
            manager: sqliteManager,
            stateProvider: NavigationProjectionStateProvider(model: self),
            twitchProfileImageURL: { accountId in
                await MainActor.run {
                    TwitchAvatarStore.shared.url(forAccountId: accountId)
                }
            },
            discordProfileImageURL: { [weak self] discordUserId in
                await MainActor.run {
                    self?.discordUsersById[discordUserId]?.avatarURL
                }
            },
            prefersDiscordProfileImage: { accountId in
                await MainActor.run {
                    Settings.shared.avatarSource(forAccountId: accountId) == .discord
                }
            },
            accountNickname: { [weak self] accountId in
                await MainActor.run {
                    self?.minerManager.miners.first { $0.accountId == accountId }?.nickname
                }
            }
        )
        let clientId = Settings.shared.resolvedClientId
        let authService = TwitchAuthService(clientId: clientId, tokenStore: minerManager.tokenStore)
        let routes = DiscordAPIRoutes(
            manager: sqliteManager,
            projectionBuilder: projectionBuilder,
            apiKey: apiKey,
            adminLinkingService: adminLinkingService,
            authService: authService
        )
        await routes.setOnAccountActivated { [weak self] account, discordUserId in
            guard let self else { return }
            await self.minerManager.attachActivatedAccount(account)
            // Persist the Discord ↔ Twitch link to the Keychain account and the in-memory
            // miner so the new miner shows up as Linked immediately and survives restarts.
            await MainActor.run {
                self.minerManager.setOwnerDiscordId(forAccountId: account.id, to: discordUserId)
            }
            // Confirm to the user via Discord DM with their Twitch username and current app-level priority games.
            let priorityGames = await MainActor.run { Settings.shared.priorityGames }
            let portalBase = await MainActor.run { Self.portalBase() }
            _ = await self.swiftBotConnectionService.sendLinkedDM(
                to: discordUserId,
                twitchUsername: account.username,
                priorityGames: priorityGames,
                portalBase: portalBase
            )
        }
        await routes.setOnMinerControl { [weak self] discordUserId, action in
            guard let self else {
                return MinerControlResponse(ok: false, action: action.rawValue, state: "unavailable", twitchUsername: nil, message: "SwiftMiner is not available.")
            }
            return await self.handleDiscordMinerControl(discordUserId: discordUserId, action: action)
        }
        await routes.setOnMinerControlByAccount { [weak self] accountId, action in
            guard let self else {
                return MinerControlResponse(ok: false, action: action.rawValue, state: "unavailable", twitchUsername: nil, message: "SwiftMiner is not available.")
            }
            return await self.handleAccountMinerControl(accountId: accountId, action: action)
        }
        await routes.setOnRemoveMinerByAccount { [weak self] accountId in
            guard let self else { return false }
            let manager = await MainActor.run { self.minerManager }
            guard let miner = await MainActor.run(body: { manager.miners.first(where: { $0.accountId == accountId }) }) else {
                return false
            }
            await manager.removeAccount(minerId: miner.id)
            return true
        }
        await routes.setOnSetExcludedGamesByAccount { [weak self] accountId, games in
            guard let self else { return nil }
            return await MainActor.run {
                guard let miner = self.minerManager.miners.first(where: { $0.accountId == accountId }) else { return nil }
                let settings = Settings.shared
                let excluded = settings.setExcludedGames(accountId: accountId, games: games)
                self.minerManager.updateExcludedGames(excluded, forMinerId: miner.id)
                return settings.accountExcludedGames[accountId, default: []]
            }
        }
        await routes.setOnIgnoreLinkWarning { [weak self] discordUserId, gameName in
            guard let self else { return false }
            return await self.handleDiscordIgnoreLinkWarning(discordUserId: discordUserId, gameName: gameName)
        }
        await routes.setOnPauseLinkWarning { [weak self] discordUserId, gameName, expiresAt in
            guard let self else { return false }
            return await self.handleDiscordPauseLinkWarning(
                discordUserId: discordUserId,
                gameName: gameName,
                expiresAt: expiresAt
            )
        }
        await routes.setOnPrioritiseGame { [weak self] discordUserId, accountId, gameName in
            guard let self else { return nil }
            return await self.handleDiscordPrioritiseGame(
                discordUserId: discordUserId,
                accountId: accountId,
                gameName: gameName
            )
        }
        await routes.setOnSetPriorities { [weak self] discordUserId, accountId, games, includeGlobalPriorities, prioritySource in
            guard let self else { return nil }
            return await self.handleDiscordSetPriorities(
                discordUserId: discordUserId,
                accountId: accountId,
                games: games,
                includeGlobalPriorities: includeGlobalPriorities,
                prioritySource: prioritySource
            )
        }
        await routes.setOnSetPrioritiesByAccount { [weak self] accountId, games, includeGlobalPriorities, prioritySource in
            guard let self else { return nil }
            return await self.handleSetPrioritiesByAccount(
                accountId: accountId,
                games: games,
                includeGlobalPriorities: includeGlobalPriorities,
                prioritySource: prioritySource
            )
        }
        await routes.setOnKnownGames { [weak self] in
            guard let self else { return [] }
            return await MainActor.run {
                let names = self.minerManager.campaignStore.campaigns.map(\.game.name)
                return Array(Set(names)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            }
        }
        await routes.setOnCampaignSummaries { [weak self] accountId in
            guard let self else { return [] }
            return await MainActor.run {
                guard let miner = self.minerForAccount(accountId) else { return [] }
                let now = Date()
                let priorityKeys = Set(self.priorityGames(for: miner).map(Self.normalizedGameKey).filter { !$0.isEmpty })
                return miner.allCampaigns
                    .filter { campaign in
                        guard campaign.endDate > now,
                              campaign.status != .disabled,
                              !campaign.drops.isEmpty,
                              !campaign.drops.allSatisfy(\.isClaimed),
                              campaign.isAccountConnected else {
                            return false
                        }
                        guard !priorityKeys.isEmpty else { return true }
                        let gameName = Self.normalizedGameKey(campaign.game.name)
                        let gameId = Self.normalizedGameKey(campaign.game.id)
                        return priorityKeys.contains(gameName) || priorityKeys.contains(gameId)
                    }
                    .sorted { lhs, rhs in
                        if lhs.isTimeActive != rhs.isTimeActive { return lhs.isTimeActive }
                        return lhs.endDate < rhs.endDate
                    }
                    .prefix(12)
                    .map { campaign in
                        Self.webCampaignSummary(from: campaign)
                    }
            }
        }
        let router = HTTPRouter()
        await routes.configure(router)

        // Optional self-service web dashboard. Registered only when fully
        // configured; otherwise the server is byte-for-byte as before.
        var webPrefixes: [String] = []
        var webExact: Set<String> = []
        // Refresh SwiftBot's public hostname (for Discord SSO) before building
        // the config; fall back to the cached value if SwiftBot is unreachable.
        if Settings.shared.webDashboardEnabled, Settings.shared.swiftBotEnabled {
            if let info = await swiftBotConnectionService.fetchTunnelInfo(),
               !info.swiftBotHostname.isEmpty {
                Settings.shared.webDashboardSwiftBotHostname = info.swiftBotHostname
            }
        }
        refreshDMPortalBase()
        if Settings.shared.webDashboardConfigured, let webConfig = makeWebDashboardConfig() {
            let webRoutes = WebDashboardRoutes(
                config: webConfig,
                manager: sqliteManager,
                apiRoutes: routes,
                swiftBotSSOProvider: {
                    // Resolved per-request so pairing or tunnel info that
                    // arrives after launch enables Discord sign-in immediately —
                    // and so turning the switch off hides it just as promptly.
                    await MainActor.run {
                        let s = Settings.shared
                        let host = s.webDashboardSwiftBotHostname.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        let secret = s.swiftBotHmacSecret.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard s.webDashboardDiscordOAuthEnabled, s.swiftBotEnabled,
                              self.swiftBotState == .connected, !host.isEmpty, !secret.isEmpty else { return nil }
                        return WebSwiftBotSSO(origin: "https://\(host)", hmacSecret: secret)
                    }
                },
                twitchCredentialsProvider: {
                    // Likewise per-request: the "Allow Twitch OAuth sign-in"
                    // switch takes effect without restarting the app.
                    await MainActor.run {
                        let s = Settings.shared
                        guard s.webDashboardOAuthConfigured else { return nil }
                        return WebProviderCredentials(
                            clientID: s.webDashboardTwitchClientID.trimmingCharacters(in: .whitespacesAndNewlines),
                            clientSecret: s.webDashboardTwitchClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
                        )
                    }
                },
                logoDarkPNG: Self.webLogoPNGData(named: "web-logo-dark"),
                logoLightPNG: Self.webLogoPNGData(named: "web-logo-light"),
                audit: { [weak self] message in
                    await MainActor.run { self?.logWebAudit(message) }
                }
            )
            await webRoutes.configure(router)
            webPrefixes = WebDashboardConfig.publicPrefixes
            webExact = WebDashboardConfig.publicExactPaths
            logEvent(message: "Web dashboard enabled at \(webConfig.normalisedBase ?? "local-only")", level: .info)
        }

        let server = HTTPAPIServer(
            port: port,
            apiKey: apiKey,
            router: router,
            publicPathPrefixes: webPrefixes,
            publicExactPaths: webExact
        )
        do {
            try await server.start()
            httpAPIServer = server
            logEvent(message: "API server listening on port \(port)", level: .info)
            autoRegisterWebDashboardHostnameIfNeeded()
            if Settings.shared.webDashboardConfigured {
                onWebDashboardAvailabilityChanged?(true, nil)
            }
            Logger.app.info("SwiftMiner HTTP server listening on port \(port)")
        } catch {
            logEvent(message: "API server failed on port \(port): \(error.localizedDescription)", level: .error)
            if Settings.shared.webDashboardConfigured {
                onWebDashboardAvailabilityChanged?(false, error.localizedDescription)
            }
            Logger.app.error("Failed to start the HTTP server on port \(port): \(error.localizedDescription)")
        }
    }

    /// Number of miners currently configured (used to gate web internet access).
    public var configuredMinerCount: Int { minerManager.miners.count }

    /// True when it's safe to install an update and relaunch: no miner is
    /// actively earning progress. Stalled, errored, or auth-blocked miners
    /// don't block the install — an update may be exactly what fixes them.
    public var isSafeToInstallUpdateNow: Bool {
        !minerManager.miners.contains { miner in
            miner.isRunning
                && miner.currentCampaignId != nil
                && !miner.needsAuth
                && miner.status != .error
                && miner.status != .blockedAccountNotLinked
        }
    }

    /// Records a web-dashboard audit entry in the Activity Log. The raw message
    /// carries the `[web-audit]` tag so the log's Audit filter picks it up.
    public func logWebAudit(_ message: String) {
        logEvent(message: message, level: .info, rawMessage: "[web-audit] \(message)")
    }

    /// Human-readable name for a web principal, for audit entries.
    func webAuditActorName(principalType: String, principalId: String) -> String {
        switch principalType {
        case "twitch":
            return minerManager.miners.first { $0.accountId == principalId }?.username ?? "Twitch user"
        case "discord":
            if let miner = minerManager.miners.first(where: { $0.ownerDiscordId == principalId }) {
                return miner.username
            }
            return "Discord user"
        case "local":
            return principalId
        default:
            return "Web user"
        }
    }

    /// Audits the difference between two priority lists as plain sentences,
    /// e.g. "Gabe added Titanfall to their priority list".
    func auditPriorityChange(
        actor: String,
        old: [String],
        new: [String],
        oldSource: Settings.AccountPrioritySource,
        newSource: Settings.AccountPrioritySource
    ) {
        for message in Self.priorityAuditMessages(
            actor: actor,
            old: old,
            new: new,
            oldSource: oldSource,
            newSource: newSource
        ) {
            logWebAudit(message)
        }
    }

    static func priorityAuditMessages(
        actor: String,
        old: [String],
        new: [String],
        oldSource: Settings.AccountPrioritySource,
        newSource: Settings.AccountPrioritySource
    ) -> [String] {
        var messages: [String] = []
        if oldSource != newSource {
            messages.append("\(actor) changed priority mode from \(prioritySourceTitle(oldSource)) to \(prioritySourceTitle(newSource))")
        }

        let added = new.filter { !old.contains($0) }
        let removed = old.filter { !new.contains($0) }
        for game in added {
            messages.append("\(actor) added \(game) to their priority list")
        }
        for game in removed {
            messages.append("\(actor) removed \(game) from their priority list")
        }
        if added.isEmpty, removed.isEmpty, old != new {
            messages.append("\(actor) reordered their priority list")
        }
        return messages
    }

    private static func prioritySourceTitle(_ source: Settings.AccountPrioritySource) -> String {
        switch source {
        case .global: return "Global"
        case .globalAndPersonal: return "Mixed"
        case .personal: return "Personal"
        }
    }

    /// Fetches SwiftBot's tunnel domain so the Web tab only needs a subdomain.
    func fetchSwiftBotTunnelInfo() async -> SwiftBotTunnelInfo? {
        await swiftBotConnectionService.fetchTunnelInfo()
    }

    /// Asks SwiftBot to carry the dashboard's public hostname on its Cloudflare
    /// tunnel, routed to SwiftMiner's local HTTP server. One-click alternative
    /// to manually adding the hostname in the Cloudflare dashboard.
    /// `logFailures` is off for the launch-time auto attempt so retries while
    /// SwiftBot is still starting don't spam the Activity Log.
    func registerWebDashboardHostnameWithSwiftBot(logFailures: Bool = true) async -> SwiftBotTunnelRegistrationResult {
        let s = Settings.shared
        guard let url = Settings.normalizedWebDashboardURL(from: s.webDashboardBaseURL),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else {
            return .failure(message: "Set a valid https Public URL first.")
        }
        let port = URL(string: s.swiftMinerAPIEndpoint)?.port ?? 8080
        let result = await swiftBotConnectionService.registerTunnelHostname(
            hostname: host,
            service: "http://localhost:\(port)",
            hmacSecret: s.swiftBotHmacSecret
        )
        switch result {
        case .success(let publicURL):
            logEvent(message: "Web dashboard registered on SwiftBot's tunnel at \(publicURL)", level: .info)
            refreshDMPortalBase()
            await announceWebDashboardIfNeeded()
        case .failure(let message):
            if logFailures {
                logEvent(message: "Web dashboard tunnel registration failed: \(message)", level: .warning)
            }
        }
        return result
    }

    /// One-time "your web dashboard is live" DM to every registered Discord
    /// user, sent only after the dashboard is confirmed working (a successful
    /// tunnel registration). Never resent on updates or relaunches.
    private func announceWebDashboardIfNeeded() async {
        guard !Settings.shared.webDashboardAnnounced, Settings.shared.swiftBotEnabled else { return }
        let users = await adminLinkingService.getAllUsers()
        guard !users.isEmpty else {
            // No one to tell yet — keep the flag clear so the first user
            // linked after launch still gets the announcement.
            return
        }
        var sent = 0
        for user in users {
            let portal = SwiftMinerPortalLink(base: Self.portalBase())
            let request = SwiftBotDMRequest(
                messageType: .webDashboardAvailable,
                debug: false,
                eventId: "webDashboardAvailable:\(user.discordId)",
                portalURL: portal?.dashboard,
                portalDestination: portal.map { _ in SwiftBotPortalDestination.dashboard.rawValue },
                helpURL: SwiftMinerHelpLink.webDashboard
            )
            if await swiftBotConnectionService.sendEventDM(to: user.discordId, request: request) {
                sent += 1
            }
        }
        if sent > 0 {
            Settings.shared.webDashboardAnnounced = true
            logWebAudit("Web dashboard announcement sent to \(sent) Discord user\(sent == 1 ? "" : "s")")
        }
    }

    /// Re-asserts the dashboard's hostname on SwiftBot's tunnel at launch, so a
    /// configured setup self-heals (tunnel reset, restored settings, SwiftBot
    /// reinstalls) without anyone clicking the Register button again. Retries
    /// quietly for a while because SwiftBot may still be starting up; logs one
    /// warning only if every attempt fails.
    private func autoRegisterWebDashboardHostnameIfNeeded() {
        let s = Settings.shared
        guard s.webDashboardEnabled, s.swiftBotEnabled,
              !s.swiftBotHmacSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let url = Settings.normalizedWebDashboardURL(from: s.webDashboardBaseURL),
              url.scheme?.lowercased() == "https" else {
            return
        }
        Task { [weak self] in
            var lastFailure = "SwiftBot was unreachable."
            for attempt in 0..<5 {
                if attempt > 0 { try? await Task.sleep(for: .seconds(20)) }
                guard let self else { return }
                let result = await self.registerWebDashboardHostnameWithSwiftBot(logFailures: false)
                switch result {
                case .success:
                    return // success is logged by the register call itself
                case .failure(let message):
                    lastFailure = message
                }
            }
            guard let self else { return }
            await MainActor.run {
                self.logEvent(message: "Web dashboard tunnel auto-registration failed: \(lastFailure)", level: .warning)
            }
        }
    }

    /// Bundled login-logo PNG (light/dark exports of the gem artwork with
    /// mode-appropriate shadows baked in). Falls back to rendering the live app
    /// icon if the bundled asset is somehow missing.
    private static func webLogoPNGData(named name: String) -> Data? {
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let data = try? Data(contentsOf: url) {
            return data
        }
        return appIconPNGData()
    }

    /// The app icon rendered to a 128pt PNG — fallback for the login logo.
    private static func appIconPNGData() -> Data? {
        guard let icon = NSApplication.shared.applicationIconImage else { return nil }
        let size = NSSize(width: 128, height: 128)
        let rendered = NSImage(size: size)
        rendered.lockFocus()
        icon.draw(in: NSRect(origin: .zero, size: size))
        rendered.unlockFocus()
        guard let tiff = rendered.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    /// The portal origin DM deep links are built from, or nil when no public
    /// URL is configured. DMs then carry no portal button rather than one that
    /// cannot resolve for the recipient.
    static func portalBase() -> String? {
        Settings.normalizedWebDashboardURL(from: Settings.shared.webDashboardBaseURL)?.absoluteString
    }

    /// Re-point DM deep links after the public URL changes — the operator can
    /// edit it in Settings, and tunnel registration composes it automatically.
    func refreshDMPortalBase() {
        let base = Self.portalBase()
        Task { await dmEventService?.updatePortalBase(base) }
    }

    /// Build the web dashboard config from Settings, or nil if no sign-in method
    /// is available. A public URL is optional — local sign-in needs none.
    private func makeWebDashboardConfig() -> WebDashboardConfig? {
        let s = Settings.shared
        func clean(_ v: String) -> String { v.trimmingCharacters(in: .whitespacesAndNewlines) }

        // Public URL is optional; bare hostnames are treated as https.
        let baseURL = Settings.normalizedWebDashboardURL(from: s.webDashboardBaseURL)

        // Provider switches let the operator turn either public OAuth flow off
        // without deleting its credentials or SwiftBot pairing details.
        var twitch: WebProviderCredentials?
        if s.webDashboardOAuthConfigured {
            twitch = WebProviderCredentials(clientID: clean(s.webDashboardTwitchClientID),
                                            clientSecret: clean(s.webDashboardTwitchClientSecret))
        }
        var local: WebLocalCredentials?
        if s.webDashboardLocalConfigured {
            local = WebLocalCredentials(username: clean(s.webDashboardLocalUsername),
                                        passwordHash: s.webDashboardLocalPasswordHash)
        }

        // Discord sign-in brokered via the paired SwiftBot — needs SwiftBot's
        // public hostname (cached from its tunnel info) and the pairing secret.
        var swiftBotSSO: WebSwiftBotSSO?
        let botHost = clean(s.webDashboardSwiftBotHostname).lowercased()
        let pairingSecret = clean(s.swiftBotHmacSecret)
        if s.webDashboardDiscordOAuthConfigured, !botHost.isEmpty, !pairingSecret.isEmpty {
            swiftBotSSO = WebSwiftBotSSO(origin: "https://\(botHost)", hmacSecret: pairingSecret)
        }

        let config = WebDashboardConfig(baseURL: baseURL, discord: nil, twitch: twitch, local: local, swiftBotSSO: swiftBotSSO)
        return config.anyEnabled ? config : nil
    }

    /// Restores a miner's Discord owner from the database when the stored
    /// account has lost it.
    ///
    /// Signing in again used to save an account built purely from Twitch's
    /// response, which erased the Discord owner from the Keychain record while
    /// the `twitch_accounts` row kept it. The two disagreed from then on: the
    /// web dashboard reads the row and still resolved Discord profile pictures,
    /// the app read the account and could not. Re-auth now preserves the owner,
    /// so this only repairs accounts an earlier build already unlinked.
    func restoreDiscordOwnersFromDatabase() async {
        for miner in minerManager.miners where miner.ownerDiscordId == nil {
            guard let ownerDiscordId = await sqliteManager.ownerDiscordId(forTwitchAccount: miner.accountId) else {
                continue
            }
            minerManager.setOwnerDiscordId(forAccountId: miner.accountId, to: ownerDiscordId)
            logEvent(
                message: "Restored the Discord link for \(miner.displayName)",
                level: .info,
                minerId: miner.id
            )
        }
    }

    /// Upserts every MinerManager account into SQLite so AdminLinkingService can find them.
    /// Only touches twitch_id and username — never overwrites owner_discord_id or tokens.
    func syncMinersToSQLite() async {
        for miner in minerManager.miners {
            await adminLinkingService.upsertAccountIdentity(
                twitchId: miner.accountId,
                username: miner.username,
                isOperator: miner.isOperator
            )
        }
    }

    public func refreshUnownedAccounts() async {
        unownedAccounts = await adminLinkingService.getUnownedAccounts()
    }

    public func refreshRegisteredUsers() async {
        registeredUsers = await adminLinkingService.getAllUsers()
    }

    // MARK: - Events

    /// Human-readable event entries.
    public var events: [EventEntry] = []
    /// Retention size, from Settings. Read on each use so changing it in Advanced
    /// takes effect without a relaunch.
    private var maxEvents: Int { Settings.shared.maxLogEntries }
    private var completedUpdateAwaitingNotification: CompletedUpdate?
    private static let lastLaunchedVersionKey = "SwiftMinerLastLaunchedVersion"
    private static let lastLaunchedBuildKey = "SwiftMinerLastLaunchedBuild"
    private static let pendingUpdateFromVersionKey = "SwiftMinerPendingUpdateFromVersion"
    private static let pendingUpdateToVersionKey = "SwiftMinerPendingUpdateToVersion"

    // MARK: - Drop Completion Tracking

    /// Timestamps of when a drop was first seen as claimed/completed.
    /// Key: dropId, Value: completion Date.
    public var completedDropTimestamps: [String: Date] = [:]

    // MARK: - Miner Manager

    public let minerManager: MinerManager
    /// Opt-in diagnostic that tracks the app's own CPU/memory usage (Advanced settings).
    let resourceUsageMonitor = ResourceUsageMonitor()
    public let adminLinkingService: any AdminLinkingService
    public let swiftBotConnectionService: any SwiftBotConnectionService
    public let eventOutboxService: EventOutboxService
    public let eventEmitter: EventEmitterService
    public let dmLogStore: DMLogStore
    public private(set) var dmEventService: SwiftMinerDMEventService?
    /// Cached Discord display names keyed by Discord user ID. Refreshed from
    /// SwiftBot whenever the connection is healthy or the Discord tab loads.
    public private(set) var discordDisplayNamesById: [String: String] = [:]
    public private(set) var discordUsersById: [String: SwiftBotDiscordUser] = [:]
    private let sqliteManager: SQLiteManager
    private let activityLogStore: ActivityLogStore
    private var httpAPIServer: HTTPAPIServer?
    private var onboardingSetupTask: Task<Void, Never>?
    @ObservationIgnored private var dropsPreloadTask: Task<Void, Never>?
    @ObservationIgnored private var dropsBackgroundRefreshTask: Task<Void, Never>?
    private var lastDropsBackgroundRefreshStartedAt: Date?
    private var lastKnownAccountCount = 0
    private var hasConfiguredOnboardingBaseline = false

    // MARK: - Initialization

    public init(clientId: String, minerManager: MinerManager? = nil) {
        self.minerManager = minerManager ?? MinerManager(clientId: clientId)
        
        let folderURL = SwiftMinerRuntime.isRunningTests
            ? SwiftMinerRuntime.testSupportDirectory
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SwiftMiner")
        
        // Create directory synchronously to avoid races in Phase 1
        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        
        let databaseName = SwiftMinerRuntime.isRunningTests
            ? "miner-\(UUID().uuidString).db"
            : "miner.db"
        let dbURL = folderURL.appendingPathComponent(databaseName)
        let manager = SQLiteManager(databaseURL: dbURL)
        self.sqliteManager = manager
        // The floor matches the overall size, so narrowing to one filter can fill the
        // Activity Log to its configured capacity instead of running out after a few
        // hundred rows. Rare categories never approach it; busy ones are what grow.
        self.activityLogStore = ActivityLogStore(
            manager: manager,
            maxEntries: Settings.shared.maxLogEntries,
            perCategoryFloor: Settings.shared.maxLogEntries
        )
        self.adminLinkingService = SQLiteAdminLinkingService(manager: manager)
        self.eventEmitter = EventEmitterService(manager: manager)
        let dmLogStore = DMLogStore(manager: manager)
        self.dmLogStore = dmLogStore
        
        // Initialize event outbox delivery service first so connection service can reference it
        let webhookURL = URL(string: Settings.shared.swiftBotWebhookURL)
        let outboxService = EventOutboxService(
            manager: manager,
            webhookURL: webhookURL,
            hmacSecret: Settings.shared.swiftBotHmacSecret
        )
        self.eventOutboxService = outboxService

        // Initialize SwiftBot connection service
        let endpoint = Settings.shared.swiftBotEndpoint
        self.swiftBotConnectionService = RestSwiftBotConnectionService(
            endpoint: endpoint,
            dmLogStore: dmLogStore
        ) {
            outboxService
        }
    }

    // MARK: - Setup

    /// Wire MinerManager callbacks and load saved accounts.
    /// Must be awaited before `AppModel.setup()` so `miners` is populated.
    public func setup() async {
        // Phase 1: Open DB before any service calls
        do {
            try await sqliteManager.open()
            await loadPersistentEvents()
            recordInstalledVersionTransition()
        } catch {
            Logger.storage.error("Failed to open the SwiftMiner database: \(error.localizedDescription). Activity history and persisted events are unavailable this session.")
        }

        await wireDMActivityLogging()

        if !SwiftMinerRuntime.isRunningTests, Settings.shared.swiftBotEnabled {
            await checkSwiftBotConnection()
            await eventOutboxService.updateConfig(
                webhookURL: URL(string: Settings.shared.swiftBotWebhookURL),
                hmacSecret: Settings.shared.swiftBotHmacSecret
            )
            await eventOutboxService.start()
            await refreshDiscordDisplayNames()
        }
        if !SwiftMinerRuntime.isRunningTests {
            startSwiftBotStateSync()
            startResourceUsageMonitoringIfEnabled()
        }

        // Wire DM event production — lightweight event emission, notification decisions stay in SwiftBot
        let dmEventService = SwiftMinerDMEventService(
            connectionService: swiftBotConnectionService,
            portalBase: Self.portalBase()
        )
        self.dmEventService = dmEventService

        // No Discord DM is sent per drop claim — user-facing DMs are sent only
        // when the full campaign completes, to keep DM volume low.

        minerManager.onAuthRequiredEvent = { [weak self] minerId in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard Settings.shared.dmConnectionExpiredEnabled else { return }
                guard Settings.shared.allowsOperatorNotifications() else { return }
                guard let miner = self.minerManager.miners.first(where: { $0.id == minerId }) else { return }
                let priorityGames = self.priorityGames(for: miner)
                await dmEventService.emitReauthRequired(
                    accountId: miner.accountId,
                    discordUserId: miner.ownerDiscordId,
                    twitchUsername: miner.username,
                    priorityGames: priorityGames
                )
            }
        }

        // Persists each claim so the Discord "drops claimed today / this week"
        // stats have data. Nothing wrote `reward_ledger` before, so both of
        // those figures always read zero regardless of how much was claimed.
        minerManager.onDropClaimedEvent = { [weak self] minerId, drop, _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let miner = self.minerManager.miners.first(where: { $0.id == minerId }) else { return }

                // Twitch benefit IDs identify a reward, not a reward-per-user,
                // so two accounts claiming the same drop share one. The ledger
                // keys on benefit_id, so scope it per account — otherwise the
                // second account's claim is silently deduped away and its
                // per-account count comes out short.
                let resolved = miner.allCampaigns
                    .flatMap(\.drops)
                    .first { $0.id == drop.id }
                let benefitId = resolved?.benefitIds.first
                    ?? resolved?.benefitID.nilIfBlank
                    ?? drop.id
                await self.sqliteManager.recordClaimedReward(
                    twitchId: miner.accountId,
                    benefitId: "\(miner.accountId):\(benefitId)",
                    rewardName: drop.name
                )
            }
        }

        minerManager.onCampaignCompletedEvent = { [weak self] minerId, campaign in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard Settings.shared.dmCampaignCompletedEnabled else { return }
                guard Settings.shared.allowsOperatorNotifications() else { return }
                guard let miner = self.minerManager.miners.first(where: { $0.id == minerId }) else { return }
                let priorityGames = self.priorityGames(for: miner)
                await dmEventService.emitCampaignCompleted(
                    campaignId: campaign.id,
                    campaignName: campaign.name,
                    gameName: campaign.game.name,
                    gameId: campaign.game.id,
                    gameArtworkURL: campaign.game.boxArtURL?.absoluteString,
                    accountId: miner.accountId,
                    minerDisplayName: miner.displayName,
                    discordUserId: miner.ownerDiscordId,
                    priorityGames: priorityGames
                )
            }
        }

        minerManager.onCampaignDetectedEvent = { [weak self] minerId, campaign in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard Settings.shared.allowsOperatorNotifications() else { return }

                if Settings.shared.swiftBotEnabled {
                    await self.eventEmitter.emitSwiftMinerCampaignAnnounced(campaign: campaign)
                }

                guard Settings.shared.dmCampaignDetectedEnabled else { return }
                guard let miner = self.minerManager.miners.first(where: { $0.id == minerId }) else { return }
                let priorityGames = self.priorityGames(for: miner)
                guard priorityGames.contains(where: { $0.caseInsensitiveCompare(campaign.game.name) == .orderedSame }) else { return }
                await dmEventService.emitCampaignDetected(
                    campaignId: campaign.id,
                    campaignName: campaign.name,
                    gameName: campaign.game.name,
                    gameId: campaign.game.id,
                    gameArtworkURL: campaign.game.boxArtURL?.absoluteString,
                    accountId: miner.accountId,
                    minerDisplayName: miner.displayName,
                    discordUserId: miner.ownerDiscordId,
                    priorityGames: priorityGames
                )
            }
        }

        minerManager.onLinkWarningEvent = { [weak self] minerId, gameName in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard Settings.shared.dmLinkRequiredEnabled else { return }
                guard Settings.shared.allowsOperatorNotifications() else { return }
                guard let miner = self.minerManager.miners.first(where: { $0.id == minerId }) else { return }
                let priorityGames = self.priorityGames(for: miner)
                let gameId = self.accountLinkWarningGameKey(for: gameName)
                await dmEventService.emitPrioritisedGameNeedsLinking(
                    gameName: gameName,
                    gameId: gameId,
                    accountId: miner.accountId,
                    minerDisplayName: miner.displayName,
                    discordUserId: miner.ownerDiscordId,
                    priorityGames: priorityGames
                )
            }
        }

        minerManager.onAccountActionRequiredEvent = { [weak self] minerId, reason in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard Settings.shared.dmAccountActionRequiredEnabled else { return }
                guard Settings.shared.allowsOperatorNotifications() else { return }
                guard let miner = self.minerManager.miners.first(where: { $0.id == minerId }) else { return }
                let priorityGames = self.priorityGames(for: miner)
                await dmEventService.emitAccountActionRequired(
                    accountId: miner.accountId,
                    reason: reason,
                    discordUserId: miner.ownerDiscordId,
                    twitchUsername: miner.username,
                    priorityGames: priorityGames
                )
            }
        }

        minerManager.onWelcomeBackEvent = { [weak self] minerId in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard Settings.shared.dmWelcomeBackEnabled else { return }
                guard Settings.shared.allowsOperatorNotifications() else { return }
                guard let miner = self.minerManager.miners.first(where: { $0.id == minerId }) else { return }
                let priorityGames = self.priorityGames(for: miner)
                await dmEventService.emitWelcomeBack(
                    accountId: miner.accountId,
                    discordUserId: miner.ownerDiscordId,
                    twitchUsername: miner.username,
                    priorityGames: priorityGames
                )
            }
        }

        minerManager.onLogMessage = { [weak self] minerId, message in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.processLogMessage(minerId: minerId, message: message)
            }
        }
        let settings = Settings.shared
        minerManager.updateClientId(settings.resolvedClientId)
        minerManager.onMinerIdentitiesChanged = { [weak self] in
            Task { [weak self] in
                await self?.syncMinersToSQLite()
            }
        }
        minerManager.onAccountRemoved = { [weak self] twitchAccountId in
            Task { @MainActor [weak self] in
                Settings.shared.removeAvatarSource(forAccountId: twitchAccountId)
                Settings.shared.removeExcludedGames(forAccountId: twitchAccountId)
                await self?.adminLinkingService.deleteAccountRow(twitchId: twitchAccountId)
            }
        }

        await minerManager.setup(
            autoStart: !SwiftMinerRuntime.isRunningTests,
            priorityGames: settings.priorityGames,
            excludedGames: settings.excludedGames,
            strategy: settings.miningStrategy,
            enableBadgesEmotes: settings.enableBadgesEmotes,
            avoidDuplicateStreams: settings.avoidDuplicateStreams,
            antiStallRecoveryEnabled: settings.antiStallRecoveryEnabled,
            prioritiseFollowedStreamers: settings.prioritiseFollowedStreamers,
            failoverStreamers: settings.gameFailoverStreamers,
            ignoredWarnings: settings.activeIgnoredWarnings,
            priorityGamesForMiner: { miner in
                settings.priorityGames(forAccountId: miner.accountId)
            },
            excludedGamesForMiner: { miner in
                settings.excludedGames(forAccountId: miner.accountId)
            }
        )

        // Re-adopt Discord owners that an older build's re-auth dropped from the
        // stored accounts, before anything reads `ownerDiscordId`.
        await restoreDiscordOwnersFromDatabase()

        // Mirror saved identities before serving the dashboard. This also makes
        // a Discord operator's role available with the first web request.
        await syncMinersToSQLite()

        // The dashboard's startup avatar warm-up needs the persisted accounts
        // that `minerManager.setup` has just loaded. Starting it before this
        // point works only when a prior run happened to leave an avatar cache,
        // which made Release builds show the Twitch placeholder on first load.
        if !SwiftMinerRuntime.isRunningTests {
            await startSwiftMinerHTTPServerIfNeeded()
        }
        preloadDropsTab()
    }

    public func preloadDropsTab(force: Bool = false) {
        guard !minerManager.miners.isEmpty else { return }

        let coordinator = minerManager.dataCoordinator
        if !force, !coordinator.lastKnownAllCampaigns.isEmpty {
            return
        }
        if !force, dropsPreloadTask != nil {
            return
        }

        dropsPreloadTask?.cancel()
        dropsPreloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.dropsPreloadTask = nil }

            let coordinator = self.minerManager.dataCoordinator
            if !force, !coordinator.lastKnownAllCampaigns.isEmpty {
                return
            }

            _ = await coordinator.allCampaigns()
            guard !Task.isCancelled else { return }

            _ = self.refreshDropsInBackground(force: force)
        }
    }

    @discardableResult
    public func refreshDropsInBackground(force: Bool = false) -> Bool {
        guard !minerManager.miners.isEmpty else { return false }

        if dropsBackgroundRefreshTask != nil {
            return true
        }

        let minimumRefreshInterval: TimeInterval = 120
        if !force,
           let lastDropsBackgroundRefreshStartedAt,
           Date().timeIntervalSince(lastDropsBackgroundRefreshStartedAt) < minimumRefreshInterval {
            return false
        }

        lastDropsBackgroundRefreshStartedAt = Date()
        isDropsBackgroundRefreshRunning = true
        dropsBackgroundRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isDropsBackgroundRefreshRunning = false
                self.dropsBackgroundRefreshTask = nil
            }

            let coordinator = self.minerManager.dataCoordinator
            await coordinator.refreshAll()
            guard !Task.isCancelled else { return }

            NotificationCenter.default.post(name: .dropsCampaignsDidUpdate, object: coordinator)
        }
        return true
    }

    public func configureOnboardingPresentation() {
        lastKnownAccountCount = minerManager.miners.count
        hasConfiguredOnboardingBaseline = true
        clearOnboardingPresentation()
    }

    public func refreshOnboardingPresentation() {
        clearOnboardingPresentation()
    }

    public func dismissOnboarding() {
        onboardingSetupTask?.cancel()
        onboardingSetupTask = nil
        isRunningOnboardingSetup = false
        settings.hasDismissedOnboarding = true
        clearOnboardingPresentation()
    }

    public func updateOnboardingSetupStage(_ stage: OnboardingSetupStage) {
        onboardingSetupStage = stage
        clearOnboardingPresentation()
    }

    public func handleOnboardingAuthenticationCompleted(resetDismissal _: Bool = true) {
        clearOnboardingPresentation()
    }

    public func handleAccountCountChange() {
        let currentCount = minerManager.miners.count

        // Ignore account-load churn before the initial onboarding baseline is configured.
        // This prevents restoring multiple saved accounts from accidentally resetting
        // a previously dismissed onboarding flow.
        guard hasConfiguredOnboardingBaseline else {
            lastKnownAccountCount = currentCount
            return
        }

        let previousCount = lastKnownAccountCount
        guard currentCount != previousCount else {
            clearOnboardingPresentation()
            return
        }

        lastKnownAccountCount = currentCount
        clearOnboardingPresentation()
    }

    public func startOnboardingSetupIfNeeded() {
        clearOnboardingPresentation()
    }

    private func processLogMessage(minerId: String, message: String) {
        let level = eventLevel(forLogMessage: message)
        guard Self.shouldRecordActivityLogMessage(message, level: level) else { return }
        
        // Transform common logs into readable events
        var displayMessage = message
        if message.contains("[Engine] Started watching") {
            displayMessage = "Started watching campaign"
        } else if message.contains("CLAIMED") {
            displayMessage = "Drop claimed successfully"
        }
        
        logEvent(message: displayMessage, level: level, minerId: minerId, rawMessage: message)
    }

    private func eventLevel(forLogMessage message: String) -> EventLevel {
        let lowercased = message.lowercased()
        if lowercased.contains("\u{26A0}\u{FE0F}")
            || lowercased.hasPrefix("warning")
            || lowercased.contains(" warning")
            || lowercased.contains("could not")
            || lowercased.contains("progress stalled")
            || lowercased.contains("subscription required")
            || lowercased.contains("may need linking") {
            return .warning
        }

        if lowercased.contains("\u{274C}")
            || lowercased.hasPrefix("error")
            || lowercased.contains(" error:")
            || lowercased.contains("failed to")
            || lowercased.contains("failure") {
            return .error
        }

        return .info
    }

    nonisolated static func shouldRecordActivityLogMessage(_ message: String, level: EventLevel) -> Bool {
        guard level == .info else { return true }

        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("· ") {
            return false
        }

        if message.hasPrefix("[CampaignSelect]") {
            return false
        }

        if message.hasPrefix("[ChannelSelect]   Verifying ")
            || message.hasPrefix("[ChannelSelect]     None of our candidates active here")
            || message.hasPrefix("[ChannelSelect]     ACL blocked match")
            || message.hasPrefix("[ChannelSelect]   Probing ACL channel") {
            return false
        }

        if message.hasPrefix("Campaigns: ")
            || message.hasPrefix("Checking game: ")
            || message.hasPrefix("No claimable drops found in inventory")
            || message.hasPrefix("Watch heartbeat sent for ") {
            return false
        }

        return true
    }

    public func logEvent(message: String, level: EventLevel = .info, minerId: String? = nil, rawMessage: String? = nil) {
        let base = EventEntry(message: message, level: level, minerId: minerId, rawMessage: rawMessage)
        let entry = base.withCategory(primaryEventFilter(for: base).rawValue)
        events.insert(entry, at: 0)
        events = Self.applyRetention(to: events, maxEntries: maxEvents, perCategoryFloor: maxEvents)
        Task { [activityLogStore] in
            await activityLogStore.save(entry)
        }
    }

    /// Applies a changed Activity Log retention size to the live in-memory list and the
    /// store, so Advanced settings takes effect without a relaunch. Growing it also
    /// reloads, since the extra history is on disk but not yet in `events`.
    public func setActivityLogRetention(_ maxEntries: Int) {
        events = Self.applyRetention(to: events, maxEntries: maxEntries, perCategoryFloor: maxEntries)
        Task { [activityLogStore] in
            await activityLogStore.setRetention(maxEntries: maxEntries, perCategoryFloor: maxEntries)
            await loadPersistentEvents()
        }
    }

    /// Keeps the newest `maxEvents` overall, plus a floor of the newest entries in each
    /// category. Trimming by recency alone means routine chatter — 99.9% of the volume on
    /// a multi-miner instance — evicts every audit entry and warning within the hour, so
    /// selecting a single filter showed almost nothing. Mirrors `ActivityLogStore`'s prune.
    static func applyRetention(
        to entries: [EventEntry],
        maxEntries: Int = 5000,
        perCategoryFloor: Int = 500
    ) -> [EventEntry] {
        guard entries.count > maxEntries else { return entries }

        let ordered = entries.sorted { $0.timestamp > $1.timestamp }
        var keep = Set(ordered.prefix(maxEntries).map(\.id))

        var seenPerCategory: [String: Int] = [:]
        for entry in ordered {
            let category = entry.category ?? EventFilter.system.rawValue
            let seen = seenPerCategory[category, default: 0]
            guard seen < perCategoryFloor else { continue }
            seenPerCategory[category] = seen + 1
            keep.insert(entry.id)
        }

        return ordered.filter { keep.contains($0.id) }
    }

    private func loadPersistentEvents() async {
        let persisted = await activityLogStore.loadEntries(limit: maxEvents)
        guard !persisted.isEmpty else { return }

        var entriesById = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
        for entry in persisted {
            entriesById[entry.id] = entry
        }

        events = Self.applyRetention(to: Array(entriesById.values), maxEntries: maxEvents, perCategoryFloor: maxEvents)
    }

    public func recordPendingUpdate(to version: String) {
        let currentVersion = Self.currentAppVersion
        UserDefaults.standard.set(currentVersion, forKey: Self.pendingUpdateFromVersionKey)
        UserDefaults.standard.set(version, forKey: Self.pendingUpdateToVersionKey)
    }

    private func recordInstalledVersionTransition() {
        let defaults = UserDefaults.standard
        let currentVersion = Self.currentAppVersion
        let currentBuild = Self.currentAppBuild
        let pendingFrom = defaults.string(forKey: Self.pendingUpdateFromVersionKey)
        let pendingTo = defaults.string(forKey: Self.pendingUpdateToVersionKey)
        let lastVersion = defaults.string(forKey: Self.lastLaunchedVersionKey)

        let previousVersion = pendingFrom ?? lastVersion
        let updateCompleted = previousVersion.map { $0 != currentVersion } == true
            || (pendingTo == currentVersion && pendingFrom != currentVersion)

        if updateCompleted, let previousVersion {
            completedUpdateAwaitingNotification = CompletedUpdate(
                previousVersion: previousVersion,
                currentVersion: currentVersion,
                currentBuild: currentBuild
            )
            logEvent(
                message: "SwiftMiner updated from \(previousVersion) to \(currentVersion) (build \(currentBuild))",
                level: .info,
                rawMessage: "[update] Installed SwiftMiner \(currentVersion) build \(currentBuild) from \(previousVersion)"
            )
        } else if previousVersion == nil {
            // Establish a durable version baseline for fresh installs and for
            // users upgrading from versions released before update auditing.
            logEvent(
                message: "SwiftMiner \(currentVersion) launched (build \(currentBuild))",
                level: .info,
                rawMessage: "[update] Version baseline \(currentVersion) build \(currentBuild)"
            )
        }

        defaults.set(currentVersion, forKey: Self.lastLaunchedVersionKey)
        defaults.set(currentBuild, forKey: Self.lastLaunchedBuildKey)
        if updateCompleted || pendingTo == nil {
            defaults.removeObject(forKey: Self.pendingUpdateFromVersionKey)
            defaults.removeObject(forKey: Self.pendingUpdateToVersionKey)
        }
    }

    public func consumeCompletedUpdateNotification() -> CompletedUpdate? {
        defer { completedUpdateAwaitingNotification = nil }
        return completedUpdateAwaitingNotification
    }

    private static var currentAppVersion: String {
        let value = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "unknown" : value
    }

    private static var currentAppBuild: String {
        let value = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "unknown" : value
    }

    /// Wires DM dispatch in the connection service into the activity log.
    /// Production sends only — debug previews stay out of the timeline.
    private func wireDMActivityLogging() async {
        guard let rest = swiftBotConnectionService as? RestSwiftBotConnectionService else { return }
        await rest.setDMActivityHandler { [weak self] messageType, discordUserId, success, debug in
            guard !debug else { return }
            await MainActor.run {
                self?.logDMActivityEvent(
                    messageType: messageType,
                    discordUserId: discordUserId,
                    success: success
                )
            }
        }
    }

    private func logDMActivityEvent(
        messageType: SwiftBotDMMessageType,
        discordUserId: String,
        success: Bool
    ) {
        let miner = minerManager.miners.first { $0.ownerDiscordId == discordUserId }
        // Prefer the Discord display name — it's the human-readable handle the
        // recipient actually recognises. Fall back to the miner's Twitch
        // display name only if SwiftBot hasn't told us the Discord name yet,
        // and finally to a generic placeholder if neither is known.
        let target = discordDisplayNamesById[discordUserId]
            ?? miner?.displayName
            ?? "Discord user"
        let message: String
        if success {
            message = "Sent \(messageType.displayName) DM to \(target)"
        } else {
            message = "Failed to send \(messageType.displayName) DM to \(target)"
        }
        // Tag rawMessage with the sentinel so EventLogView's filter resolver
        // routes this entry to the .discord chip.
        let tagged = "[discord-dm] \(messageType.rawValue) \(success ? "ok" : "fail") \(discordUserId)"
        logEvent(
            message: message,
            level: success ? .info : .warning,
            minerId: miner?.id,
            rawMessage: tagged
        )

        // If we logged the event without a known Discord name, opportunistically
        // refresh the cache so future DMs to this user get the proper handle.
        if discordDisplayNamesById[discordUserId] == nil {
            Task { [weak self] in await self?.refreshDiscordDisplayNames() }
        }
    }

    /// Refreshes the Discord display-name cache from SwiftBot. Cheap (one
    /// HTTP call) and best-effort — any failure just leaves the cache as-is.
    public func refreshDiscordDisplayNames() async {
        let users = await swiftBotConnectionService.fetchDiscordUsers()
        guard !users.isEmpty else { return }
        var map: [String: String] = [:]
        var usersMap: [String: SwiftBotDiscordUser] = [:]
        for user in users {
            map[user.id] = user.displayName
            usersMap[user.id] = user
        }
        discordDisplayNamesById = map
        discordUsersById = usersMap
    }

    /// Clear all events.
    public func clearEvents() {
        events.removeAll()
        Task { [activityLogStore] in
            await activityLogStore.clear()
        }
    }

    /// Recreate the useful parts of app launch from an already-open Overview:
    /// restart miner workers with current settings, then refresh campaign and
    /// inventory projections so the dashboard reflects the recovered state.
    public func restartMinersAndRefreshOverviewData() async {
        let settings = Settings.shared
        guard !minerManager.miners.isEmpty else {
            await minerManager.dataCoordinator.refreshAll()
            return
        }

        await minerManager.stopAll()
        for miner in minerManager.miners {
            try? await minerManager.startMiner(
                minerId: miner.id,
                priorityGames: priorityGames(for: miner),
                excludedGames: settings.excludedGames(forAccountId: miner.accountId),
                strategy: settings.miningStrategy,
                enableBadgesEmotes: settings.enableBadgesEmotes,
                showClaimNotifications: settings.showClaimNotifications,
                avoidDuplicateStreams: settings.avoidDuplicateStreams,
                antiStallRecoveryEnabled: settings.antiStallRecoveryEnabled,
                prioritiseFollowedStreamers: settings.prioritiseFollowedStreamers,
                failoverStreamers: settings.gameFailoverStreamers
            )
        }
        // `startMiner` already begins with a fresh campaign scan. Forcing a
        // second one immediately afterwards can interrupt its first watch
        // session before setup has completed.
        await minerManager.dataCoordinator.refreshAll()
    }

    public func refreshRunningMinerPreferences() async {
        let settings = Settings.shared
        await minerManager.updateMiningPreferences(
            priorityGamesForMiner: { [weak self] miner in
                self?.priorityGames(for: miner) ?? settings.priorityGames(forAccountId: miner.accountId)
            },
            excludedGames: settings.excludedGames,
            excludedGamesForMiner: { miner in
                settings.excludedGames(forAccountId: miner.accountId)
            },
            strategy: settings.miningStrategy,
            enableBadgesEmotes: settings.enableBadgesEmotes,
            showClaimNotifications: settings.showClaimNotifications && settings.allowsOperatorNotifications(),
            avoidDuplicateStreams: settings.avoidDuplicateStreams,
            prioritiseFollowedStreamers: settings.prioritiseFollowedStreamers,
            failoverStreamers: settings.gameFailoverStreamers
        )
    }

    private var settings: Settings { Settings.shared }

    private func clearOnboardingPresentation() {
        onboardingPresentation = nil
        showOnboarding = false
    }

    private func runOnboardingSetupSequence() async {
        defer {
            isRunningOnboardingSetup = false
            onboardingSetupTask = nil
            refreshOnboardingPresentation()
        }

        updateOnboardingSetupStage(.connecting)
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }

        updateOnboardingSetupStage(.campaigns)
        await minerManager.forceRefreshAllMiners()
        try? await Task.sleep(for: .milliseconds(500))
        guard !Task.isCancelled else { return }

        updateOnboardingSetupStage(.inventory)
        await minerManager.dataCoordinator.refreshAll()
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }

        updateOnboardingSetupStage(.finalising)
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
    }
}


public enum EventLevel: String, Codable, Sendable {
    case info
    case warning
    case error
}

public struct EventEntry: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let message: String
    public let level: EventLevel
    public let minerId: String?
    public let rawMessage: String?
    /// Which filter this event is filed under, resolved when it is logged and stored
    /// with it. Retention protects the rare categories, so this has to be known
    /// without re-reading the message text. Nil on rows written before 1.37.
    public let category: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        message: String,
        level: EventLevel,
        minerId: String? = nil,
        rawMessage: String? = nil,
        category: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.message = message
        self.level = level
        self.minerId = minerId
        self.rawMessage = rawMessage
        self.category = category
    }

    func withCategory(_ category: String) -> EventEntry {
        EventEntry(
            id: id,
            timestamp: timestamp,
            message: message,
            level: level,
            minerId: minerId,
            rawMessage: rawMessage,
            category: category
        )
    }
}
