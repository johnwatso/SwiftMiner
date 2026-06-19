import Foundation
import CryptoKit

// MARK: - Configuration

/// An OAuth identity provider for web sign-in.
public enum WebProvider: String, Sendable, CaseIterable {
    case discord
    case twitch
}

/// OAuth client credentials for one provider.
public struct WebProviderCredentials: Sendable {
    public let clientID: String
    public let clientSecret: String
    public init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }
}

/// Local username/password sign-in (operator console). Honoured only for
/// local/LAN access, never over the public domain.
public struct WebLocalCredentials: Sendable {
    public let username: String
    /// Encoded salted hash, see `WebSecurity.hashLocalPassword`.
    public let passwordHash: String
    public init(username: String, passwordHash: String) {
        self.username = username
        self.passwordHash = passwordHash
    }
}

/// Discord sign-in brokered through a paired SwiftBot: SwiftBot runs its own
/// Discord OAuth and hands back a short-lived identity assertion signed with
/// the shared pairing secret. No Discord app credentials live in SwiftMiner.
public struct WebSwiftBotSSO: Sendable {
    /// SwiftBot's public origin, e.g. "https://swiftbot.example.com".
    public let origin: String
    /// The shared pairing secret used to verify assertions.
    public let hmacSecret: String
    public init(origin: String, hmacSecret: String) {
        self.origin = origin
        self.hmacSecret = hmacSecret
    }
}

/// Configuration for the optional self-service web dashboard.
///
/// The dashboard is **disabled unless at least one provider is configured** —
/// every deployment that doesn't set these values behaves exactly as before,
/// with no new routes registered and the Bot-key gate unchanged. Discord and
/// Twitch sign-in are each enabled independently based on their credentials.
public struct WebDashboardConfig: Sendable {
    /// Public origin the dashboard is served from, e.g. `https://swiftminer.example.com`.
    /// Optional: a local-only deployment (username/password, no OAuth) needs none.
    public let baseURL: URL?
    public let discord: WebProviderCredentials?
    public let twitch: WebProviderCredentials?
    public let local: WebLocalCredentials?
    public let swiftBotSSO: WebSwiftBotSSO?

    /// Path segments. A single callback serves both providers — the provider is
    /// recovered from the one-time `state` — so only one redirect URL needs to
    /// be registered with Discord and Twitch.
    public static let callbackPath = "/oauth/callback"
    public static let loginPath = "/login"
    public static let logoutPath = "/logout"
    public static let appPath = "/app"
    public static let rootPath = "/"

    public static let publicPrefixes = ["/oauth", "/me", loginPath, logoutPath, appPath]
    public static let publicExactPaths: Set<String> = [rootPath]

    public static let sessionCookieName = "sm_session"
    public static let csrfHeaderName = "x-sm-csrf"
    public static let sessionTTL: TimeInterval = 7 * 24 * 60 * 60
    public static let oauthStateTTL: TimeInterval = 10 * 60

