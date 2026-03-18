import SwiftUI
import SwiftTwitchMiner

/// User settings managed via @AppStorage.
/// Provides persistent preferences across app launches.
@MainActor
public final class Settings: ObservableObject {
    
    // MARK: - Shared Instance
    
    public static let shared = Settings()
    
    // MARK: - @AppStorage Properties
    
    /// Whether auto-claim is enabled for completed drops
    @AppStorage("autoClaimEnabled")
    public var autoClaimEnabled: Bool = true
    
    /// Whether to auto-claim community points bonuses
    @AppStorage("autoClaimPointsEnabled")
    public var autoClaimPointsEnabled: Bool = true
    
    /// Log level for console output
    @AppStorage("logLevel")
    public var logLevel: LogLevel = .info
    
    /// Whether to show the log console in the UI
    @AppStorage("showLogConsole")
    public var showLogConsole: Bool = true
    
    /// Maximum number of log entries to keep in memory
    @AppStorage("maxLogEntries")
    public var maxLogEntries: Int = 500
    
    /// Whether to minimize to menu bar instead of dock
    @AppStorage("minimizeToMenuBar")
    public var minimizeToMenuBar: Bool = false
    
    /// Whether to start mining automatically on launch (if authenticated)
    @AppStorage("autoStartOnLaunch")
    public var autoStartOnLaunch: Bool = false

    /// Whether to sync all miners state (start/stop together)
    @AppStorage("syncMinersState")
    public var syncMinersState: Bool = true

    /// Whether to run in background when window is closed
    @AppStorage("runInBackground")
    public var runInBackground: Bool = true

    /// Preferred stream quality (for future use)
    @AppStorage("preferredQuality")
    public var preferredQuality: StreamQuality = .auto
    
    /// Whether to show notifications for drop claims
    @AppStorage("showClaimNotifications")
    public var showClaimNotifications: Bool = true
    
    /// Last selected game/category (for UI restoration)
    @AppStorage("lastSelectedGameId")
    public var lastSelectedGameId: String = ""

    /// Twitch application Client ID (set once; used by all miners)
    @AppStorage("twitchClientId")
    public var twitchClientId: String = ""
    
    /// JSON-encoded array of GamePreference for selected games
    @AppStorage("gamePreferencesData")
    public var gamePreferencesData: String = "[]"

    /// Legacy storage (kept for migration only)
    @AppStorage("priorityGamesString")
    private var priorityGamesString: String = ""

    /// Legacy storage (kept for migration only)
    @AppStorage("excludedGamesString")
    private var excludedGamesString: String = ""

    /// Mining strategy selection
    @AppStorage("miningStrategy")
    public var miningStrategy: MiningStrategy = .mineAll

    // MARK: - Game Preferences

    /// Decoded game preferences from JSON storage
    public var gamePreferences: [GamePreference] {
        get {
            guard let data = gamePreferencesData.data(using: .utf8),
                  let prefs = try? JSONDecoder().decode([GamePreference].self, from: data) else {
                return []
            }
            return prefs
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let string = String(data: data, encoding: .utf8) {
                gamePreferencesData = string
            }
        }
    }

    /// Priority game names derived from preferences (backward compat for MinerEngine)
    public var priorityGames: [String] {
        gamePreferences.filter { $0.state == .preferred }.map { $0.gameName }
    }

    /// Excluded game names derived from preferences (backward compat for MinerEngine)
    public var excludedGames: [String] {
        gamePreferences.filter { $0.state == .excluded }.map { $0.gameName }
    }

    /// Add or update a game preference
    public func addGamePreference(_ game: Game, state: PreferenceState) {
        var prefs = gamePreferences
        prefs.removeAll { $0.gameId == game.id }
        prefs.append(GamePreference(gameId: game.id, gameName: game.name, boxArtURL: game.boxArtURL, state: state))
        gamePreferences = prefs
    }

    /// Remove a game preference by game ID
    public func removeGamePreference(gameId: String) {
        var prefs = gamePreferences
        prefs.removeAll { $0.gameId == gameId }
        gamePreferences = prefs
    }

    /// Toggle a game between preferred and excluded
    public func togglePreferenceState(gameId: String) {
        var prefs = gamePreferences
        if let idx = prefs.firstIndex(where: { $0.gameId == gameId }) {
            let old = prefs[idx]
            prefs[idx] = GamePreference(
                gameId: old.gameId,
                gameName: old.gameName,
                boxArtURL: old.boxArtURL,
                state: old.state == .preferred ? .excluded : .preferred
            )
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
        showClaimNotifications = true
        lastSelectedGameId = ""
        gamePreferencesData = "[]"
        miningStrategy = .mineAll
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
