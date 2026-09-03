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
    public enum AccountPrioritySource: String, Codable, Sendable, CaseIterable {
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

    static func read(_ key: String, default def: Bool) -> Bool {
        (appStorageStore.object(forKey: key) as? Bool) ?? def
    }

    static func read(_ key: String, default def: Int) -> Int {
        (appStorageStore.object(forKey: key) as? Int) ?? def
    }

    static func read(_ key: String, default def: String) -> String {
        appStorageStore.string(forKey: key) ?? def
    }

    static func read<V: RawRepresentable>(_ key: String, default def: V) -> V where V.RawValue == String {
        guard let rawValue = appStorageStore.string(forKey: key),
              let value = V(rawValue: rawValue) else {
            return def
        }
        return value
    }

    static func write(_ key: String, _ value: Bool) {
        appStorageStore.set(value, forKey: key)
    }

    static func write(_ key: String, _ value: Int) {
        appStorageStore.set(value, forKey: key)
    }

    static func write(_ key: String, _ value: String) {
        appStorageStore.set(value, forKey: key)
    }

    static func write<V: RawRepresentable>(_ key: String, _ value: V) where V.RawValue == String {
        appStorageStore.set(value.rawValue, forKey: key)
    }

    // MARK: - Secret Access
    //
    // Bearer credentials (the SwiftBot pairing secret, the local API key, the dashboard's
    // Twitch client secret) go to the Keychain in release builds. Unsigned DEBUG builds use
    // isolated debug-only defaults so changing the app's code identity does not produce a
    // Keychain authorization prompt for every observed-property read. Release reads still fall
    // back to `appStorageStore` until `SecretStore.migrateIfNeeded` completes.

    static func readSecret(_ key: SecretStore.Key) -> String {
        SecretStore.read(key, legacyDefaults: appStorageStore) ?? ""
    }

    static func writeSecret(_ key: SecretStore.Key, _ value: String) {
        do {
            try SecretStore.write(key, value)
            #if !DEBUG
            // Clear any legacy plaintext copy so the two can never disagree.
            appStorageStore.removeObject(forKey: key.rawValue)
            #endif
        } catch {
            // Losing the value outright would break the integration; keep it working and say so.
            Logger.storage.error("Could not save \(key.rawValue) to the Keychain: \(error.localizedDescription)")
            appStorageStore.set(value, forKey: key.rawValue)
        }
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
    
    /// How many Activity Log entries to keep, in memory and on disk.
    ///
    /// Rare categories are retained on top of this figure — see
    /// `NavigationModel.applyRetention` — so lowering it thins routine chatter
    /// without throwing away audit entries, warnings, or errors.
    ///
    /// Stored values below `Self.minLogEntries` are legacy: this setting was written
    /// but never read before 1.37, so a saved 500 reflects an old default rather than
    /// a choice anyone made, and honouring it would cut retention tenfold.
    public var maxLogEntries: Int {
        get {
            access(keyPath: \.maxLogEntries)
            return max(Self.minLogEntries, Self.read("maxLogEntries", default: Self.defaultLogEntries))
        }
        set {
            withMutation(keyPath: \.maxLogEntries) {
                Self.write("maxLogEntries", max(Self.minLogEntries, newValue))
            }
        }
    }

    /// Retention sizes offered in Advanced settings.
    public static let logEntryChoices = [5_000, 20_000, 50_000, 100_000]
    public static let defaultLogEntries = 5_000
    public static let minLogEntries = 1_000

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
            return Self.read("mineIRLCampaigns", default: false)
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

    /// Whether followed streamers should be preferred during channel selection.
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

    /// Legacy global miner-picture preference, retained so older settings backups
    /// still import cleanly. New avatar choices are stored per account in
    /// `accountAvatarSourcesData`.
    public var minerAvatarSource: MinerAvatarSource {
        get {
            access(keyPath: \.minerAvatarSource)
            return Self.read("minerAvatarSource", default: .automatic)
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

    /// JSON-backed source selection for each Twitch account's profile picture.
    /// Accounts with no entry fall back to `defaultAvatarSource`, so a setup that
    /// never opens the picker keeps drawing the picture it drew before the
    /// preference became per-account.
    public var accountAvatarSourcesData: String {
        get {
            access(keyPath: \.accountAvatarSourcesData)
            return Self.read("accountAvatarSourcesData", default: "{}")
        }
        set {
            withMutation(keyPath: \.accountAvatarSourcesData) {
                Self.write("accountAvatarSourcesData", newValue)
            }
        }
    }

    public var accountAvatarSources: [String: AccountAvatarSource] {
        get {
            guard let data = accountAvatarSourcesData.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String: AccountAvatarSource].self, from: data) else {
                return [:]
            }
            return decoded.reduce(into: [String: AccountAvatarSource]()) { result, entry in
                let accountId = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
                if !accountId.isEmpty {
                    result[accountId] = entry.value
                }
            }
        }
        set {
            let normalized = newValue.reduce(into: [String: AccountAvatarSource]()) { result, entry in
                let accountId = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
                if !accountId.isEmpty {
                    result[accountId] = entry.value
                }
            }
            // Sorted keys keep the stored string stable for an unchanged mapping,
            // so the guard below actually suppresses no-op writes — and the
            // observers hanging off `accountAvatarSourcesData` with them.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(normalized),
                  let encoded = String(data: data, encoding: .utf8),
                  accountAvatarSourcesData != encoded else {
                return
            }
            accountAvatarSourcesData = encoded
        }
    }

    /// What an account with no explicit choice uses. Derived from the retired
    /// global preference so a setup that had picked Discord before 1.37 keeps
    /// Discord pictures instead of silently reverting to Twitch.
    public var defaultAvatarSource: AccountAvatarSource {
        minerAvatarSource == .discord ? .discord : .twitch
    }

    public func avatarSource(forAccountId accountId: String) -> AccountAvatarSource {
        let key = accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return defaultAvatarSource }
        return accountAvatarSources[key] ?? defaultAvatarSource
    }

    public func setAvatarSource(_ source: AccountAvatarSource, forAccountId accountId: String) {
        let key = accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        var sources = accountAvatarSources
        sources[key] = source
        accountAvatarSources = sources
    }

    public func removeAvatarSource(forAccountId accountId: String) {
        let key = accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        var sources = accountAvatarSources
        guard sources.removeValue(forKey: key) != nil else { return }
        accountAvatarSources = sources
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

    /// JSON-encoded array of DropFilter for the Drops list view.
    var selectedDropsFiltersData: String {
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

    /// Earlier builds encoded the exclusive All chip as an empty selection. The
    /// toggle-style All control needs empty to mean every filter is off instead.
    private var dropsFilterToggleAllMigrationApplied: Bool {
        get {
            access(keyPath: \.dropsFilterToggleAllMigrationApplied)
            return Self.read("dropsFilterToggleAllMigrationApplied", default: false)
        }
        set {
            withMutation(keyPath: \.dropsFilterToggleAllMigrationApplied) {
                Self.write("dropsFilterToggleAllMigrationApplied", newValue)
            }
        }
    }

    /// JSON-encoded array of EventFilter for the Events view.
    var selectedEventFiltersData: String {
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
    var ignoredWarningsData: String {
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

    /// Shared HMAC-SHA256 secret for webhook request signing.
    /// Held in the Keychain, not `UserDefaults` — see `Self.readSecret`.
    public var swiftBotHmacSecret: String {
        get {
            access(keyPath: \.swiftBotHmacSecret)
            return Self.readSecret(.swiftBotHmacSecret)
        }
        set {
            withMutation(keyPath: \.swiftBotHmacSecret) {
                Self.writeSecret(.swiftBotHmacSecret, newValue)
            }
        }
    }

    /// API Key for the SwiftMiner HTTP service (used by SwiftBot).
    /// Held in the Keychain, not `UserDefaults` — see `Self.readSecret`.
    public var swiftMinerAPIKey: String {
        get {
            access(keyPath: \.swiftMinerAPIKey)
            return Self.readSecret(.swiftMinerAPIKey)
        }
        set {
            withMutation(keyPath: \.swiftMinerAPIKey) {
                Self.writeSecret(.swiftMinerAPIKey, newValue)
            }
        }
    }

    // MARK: - Game Preference Cache
    //
    // Stored here rather than in Settings+GamePreferences.swift only because an extension
    // cannot declare stored properties; the logic that uses them lives in that file.
    @ObservationIgnored var cachedGamePreferences: [GamePreference] = []
    @ObservationIgnored var cachedGamePreferencesKey: String?

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
        applyDropsFilterToggleAllMigrationIfNeeded()
        applyHeartbeatFilterDefaultIfNeeded()
        applyAuditFilterDefaultIfNeeded()
        applyUpdatesFilterDefaultIfNeeded()
        applyHardenedAntiStallDefaultIfNeeded()
    }

    private func applyDropsFilterToggleAllMigrationIfNeeded() {
        guard !dropsFilterToggleAllMigrationApplied else { return }
        selectedDropsFilters = DropsCampaignFilterRules.migratingLegacyAllSelection(
            selectedDropsFilters,
            migrationAlreadyApplied: false
        )
        dropsFilterToggleAllMigrationApplied = true
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

    func nextPreferenceState(after state: PreferenceState) -> PreferenceState {
        switch state {
        case .preferred:
            return .excluded
        case .excluded:
            return .neutral
        case .neutral:
            return .preferred
        }
    }

    func gameNames(for state: PreferenceState) -> [String] {
        // `gamePreferences` is already normalized (and memoized); no need to
        // re-run the dedupe/trim pass on every access.
        gamePreferences
            .filter { $0.state == state }
            .map(\.gameName)
    }

    func normalizedPreferences(_ preferences: [GamePreference]) -> [GamePreference] {
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

    func normalizedFailoverStreamers(_ streamers: [GameFailoverStreamer]) -> [GameFailoverStreamer] {
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

    static func normalizedPriorityGameNames(_ games: [String]) -> [String] {
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

    func preferenceMatches(_ preference: GamePreference, gameId: String, gameName: String) -> Bool {
        let storedId = preference.gameId.trimmingCharacters(in: .whitespacesAndNewlines)
        let incomingId = gameId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !storedId.isEmpty && !incomingId.isEmpty && storedId == incomingId {
            return true
        }

        return preference.gameName.trimmingCharacters(in: .whitespacesAndNewlines)
            .localizedCaseInsensitiveCompare(gameName.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
    }

    func failoverMatches(_ failover: GameFailoverStreamer, gameId: String, gameName: String) -> Bool {
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

    func customArtworkDirectory() throws -> URL {
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

    func preferredArtworkExtension(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        let supported = Set(["png", "jpg", "jpeg", "heic", "webp", "tiff", "gif"])
        return supported.contains(ext) ? ext : "png"
    }

    func customArtworkFileStem(gameId: String, gameName: String) -> String {
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

    func removeCachedArtworkFiles(for preferences: [GamePreference]) {
        for preference in preferences {
            removeCachedArtworkFile(at: preference.customArtworkURL)
        }
    }

    func removeCachedArtworkFile(at url: URL?) {
        guard let url, url.isFileURL, FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
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
        maxLogEntries = Self.defaultLogEntries
        minimizeToMenuBar = false
        appPresenceMode = .dockOnly
        autoStartOnLaunch = false
        enableBadgesEmotes = false
        mineIRLCampaigns = false
        avoidDuplicateStreams = true
        antiStallRecoveryEnabled = true
        prioritiseFollowedStreamers = false
        syncMinersState = true
        runInBackground = true
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
        minerAvatarSource = .automatic
        twitchAvatarsData = "{}"
        accountAvatarSourcesData = "{}"
        ignoredWarningsData = "[]"
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

}