    // OAuth providers require a public URL (for the redirect). Local sign-in
    // does not.
    public var discordEnabled: Bool { baseURL != nil && discord != nil }
    public var twitchEnabled: Bool { baseURL != nil && twitch != nil }
    public var localEnabled: Bool { local != nil }
    /// Discord-via-SwiftBot needs the public URL too: the assertion comes back
    /// to the dashboard's own https callback.
    public var swiftBotSSOEnabled: Bool {
        baseURL != nil && swiftBotSSO != nil
            && !(swiftBotSSO?.hmacSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }
    public var anyProviderEnabled: Bool { discordEnabled || twitchEnabled || swiftBotSSOEnabled }
    public var anyEnabled: Bool { anyProviderEnabled || localEnabled }

    public func credentials(for provider: WebProvider) -> WebProviderCredentials? {
        switch provider {
        case .discord: return discordEnabled ? discord : nil
        case .twitch: return twitchEnabled ? twitch : nil
        }
    }

    /// OAuth redirect URI, or nil if no public URL is configured.
    public var redirectURI: String? {
        normalisedBase.map { $0 + WebDashboardConfig.callbackPath }
    }

    /// `baseURL` with any trailing slash removed, or nil.
    public var normalisedBase: String? {
        guard let baseURL else { return nil }
        var s = baseURL.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Host of the public domain, used to distinguish public vs local access.
    public var publicHost: String? { baseURL?.host?.lowercased() }

    /// Cookies are marked `Secure` over HTTPS (the intended production setup
    /// behind a TLS tunnel). Omitted for plain-HTTP local access.
    public var useSecureCookies: Bool { baseURL?.scheme?.lowercased() == "https" }

    public init(
        baseURL: URL?,
        discord: WebProviderCredentials?,
        twitch: WebProviderCredentials?,
        local: WebLocalCredentials? = nil,
        swiftBotSSO: WebSwiftBotSSO? = nil
    ) {
        if baseURL == nil, let swiftBotSSO {
            self.baseURL = URL(string: swiftBotSSO.origin)
        } else {
            self.baseURL = baseURL
        }
        self.discord = discord
        self.twitch = twitch
        self.local = local
        self.swiftBotSSO = swiftBotSSO
    }

    /// Build from environment, falling back to `UserDefaults`. Returns `nil`
    /// unless at least one sign-in method is configured. OAuth providers need a
    /// valid public base URL; local sign-in does not.
    public static func fromEnvironment(_ defaults: UserDefaults = .standard) -> WebDashboardConfig? {
        let env = ProcessInfo.processInfo.environment
        func value(_ envKey: String, _ defaultsKeys: String...) -> String? {
            if let v = env[envKey], !v.isEmpty { return v }
            for defaultsKey in defaultsKeys {
                if let v = defaults.string(forKey: defaultsKey), !v.isEmpty { return v }
            }
            return nil
        }

        let baseURL: URL?
        if let baseRaw = value("SWIFTMINER_WEB_BASE_URL", "webDashboardBaseURL", "swiftMinerWebBaseURL"),
           let url = URL(string: baseRaw),
           let scheme = url.scheme?.lowercased(),
           (scheme == "https" || scheme == "http"),
           url.host != nil {
            baseURL = url
        } else {
            baseURL = nil
        }

        var discord: WebProviderCredentials?
        if let id = value("SWIFTMINER_DISCORD_CLIENT_ID", "webDashboardDiscordClientID", "swiftMinerDiscordClientID"),
           let secret = value("SWIFTMINER_DISCORD_CLIENT_SECRET", "webDashboardDiscordClientSecret", "swiftMinerDiscordClientSecret") {
            discord = WebProviderCredentials(clientID: id, clientSecret: secret)
        }
        var twitch: WebProviderCredentials?
        if let id = value("SWIFTMINER_TWITCH_CLIENT_ID", "webDashboardTwitchClientID", "swiftMinerTwitchClientID"),
           let secret = value("SWIFTMINER_TWITCH_CLIENT_SECRET", "webDashboardTwitchClientSecret", "swiftMinerTwitchClientSecret") {
            twitch = WebProviderCredentials(clientID: id, clientSecret: secret)
        }

        var local: WebLocalCredentials?
        let localEnabled = defaults.object(forKey: "webDashboardLocalEnabled") as? Bool ?? true
        if localEnabled,
           let username = value("SWIFTMINER_WEB_LOCAL_USERNAME", "webDashboardLocalUsername"),
           let passwordHash = value("SWIFTMINER_WEB_LOCAL_PASSWORD_HASH", "webDashboardLocalPasswordHash") {
            let cleanUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
            if !cleanUsername.isEmpty {
                local = WebLocalCredentials(username: cleanUsername, passwordHash: passwordHash)
            }
        }

        let config = WebDashboardConfig(baseURL: baseURL, discord: discord, twitch: twitch, local: local)
        return config.anyEnabled ? config : nil
    }
}

// MARK: - Crypto helpers

public enum WebSecurity {
    /// 256 bits of CSPRNG output, hex-encoded. Swift's `SystemRandomNumberGenerator`
    /// is documented as cryptographically secure on Apple platforms.
    public static func randomToken(byteCount: Int = 32) -> String {
        var rng = SystemRandomNumberGenerator()
        var bytes = [UInt8]()
        bytes.reserveCapacity(byteCount)
        for _ in 0..<byteCount { bytes.append(UInt8.random(in: UInt8.min...UInt8.max, using: &rng)) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Length-independent, content constant-time string comparison. Prevents the
    /// compare itself from leaking how many leading characters matched.
    public static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let ab = Array(a.utf8)
        let bb = Array(b.utf8)
        var diff = ab.count ^ bb.count
        let n = max(ab.count, bb.count)
        var i = 0
        while i < n {
            let x = i < ab.count ? ab[i] : 0
            let y = i < bb.count ? bb[i] : 0
            diff |= Int(x ^ y)
            i += 1
        }
        return diff == 0
    }

    // MARK: - Local password hashing
    //
    // Salted, iterated HMAC-SHA256 (a PBKDF2-style chain). Strong enough for a
    // local-network password and dependency-free (CryptoKit only). Encoded as
    // "iterations:saltHex:hashHex".

    public static let passwordIterations = 210_000

    public static func hashLocalPassword(_ password: String, iterations: Int = passwordIterations) -> String {
        let salt = randomBytes(16)
        let hash = derive(password: password, salt: salt, iterations: iterations)
        return "\(iterations):\(hex(salt)):\(hex(hash))"
    }

    /// Verify `password` against an encoded hash in constant time. Returns false
    /// for malformed/empty stored values.
    public static func verifyLocalPassword(_ password: String, encoded: String) -> Bool {
        let parts = encoded.split(separator: ":", maxSplits: 2).map(String.init)
        guard parts.count == 3, let iterations = Int(parts[0]),
              let salt = bytes(fromHex: parts[1]), !parts[2].isEmpty else {
            return false
        }
        let computed = hex(derive(password: password, salt: salt, iterations: iterations))
        return constantTimeEquals(computed, parts[2])
    }

    private static func derive(password: String, salt: [UInt8], iterations: Int) -> [UInt8] {
        let key = SymmetricKey(data: Data(salt))
        var block = Data(password.utf8)
        var result = [UInt8]()
        for _ in 0..<max(iterations, 1) {
            let mac = HMAC<SHA256>.authenticationCode(for: block, using: key)
            result = Array(mac)
            block = Data(result)
        }
        return result
    }

    private static func randomBytes(_ count: Int) -> [UInt8] {
        var rng = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: UInt8.min...UInt8.max, using: &rng) }
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func bytes(fromHex hex: String) -> [UInt8]? {
        guard hex.count % 2 == 0 else { return nil }
        var out = [UInt8]()
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let b = UInt8(hex[idx..<next], radix: 16) else { return nil }
            out.append(b)
            idx = next
        }
        return out
    }
}

// MARK: - Cookie helpers

public enum WebCookie {
    /// Parse a `Cookie:` header value into a name→value map.
    public static func parse(_ header: String?) -> [String: String] {
        guard let header else { return [:] }
        var out: [String: String] = [:]
        for pair in header.split(separator: ";") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = kv[0].trimmingCharacters(in: .whitespaces)
            let value = kv[1].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { out[key] = value }
        }
        return out
    }

