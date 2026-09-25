import Foundation

/// Single source of truth for the User-Agent strings SwiftMiner sends to Twitch.
///
/// The pool starts with TDM's `ClientType.ANDROID_APP` user agents verbatim and
/// adds further plausible Galaxy variants so multi-miner setups can spread
/// across the pool without colliding.
///
/// Use `shared.userAgent(for: accountId)` to get a sticky-per-account UA — the
/// same account always receives the same UA, and concurrently active accounts
/// are guaranteed unique UAs until the pool is exhausted (16+ miners). For
/// transient contexts that don't have an account yet (e.g. the device-code
/// login flow), call `randomAndroidUserAgent()`.
public final class TwitchClientFingerprint: @unchecked Sendable {
    public static let shared = TwitchClientFingerprint()

    public static let androidUserAgents: [String] = [
        // TDM's verbatim pool (7)
        "Dalvik/2.1.0 (Linux; U; Android 16; SM-S911B Build/TP1A.220624.014) tv.twitch.android.app/25.3.0/2503006",
        "Dalvik/2.1.0 (Linux; U; Android 16; SM-S938B Build/BP2A.250605.031) tv.twitch.android.app/25.3.0/2503006",
        "Dalvik/2.1.0 (Linux; Android 16; SM-X716N Build/UP1A.231005.007) tv.twitch.android.app/25.3.0/2503006",
        "Dalvik/2.1.0 (Linux; U; Android 15; SM-G990B Build/AP3A.240905.015.A2) tv.twitch.android.app/25.3.0/2503006",
        "Dalvik/2.1.0 (Linux; U; Android 15; SM-G970F Build/AP3A.241105.008) tv.twitch.android.app/25.3.0/2503006",
        "Dalvik/2.1.0 (Linux; U; Android 15; SM-A566E Build/AP3A.240905.015.A2) tv.twitch.android.app/25.3.0/2503006",
        "Dalvik/2.1.0 (Linux; U; Android 14; SM-X306B Build/UP1A.231005.007) tv.twitch.android.app/25.3.0/2503006",
        // Additional Galaxy variants (8) — same Twitch app version, real device codes
        "Dalvik/2.1.0 (Linux; U; Android 16; SM-S921B Build/BP2A.250605.031) tv.twitch.android.app/25.3.0/2503006",
        "Dalvik/2.1.0 (Linux; U; Android 16; SM-S928B Build/BP2A.250605.031) tv.twitch.android.app/25.3.0/2503006",
        "Dalvik/2.1.0 (Linux; U; Android 15; SM-A346B Build/AP3A.241105.008) tv.twitch.android.app/25.3.0/2503006",
        "Dalvik/2.1.0 (Linux; Android 15; SM-A556B Build/AP3A.240905.015.A2) tv.twitch.android.app/25.3.0/2503006",
        "Dalvik/2.1.0 (Linux; U; Android 14; SM-G998B Build/UP1A.231005.007) tv.twitch.android.app/25.3.0/2503006",
        "Dalvik/2.1.0 (Linux; U; Android 15; SM-F731B Build/AP3A.240905.015.A2) tv.twitch.android.app/25.3.0/2503006",
        "Dalvik/2.1.0 (Linux; U; Android 15; SM-F946B Build/AP3A.241105.008) tv.twitch.android.app/25.3.0/2503006",
        "Dalvik/2.1.0 (Linux; Android 14; SM-T970 Build/UP1A.231005.007) tv.twitch.android.app/25.3.0/2503006",
    ]

    private let lock = NSLock()
    private var assignments: [String: String] = [:]

    /// Returns the UA assigned to this account, allocating one on first call.
    /// The same accountId always gets the same UA across calls (so a miner's
    /// auth, API and spade traffic all share a fingerprint). Different
    /// accountIds get distinct UAs until the pool is exhausted; beyond that
    /// the allocator falls back to a random pick to avoid blocking.
    public func userAgent(for accountId: String) -> String {
        // A TV-issued token is presented with the TV app's fingerprint. Pairing it with an
        // Android UA would claim to be a client the token was never issued to.
        if AccountClientRegistry.shared.clientId(for: accountId) == TwitchClientIDs.tv {
            return TwitchClientIDs.tvUserAgent
        }

        lock.lock()
        defer { lock.unlock() }

        if let existing = assignments[accountId] {
            return existing
        }
        let inUse = Set(assignments.values)
        let pool = Self.androidUserAgents
        let available = pool.filter { !inUse.contains($0) }
        let chosen = available.randomElement() ?? pool.randomElement() ?? pool[0]
        assignments[accountId] = chosen
        return chosen
    }

