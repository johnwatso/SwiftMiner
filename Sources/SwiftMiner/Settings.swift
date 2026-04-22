import SwiftUI
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
    
    /// Whether to minimize to menu bar instead of dock
    @AppStorage("minimizeToMenuBar", store: Settings.appStorageStore)
    public var minimizeToMenuBar: Bool = false
    
    /// Whether to start mining automatically on launch (if authenticated)
    @AppStorage("autoStartOnLaunch", store: Settings.appStorageStore)
    public var autoStartOnLaunch: Bool = false

    /// Whether to include campaigns that only give non-drop rewards (badges/emotes)
    @AppStorage("enableBadgesEmotes", store: Settings.appStorageStore)
    public var enableBadgesEmotes: Bool = false

    /// Whether to sync all miners state (start/stop together)
    @AppStorage("syncMinersState", store: Settings.appStorageStore)
    public var syncMinersState: Bool = true

    /// Whether to use Steam CDN artwork instead of Twitch game artwork
    @AppStorage("preferSteamArtwork", store: Settings.appStorageStore)
    public var preferSteamArtwork: Bool = true

    /// Whether to run in background when window is closed
    @AppStorage("runInBackground", store: Settings.appStorageStore)
    public var runInBackground: Bool = true

    /// Display style used for the Mining/Queued queue rail in Overview.
    @AppStorage("queueDisplayStyle", store: Settings.appStorageStore)
    public var queueDisplayStyle: QueueDisplayStyle = .stacked

    /// Miner whose queue should be shown on Overview. Empty means aggregate/all miners.
    @AppStorage("overviewQueueMinerId", store: Settings.appStorageStore)
    public var overviewQueueMinerId: String = ""

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
                objectWillChange.send()
                selectedDropsFiltersData = string
            }
        }
    }

#if DEBUG
    /// Whether Overview should render a synthetic queue for testing/screenshots.
    @AppStorage("debugFakeQueueEnabled", store: Settings.appStorageStore)
    public var debugFakeQueueEnabled: Bool = false

    /// Whether fake queue cards should show the "Debug Preview" badge.
    @AppStorage("debugShowPreviewBadge", store: Settings.appStorageStore)
    public var debugShowPreviewBadge: Bool = false

    /// Data source used for fake queue generation in debug builds.
    @AppStorage("debugFakeQueueSource", store: Settings.appStorageStore)
    public var debugFakeQueueSource: DebugFakeQueueSource = .prioritisedGames

    /// Number of cards to render in the fake queue.
    @AppStorage("debugFakeQueueLength", store: Settings.appStorageStore)
    public var debugFakeQueueLength: Int = 3

    /// JSON-encoded custom game name list for debug fake queue generation.
    @AppStorage("debugFakeQueueCustomGamesData", store: Settings.appStorageStore)
    private var debugFakeQueueCustomGamesData: String = "[]"

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

    public enum WarningType: String, Codable, Sendable {
        case accountLink = "accountLink"
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
                objectWillChange.send()
                ignoredWarningsData = encoded
            }
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
        return ignoredWarnings.contains(specific) || ignoredWarnings.contains(global)
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

    /// Last selected game/category (for UI restoration)
    @AppStorage("lastSelectedGameId", store: Settings.appStorageStore)
    public var lastSelectedGameId: String = ""

    /// Whether the user explicitly dismissed the optional onboarding surface.
    @AppStorage("hasDismissedOnboarding", store: Settings.appStorageStore)
    public var hasDismissedOnboarding: Bool = false

    /// Twitch application Client ID (set once; used by all miners)
    @AppStorage("twitchClientId", store: Settings.appStorageStore)
    public var twitchClientId: String = ""
    
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
                objectWillChange.send()
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

