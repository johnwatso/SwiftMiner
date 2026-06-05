import SwiftUI
import Security
import ServiceManagement
import SwiftMinerCore

/// User settings managed via @AppStorage.
/// Provides persistent preferences across app launches.
@MainActor
public final class Settings: ObservableObject {
    
    // MARK: - Shared Instance

    static let appStorageStore: UserDefaults = {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            let suiteName = "com.swiftminer.app.tests.\(ProcessInfo.processInfo.globallyUniqueString)"
            guard let defaults = UserDefaults(suiteName: suiteName) else {
                return .standard
            }
            defaults.removePersistentDomain(forName: suiteName)
            return defaults
        }
        return .standard
    }()
    
    public static let shared = Settings()

    // MARK: - @AppStorage Properties
    
    /// Whether auto-claim is enabled for completed drops
    @AppStorage("autoClaimEnabled", store: Settings.appStorageStore)
    public var autoClaimEnabled: Bool = true
    
    /// Whether to auto-claim community points bonuses
    @AppStorage("autoClaimPointsEnabled", store: Settings.appStorageStore)
    public var autoClaimPointsEnabled: Bool = true
    
    /// Log level for console output
    @AppStorage("logLevel", store: Settings.appStorageStore)
    public var logLevel: LogLevel = .info
    
    /// Whether to show the log console in the UI
    @AppStorage("showLogConsole", store: Settings.appStorageStore)
    public var showLogConsole: Bool = true
    
    /// Maximum number of log entries to keep in memory
    @AppStorage("maxLogEntries", store: Settings.appStorageStore)
    public var maxLogEntries: Int = 500
    
    /// Legacy preference retained for users upgrading from the old boolean setting.
    @AppStorage("minimizeToMenuBar", store: Settings.appStorageStore)
    public var minimizeToMenuBar: Bool = false

    /// Where SwiftMiner should appear while it is running.
    @AppStorage("appPresenceMode", store: Settings.appStorageStore)
    public var appPresenceMode: AppPresenceMode = .dockOnly
    
    /// Whether to start mining automatically on launch (if authenticated)
    @AppStorage("autoStartOnLaunch", store: Settings.appStorageStore)
    public var autoStartOnLaunch: Bool = false

    /// Whether the main window should minimize itself when SwiftMiner launches.
    @AppStorage("startMinimized", store: Settings.appStorageStore)
    public var startMinimized: Bool = false

    /// Whether to include campaigns that only give non-drop rewards (badges/emotes)
    @AppStorage("enableBadgesEmotes", store: Settings.appStorageStore)
    public var enableBadgesEmotes: Bool = false

    /// Prefer spreading miners across different streams for the same campaign when enough streams are available.
    @AppStorage("avoidDuplicateStreams", store: Settings.appStorageStore)
    public var avoidDuplicateStreams: Bool = true

    /// Whether SwiftMiner should restart a miner that appears stuck after a stall or recoverable error.
    @AppStorage("antiStallRecoveryEnabled", store: Settings.appStorageStore)
    public var antiStallRecoveryEnabled: Bool = true

    /// Whether followed or subscribed streamers should be preferred during channel selection.
    @AppStorage("prioritiseFollowedStreamers", store: Settings.appStorageStore)
    public var prioritiseFollowedStreamers: Bool = false

    /// Whether to sync all miners state (start/stop together)
    @AppStorage("syncMinersState", store: Settings.appStorageStore)
    public var syncMinersState: Bool = true

    /// Whether to use Steam CDN artwork instead of Twitch game artwork
    @AppStorage("preferSteamArtwork", store: Settings.appStorageStore)
    public var preferSteamArtwork: Bool = true

    /// Whether in-app TipKit hints are shown.
    @AppStorage("tipsEnabled", store: Settings.appStorageStore)
    public var tipsEnabled: Bool = true

    /// Whether to run in background when window is closed
    @AppStorage("runInBackground", store: Settings.appStorageStore)
    public var runInBackground: Bool = true

    /// Whether to show category icons next to each row in the Activity Log.
    @AppStorage("showActivityLogIcons", store: Settings.appStorageStore)
    public var showActivityLogIcons: Bool = true

    /// Whether to animate new rows sliding into the Activity Log.
    @AppStorage("animateActivityLogRows", store: Settings.appStorageStore)
    public var animateActivityLogRows: Bool = true

    /// Whether to animate status icons with Apple-style transitions and drawing effects.
    @AppStorage("animatedStatusIcons", store: Settings.appStorageStore)
    public var animatedStatusIcons: Bool = true

    /// Whether to use colour in palette-rendered status icons (e.g. the clock badge exclamation icon).
    @AppStorage("coloredStatusIcons", store: Settings.appStorageStore)
    public var coloredStatusIcons: Bool = true

    /// JSON-encoded array of DropFilter for the Drops list view.
    @AppStorage("selectedDropsFiltersData", store: Settings.appStorageStore)
    private var selectedDropsFiltersData: String = "[\"active\"]"

    /// Persistent filter selection for the Drops list view.
    public var selectedDropsFilters: Set<DropFilter> {
        get {
            guard let data = selectedDropsFiltersData.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([DropFilter].self, from: data) else {
                return [.active]
            }
            return Set(decoded)
        }
        set {
            let encoded = Array(newValue).sorted { $0.rawValue < $1.rawValue }
            if let data = try? JSONEncoder().encode(encoded),
               let string = String(data: data, encoding: .utf8),
               selectedDropsFiltersData != string {
                selectedDropsFiltersData = string
            }
        }
    }

    /// JSON-encoded array of EventFilter for the Events view.
    @AppStorage("selectedEventFiltersData", store: Settings.appStorageStore)
    private var selectedEventFiltersData: String = "[\"drops\",\"errors\",\"heartbeats\",\"mining\",\"system\",\"warnings\"]"

    /// One-time migration so existing users see heartbeat diagnostics after upgrading.
    @AppStorage("eventFiltersHeartbeatDefaultApplied", store: Settings.appStorageStore)
    private var eventFiltersHeartbeatDefaultApplied: Bool = false

    /// Persistent filter selection for the Events view.
    public var selectedEventFilters: Set<EventFilter> {
        get {
            guard let data = selectedEventFiltersData.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([EventFilter].self, from: data) else {
                return Self.defaultEventFilters
            }
            return Set(decoded)
        }
        set {
            let encoded = Array(newValue).sorted { $0.rawValue < $1.rawValue }
            if let data = try? JSONEncoder().encode(encoded),
               let string = String(data: data, encoding: .utf8),
               selectedEventFiltersData != string {
                selectedEventFiltersData = string
            }
        }
    }

    /// Apply the one-time migration that enables heartbeat diagnostics for existing users.
    /// Must be called from init(), not from a property getter, to avoid mutating
    /// @AppStorage during a view update (which triggers the SwiftUI runtime warning).
    private func applyHeartbeatFilterDefaultIfNeeded() {
        guard !eventFiltersHeartbeatDefaultApplied else { return }
        var filters = selectedEventFilters
        filters.insert(.heartbeats)
        eventFiltersHeartbeatDefaultApplied = true
        let encoded = Array(filters).sorted { $0.rawValue < $1.rawValue }
        if let data = try? JSONEncoder().encode(encoded),
           let string = String(data: data, encoding: .utf8) {
            selectedEventFiltersData = string
        }
    }

    private static var defaultEventFilters: Set<EventFilter> {
        [.mining, .heartbeats, .drops, .warnings, .errors, .discord, .system]
    }

