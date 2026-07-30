import SwiftUI
import Security
import ServiceManagement
import SwiftMinerCore

/// User settings persisted in UserDefaults.
/// Provides persistent preferences across app launches; properties are
/// observation-tracked per key via @Observable so views only re-render for
/// the settings they actually read.
@Observable
@MainActor
public final class Settings {

    /// Selects which priority list a miner uses. Kept separately from the
    /// personal list so choosing Global does not discard someone’s own list.
    public enum AccountPrioritySource: String, Codable, Sendable {
        case global
        case globalAndPersonal
        case personal
    }
    
    // MARK: - Shared Instance

    static let appStorageStore: UserDefaults = {
        if SwiftMinerRuntime.isRunningTests {
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

    // MARK: - UserDefaults Access

    // Typed accessors that mirror @AppStorage semantics: missing or mistyped
    // values fall back to the default, enums round-trip through rawValue.

    private static func read(_ key: String, default def: Bool) -> Bool {
        (appStorageStore.object(forKey: key) as? Bool) ?? def
    }

    private static func read(_ key: String, default def: Int) -> Int {
        (appStorageStore.object(forKey: key) as? Int) ?? def
    }

    private static func read(_ key: String, default def: String) -> String {
        appStorageStore.string(forKey: key) ?? def
    }

    private static func read<V: RawRepresentable>(_ key: String, default def: V) -> V where V.RawValue == String {
        guard let rawValue = appStorageStore.string(forKey: key),
              let value = V(rawValue: rawValue) else {
            return def
        }
        return value
    }

    private static func write(_ key: String, _ value: Bool) {
        appStorageStore.set(value, forKey: key)
    }

    private static func write(_ key: String, _ value: Int) {
        appStorageStore.set(value, forKey: key)
    }

    private static func write(_ key: String, _ value: String) {
        appStorageStore.set(value, forKey: key)
    }

    private static func write<V: RawRepresentable>(_ key: String, _ value: V) where V.RawValue == String {
        appStorageStore.set(value.rawValue, forKey: key)
    }

    // MARK: - Persisted Properties
    
    /// Whether auto-claim is enabled for completed drops
    public var autoClaimEnabled: Bool {
        get {
            access(keyPath: \.autoClaimEnabled)
            return Self.read("autoClaimEnabled", default: true)
        }
        set {
            withMutation(keyPath: \.autoClaimEnabled) {
                Self.write("autoClaimEnabled", newValue)
            }
        }
    }
    
    /// Whether to auto-claim community points bonuses
    public var autoClaimPointsEnabled: Bool {
        get {
            access(keyPath: \.autoClaimPointsEnabled)
            return Self.read("autoClaimPointsEnabled", default: true)
        }
        set {
            withMutation(keyPath: \.autoClaimPointsEnabled) {
                Self.write("autoClaimPointsEnabled", newValue)
            }
        }
    }
    
    /// Log level for console output
    public var logLevel: LogLevel {
        get {
            access(keyPath: \.logLevel)
            return Self.read("logLevel", default: .info)
        }
        set {
            withMutation(keyPath: \.logLevel) {
                Self.write("logLevel", newValue)
            }
        }
    }
    
    /// Whether to show the log console in the UI
    public var showLogConsole: Bool {
        get {
            access(keyPath: \.showLogConsole)
            return Self.read("showLogConsole", default: true)
        }
        set {
            withMutation(keyPath: \.showLogConsole) {
                Self.write("showLogConsole", newValue)
            }
        }
    }
    
    /// Maximum number of log entries to keep in memory
    public var maxLogEntries: Int {
        get {
            access(keyPath: \.maxLogEntries)
            return Self.read("maxLogEntries", default: 500)
        }
        set {
            withMutation(keyPath: \.maxLogEntries) {
                Self.write("maxLogEntries", newValue)
            }
        }
    }

    /// Diagnostic: when on, SwiftMiner samples its own CPU/memory usage so the
    /// Advanced "Resource Usage" popup can show averages. Off by default; nothing
    /// is sampled unless enabled, so there is no cost for normal use.
    public var monitorResourceUsage: Bool {
        get {
            access(keyPath: \.monitorResourceUsage)
            return Self.read("monitorResourceUsage", default: false)
        }
        set {
            withMutation(keyPath: \.monitorResourceUsage) {
                Self.write("monitorResourceUsage", newValue)
            }
        }
    }
    
    /// Legacy preference retained for users upgrading from the old boolean setting.
    public var minimizeToMenuBar: Bool {
        get {
            access(keyPath: \.minimizeToMenuBar)
            return Self.read("minimizeToMenuBar", default: false)
        }
        set {
            withMutation(keyPath: \.minimizeToMenuBar) {
                Self.write("minimizeToMenuBar", newValue)
            }
        }
    }

    /// Where SwiftMiner should appear while it is running.
    public var appPresenceMode: AppPresenceMode {
        get {
            access(keyPath: \.appPresenceMode)
            return Self.read("appPresenceMode", default: .dockOnly)
        }
        set {
            withMutation(keyPath: \.appPresenceMode) {
                Self.write("appPresenceMode", newValue)
            }
        }
    }
    
    /// Whether to start mining automatically on launch (if authenticated)
    public var autoStartOnLaunch: Bool {
        get {
            access(keyPath: \.autoStartOnLaunch)
            return Self.read("autoStartOnLaunch", default: false)
        }
        set {
            withMutation(keyPath: \.autoStartOnLaunch) {
                Self.write("autoStartOnLaunch", newValue)
            }
        }
    }

    /// Whether the main window should minimize itself when SwiftMiner launches.
    public var startMinimized: Bool {
        get {
            access(keyPath: \.startMinimized)
            return Self.read("startMinimized", default: false)
        }
        set {
            withMutation(keyPath: \.startMinimized) {
                Self.write("startMinimized", newValue)
            }
        }
    }

    /// Whether to include campaigns that only give non-drop rewards (badges/emotes)
    public var enableBadgesEmotes: Bool {
        get {
            access(keyPath: \.enableBadgesEmotes)
            return Self.read("enableBadgesEmotes", default: false)
        }
        set {
            withMutation(keyPath: \.enableBadgesEmotes) {
                Self.write("enableBadgesEmotes", newValue)
            }
        }
    }

    /// Whether IRL-category campaigns can be mined as earn-anywhere special campaigns.
    public var mineIRLCampaigns: Bool {
        get {
            access(keyPath: \.mineIRLCampaigns)
            return Self.read("mineIRLCampaigns", default: true)
        }
        set {
            withMutation(keyPath: \.mineIRLCampaigns) {
                Self.write("mineIRLCampaigns", newValue)
            }
        }
    }

    /// Prefer spreading miners across different streams for the same campaign when enough streams are available.
    public var avoidDuplicateStreams: Bool {
        get {
            access(keyPath: \.avoidDuplicateStreams)
            return Self.read("avoidDuplicateStreams", default: true)
        }
        set {
            withMutation(keyPath: \.avoidDuplicateStreams) {
                Self.write("avoidDuplicateStreams", newValue)
            }
        }
    }

    /// Whether SwiftMiner should restart a miner that appears stuck after a stall or recoverable error.
    /// Hidden and disabled by default while supervisor recovery is being reworked.
    public var antiStallRecoveryEnabled: Bool {
        get {
            access(keyPath: \.antiStallRecoveryEnabled)
            return Self.read("antiStallRecoveryEnabled", default: true)
        }
        set {
            withMutation(keyPath: \.antiStallRecoveryEnabled) {
                Self.write("antiStallRecoveryEnabled", newValue)
            }
        }
    }

    /// Whether followed or subscribed streamers should be preferred during channel selection.
    public var prioritiseFollowedStreamers: Bool {
        get {
            access(keyPath: \.prioritiseFollowedStreamers)
            return Self.read("prioritiseFollowedStreamers", default: false)
        }
        set {
            withMutation(keyPath: \.prioritiseFollowedStreamers) {
                Self.write("prioritiseFollowedStreamers", newValue)
            }
        }
    }

    /// Whether to sync all miners state (start/stop together)
    public var syncMinersState: Bool {
        get {
            access(keyPath: \.syncMinersState)
            return Self.read("syncMinersState", default: true)
        }
        set {
            withMutation(keyPath: \.syncMinersState) {
                Self.write("syncMinersState", newValue)
            }
        }
    }

    /// Whether to use Steam CDN artwork instead of Twitch game artwork.
    ///
    /// Off by default. Twitch box art is now requested at a usable resolution
    /// (see `TwitchBoxArt`), which removed the original reason to reach for Steam,
    /// and Steam answers 200 with a blank grey placeholder for titles it has no
    /// library art for — so preferring it could replace real artwork with nothing.
    public var preferSteamArtwork: Bool {
        get {
            access(keyPath: \.preferSteamArtwork)
            return Self.read("preferSteamArtwork", default: false)
        }
        set {
            withMutation(keyPath: \.preferSteamArtwork) {
                Self.write("preferSteamArtwork", newValue)
            }
        }
    }

    /// Which service the miner header picture is pulled from. Whichever source is
    /// picked, the other one is used when it has nothing, and the initial is drawn
    /// when neither does.
    public var minerAvatarSource: MinerAvatarSource {
        get {
            access(keyPath: \.minerAvatarSource)
            return Self.read("minerAvatarSource", default: .discord)
        }
        set {
            withMutation(keyPath: \.minerAvatarSource) {
                Self.write("minerAvatarSource", newValue)
            }
        }
    }

    /// JSON-encoded map of Twitch account ID -> cached profile-picture URL and the
    /// time it was resolved. Twitch only hands the URL out through an authenticated
    /// lookup, so caching it is what lets an avatar draw at launch; see
    /// `TwitchAvatarStore`, which owns the encoding.
    public var twitchAvatarsData: String {
        get {
            access(keyPath: \.twitchAvatarsData)
            return Self.read("twitchAvatarsData", default: "{}")
        }
        set {
            withMutation(keyPath: \.twitchAvatarsData) {
                Self.write("twitchAvatarsData", newValue)
            }
        }
    }

    /// Whether in-app TipKit hints are shown.
    public var tipsEnabled: Bool {
        get {
            access(keyPath: \.tipsEnabled)
            return Self.read("tipsEnabled", default: true)
        }
        set {
            withMutation(keyPath: \.tipsEnabled) {
                Self.write("tipsEnabled", newValue)
            }
        }
    }

    /// Whether to run in background when window is closed
    public var runInBackground: Bool {
        get {
            access(keyPath: \.runInBackground)
            return Self.read("runInBackground", default: true)
        }
        set {
            withMutation(keyPath: \.runInBackground) {
                Self.write("runInBackground", newValue)
            }
        }
    }

    /// Whether to show category icons next to each row in the Activity Log.
    public var showActivityLogIcons: Bool {
        get {
            access(keyPath: \.showActivityLogIcons)
            return Self.read("showActivityLogIcons", default: true)
        }
        set {
            withMutation(keyPath: \.showActivityLogIcons) {
                Self.write("showActivityLogIcons", newValue)
            }
        }
    }

    /// Whether to animate new rows sliding into the Activity Log.
    public var animateActivityLogRows: Bool {
        get {
            access(keyPath: \.animateActivityLogRows)
            return Self.read("animateActivityLogRows", default: true)
        }
        set {
            withMutation(keyPath: \.animateActivityLogRows) {
                Self.write("animateActivityLogRows", newValue)
            }
        }
    }

    /// Whether to animate status icons with Apple-style transitions and drawing effects.
    public var animatedStatusIcons: Bool {
        get {
            access(keyPath: \.animatedStatusIcons)
            return Self.read("animatedStatusIcons", default: true)
        }
        set {
            withMutation(keyPath: \.animatedStatusIcons) {
                Self.write("animatedStatusIcons", newValue)
            }
        }
    }

    /// Whether to use colour in palette-rendered status icons (e.g. the clock badge exclamation icon).
    public var coloredStatusIcons: Bool {
        get {
            access(keyPath: \.coloredStatusIcons)
            return Self.read("coloredStatusIcons", default: true)
        }
        set {
            withMutation(keyPath: \.coloredStatusIcons) {
                Self.write("coloredStatusIcons", newValue)
            }
        }
    }

    /// JSON-encoded array of DropFilter for the Drops list view.
    private var selectedDropsFiltersData: String {
        get {
            access(keyPath: \.selectedDropsFiltersData)
            return Self.read("selectedDropsFiltersData", default: "[\"active\"]")
        }
        set {
            withMutation(keyPath: \.selectedDropsFiltersData) {
                Self.write("selectedDropsFiltersData", newValue)
            }
        }
    }

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
    private var selectedEventFiltersData: String {
        get {
            access(keyPath: \.selectedEventFiltersData)
            return Self.read("selectedEventFiltersData", default: "[\"audit\",\"drops\",\"errors\",\"heartbeats\",\"mining\",\"system\",\"updates\",\"warnings\"]")
        }
        set {
            withMutation(keyPath: \.selectedEventFiltersData) {
                Self.write("selectedEventFiltersData", newValue)
            }
        }
    }

    /// One-time migration so existing users see heartbeat diagnostics after upgrading.
    private var eventFiltersHeartbeatDefaultApplied: Bool {
        get {
            access(keyPath: \.eventFiltersHeartbeatDefaultApplied)
            return Self.read("eventFiltersHeartbeatDefaultApplied", default: false)
        }
        set {
            withMutation(keyPath: \.eventFiltersHeartbeatDefaultApplied) {
                Self.write("eventFiltersHeartbeatDefaultApplied", newValue)
            }
        }
    }

    /// One-time migration so existing users see web-audit entries after upgrading.
    private var eventFiltersAuditDefaultApplied: Bool {
        get {
            access(keyPath: \.eventFiltersAuditDefaultApplied)
            return Self.read("eventFiltersAuditDefaultApplied", default: false)
        }
        set {
            withMutation(keyPath: \.eventFiltersAuditDefaultApplied) {
                Self.write("eventFiltersAuditDefaultApplied", newValue)
            }
        }
    }

    /// One-time migration so existing users see update entries after upgrading.
    private var eventFiltersUpdatesDefaultApplied: Bool {
        get {
            access(keyPath: \.eventFiltersUpdatesDefaultApplied)
            return Self.read("eventFiltersUpdatesDefaultApplied", default: false)
        }
        set {
            withMutation(keyPath: \.eventFiltersUpdatesDefaultApplied) {
                Self.write("eventFiltersUpdatesDefaultApplied", newValue)
            }
        }
    }

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
    private func applyUpdatesFilterDefaultIfNeeded() {
        guard !eventFiltersUpdatesDefaultApplied else { return }
        var filters = selectedEventFilters
        filters.insert(.updates)
        selectedEventFilters = filters
        eventFiltersUpdatesDefaultApplied = true
    }

    private func applyAuditFilterDefaultIfNeeded() {
        guard !eventFiltersAuditDefaultApplied else { return }
        var filters = selectedEventFilters
        filters.insert(.audit)
        selectedEventFilters = filters
        eventFiltersAuditDefaultApplied = true
    }

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
        [.mining, .heartbeats, .drops, .warnings, .errors, .discord, .audit, .updates, .system]
    }

#if DEBUG
    /// Bypass account-link/eligibility gates so the miner watches a random live channel
    /// for any time-active campaign. For exercising the watch pipeline only — drops
    /// won't actually credit for unlinked accounts.
    public var debugBypassLinkRequirement: Bool {
        get {
            access(keyPath: \.debugBypassLinkRequirement)
            return Self.read("debugBypassLinkRequirement", default: false)
        }
        set {
            withMutation(keyPath: \.debugBypassLinkRequirement) {
                Self.write("debugBypassLinkRequirement", newValue)
            }
        }
    }
#endif

    /// Preferred stream quality (for future use)
    public var preferredQuality: StreamQuality {
        get {
            access(keyPath: \.preferredQuality)
            return Self.read("preferredQuality", default: .auto)
        }
        set {
            withMutation(keyPath: \.preferredQuality) {
                Self.write("preferredQuality", newValue)
            }
        }
    }
    
    /// Whether to show notifications for drop claims
    public var showClaimNotifications: Bool { // Disabled by default per user request
        get {
            access(keyPath: \.showClaimNotifications)
            return Self.read("showClaimNotifications", default: false)
        }
        set {
            withMutation(keyPath: \.showClaimNotifications) {
                Self.write("showClaimNotifications", newValue)
            }
        }
    }

    /// JSON-encoded warnings that should be suppressed.
    /// Format: "accountId:gameId:warningType"
    private var ignoredWarningsData: String {
        get {
            access(keyPath: \.ignoredWarningsData)
            return Self.read("ignoredWarningsData", default: "[]")
        }
        set {
            withMutation(keyPath: \.ignoredWarningsData) {
                Self.write("ignoredWarningsData", newValue)
            }
        }
    }

    /// JSON-encoded temporary warning suppressions keyed by
    /// "accountId:gameId:warningType", with ISO-8601 expiry dates.
    private var temporaryIgnoredWarningsData: String {
        get {
            access(keyPath: \.temporaryIgnoredWarningsData)
            return Self.read("temporaryIgnoredWarningsData", default: "{}")
        }
        set {
            withMutation(keyPath: \.temporaryIgnoredWarningsData) {
                Self.write("temporaryIgnoredWarningsData", newValue)
            }
        }
    }

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
    public var lastSelectedGameId: String {
        get {
            access(keyPath: \.lastSelectedGameId)
            return Self.read("lastSelectedGameId", default: "")
        }
        set {
            withMutation(keyPath: \.lastSelectedGameId) {
                Self.write("lastSelectedGameId", newValue)
            }
        }
    }

    /// Whether the user explicitly dismissed the optional onboarding surface.
    public var hasDismissedOnboarding: Bool {
        get {
            access(keyPath: \.hasDismissedOnboarding)
            return Self.read("hasDismissedOnboarding", default: false)
        }
        set {
            withMutation(keyPath: \.hasDismissedOnboarding) {
                Self.write("hasDismissedOnboarding", newValue)
            }
        }
    }

    /// Twitch application Client ID (set once; used by all miners)
    public var twitchClientId: String {
        get {
            access(keyPath: \.twitchClientId)
            return Self.read("twitchClientId", default: "")
        }
        set {
            withMutation(keyPath: \.twitchClientId) {
                Self.write("twitchClientId", newValue)
            }
        }
    }

    /// Whether SwiftBot Discord integration is enabled
    public var swiftBotEnabled: Bool {
        get {
            access(keyPath: \.swiftBotEnabled)
            return Self.read("swiftBotEnabled", default: false)
        }
        set {
            withMutation(keyPath: \.swiftBotEnabled) {
                Self.write("swiftBotEnabled", newValue)
            }
        }
    }

    /// SwiftBot integration endpoint (e.g. http://127.0.0.1:8080)
    public var swiftBotEndpoint: String {
        get {
            access(keyPath: \.swiftBotEndpoint)
            return Self.read("swiftBotEndpoint", default: "")
        }
        set {
            withMutation(keyPath: \.swiftBotEndpoint) {
                Self.write("swiftBotEndpoint", newValue)
            }
        }
    }

    /// Webhook URL SwiftMiner POSTs events to (e.g. http://127.0.0.1:8080/webhooks/swiftminer/events)
    public var swiftBotWebhookURL: String {
        get {
            access(keyPath: \.swiftBotWebhookURL)
            return Self.read("swiftBotWebhookURL", default: "")
        }
        set {
            withMutation(keyPath: \.swiftBotWebhookURL) {
                Self.write("swiftBotWebhookURL", newValue)
            }
        }
    }

    /// Local SwiftMiner API endpoint SwiftBot calls for miner status and setup.
    public var swiftMinerAPIEndpoint: String {
        get {
            access(keyPath: \.swiftMinerAPIEndpoint)
            return Self.read("swiftMinerAPIEndpoint", default: "http://127.0.0.1:8080")
        }
        set {
            withMutation(keyPath: \.swiftMinerAPIEndpoint) {
                Self.write("swiftMinerAPIEndpoint", newValue)
            }
        }
    }

    /// Shared HMAC-SHA256 secret for webhook request signing
    public var swiftBotHmacSecret: String {
        get {
            access(keyPath: \.swiftBotHmacSecret)
            return Self.read("swiftBotHmacSecret", default: "")
        }
        set {
            withMutation(keyPath: \.swiftBotHmacSecret) {
                Self.write("swiftBotHmacSecret", newValue)
            }
        }
    }

    /// API Key for the SwiftMiner HTTP service (used by SwiftBot)
    public var swiftMinerAPIKey: String {
        get {
            access(keyPath: \.swiftMinerAPIKey)
            return Self.read("swiftMinerAPIKey", default: "")
        }
        set {
            withMutation(keyPath: \.swiftMinerAPIKey) {
                Self.write("swiftMinerAPIKey", newValue)
            }
        }
    }

    // MARK: - Web Dashboard
    //
    // Optional self-service browser dashboard. Independent of SwiftBot — it only
    // needs a Discord OAuth app (for sign-in) and a public origin. Disabled by
    // default; the in-process HTTP server registers its routes only when enabled.

    /// Whether the self-service web dashboard is enabled
    public var webDashboardEnabled: Bool {
        get {
            access(keyPath: \.webDashboardEnabled)
            return Self.read("webDashboardEnabled", default: false)
        }
        set {
            withMutation(keyPath: \.webDashboardEnabled) {
                Self.write("webDashboardEnabled", newValue)
            }
        }
    }

    /// Public origin the dashboard is served from (e.g. https://swiftminer.example.com).
    /// When SwiftBot is paired this is composed automatically from
    /// `webDashboardSubdomain` + the domain SwiftBot reports.
    public var webDashboardBaseURL: String {
        get {
            access(keyPath: \.webDashboardBaseURL)
            return Self.read("webDashboardBaseURL", default: "")
        }
        set {
            withMutation(keyPath: \.webDashboardBaseURL) {
                Self.write("webDashboardBaseURL", newValue)
            }
        }
    }

    /// Subdomain for the dashboard when the domain comes from SwiftBot
    /// (e.g. "swiftminer" → swiftminer.example.com).
    public var webDashboardSubdomain: String {
        get {
            access(keyPath: \.webDashboardSubdomain)
            return Self.read("webDashboardSubdomain", default: "swiftminer")
        }
        set {
            withMutation(keyPath: \.webDashboardSubdomain) {
                Self.write("webDashboardSubdomain", newValue)
            }
        }
    }

    /// When a downloaded update gets installed (the install relaunches the app).
    public var autoUpdateInstallPolicy: AutoUpdateInstallPolicy {
        get {
            access(keyPath: \.autoUpdateInstallPolicy)
            return Self.read("autoUpdateInstallPolicy", default: .whenIdle)
        }
        set {
            withMutation(keyPath: \.autoUpdateInstallPolicy) {
                Self.write("autoUpdateInstallPolicy", newValue)
            }
        }
    }

    /// Hour of day (0–23) for scheduled update installs.
    public var autoUpdateInstallHour: Int {
        get {
            access(keyPath: \.autoUpdateInstallHour)
            return Self.read("autoUpdateInstallHour", default: 3)
        }
        set {
            withMutation(keyPath: \.autoUpdateInstallHour) {
                Self.write("autoUpdateInstallHour", newValue)
            }
        }
    }

    /// Whether the one-time "web dashboard is live" DM announcement has been
    /// sent. Set after the first confirmed tunnel registration; never resent on
    /// updates or relaunches.
    public var webDashboardAnnounced: Bool {
        get {
            access(keyPath: \.webDashboardAnnounced)
            return Self.read("webDashboardAnnounced", default: false)
        }
        set {
            withMutation(keyPath: \.webDashboardAnnounced) {
                Self.write("webDashboardAnnounced", newValue)
            }
        }
    }

    /// SwiftBot's public hostname (e.g. swiftbot.example.com), cached from its
    /// tunnel info. Used for Discord sign-in brokered via SwiftBot.
    public var webDashboardSwiftBotHostname: String {
        get {
            access(keyPath: \.webDashboardSwiftBotHostname)
            return Self.read("webDashboardSwiftBotHostname", default: "")
        }
        set {
            withMutation(keyPath: \.webDashboardSwiftBotHostname) {
                Self.write("webDashboardSwiftBotHostname", newValue)
            }
        }
    }

    /// Whether users may sign in to the web dashboard with Twitch OAuth.
    /// Credentials stay saved when this is off, so the provider can be
    /// temporarily disabled without reconfiguring the Twitch application.
    public var webDashboardTwitchOAuthEnabled: Bool {
        get {
            access(keyPath: \.webDashboardTwitchOAuthEnabled)
            return Self.read("webDashboardTwitchOAuthEnabled", default: true)
        }
        set {
            withMutation(keyPath: \.webDashboardTwitchOAuthEnabled) {
                Self.write("webDashboardTwitchOAuthEnabled", newValue)
            }
        }
    }

    /// Whether users may sign in to the web dashboard with Discord OAuth.
    /// Discord OAuth is completed by a paired SwiftBot, which also verifies
    /// server membership before it returns an identity assertion.
    public var webDashboardDiscordOAuthEnabled: Bool {
        get {
            access(keyPath: \.webDashboardDiscordOAuthEnabled)
            return Self.read("webDashboardDiscordOAuthEnabled", default: true)
        }
        set {
            withMutation(keyPath: \.webDashboardDiscordOAuthEnabled) {
                Self.write("webDashboardDiscordOAuthEnabled", newValue)
            }
        }
    }

    /// Twitch OAuth application client ID used for web sign-in
    public var webDashboardTwitchClientID: String {
        get {
            access(keyPath: \.webDashboardTwitchClientID)
            return Self.read("webDashboardTwitchClientID", default: "")
        }
        set {
            withMutation(keyPath: \.webDashboardTwitchClientID) {
                Self.write("webDashboardTwitchClientID", newValue)
            }
        }
    }

    /// Twitch OAuth application client secret used for web sign-in
    public var webDashboardTwitchClientSecret: String {
        get {
            access(keyPath: \.webDashboardTwitchClientSecret)
            return Self.read("webDashboardTwitchClientSecret", default: "")
        }
        set {
            withMutation(keyPath: \.webDashboardTwitchClientSecret) {
                Self.write("webDashboardTwitchClientSecret", newValue)
            }
        }
    }

    /// Whether local username/password sign-in is allowed (default on). Only
    /// honoured for local/LAN access, never over the public domain.
    public var webDashboardLocalEnabled: Bool {
        get {
            access(keyPath: \.webDashboardLocalEnabled)
            return Self.read("webDashboardLocalEnabled", default: true)
        }
        set {
            withMutation(keyPath: \.webDashboardLocalEnabled) {
                Self.write("webDashboardLocalEnabled", newValue)
            }
        }
    }

    /// Username for local sign-in.
    public var webDashboardLocalUsername: String {
        get {
            access(keyPath: \.webDashboardLocalUsername)
            return Self.read("webDashboardLocalUsername", default: "admin")
        }
        set {
            withMutation(keyPath: \.webDashboardLocalUsername) {
                Self.write("webDashboardLocalUsername", newValue)
            }
        }
    }

    /// Encoded salted hash of the local password ("iterations:saltHex:hashHex").
    /// Empty until the operator sets a password; local sign-in is unavailable
    /// until then (no default credential ships).
    public var webDashboardLocalPasswordHash: String {
        get {
            access(keyPath: \.webDashboardLocalPasswordHash)
            return Self.read("webDashboardLocalPasswordHash", default: "")
        }
        set {
            withMutation(keyPath: \.webDashboardLocalPasswordHash) {
                Self.write("webDashboardLocalPasswordHash", newValue)
            }
        }
    }

    private static let webDashboardLocalPasswordService = "com.swiftminer.app.web-dashboard.local-password"

    public func webDashboardLocalPassword() -> String? {
        Self.readWebDashboardLocalPassword(username: webDashboardLocalUsername)
    }

    public func saveWebDashboardLocalPassword(_ password: String, username: String) throws {
        let cleanUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanUsername.isEmpty else { return }

        let oldUsername = webDashboardLocalUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        if !oldUsername.isEmpty, oldUsername != cleanUsername {
            Self.deleteWebDashboardLocalPassword(username: oldUsername)
        }

        try Self.writeWebDashboardLocalPassword(password, username: cleanUsername)
    }

    public func deleteWebDashboardLocalPassword(username: String? = nil) {
        Self.deleteWebDashboardLocalPassword(username: username ?? webDashboardLocalUsername)
    }

    private func isBlank(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether local sign-in is fully set up (enabled, username, password set).
    public var webDashboardLocalConfigured: Bool {
        webDashboardLocalEnabled && !isBlank(webDashboardLocalUsername) && !isBlank(webDashboardLocalPasswordHash)
    }

    /// Whether Twitch web sign-in has complete credentials.
    public var webDashboardTwitchConfigured: Bool {
        !isBlank(webDashboardTwitchClientID) && !isBlank(webDashboardTwitchClientSecret)
    }

    /// Parses the user-entered Public URL leniently: a bare hostname like
    /// "swiftminer.example.com" is treated as https. Returns nil only when the
    /// value is empty or genuinely not a usable http(s) origin.
    public static func normalizedWebDashboardURL(from raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host, host.contains(".") || host == "localhost" else {
            return nil
        }
        return url
    }

    /// Whether Twitch OAuth sign-in is fully configured (needs the public URL).
    public var webDashboardOAuthConfigured: Bool {
        webDashboardTwitchOAuthEnabled && !isBlank(webDashboardBaseURL) && webDashboardTwitchConfigured
    }

    public var webDashboardSwiftBotSSOConfigured: Bool {
        swiftBotEnabled
            && !isBlank(swiftBotHmacSecret)
            && !isBlank(webDashboardSwiftBotHostname)
    }

    /// Whether Discord OAuth can be offered by the paired SwiftBot.
    public var webDashboardDiscordOAuthConfigured: Bool {
        webDashboardDiscordOAuthEnabled && webDashboardSwiftBotSSOConfigured
    }

    /// Whether the dashboard is usable: enabled, and at least one sign-in method
    /// available — local username/password, Twitch OAuth, or Discord via SwiftBot.
    public var webDashboardConfigured: Bool {
        webDashboardEnabled
            && (webDashboardLocalConfigured || webDashboardOAuthConfigured || webDashboardDiscordOAuthConfigured)
    }

    // MARK: - Discord DM Notification Preferences

    // MARK: - Discord DM Notification Preferences
    //
    // Important notifications default ON — these relate to account recovery and action required.
    // Activity notifications default OFF — these are informational and can be noisy.

    public var dmCampaignCompletedEnabled: Bool {
        get {
            access(keyPath: \.dmCampaignCompletedEnabled)
            return Self.read("dmCampaignCompletedEnabled", default: false)
        }
        set {
            withMutation(keyPath: \.dmCampaignCompletedEnabled) {
                Self.write("dmCampaignCompletedEnabled", newValue)
            }
        }
    }

    public var dmConnectionExpiredEnabled: Bool {
        get {
            access(keyPath: \.dmConnectionExpiredEnabled)
            return Self.read("dmConnectionExpiredEnabled", default: true)
        }
        set {
            withMutation(keyPath: \.dmConnectionExpiredEnabled) {
                Self.write("dmConnectionExpiredEnabled", newValue)
            }
        }
    }

    public var dmWelcomeBackEnabled: Bool {
        get {
            access(keyPath: \.dmWelcomeBackEnabled)
            return Self.read("dmWelcomeBackEnabled", default: false)
        }
        set {
            withMutation(keyPath: \.dmWelcomeBackEnabled) {
                Self.write("dmWelcomeBackEnabled", newValue)
            }
        }
    }

    public var dmLinkRequiredEnabled: Bool {
        get {
            access(keyPath: \.dmLinkRequiredEnabled)
            return Self.read("dmLinkRequiredEnabled", default: true)
        }
        set {
            withMutation(keyPath: \.dmLinkRequiredEnabled) {
                Self.write("dmLinkRequiredEnabled", newValue)
            }
        }
    }

    public var dmCampaignDetectedEnabled: Bool {
        get {
            access(keyPath: \.dmCampaignDetectedEnabled)
            return Self.read("dmCampaignDetectedEnabled", default: false)
        }
        set {
            withMutation(keyPath: \.dmCampaignDetectedEnabled) {
                Self.write("dmCampaignDetectedEnabled", newValue)
            }
        }
    }

    public var dmAccountActionRequiredEnabled: Bool {
        get {
            access(keyPath: \.dmAccountActionRequiredEnabled)
            return Self.read("dmAccountActionRequiredEnabled", default: true)
        }
        set {
            withMutation(keyPath: \.dmAccountActionRequiredEnabled) {
                Self.write("dmAccountActionRequiredEnabled", newValue)
            }
        }
    }

    public var quietHoursEnabled: Bool {
        get {
            access(keyPath: \.quietHoursEnabled)
            return Self.read("quietHoursEnabled", default: false)
        }
        set {
            withMutation(keyPath: \.quietHoursEnabled) {
                Self.write("quietHoursEnabled", newValue)
            }
        }
    }

    public var quietHoursStartMinute: Int {
        get {
            access(keyPath: \.quietHoursStartMinute)
            return Self.read("quietHoursStartMinute", default: 22 * 60)
        }
        set {
            withMutation(keyPath: \.quietHoursStartMinute) {
                Self.write("quietHoursStartMinute", newValue)
            }
        }
    }

    public var quietHoursEndMinute: Int {
        get {
            access(keyPath: \.quietHoursEndMinute)
            return Self.read("quietHoursEndMinute", default: 7 * 60)
        }
        set {
            withMutation(keyPath: \.quietHoursEndMinute) {
                Self.write("quietHoursEndMinute", newValue)
            }
        }
    }
    
    /// JSON-encoded array of GamePreference for selected games
    public var gamePreferencesData: String {
        get {
            access(keyPath: \.gamePreferencesData)
            return Self.read("gamePreferencesData", default: "[]")
        }
        set {
            withMutation(keyPath: \.gamePreferencesData) {
                Self.write("gamePreferencesData", newValue)
            }
        }
    }

    /// JSON-encoded array of game-scoped failover streamer rules.
    public var gameFailoverStreamersData: String {
        get {
            access(keyPath: \.gameFailoverStreamersData)
            return Self.read("gameFailoverStreamersData", default: "[]")
        }
        set {
            withMutation(keyPath: \.gameFailoverStreamersData) {
                Self.write("gameFailoverStreamersData", newValue)
            }
        }
    }

    /// Legacy storage (kept for migration only)
    private var priorityGamesString: String {
        get {
            access(keyPath: \.priorityGamesString)
            return Self.read("priorityGamesString", default: "")
        }
        set {
            withMutation(keyPath: \.priorityGamesString) {
                Self.write("priorityGamesString", newValue)
            }
        }
    }

    /// Legacy storage (kept for migration only)
    private var excludedGamesString: String {
        get {
            access(keyPath: \.excludedGamesString)
            return Self.read("excludedGamesString", default: "")
        }
        set {
            withMutation(keyPath: \.excludedGamesString) {
                Self.write("excludedGamesString", newValue)
            }
        }
    }

    /// JSON-encoded map of Twitch account ID -> ordered priority game names.
    public var accountPriorityGamesData: String {
        get {
            access(keyPath: \.accountPriorityGamesData)
            return Self.read("accountPriorityGamesData", default: "{}")
        }
        set {
            withMutation(keyPath: \.accountPriorityGamesData) {
                Self.write("accountPriorityGamesData", newValue)
            }
        }
    }

    /// JSON-encoded map of Twitch account ID -> whether global priority games
    /// should be appended after the miner's own list. Missing means true for
    /// backward compatibility.
    public var accountIncludesGlobalPriorityGamesData: String {
        get {
            access(keyPath: \.accountIncludesGlobalPriorityGamesData)
            return Self.read("accountIncludesGlobalPriorityGamesData", default: "{}")
        }
        set {
            withMutation(keyPath: \.accountIncludesGlobalPriorityGamesData) {
                Self.write("accountIncludesGlobalPriorityGamesData", newValue)
            }
        }
    }

    /// JSON-backed per-account source selection for priority games.
    public var accountPrioritySourcesData: String {
        get {
            access(keyPath: \.accountPrioritySourcesData)
            return Self.read("accountPrioritySourcesData", default: "{}")
        }
        set {
            withMutation(keyPath: \.accountPrioritySourcesData) {
                Self.write("accountPrioritySourcesData", newValue)
            }
        }
    }

    /// Mining strategy selection
    public var miningStrategy: MiningStrategy {
        get {
            access(keyPath: \.miningStrategy)
            return Self.read("miningStrategy", default: .mineAll)
        }
        set {
            withMutation(keyPath: \.miningStrategy) {
                Self.write("miningStrategy", newValue)
            }
        }
    }

    // MARK: - Game Preferences

    /// Memoized decode of `gamePreferencesData`. Decoding + normalization is
    /// expensive and `gamePreferences` is read many times per SwiftUI render
    /// (directly, and via `excludedGames`/`gameNames(for:)`), so we cache the
    /// result and only re-decode when the backing JSON string actually changes.
    /// `@ObservationIgnored` storage on this `@MainActor` class: mutating it
    /// from the getter is safe and never triggers a view-update cycle.
    @ObservationIgnored private var cachedGamePreferences: [GamePreference] = []
    @ObservationIgnored private var cachedGamePreferencesKey: String?

    /// Decoded game preferences from JSON storage
    public var gamePreferences: [GamePreference] {
        get {
            let raw = gamePreferencesData
            if cachedGamePreferencesKey == raw {
                return cachedGamePreferences
            }
            let decoded: [GamePreference]
            if let data = raw.data(using: .utf8),
               let prefs = try? JSONDecoder().decode([GamePreference].self, from: data) {
                decoded = normalizedPreferences(prefs)
            } else {
                decoded = []
            }
            cachedGamePreferencesKey = raw
            cachedGamePreferences = decoded
            return decoded
        }
        set {
            let normalized = normalizedPreferences(newValue)
            if let data = try? JSONEncoder().encode(normalized),
               let string = String(data: data, encoding: .utf8) {
                guard gamePreferencesData != string else { return }
                gamePreferencesData = string
                // Keep the cache hot for the value we just persisted.
                cachedGamePreferencesKey = string
                cachedGamePreferences = normalized
            }
        }
    }

    public var gameFailoverStreamers: [GameFailoverStreamer] {
        get {
            guard let data = gameFailoverStreamersData.data(using: .utf8),
                  let rules = try? JSONDecoder().decode([GameFailoverStreamer].self, from: data) else {
                return []
            }
            return normalizedFailoverStreamers(rules)
        }
        set {
            let normalized = normalizedFailoverStreamers(newValue)
            if let data = try? JSONEncoder().encode(normalized),
               let string = String(data: data, encoding: .utf8) {
                guard gameFailoverStreamersData != string else { return }
                gameFailoverStreamersData = string
            }
        }
    }

    /// Priority game names derived from preferences (backward compat for MinerEngine)
    public var priorityGames: [String] {
        gameNames(for: .preferred)
    }

    public var accountPriorityGames: [String: [String]] {
        get {
            guard let data = accountPriorityGamesData.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) else {
                return [:]
            }
            return decoded.mapValues(Self.normalizedPriorityGameNames)
        }
        set {
            let normalized = newValue.reduce(into: [String: [String]]()) { result, entry in
                let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
                let values = Self.normalizedPriorityGameNames(entry.value)
                if !key.isEmpty, !values.isEmpty {
                    result[key] = values
                }
            }
            if let data = try? JSONEncoder().encode(normalized),
               let string = String(data: data, encoding: .utf8) {
                accountPriorityGamesData = string
            }
        }
    }

    public func priorityGames(forAccountId accountId: String) -> [String] {
        let key = accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return priorityGames }
        switch prioritySource(forAccountId: key) {
        case .global:
            return priorityGames
        case .globalAndPersonal:
            return Self.normalizedPriorityGameNames(personalPriorityGames(forAccountId: key) + priorityGames)
        case .personal:
            return personalPriorityGames(forAccountId: key)
        }
    }

