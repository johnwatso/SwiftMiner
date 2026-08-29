import Foundation
import Security

// Optional self-service browser dashboard. Independent of SwiftBot — it only needs a Discord
// OAuth app (for sign-in) and a public origin. Disabled by default; the in-process HTTP server
// registers its routes only when enabled.
//
// Split out of Settings.swift, which had grown past the point where one file could be read.
// These are the dashboard's own preferences plus the Keychain access for its local password;
// the password itself never goes through UserDefaults.

extension Settings {
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
}
