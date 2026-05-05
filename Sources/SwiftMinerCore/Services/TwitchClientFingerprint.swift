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