    public var accountIncludesGlobalPriorityGames: [String: Bool] {
        get {
            guard let data = accountIncludesGlobalPriorityGamesData.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String: Bool].self, from: data) else {
                return [:]
            }
            return decoded.reduce(into: [String: Bool]()) { result, entry in
                let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty {
                    result[key] = entry.value
                }
            }
        }
        set {
            let normalized = newValue.reduce(into: [String: Bool]()) { result, entry in
                let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty {
                    result[key] = entry.value
                }
            }
            if let data = try? JSONEncoder().encode(normalized),
               let string = String(data: data, encoding: .utf8) {
                accountIncludesGlobalPriorityGamesData = string
            }
        }
    }

    public func includesGlobalPriorityGames(forAccountId accountId: String) -> Bool {
        switch prioritySource(forAccountId: accountId) {
        case .global, .globalAndPersonal: return true
        case .personal: return false
        }
    }

    public var accountPrioritySources: [String: AccountPrioritySource] {
        get {
            guard let data = accountPrioritySourcesData.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String: AccountPrioritySource].self, from: data) else {
                return [:]
            }
            return decoded.reduce(into: [String: AccountPrioritySource]()) { result, entry in
                let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty { result[key] = entry.value }
            }
        }
        set {
            let normalized = newValue.reduce(into: [String: AccountPrioritySource]()) { result, entry in
                let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty { result[key] = entry.value }
            }
            if let data = try? JSONEncoder().encode(normalized),
               let string = String(data: data, encoding: .utf8) {
                accountPrioritySourcesData = string
            }
        }
    }

    public func prioritySource(forAccountId accountId: String) -> AccountPrioritySource {
        let key = accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .global }
        if let source = accountPrioritySources[key] { return source }
        if accountIncludesGlobalPriorityGames[key] == false { return .personal }
        return accountPriorityGames[key, default: []].isEmpty ? .global : .globalAndPersonal
    }

    public func setPrioritySource(_ source: AccountPrioritySource, forAccountId accountId: String) {
        let key = accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        var sources = accountPrioritySources
        sources[key] = source
        accountPrioritySources = sources

        // Keep the legacy value aligned for callers that have not yet migrated.
        var includeGlobals = accountIncludesGlobalPriorityGames
        includeGlobals[key] = source != .personal
        accountIncludesGlobalPriorityGames = includeGlobals
    }

    public func setIncludesGlobalPriorityGames(_ include: Bool, forAccountId accountId: String) {
        let key = accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        if include {
            let hasPersonalPriorities = !accountPriorityGames[key, default: []].isEmpty
            setPrioritySource(hasPersonalPriorities ? .globalAndPersonal : .global, forAccountId: key)
        } else {
            setPrioritySource(.personal, forAccountId: key)
        }
    }

    @discardableResult
    public func prioritiseGameForAccount(accountId: String, gameName: String) -> [String] {
        let key = accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        let game = gameName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !game.isEmpty else { return priorityGames(forAccountId: accountId) }

        if prioritySource(forAccountId: key) == .global {
            setPrioritySource(.globalAndPersonal, forAccountId: key)
        }
        var map = accountPriorityGames
        let existing = priorityGames(forAccountId: key)
        let remaining = existing.filter { $0.localizedCaseInsensitiveCompare(game) != .orderedSame }
        let updated = Self.normalizedPriorityGameNames([game] + remaining)
        map[key] = updated
        accountPriorityGames = map
        return priorityGames(forAccountId: key)
    }

    /// Remove a game from a miner's personal priority override, returning the
    /// miner's resulting effective list. Seeds the override from the global list
    /// first (so removing a personal game doesn't accidentally re-inherit it).
    @discardableResult
    public func deprioritiseGameForAccount(accountId: String, gameName: String) -> [String] {
        let key = accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        let game = gameName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !game.isEmpty else { return priorityGames(forAccountId: accountId) }

        var map = accountPriorityGames
        let existing = priorityGames(forAccountId: key)
        let updated = Self.normalizedPriorityGameNames(
            existing.filter { $0.localizedCaseInsensitiveCompare(game) != .orderedSame }
        )
        map[key] = updated
        accountPriorityGames = map
        return priorityGames(forAccountId: key)
    }

    /// Replace a miner's personal priority games with `games`, returning the miner's
    /// resulting effective list. The stored override keeps the personal games ahead of
    /// the global list (global still applies, at lower priority). Used by the Discord
    /// "edit games" modal, which submits the whole personal list at once.
    @discardableResult
    public func setPersonalPriorityGames(accountId: String, games: [String]) -> [String] {
        let key = accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return priorityGames(forAccountId: accountId) }

        let combined = Self.normalizedPriorityGameNames(games)
        var map = accountPriorityGames
        map[key] = combined
        accountPriorityGames = map
        if !combined.isEmpty, prioritySource(forAccountId: key) == .global {
            setPrioritySource(.globalAndPersonal, forAccountId: key)
        }
        return priorityGames(forAccountId: key)
    }

    /// The games prioritised specifically for one miner. When global priorities
    /// also apply, games that duplicate the global list are omitted from the
    /// returned list. Stored personal priorities remain available while the
    /// global-only source is selected, so changing sources never discards them.
    public func personalPriorityGames(forAccountId accountId: String) -> [String] {
        let key = accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, let override = accountPriorityGames[key] else { return [] }
        // Hide global duplicates only while the global list still applies to
        // this miner — there they'd be redundant. When the miner opts out of
        // global priorities, a personally-added game must stand on its own even
        // if it also appears globally; filtering it here made adding such a
        // game silently do nothing.
        guard prioritySource(forAccountId: key) == .globalAndPersonal else { return override }
        let globalKeys = Set(priorityGames.map { $0.lowercased() })
        return override.filter { !globalKeys.contains($0.lowercased()) }
    }

    /// Excluded game names derived from preferences (backward compat for MinerEngine)
    public var excludedGames: [String] {
        var games = gameNames(for: .excluded)
        if !mineIRLCampaigns {
            games.append(Game.specialIRLCategoryId)
        }
        return games
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
        clearFailoverStreamer(for: preference)
        removeCachedArtworkFiles(for: removed)
    }

    public func failoverStreamer(for preference: GamePreference) -> GameFailoverStreamer? {
        gameFailoverStreamers.first { failoverMatches($0, gameId: preference.gameId, gameName: preference.gameName) }
    }

    public func setFailoverStreamer(_ login: String, for preference: GamePreference) {
        guard let normalizedLogin = GameFailoverStreamer.normalizedStreamerLogin(login) else {
            clearFailoverStreamer(for: preference)
            return
        }

        var rules = gameFailoverStreamers
        let updated = GameFailoverStreamer(
            gameId: preference.gameId,
            gameName: preference.gameName,
            streamerLogin: normalizedLogin,
            enabled: true
        )

        if let index = rules.firstIndex(where: { failoverMatches($0, gameId: preference.gameId, gameName: preference.gameName) }) {
            rules[index] = updated
        } else {
            rules.append(updated)
        }
        gameFailoverStreamers = rules
    }

    public func clearFailoverStreamer(for preference: GamePreference) {
        var rules = gameFailoverStreamers
        rules.removeAll { failoverMatches($0, gameId: preference.gameId, gameName: preference.gameName) }
        gameFailoverStreamers = rules
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

    /// Drops persisted artwork links so the next render falls back to live artwork.
    ///
    /// Rewriting each preference through `GamePreference.init` is what does the work:
    /// it rejects `file://` URLs outright, so any cache path stored by an older build
    /// is discarded here. Uploaded artwork is passed through untouched — it lives in
    /// Application Support and is the user's own file, not a cache.
    public func clearCachedArtworkLinks() {
        gamePreferences = gamePreferences.map { preference in
            GamePreference(
                gameId: preference.gameId,
                gameName: preference.gameName,
                boxArtURL: preference.resolvedBoxArtURL,
                customArtworkURL: preference.customArtworkURL,
                state: preference.state
            )
        }
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
        applyAuditFilterDefaultIfNeeded()
        applyUpdatesFilterDefaultIfNeeded()
        applyHardenedAntiStallDefaultIfNeeded()
    }

    /// Earlier builds forcibly disabled this setting on every launch while recovery was being
    /// reworked. Apply the hardened default once so existing installs are not permanently left
    /// without a watchdog, while preserving any choice made after this migration.
    private func applyHardenedAntiStallDefaultIfNeeded() {
        let migrationKey = "hardenedAntiStallDefaultApplied"
        guard !Self.read(migrationKey, default: false) else { return }
        antiStallRecoveryEnabled = true
        Self.write(migrationKey, true)
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
        // `gamePreferences` is already normalized (and memoized); no need to
        // re-run the dedupe/trim pass on every access.
        gamePreferences
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

    private func normalizedFailoverStreamers(_ streamers: [GameFailoverStreamer]) -> [GameFailoverStreamer] {
        var seen = Set<String>()
        var deduped: [GameFailoverStreamer] = []

        for streamer in streamers.reversed() {
            let trimmedName = streamer.gameName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty,
                  let login = GameFailoverStreamer.normalizedStreamerLogin(streamer.streamerLogin) else { continue }

            let normalized = GameFailoverStreamer(
                gameId: streamer.gameId,
                gameName: trimmedName,
                streamerLogin: login,
                enabled: streamer.enabled
            )

            guard seen.insert(failoverKey(for: normalized)).inserted else { continue }
            deduped.append(normalized)
        }

        return deduped.reversed()
    }

    private static func normalizedPriorityGameNames(_ games: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for game in games {
            let trimmed = game.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard seen.insert(trimmed.lowercased()).inserted else { continue }
            result.append(trimmed)
        }
        return result
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

    private func failoverMatches(_ failover: GameFailoverStreamer, gameId: String, gameName: String) -> Bool {
        let storedId = failover.gameId.trimmingCharacters(in: .whitespacesAndNewlines)
        let incomingId = gameId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !storedId.isEmpty && !incomingId.isEmpty && storedId == incomingId {
            return true
        }

        return failover.gameName.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveCompare(gameName.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    private func preferenceKey(for preference: GamePreference) -> String {
        preferenceKey(gameId: preference.gameId, gameName: preference.gameName)
    }

    private func failoverKey(for failover: GameFailoverStreamer) -> String {
        preferenceKey(gameId: failover.gameId, gameName: failover.gameName)
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

    private static func readWebDashboardLocalPassword(username: String) -> String? {
        let cleanUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanUsername.isEmpty else { return nil }

        var query = webDashboardLocalPasswordQuery(username: cleanUsername)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func writeWebDashboardLocalPassword(_ password: String, username: String) throws {
        let data = Data(password.utf8)
        let query = webDashboardLocalPasswordQuery(username: username)
        let update: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        if status != errSecItemNotFound {
            throw keychainError(status, operation: "update")
        }

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw keychainError(addStatus, operation: "save")
        }
    }

    private static func deleteWebDashboardLocalPassword(username: String) {
        let cleanUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanUsername.isEmpty else { return }
        SecItemDelete(webDashboardLocalPasswordQuery(username: cleanUsername) as CFDictionary)
    }

    private static func webDashboardLocalPasswordQuery(username: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: webDashboardLocalPasswordService,
            kSecAttrAccount as String: username
        ]
    }

    private static func keychainError(_ status: OSStatus, operation: String) -> NSError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return NSError(
            domain: "SwiftMiner.WebDashboardLocalPassword",
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: "Could not \(operation) the local dashboard password in Keychain: \(message)"]
        )
    }

    // MARK: - Legacy Keychain backup cleanup

    private static let legacyBackupPromptLastShownKey = "legacyBackupPromptLastShown"
    private static let legacyBackupPromptInterval: TimeInterval = 7 * 24 * 60 * 60

    /// Whether the one-time migration of accounts into the real Keychain has completed.
    public var legacyAccountsMigrated: Bool {
        Self.appStorageStore.object(forKey: LegacyAccountMigrator.migratedAtKey) != nil
    }

    /// Whether to offer deleting the leftover `accounts.enc` backup at launch: migration is done,
    /// a backup file still exists, and we haven't asked within the last week.
    public var shouldPromptForLegacyBackupDeletion: Bool {
        guard legacyAccountsMigrated, LegacyAccountMigrator.legacyBackupExists else { return false }
        guard let last = Self.appStorageStore.object(forKey: Self.legacyBackupPromptLastShownKey) as? Date else { return true }
        return Date().timeIntervalSince(last) > Self.legacyBackupPromptInterval
    }

    /// Record that the backup-deletion prompt was shown now (suppresses it for ~a week).
    public func markLegacyBackupPromptShown() {
        Self.appStorageStore.set(Date(), forKey: Self.legacyBackupPromptLastShownKey)
    }

    /// Delete the leftover legacy backup file and clear the prompt schedule.
    public func deleteLegacyBackup() throws {
        try LegacyAccountMigrator.deleteLegacyBackup()
        Self.appStorageStore.removeObject(forKey: Self.legacyBackupPromptLastShownKey)
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
        let previousLocalUsername = webDashboardLocalUsername
        autoClaimEnabled = true
        autoClaimPointsEnabled = true
        logLevel = .info
        showLogConsole = true
        maxLogEntries = 500
        monitorResourceUsage = false
        minimizeToMenuBar = false
        appPresenceMode = .dockOnly
        autoStartOnLaunch = false
        enableBadgesEmotes = false
        mineIRLCampaigns = true
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
        webDashboardLocalEnabled = true
        webDashboardTwitchOAuthEnabled = true
        webDashboardDiscordOAuthEnabled = true
        webDashboardLocalUsername = "admin"
        webDashboardLocalPasswordHash = ""
        deleteWebDashboardLocalPassword(username: previousLocalUsername)
        deleteWebDashboardLocalPassword(username: "admin")
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
        gameFailoverStreamersData = "[]"
        accountPriorityGamesData = "{}"
        accountIncludesGlobalPriorityGamesData = "{}"
        accountPrioritySourcesData = "{}"
        selectedDropsFiltersData = "[\"active\"]"
        miningStrategy = .mineAll
        preferSteamArtwork = false
        minerAvatarSource = .discord
        twitchAvatarsData = "{}"
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
            mineIRLCampaigns: mineIRLCampaigns,
            avoidDuplicateStreams: avoidDuplicateStreams,
            antiStallRecoveryEnabled: antiStallRecoveryEnabled,
            prioritiseFollowedStreamers: prioritiseFollowedStreamers,
            syncMinersState: syncMinersState,
            preferSteamArtwork: preferSteamArtwork,
            minerAvatarSource: minerAvatarSource.rawValue,
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
        mineIRLCampaigns = backup.mineIRLCampaigns ?? true
        avoidDuplicateStreams = backup.avoidDuplicateStreams
        antiStallRecoveryEnabled = backup.antiStallRecoveryEnabled
        prioritiseFollowedStreamers = backup.prioritiseFollowedStreamers
        syncMinersState = backup.syncMinersState
        preferSteamArtwork = backup.preferSteamArtwork
        minerAvatarSource = backup.minerAvatarSource.flatMap(MinerAvatarSource.init(rawValue:)) ?? .discord
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
    public let mineIRLCampaigns: Bool?
    public let avoidDuplicateStreams: Bool
    public let antiStallRecoveryEnabled: Bool
    public let prioritiseFollowedStreamers: Bool
    public let syncMinersState: Bool
    public let preferSteamArtwork: Bool
    /// Optional: backups written before miner avatars were selectable have no value.
    public let minerAvatarSource: String?
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
        mineIRLCampaigns: Bool? = true,
        avoidDuplicateStreams: Bool,
        antiStallRecoveryEnabled: Bool,
        prioritiseFollowedStreamers: Bool,
        syncMinersState: Bool,
        preferSteamArtwork: Bool,
        minerAvatarSource: String? = nil,
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
        self.mineIRLCampaigns = mineIRLCampaigns
        self.avoidDuplicateStreams = avoidDuplicateStreams
        self.antiStallRecoveryEnabled = antiStallRecoveryEnabled
        self.prioritiseFollowedStreamers = prioritiseFollowedStreamers
        self.syncMinersState = syncMinersState
        self.preferSteamArtwork = preferSteamArtwork
        self.minerAvatarSource = minerAvatarSource
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

@Observable
@MainActor
public final class LoginItemSettings {
    public private(set) var isEnabled: Bool = false
    public private(set) var requiresApproval: Bool = false
    public private(set) var errorMessage: String?

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


/// Which service a miner's header picture comes from.
public enum MinerAvatarSource: String, CaseIterable, Identifiable, Sendable {
    /// The Discord account the miner is linked to, resolved through SwiftBot.
    case discord
    /// The miner's own Twitch account.
    case twitch

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .discord: return "Discord"
        case .twitch: return "Twitch"
        }
    }

    public var detail: String {
        switch self {
        case .discord:
            return "Use the picture from the Discord account a miner is linked to. Miners with no linked Discord fall back to their Twitch picture."
        case .twitch:
            return "Use the picture from the miner's own Twitch account. Falls back to the linked Discord picture when Twitch has none."
        }
    }

    /// Picks the preferred picture, then the other service's, then nothing — the
    /// caller draws the initial when this returns `nil`.
    public func resolve(discord: URL?, twitch: URL?) -> URL? {
        switch self {
        case .discord: return discord ?? twitch
        case .twitch: return twitch ?? discord
        }
    }
}

/// When automatically downloaded updates are installed.
public enum AutoUpdateInstallPolicy: String, CaseIterable, Identifiable {
    /// Install (and relaunch) as soon as the download finishes.
    case immediate
    /// Wait until no miner is actively mining. Stalled, errored, or
    /// auth-blocked miners count as idle — an update may be the fix.
    case whenIdle
    /// Wait for a fixed hour of day.
    case scheduled

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .immediate: return "Immediately"
        case .whenIdle: return "When miners are idle"
        case .scheduled: return "At a scheduled time"
        }
    }
}