#if DEBUG
    public var clampedDebugFakeQueueLength: Int {
        max(1, min(8, debugFakeQueueLength))
    }

    public var debugFakeQueueCustomGames: [String] {
        get {
            guard let data = debugFakeQueueCustomGamesData.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String].self, from: data) else {
                return []
            }
            return decoded
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        set {
            let normalized = newValue
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if let data = try? JSONEncoder().encode(normalized),
               let encoded = String(data: data, encoding: .utf8) {
                debugFakeQueueCustomGamesData = encoded
            }
        }
    }

    public func addDebugFakeQueueGame(_ gameName: String) {
        let trimmed = gameName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var games = debugFakeQueueCustomGames
        guard !games.contains(where: { $0.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        games.append(trimmed)
        debugFakeQueueCustomGames = games
    }

    public func removeDebugFakeQueueGames(atOffsets offsets: IndexSet) {
        var games = debugFakeQueueCustomGames
        games.remove(atOffsets: offsets)
        debugFakeQueueCustomGames = games
    }

    public func moveDebugFakeQueueGames(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        var games = debugFakeQueueCustomGames
        games.move(fromOffsets: offsets, toOffset: destination)
        debugFakeQueueCustomGames = games
    }
#endif

    /// Add or update a game preference
    public func addGamePreference(_ game: Game, state: PreferenceState) {
        setGamePreference(game, state: state)
    }

    /// Add or update a game preference with the provided state.
    public func setGamePreference(_ game: Game, state: PreferenceState) {
        var prefs = gamePreferences
        if let index = prefs.firstIndex(where: { preferenceMatches($0, gameId: game.id, gameName: game.name) }) {
            prefs[index] = GamePreference(gameId: game.id, gameName: game.name, boxArtURL: game.boxArtURL, state: state)
        } else {
            prefs.append(GamePreference(gameId: game.id, gameName: game.name, boxArtURL: game.boxArtURL, state: state))
        }
        gamePreferences = prefs
    }

    /// Remove a game preference by game ID
    public func removeGamePreference(gameId: String) {
        var prefs = gamePreferences
        prefs.removeAll { $0.gameId == gameId }
        gamePreferences = prefs
    }

    /// Remove a specific game preference.
    public func removeGamePreference(_ preference: GamePreference) {
        var prefs = gamePreferences
        prefs.removeAll { preferenceMatches($0, gameId: preference.gameId, gameName: preference.gameName) }
        gamePreferences = prefs
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
                state: state
            )
        }
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

    public enum QueueDisplayStyle: String, CaseIterable, Identifiable, Sendable {
        case classic = "classic"
        case stacked = "stacked"
        case coverFlow = "coverFlow"

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .classic:
                return "Classic"
            case .stacked:
                return "Stacked"
            case .coverFlow:
                return "Cover Flow"
            }
        }
    }

#if DEBUG
    public enum DebugFakeQueueSource: String, CaseIterable, Identifiable, Sendable {
        case prioritisedGames = "prioritisedGames"
        case customGames = "customGames"

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .prioritisedGames:
                return "Prioritised Games"
            case .customGames:
                return "Custom Games"
            }
        }
    }
#endif
    
    // MARK: - Initialization
    
    private init() {
        migrateFromLegacyIfNeeded()
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
                state: preference.state
            )

            guard seen.insert(preferenceKey(for: normalized)).inserted else { continue }
            deduped.append(normalized)
        }

        return deduped.reversed()
    }

    private func preferenceMatches(_ preference: GamePreference, gameId: String, gameName: String) -> Bool {
        preferenceKey(gameId: preference.gameId, gameName: preference.gameName) == preferenceKey(gameId: gameId, gameName: gameName)
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
        autoStartOnLaunch = false
        syncMinersState = true
        runInBackground = true
        preferredQuality = .auto
        showClaimNotifications = false
        lastSelectedGameId = ""
        hasDismissedOnboarding = false
        gamePreferencesData = "[]"
        miningStrategy = .mineAll
        preferSteamArtwork = true
        overviewQueueMinerId = ""
        ignoredWarningsData = "[]"
    }
}

// MARK: - Extensions

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