    /// Build a `Set-Cookie` value for the session cookie.
    public static func sessionCookie(name: String, value: String, maxAge: TimeInterval, secure: Bool) -> String {
        var parts = ["\(name)=\(value)", "Path=/", "HttpOnly", "SameSite=Lax", "Max-Age=\(Int(maxAge))"]
        if secure { parts.append("Secure") }
        return parts.joined(separator: "; ")
    }

    /// Build a `Set-Cookie` value that immediately clears the session cookie.
    public static func expiredCookie(name: String, secure: Bool) -> String {
        var parts = ["\(name)=", "Path=/", "HttpOnly", "SameSite=Lax", "Max-Age=0"]
        if secure { parts.append("Secure") }
        return parts.joined(separator: "; ")
    }
}

// MARK: - Form parsing

public enum WebForm {
    /// Parse an `application/x-www-form-urlencoded` body into a field map.
    public static func parse(_ body: Data) -> [String: String] {
        guard let raw = String(data: body, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for pair in raw.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard let keyRaw = kv.first else { continue }
            let key = decode(String(keyRaw))
            let value = kv.count > 1 ? decode(String(kv[1])) : ""
            if !key.isEmpty { out[key] = value }
        }
        return out
    }

    private static func decode(_ s: String) -> String {
        s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? s
    }
}