    /// Releases an account's UA back to the pool. Call on miner teardown so
    /// long-running app sessions don't leak slots when accounts are removed.
    public func release(accountId: String) {
        lock.lock()
        defer { lock.unlock() }
        assignments.removeValue(forKey: accountId)
    }

    /// One-shot random pick, no pool tracking. Use for short-lived contexts
    /// (device-code login, validation pings) where there's no stable account
    /// id yet.
    public static func randomAndroidUserAgent() -> String {
        androidUserAgents.randomElement() ?? androidUserAgents[0]
    }
}

/// Twitch's first-party client IDs SwiftMiner signs in with.
public enum TwitchClientIDs {
    /// Twitch's Android app — TwitchDropsMiner's `ANDROID_APP`. Every account added before
    /// September 2026 holds a token issued to it, and its tokens can still read the drops
    /// dashboard without an integrity token. Twitch stopped accepting it for new device-code
    /// sign-ins on 2026-09-18 (`invalid client`).
    public static let android = "kd1unb4b3q4t58fwlpcbzcbnm76a8fp"

    /// Twitch's Android TV app — TwitchDropsMiner's `SMARTBOX`. It still accepts device-code
    /// sign-in, and its tokens can watch, read inventory and drop progress, and claim. Twitch
    /// returns a silent `null` for the drops dashboard and campaign details, so campaigns for
    /// these accounts are discovered from live channels instead (see `TwitchAPIClient`).
    public static let tv = "ue6666qo983tsx6so1t0vnawi233wa"

    /// TwitchDropsMiner's `SMARTBOX` user agent, sent with TV-issued tokens.
    public static let tvUserAgent =
        "Mozilla/5.0 (Linux; Android 7.1; Smart Box C1) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/138.0.0.0 Safari/537.36"

    /// Whether tokens from this client can read the drops dashboard and campaign details.
    public static func canReadDropsDashboard(_ clientId: String) -> Bool {
        clientId != tv
    }
}

/// Remembers which Twitch client each account's token was issued to.
///
/// A token only works with the client ID that issued it, and SwiftMiner now signs accounts in
/// with more than one client. The mapping lives beside the account rather than on `Account`:
/// accounts are rebuilt field by field across several token stores, and a dropped field would
/// silently send a TV token with the Android client ID. Accounts with no entry predate the
/// registry and were all issued to `TwitchClientIDs.android`. Client IDs are public, so this is
/// ordinary defaults data, not a secret.
public final class AccountClientRegistry: @unchecked Sendable {
    public static let shared = AccountClientRegistry(
        defaults: SwiftMinerRuntime.isRunningTests
            ? (UserDefaults(suiteName: "SwiftMinerTests.AccountClientRegistry") ?? .standard)
            : .standard
    )

    private static let defaultsKey = "twitchClientIdByAccount"

    private let defaults: UserDefaults
    private let lock = NSLock()

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The client ID that issued this account's token, or nil for an account added before
    /// the registry existed.
    public func clientId(for accountId: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storedMap()[accountId]
    }

    public func record(_ clientId: String, for accountId: String) {
        let trimmed = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !accountId.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var map = storedMap()
        guard map[accountId] != trimmed else { return }
        map[accountId] = trimmed
        defaults.set(map, forKey: Self.defaultsKey)
    }

    public func remove(accountId: String) {
        lock.lock()
        defer { lock.unlock() }
        var map = storedMap()
        guard map.removeValue(forKey: accountId) != nil else { return }
        defaults.set(map, forKey: Self.defaultsKey)
    }

    private func storedMap() -> [String: String] {
        defaults.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
    }
}