#if DEBUG
    /// Bypass account-link/eligibility gates so the miner watches a random live channel
    /// for any time-active campaign. For exercising the watch pipeline only — drops
    /// won't actually credit for unlinked accounts.
    @AppStorage("debugBypassLinkRequirement", store: Settings.appStorageStore)
    public var debugBypassLinkRequirement: Bool = false
#endif

    /// Preferred stream quality (for future use)
    @AppStorage("preferredQuality", store: Settings.appStorageStore)
    public var preferredQuality: StreamQuality = .auto
    
    /// Whether to show notifications for drop claims
    @AppStorage("showClaimNotifications", store: Settings.appStorageStore)
    public var showClaimNotifications: Bool = false // Disabled by default per user request

    /// JSON-encoded warnings that should be suppressed.
    /// Format: "accountId:gameId:warningType"
    @AppStorage("ignoredWarningsData", store: Settings.appStorageStore)
    private var ignoredWarningsData: String = "[]"

    /// JSON-encoded temporary warning suppressions keyed by
    /// "accountId:gameId:warningType", with ISO-8601 expiry dates.
    @AppStorage("temporaryIgnoredWarningsData", store: Settings.appStorageStore)
    private var temporaryIgnoredWarningsData: String = "{}"

    public enum WarningType: String, Codable, Sendable {
        case accountLink = "accountLink"
        case subscriptionRequired = "subscriptionRequired"
    }

    /// Scoped warnings that should be suppressed.
    public var ignoredWarnings: [String] {
        get {
            guard let data = ignoredWarningsData.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String].self, from: data) else {
                return []
            }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let encoded = String(data: data, encoding: .utf8),
               ignoredWarningsData != encoded {
                ignoredWarningsData = encoded
            }
        }
    }

    public var activeIgnoredWarnings: [String] {
        pruneExpiredTemporaryIgnoredWarnings()
        return Array(Set(ignoredWarnings + Array(temporaryIgnoredWarnings.keys))).sorted()
    }

    private var temporaryIgnoredWarnings: [String: Date] {
        get {
            guard let data = temporaryIgnoredWarningsData.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String: Date].self, from: data) else {
                return [:]
            }
            return decoded
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let encoded = String(data: data, encoding: .utf8),
               temporaryIgnoredWarningsData != encoded {
                temporaryIgnoredWarningsData = encoded
            }
        }
    }

    public func temporaryWarningExpiry(accountId: String, gameId: String = "all", type: WarningType) -> Date? {
        pruneExpiredTemporaryIgnoredWarnings()
        let specific = "\(accountId):\(gameId):\(type.rawValue)"
        let global = "\(accountId):all:\(type.rawValue)"
        return temporaryIgnoredWarnings[specific] ?? temporaryIgnoredWarnings[global]
    }

    public func setTemporaryIgnoreWarning(
        until expiry: Date,
        accountId: String,
        gameId: String = "all",
        type: WarningType
    ) {
        var current = temporaryIgnoredWarnings
        current["\(accountId):\(gameId):\(type.rawValue)"] = expiry
        temporaryIgnoredWarnings = current
    }

    public func pruneExpiredTemporaryIgnoredWarnings(now: Date = Date()) {
        var current = temporaryIgnoredWarnings
        let originalCount = current.count
        current = current.filter { $0.value > now }
        if current.count != originalCount {
            temporaryIgnoredWarnings = current
        }
    }

    /// Account IDs that should suppress account-link-required warnings (Legacy/Global).
    public var ignoredAccountLinkWarningAccountIds: [String] {
        get {
            let ids = ignoredWarnings
                .filter { $0.contains(":all:accountLink") || !$0.contains(":") }
                .map { $0.components(separatedBy: ":").first ?? $0 }
            return Array(Set(ids)).sorted()
        }
        set {
            var current = ignoredWarnings
            // Remove all global accountLink warnings for these IDs
            current.removeAll { warning in
                let parts = warning.components(separatedBy: ":")
                return parts.count <= 1 || (parts.count >= 3 && parts[1] == "all" && parts[2] == WarningType.accountLink.rawValue)
            }
            // Add them back as global
            for id in newValue {
                current.append("\(id):all:accountLink")
            }
            ignoredWarnings = Array(Set(current)).sorted()
        }
    }

    public func isIgnoringWarning(accountId: String, gameId: String = "all", type: WarningType) -> Bool {
        let specific = "\(accountId):\(gameId):\(type.rawValue)"
        let global = "\(accountId):all:\(type.rawValue)"
        pruneExpiredTemporaryIgnoredWarnings()
        return ignoredWarnings.contains(specific) ||
            ignoredWarnings.contains(global) ||
            temporaryIgnoredWarnings[specific] != nil ||
            temporaryIgnoredWarnings[global] != nil
    }

    public func setIgnoreWarning(_ ignored: Bool, accountId: String, gameId: String = "all", type: WarningType) {
        let key = "\(accountId):\(gameId):\(type.rawValue)"
        var current = ignoredWarnings
        if ignored {
            if !current.contains(key) {
                current.append(key)
            }
        } else {
            current.removeAll { $0 == key }
        }
        ignoredWarnings = current
    }

    public func isIgnoringAccountLinkWarnings(for accountId: String) -> Bool {
        isIgnoringWarning(accountId: accountId, type: .accountLink)
    }

    public func isIgnoringAccountLinkWarnings(for accountId: String, gameId: String) -> Bool {
        isIgnoringWarning(accountId: accountId, gameId: gameId, type: .accountLink)
    }

    public func setIgnoreAccountLinkWarnings(_ ignored: Bool, for accountId: String, gameId: String = "all") {
        setIgnoreWarning(ignored, accountId: accountId, gameId: gameId, type: .accountLink)
    }

    public func isIgnoringSubscriptionRequiredWarnings(for accountId: String, campaignId: String) -> Bool {
        isIgnoringWarning(accountId: accountId, gameId: campaignId, type: .subscriptionRequired)
    }

    public func setIgnoreSubscriptionRequiredWarnings(_ ignored: Bool, for accountId: String, campaignId: String) {
        setIgnoreWarning(ignored, accountId: accountId, gameId: campaignId, type: .subscriptionRequired)
    }

    /// Last selected game/category (for UI restoration)
    @AppStorage("lastSelectedGameId", store: Settings.appStorageStore)
    public var lastSelectedGameId: String = ""

    /// Whether the user explicitly dismissed the optional onboarding surface.
    @AppStorage("hasDismissedOnboarding", store: Settings.appStorageStore)
    public var hasDismissedOnboarding: Bool = false

    /// Twitch application Client ID (set once; used by all miners)
    @AppStorage("twitchClientId", store: Settings.appStorageStore)
    public var twitchClientId: String = ""

    /// Whether SwiftBot Discord integration is enabled
    @AppStorage("swiftBotEnabled", store: Settings.appStorageStore)
    public var swiftBotEnabled: Bool = false

    /// SwiftBot integration endpoint (e.g. http://127.0.0.1:8080)
    @AppStorage("swiftBotEndpoint", store: Settings.appStorageStore)
    public var swiftBotEndpoint: String = ""

    /// Webhook URL SwiftMiner POSTs events to (e.g. http://127.0.0.1:8080/webhooks/swiftminer/events)
    @AppStorage("swiftBotWebhookURL", store: Settings.appStorageStore)
    public var swiftBotWebhookURL: String = ""

    /// Local SwiftMiner API endpoint SwiftBot calls for miner status and setup.
    @AppStorage("swiftMinerAPIEndpoint", store: Settings.appStorageStore)
    public var swiftMinerAPIEndpoint: String = "http://127.0.0.1:8080"

    /// Shared HMAC-SHA256 secret for webhook request signing
    @AppStorage("swiftBotHmacSecret", store: Settings.appStorageStore)
    public var swiftBotHmacSecret: String = ""

    /// API Key for the SwiftMiner HTTP service (used by SwiftBot)
    @AppStorage("swiftMinerAPIKey", store: Settings.appStorageStore)
    public var swiftMinerAPIKey: String = ""

    // MARK: - Discord DM Notification Preferences

    // MARK: - Discord DM Notification Preferences
    //
    // Important notifications default ON — these relate to account recovery and action required.
    // Activity notifications default OFF — these are informational and can be noisy.

    @AppStorage("dmCampaignCompletedEnabled", store: Settings.appStorageStore)
    public var dmCampaignCompletedEnabled: Bool = false

    @AppStorage("dmConnectionExpiredEnabled", store: Settings.appStorageStore)
    public var dmConnectionExpiredEnabled: Bool = true

    @AppStorage("dmWelcomeBackEnabled", store: Settings.appStorageStore)
    public var dmWelcomeBackEnabled: Bool = false

    @AppStorage("dmLinkRequiredEnabled", store: Settings.appStorageStore)
    public var dmLinkRequiredEnabled: Bool = true

    @AppStorage("dmCampaignDetectedEnabled", store: Settings.appStorageStore)
    public var dmCampaignDetectedEnabled: Bool = false

    @AppStorage("dmAccountActionRequiredEnabled", store: Settings.appStorageStore)
    public var dmAccountActionRequiredEnabled: Bool = true

    @AppStorage("quietHoursEnabled", store: Settings.appStorageStore)
    public var quietHoursEnabled: Bool = false

    @AppStorage("quietHoursStartMinute", store: Settings.appStorageStore)
    public var quietHoursStartMinute: Int = 22 * 60

    @AppStorage("quietHoursEndMinute", store: Settings.appStorageStore)
    public var quietHoursEndMinute: Int = 7 * 60
    
    /// JSON-encoded array of GamePreference for selected games
    @AppStorage("gamePreferencesData", store: Settings.appStorageStore)
    public var gamePreferencesData: String = "[]"

    /// Legacy storage (kept for migration only)
    @AppStorage("priorityGamesString", store: Settings.appStorageStore)
    private var priorityGamesString: String = ""

    /// Legacy storage (kept for migration only)
    @AppStorage("excludedGamesString", store: Settings.appStorageStore)
    private var excludedGamesString: String = ""

    /// Mining strategy selection
    @AppStorage("miningStrategy", store: Settings.appStorageStore)
    public var miningStrategy: MiningStrategy = .mineAll

    // MARK: - Game Preferences

    /// Decoded game preferences from JSON storage
    public var gamePreferences: [GamePreference] {
        get {
            guard let data = gamePreferencesData.data(using: .utf8),
                  let prefs = try? JSONDecoder().decode([GamePreference].self, from: data) else {
                return []
            }
            return normalizedPreferences(prefs)
        }
        set {
            let normalized = normalizedPreferences(newValue)
            if let data = try? JSONEncoder().encode(normalized),
               let string = String(data: data, encoding: .utf8) {
                guard gamePreferencesData != string else { return }
                gamePreferencesData = string
            }
        }
    }

    /// Priority game names derived from preferences (backward compat for MinerEngine)
    public var priorityGames: [String] {
        gameNames(for: .preferred)
    }

    /// Excluded game names derived from preferences (backward compat for MinerEngine)
    public var excludedGames: [String] {
        gameNames(for: .excluded)
    }

    /// Add or update a game preference
    public func addGamePreference(_ game: Game, state: PreferenceState) {
        setGamePreference(game, state: state)
    }

    /// Add or update a game preference with the provided state.
    public func setGamePreference(_ game: Game, state: PreferenceState) {
        var prefs = gamePreferences
        if let index = prefs.firstIndex(where: { preferenceMatches($0, gameId: game.id, gameName: game.name) }) {
            let old = prefs[index]
            prefs[index] = GamePreference(
                gameId: game.id,
                gameName: game.name,
                boxArtURL: game.boxArtURL ?? old.boxArtURL,
                customArtworkURL: old.customArtworkURL,
                state: state
            )
        } else {
            prefs.append(GamePreference(gameId: game.id, gameName: game.name, boxArtURL: game.boxArtURL, state: state))
        }
        gamePreferences = prefs
    }

    /// Remove a game preference by game ID
    public func removeGamePreference(gameId: String) {
        var prefs = gamePreferences
        let removed = prefs.filter { $0.gameId == gameId }
        prefs.removeAll { $0.gameId == gameId }
        gamePreferences = prefs
        removeCachedArtworkFiles(for: removed)
    }

    /// Remove a specific game preference.
    public func removeGamePreference(_ preference: GamePreference) {
        var prefs = gamePreferences
        let removed = prefs.filter { preferenceMatches($0, gameId: preference.gameId, gameName: preference.gameName) }
        prefs.removeAll { preferenceMatches($0, gameId: preference.gameId, gameName: preference.gameName) }
        gamePreferences = prefs
        removeCachedArtworkFiles(for: removed)
    }

    /// Set a stored preference to a specific state.
    public func setPreferenceState(_ state: PreferenceState, for preference: GamePreference) {
        var prefs = gamePreferences
        if let idx = prefs.firstIndex(where: { preferenceMatches($0, gameId: preference.gameId, gameName: preference.gameName) }) {
            let old = prefs[idx]
            prefs[idx] = GamePreference(
                gameId: old.gameId,
                gameName: old.gameName,
                boxArtURL: old.boxArtURL,
                customArtworkURL: old.customArtworkURL,
                state: state
            )
        }
        gamePreferences = prefs
    }

    public func setCustomArtwork(from sourceURL: URL, for game: Game) throws {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let directory = try customArtworkDirectory()
        let fileExtension = preferredArtworkExtension(for: sourceURL)
        let destination = directory
            .appendingPathComponent(customArtworkFileStem(gameId: game.id, gameName: game.name))
            .appendingPathExtension(fileExtension)

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destination)

        var prefs = gamePreferences
        if let index = prefs.firstIndex(where: { preferenceMatches($0, gameId: game.id, gameName: game.name) }) {
            let old = prefs[index]
            removeCachedArtworkFile(at: old.customArtworkURL)
            prefs[index] = GamePreference(
                gameId: old.gameId.isEmpty ? game.id : old.gameId,
                gameName: game.name,
                boxArtURL: game.boxArtURL ?? old.boxArtURL,
                customArtworkURL: destination,
                state: old.state
            )
        } else {
            prefs.append(GamePreference(
                gameId: game.id,
                gameName: game.name,
                boxArtURL: game.boxArtURL,
                customArtworkURL: destination,
                state: .preferred
            ))
        }
        gamePreferences = prefs
    }

    public func removeCustomArtwork(for game: Game) {
        var prefs = gamePreferences
        guard let index = prefs.firstIndex(where: { preferenceMatches($0, gameId: game.id, gameName: game.name) }) else {
            return
        }

        let old = prefs[index]
        removeCachedArtworkFile(at: old.customArtworkURL)
        prefs[index] = GamePreference(
            gameId: old.gameId,
            gameName: old.gameName,
            boxArtURL: old.boxArtURL,
            customArtworkURL: nil,
            state: old.state
        )
        gamePreferences = prefs
    }

    /// Toggle a stored preference through preferred -> excluded -> neutral.
    public func togglePreferenceState(for preference: GamePreference) {
        setPreferenceState(nextPreferenceState(after: preference.state), for: preference)
    }

    /// Reorder game preferences within a state group (drag-to-reorder support).
    /// Moves only items that share `state`; items in other states are unaffected.
    public func moveGamePreferences(fromOffsets: IndexSet, toOffset: Int, inState state: PreferenceState) {
        var prefs = gamePreferences
        let stateIndices = prefs.indices.filter { prefs[$0].state == state }
        var stateItems = stateIndices.map { prefs[$0] }
        stateItems.move(fromOffsets: fromOffsets, toOffset: toOffset)
        for (position, originalIndex) in stateIndices.enumerated() {
            prefs[originalIndex] = stateItems[position]
        }
        gamePreferences = prefs
    }
    
    // MARK: - Enums

    public enum LogLevel: String, CaseIterable, Identifiable, Sendable {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARNING"
        case error = "ERROR"
        
        public var id: String { rawValue }
        
        public var displayName: String {
            switch self {
            case .debug: return "Debug"
            case .info: return "Info"
            case .warning: return "Warning"
            case .error: return "Error"
            }
        }
    }
    
    public enum StreamQuality: String, CaseIterable, Identifiable, Sendable {
        case auto = "auto"
        case source = "source"
        case high = "high"
        case medium = "medium"
        case low = "low"
        
        public var id: String { rawValue }
        
        public var displayName: String {
            switch self {
            case .auto: return "Auto"
            case .source: return "Source"
            case .high: return "High"
            case .medium: return "Medium"
            case .low: return "Low"
            }
        }
    }

    // MARK: - Initialization
    
    private init() {
        if minimizeToMenuBar && appPresenceMode == .dockOnly {
            appPresenceMode = .menuBarWhenClosed
        }
        migrateFromLegacyIfNeeded()
        applyHeartbeatFilterDefaultIfNeeded()
    }

    /// One-time migration from old comma-separated strings to new JSON model
    private func migrateFromLegacyIfNeeded() {
        guard gamePreferencesData == "[]" else { return }

        var migrated: [GamePreference] = []

        let oldPriority = priorityGamesString.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for name in oldPriority {
            migrated.append(GamePreference(gameId: "", gameName: name, state: .preferred))
        }

        let oldExcluded = excludedGamesString.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        for name in oldExcluded {
            migrated.append(GamePreference(gameId: "", gameName: name, state: .excluded))
        }

        if !migrated.isEmpty {
            gamePreferences = migrated
            priorityGamesString = ""
            excludedGamesString = ""
        }
    }

    private func nextPreferenceState(after state: PreferenceState) -> PreferenceState {
        switch state {
        case .preferred:
            return .excluded
        case .excluded:
            return .neutral
        case .neutral:
            return .preferred
        }
    }

    private func gameNames(for state: PreferenceState) -> [String] {
        normalizedPreferences(gamePreferences)
            .filter { $0.state == state }
            .map(\.gameName)
    }

    private func normalizedPreferences(_ preferences: [GamePreference]) -> [GamePreference] {
        var seen = Set<String>()
        var deduped: [GamePreference] = []

        for preference in preferences.reversed() {
            let trimmedName = preference.gameName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { continue }

            let normalized = GamePreference(
                gameId: preference.gameId,
                gameName: trimmedName,
                boxArtURL: preference.boxArtURL,
                customArtworkURL: preference.customArtworkURL,
                state: preference.state
            )

            guard seen.insert(preferenceKey(for: normalized)).inserted else { continue }
            deduped.append(normalized)
        }

        return deduped.reversed()
    }

    private func preferenceMatches(_ preference: GamePreference, gameId: String, gameName: String) -> Bool {
        let storedId = preference.gameId.trimmingCharacters(in: .whitespacesAndNewlines)
        let incomingId = gameId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !storedId.isEmpty && !incomingId.isEmpty && storedId == incomingId {
            return true
        }

        return preference.gameName.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveCompare(gameName.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    private func preferenceKey(for preference: GamePreference) -> String {
        preferenceKey(gameId: preference.gameId, gameName: preference.gameName)
    }

    private func preferenceKey(gameId: String, gameName: String) -> String {
        if !gameId.isEmpty {
            return gameId
        }
        return gameName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func customArtworkDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = base
            .appendingPathComponent("SwiftMiner", isDirectory: true)
            .appendingPathComponent("CustomArtwork", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func preferredArtworkExtension(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        let supported = Set(["png", "jpg", "jpeg", "heic", "webp", "tiff", "gif"])
        return supported.contains(ext) ? ext : "png"
    }

    private func customArtworkFileStem(gameId: String, gameName: String) -> String {
        let key = preferenceKey(gameId: gameId, gameName: gameName)
        let scalars = key.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : "-"
        }
        let stem = String(scalars)
            .split(separator: "-")
            .joined(separator: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return stem.isEmpty ? UUID().uuidString : stem
    }

    private func removeCachedArtworkFiles(for preferences: [GamePreference]) {
        for preference in preferences {
            removeCachedArtworkFile(at: preference.customArtworkURL)
        }
    }

    private func removeCachedArtworkFile(at url: URL?) {
        guard let url, url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }
    
    // MARK: - Reset
    
    /// Resolved Twitch Client ID: env var → stored setting → built-in Twitch web client ID.
    /// Whitespace is always trimmed to prevent copy-paste issues.
    /// Handles JSON-wrapped values like `["value": "abc123"]` from Xcode scheme env vars.
    public var resolvedClientId: String {
        let rawEnv = ProcessInfo.processInfo.environment["TWITCH_CLIENT_ID"] ?? ""
        let envId = parseClientId(rawEnv)
        if !envId.isEmpty { return envId }
        
        let settingsId = twitchClientId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !settingsId.isEmpty { return settingsId }
        
        // Fall back to Twitch's own Android app client ID (same approach as TwitchDropsMiner)
        return Settings.twitchAndroidClientId
    }
    
    /// Parse client ID from string, handling JSON-wrapped values
    private func parseClientId(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        
        // Check if it's a JSON object like ["value": "abc123"] or {"value":"abc123"}
        if trimmed.hasPrefix("[") || trimmed.hasPrefix("{") {
            // Try to extract just the value part
            // Pattern: "value" followed by ':' then quoted string
            if let range = trimmed.range(of: "\"value\""),
               let colonRange = trimmed[range.upperBound...].range(of: ":"),
               let quoteStart = trimmed[colonRange.upperBound...].range(of: "\"") {
                let afterQuote = trimmed[quoteStart.upperBound...]
                if let quoteEnd = afterQuote.range(of: "\"") {
                    let value = String(afterQuote[..<quoteEnd.lowerBound])
                    return value.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        
        return trimmed
    }

    /// Twitch's built-in Android app client ID. Used when no custom client ID is configured.
    /// This client ID is better suited for device flow and GQL access than the web client ID.
    public static let twitchAndroidClientId = "kd1unb4b3q4t58fwlpcbzcbnm76a8fp"

    /// Legacy fallback for web client ID (no longer used by default)
    public static let twitchWebClientId = "kimne78kx3ncx6brgo4mv6wki5h1ko"

    /// Reset all settings to defaults
    public func resetToDefaults() {
        autoClaimEnabled = true
        autoClaimPointsEnabled = true
        logLevel = .info
        showLogConsole = true
        maxLogEntries = 500
        minimizeToMenuBar = false
        appPresenceMode = .dockOnly
        autoStartOnLaunch = false
        enableBadgesEmotes = false
        avoidDuplicateStreams = true
        antiStallRecoveryEnabled = true
        prioritiseFollowedStreamers = false
        syncMinersState = true
        runInBackground = true
        showActivityLogIcons = true
        animateActivityLogRows = true
        animatedStatusIcons = true
        coloredStatusIcons = true
        preferredQuality = .auto
        showClaimNotifications = false
        lastSelectedGameId = ""
        hasDismissedOnboarding = false
        twitchClientId = ""
        swiftBotEnabled = false
        swiftBotEndpoint = ""
        swiftBotWebhookURL = ""
        swiftMinerAPIEndpoint = "http://127.0.0.1:8080"
        swiftBotHmacSecret = ""
        swiftMinerAPIKey = ""
        dmCampaignCompletedEnabled = false
        dmConnectionExpiredEnabled = true
        dmWelcomeBackEnabled = false
        dmLinkRequiredEnabled = true
        dmCampaignDetectedEnabled = false
        dmAccountActionRequiredEnabled = true
        quietHoursEnabled = false
        quietHoursStartMinute = 22 * 60
        quietHoursEndMinute = 7 * 60
        gamePreferencesData = "[]"
        selectedDropsFiltersData = "[\"active\"]"
        miningStrategy = .mineAll
        preferSteamArtwork = true
        ignoredWarningsData = "[]"
#if DEBUG
        debugBypassLinkRequirement = false
#endif
    }

    public func allowsOperatorNotifications(at date: Date = Date(), calendar: Calendar = .current) -> Bool {
        guard quietHoursEnabled else { return true }
        let components = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        let start = normalizedMinute(quietHoursStartMinute)
        let end = normalizedMinute(quietHoursEndMinute)
        guard start != end else { return false }
        if start < end {
            return !(minute >= start && minute < end)
        }
        return !(minute >= start || minute < end)
    }

    public func exportBackupData(includeSecrets: Bool = false) throws -> Data {
        let backup = SettingsBackup(
            exportedAt: Date(),
            autoClaimEnabled: autoClaimEnabled,
            autoClaimPointsEnabled: autoClaimPointsEnabled,
            logLevel: logLevel.rawValue,
            maxLogEntries: maxLogEntries,
            appPresenceMode: appPresenceMode.rawValue,
            autoStartOnLaunch: autoStartOnLaunch,
            startMinimized: startMinimized,
            enableBadgesEmotes: enableBadgesEmotes,
            avoidDuplicateStreams: avoidDuplicateStreams,
            antiStallRecoveryEnabled: antiStallRecoveryEnabled,
            prioritiseFollowedStreamers: prioritiseFollowedStreamers,
            syncMinersState: syncMinersState,
            preferSteamArtwork: preferSteamArtwork,
            tipsEnabled: tipsEnabled,
            runInBackground: runInBackground,
            showActivityLogIcons: showActivityLogIcons,
            animateActivityLogRows: animateActivityLogRows,
            selectedDropsFiltersData: selectedDropsFiltersData,
            selectedEventFiltersData: selectedEventFiltersData,
            preferredQuality: preferredQuality.rawValue,
            showClaimNotifications: showClaimNotifications,
            ignoredWarningsData: ignoredWarningsData,
            twitchClientId: includeSecrets ? twitchClientId : "",
            swiftBotEnabled: swiftBotEnabled,
            swiftBotEndpoint: swiftBotEndpoint,
            swiftBotWebhookURL: swiftBotWebhookURL,
            swiftMinerAPIEndpoint: swiftMinerAPIEndpoint,
            swiftBotHmacSecret: includeSecrets ? swiftBotHmacSecret : "",
            swiftMinerAPIKey: includeSecrets ? swiftMinerAPIKey : "",
            dmCampaignCompletedEnabled: dmCampaignCompletedEnabled,
            dmConnectionExpiredEnabled: dmConnectionExpiredEnabled,
            dmWelcomeBackEnabled: dmWelcomeBackEnabled,
            dmLinkRequiredEnabled: dmLinkRequiredEnabled,
            dmCampaignDetectedEnabled: dmCampaignDetectedEnabled,
            dmAccountActionRequiredEnabled: dmAccountActionRequiredEnabled,
            quietHoursEnabled: quietHoursEnabled,
            quietHoursStartMinute: quietHoursStartMinute,
            quietHoursEndMinute: quietHoursEndMinute,
            gamePreferencesData: gamePreferencesData,
            miningStrategy: miningStrategy.rawValue
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(backup)
    }

    public func importBackupData(_ data: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(SettingsBackup.self, from: data)

        autoClaimEnabled = backup.autoClaimEnabled
        autoClaimPointsEnabled = backup.autoClaimPointsEnabled
        logLevel = Settings.LogLevel(rawValue: backup.logLevel) ?? .info
        maxLogEntries = backup.maxLogEntries
        appPresenceMode = AppPresenceMode(rawValue: backup.appPresenceMode) ?? .dockOnly
        autoStartOnLaunch = backup.autoStartOnLaunch
        startMinimized = backup.startMinimized
        enableBadgesEmotes = backup.enableBadgesEmotes
        avoidDuplicateStreams = backup.avoidDuplicateStreams
        antiStallRecoveryEnabled = backup.antiStallRecoveryEnabled
        prioritiseFollowedStreamers = backup.prioritiseFollowedStreamers
        syncMinersState = backup.syncMinersState
        preferSteamArtwork = backup.preferSteamArtwork
        tipsEnabled = backup.tipsEnabled
        runInBackground = backup.runInBackground
        showActivityLogIcons = backup.showActivityLogIcons
        animateActivityLogRows = backup.animateActivityLogRows
        selectedDropsFiltersData = backup.selectedDropsFiltersData
        selectedEventFiltersData = backup.selectedEventFiltersData
        preferredQuality = Settings.StreamQuality(rawValue: backup.preferredQuality) ?? .auto
        showClaimNotifications = backup.showClaimNotifications
        ignoredWarningsData = backup.ignoredWarningsData
        if !backup.twitchClientId.isEmpty { twitchClientId = backup.twitchClientId }
        swiftBotEnabled = backup.swiftBotEnabled
        swiftBotEndpoint = backup.swiftBotEndpoint
        swiftBotWebhookURL = backup.swiftBotWebhookURL
        swiftMinerAPIEndpoint = backup.swiftMinerAPIEndpoint
        if !backup.swiftBotHmacSecret.isEmpty { swiftBotHmacSecret = backup.swiftBotHmacSecret }
        if !backup.swiftMinerAPIKey.isEmpty { swiftMinerAPIKey = backup.swiftMinerAPIKey }
        dmCampaignCompletedEnabled = backup.dmCampaignCompletedEnabled
        dmConnectionExpiredEnabled = backup.dmConnectionExpiredEnabled
        dmWelcomeBackEnabled = backup.dmWelcomeBackEnabled
        dmLinkRequiredEnabled = backup.dmLinkRequiredEnabled
        dmCampaignDetectedEnabled = backup.dmCampaignDetectedEnabled
        dmAccountActionRequiredEnabled = backup.dmAccountActionRequiredEnabled
        quietHoursEnabled = backup.quietHoursEnabled
        quietHoursStartMinute = normalizedMinute(backup.quietHoursStartMinute)
        quietHoursEndMinute = normalizedMinute(backup.quietHoursEndMinute)
        gamePreferencesData = backup.gamePreferencesData
        miningStrategy = MiningStrategy(rawValue: backup.miningStrategy) ?? .mineAll
    }

    private func normalizedMinute(_ minute: Int) -> Int {
        min(max(minute, 0), 23 * 60 + 59)
    }

    public func ensureSwiftBotSecrets() {
        if swiftMinerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).count < 32 ||
            swiftMinerAPIKey == "dev-key-change-in-production" {
            swiftMinerAPIKey = Self.generateSecret()
        }
        if swiftBotHmacSecret.trimmingCharacters(in: .whitespacesAndNewlines).count < 32 {
            swiftBotHmacSecret = Self.generateSecret()
        }
    }

    private static func generateSecret(byteCount: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess {
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        return UUID().uuidString.replacingOccurrences(of: "-", with: "") +
            UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }
}

public struct SettingsBackup: Codable, Sendable {
    public let schemaVersion: Int
    public let exportedAt: Date
    public let autoClaimEnabled: Bool
    public let autoClaimPointsEnabled: Bool
    public let logLevel: String
    public let maxLogEntries: Int
    public let appPresenceMode: String
    public let autoStartOnLaunch: Bool
    public let startMinimized: Bool
    public let enableBadgesEmotes: Bool
    public let avoidDuplicateStreams: Bool
    public let antiStallRecoveryEnabled: Bool
    public let prioritiseFollowedStreamers: Bool
    public let syncMinersState: Bool
    public let preferSteamArtwork: Bool
    public let tipsEnabled: Bool
    public let runInBackground: Bool
    public let showActivityLogIcons: Bool
    public let animateActivityLogRows: Bool
    public let selectedDropsFiltersData: String
    public let selectedEventFiltersData: String
    public let preferredQuality: String
    public let showClaimNotifications: Bool
    public let ignoredWarningsData: String
    public let twitchClientId: String
    public let swiftBotEnabled: Bool
    public let swiftBotEndpoint: String
    public let swiftBotWebhookURL: String
    public let swiftMinerAPIEndpoint: String
    public let swiftBotHmacSecret: String
    public let swiftMinerAPIKey: String
    public let dmCampaignCompletedEnabled: Bool
    public let dmConnectionExpiredEnabled: Bool
    public let dmWelcomeBackEnabled: Bool
    public let dmLinkRequiredEnabled: Bool
    public let dmCampaignDetectedEnabled: Bool
    public let dmAccountActionRequiredEnabled: Bool
    public let quietHoursEnabled: Bool
    public let quietHoursStartMinute: Int
    public let quietHoursEndMinute: Int
    public let gamePreferencesData: String
    public let miningStrategy: String

    public init(
        schemaVersion: Int = 1,
        exportedAt: Date,
        autoClaimEnabled: Bool,
        autoClaimPointsEnabled: Bool,
        logLevel: String,
        maxLogEntries: Int,
        appPresenceMode: String,
        autoStartOnLaunch: Bool,
        startMinimized: Bool,
        enableBadgesEmotes: Bool,
        avoidDuplicateStreams: Bool,
        antiStallRecoveryEnabled: Bool,
        prioritiseFollowedStreamers: Bool,
        syncMinersState: Bool,
        preferSteamArtwork: Bool,
        tipsEnabled: Bool,
        runInBackground: Bool,
        showActivityLogIcons: Bool,
        animateActivityLogRows: Bool,
        selectedDropsFiltersData: String,
        selectedEventFiltersData: String,
        preferredQuality: String,
        showClaimNotifications: Bool,
        ignoredWarningsData: String,
        twitchClientId: String,
        swiftBotEnabled: Bool,
        swiftBotEndpoint: String,
        swiftBotWebhookURL: String,
        swiftMinerAPIEndpoint: String,
        swiftBotHmacSecret: String,
        swiftMinerAPIKey: String,
        dmCampaignCompletedEnabled: Bool,
        dmConnectionExpiredEnabled: Bool,
        dmWelcomeBackEnabled: Bool,
        dmLinkRequiredEnabled: Bool,
        dmCampaignDetectedEnabled: Bool,
        dmAccountActionRequiredEnabled: Bool,
        quietHoursEnabled: Bool,
        quietHoursStartMinute: Int,
        quietHoursEndMinute: Int,
        gamePreferencesData: String,
        miningStrategy: String
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.autoClaimEnabled = autoClaimEnabled
        self.autoClaimPointsEnabled = autoClaimPointsEnabled
        self.logLevel = logLevel
        self.maxLogEntries = maxLogEntries
        self.appPresenceMode = appPresenceMode
        self.autoStartOnLaunch = autoStartOnLaunch
        self.startMinimized = startMinimized
        self.enableBadgesEmotes = enableBadgesEmotes
        self.avoidDuplicateStreams = avoidDuplicateStreams
        self.antiStallRecoveryEnabled = antiStallRecoveryEnabled
        self.prioritiseFollowedStreamers = prioritiseFollowedStreamers
        self.syncMinersState = syncMinersState
        self.preferSteamArtwork = preferSteamArtwork
        self.tipsEnabled = tipsEnabled
        self.runInBackground = runInBackground
        self.showActivityLogIcons = showActivityLogIcons
        self.animateActivityLogRows = animateActivityLogRows
        self.selectedDropsFiltersData = selectedDropsFiltersData
        self.selectedEventFiltersData = selectedEventFiltersData
        self.preferredQuality = preferredQuality
        self.showClaimNotifications = showClaimNotifications
        self.ignoredWarningsData = ignoredWarningsData
        self.twitchClientId = twitchClientId
        self.swiftBotEnabled = swiftBotEnabled
        self.swiftBotEndpoint = swiftBotEndpoint
        self.swiftBotWebhookURL = swiftBotWebhookURL
        self.swiftMinerAPIEndpoint = swiftMinerAPIEndpoint
        self.swiftBotHmacSecret = swiftBotHmacSecret
        self.swiftMinerAPIKey = swiftMinerAPIKey
        self.dmCampaignCompletedEnabled = dmCampaignCompletedEnabled
        self.dmConnectionExpiredEnabled = dmConnectionExpiredEnabled
        self.dmWelcomeBackEnabled = dmWelcomeBackEnabled
        self.dmLinkRequiredEnabled = dmLinkRequiredEnabled
        self.dmCampaignDetectedEnabled = dmCampaignDetectedEnabled
        self.dmAccountActionRequiredEnabled = dmAccountActionRequiredEnabled
        self.quietHoursEnabled = quietHoursEnabled
        self.quietHoursStartMinute = quietHoursStartMinute
        self.quietHoursEndMinute = quietHoursEndMinute
        self.gamePreferencesData = gamePreferencesData
        self.miningStrategy = miningStrategy
    }
}

@MainActor
public final class LoginItemSettings: ObservableObject {
    @Published public private(set) var isEnabled: Bool = false
    @Published public private(set) var requiresApproval: Bool = false
    @Published public private(set) var errorMessage: String?

    public init() {
        refresh()
    }

    public func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        requiresApproval = status == .requiresApproval
    }

    public func setEnabled(_ enabled: Bool) {
        errorMessage = nil

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        refresh()
    }
}

// MARK: - Extensions

public enum AppPresenceMode: String, CaseIterable, Identifiable {
    case dockOnly
    case dockAndMenuBar
    case menuBarWhenClosed

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dockOnly:
            return "Dock only"
        case .dockAndMenuBar:
            return "Dock + menu bar icon"
        case .menuBarWhenClosed:
            return "Minimise to menu bar"
        }
    }

    public var detail: String {
        switch self {
        case .dockOnly:
            return "Default macOS app behavior with no menu bar icon."
        case .dockAndMenuBar:
            return "Keep SwiftMiner visible in the Dock and add a menu bar icon."
        case .menuBarWhenClosed:
            return "Show the Dock icon while a window is open, then keep SwiftMiner in the menu bar when windows are closed or minimised."
        }
    }

    public var showsMenuBarExtra: Bool {
        switch self {
        case .dockOnly:
            return false
        case .dockAndMenuBar, .menuBarWhenClosed:
            return true
        }
    }
}

extension Settings.LogLevel {
    /// Check if this log level should display messages of a given level
    func shouldDisplay(_ level: Settings.LogLevel) -> Bool {
        let order: [Settings.LogLevel] = [.debug, .info, .warning, .error]
        guard let selfIndex = order.firstIndex(of: self),
              let levelIndex = order.firstIndex(of: level) else {
            return true
        }
        return levelIndex >= selfIndex
    }
}
