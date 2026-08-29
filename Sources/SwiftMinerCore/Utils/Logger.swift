import Foundation
import os

/// os.log-backed logger for SwiftMinerCore diagnostics.
///
/// Messages go to the unified logging system (subsystem `com.swiftminer`), so
/// diagnostics from Release builds can be recovered with Console.app or
/// `log show --predicate 'subsystem == "com.swiftminer"'` when a user reports
/// an unattended failure — unlike `print`, whose output is lost once the app
/// is launched from Finder.
///
/// Messages are logged as public so they survive in `log show` output;
/// call sites must never interpolate secrets (tokens, cookies, passwords).
public struct Logger: Sendable {
    private let osLogger: os.Logger

    public init(category: String) {
        self.osLogger = os.Logger(subsystem: "com.swiftminer", category: category)
    }

    /// High-volume diagnostic detail. Not persisted by default; visible when
    /// streaming live (`log stream --level debug`).
    public func debug(_ message: @autoclosure () -> String) {
        let text = message()
        osLogger.debug("\(text, privacy: .public)")
    }

    /// Routine state transitions and progress notes.
    public func info(_ message: @autoclosure () -> String) {
        let text = message()
        osLogger.info("\(text, privacy: .public)")
    }

    /// Unexpected but recoverable conditions.
    public func warning(_ message: @autoclosure () -> String) {
        let text = message()
        osLogger.notice("\(text, privacy: .public)")
    }

    /// Failures that degrade functionality.
    public func error(_ message: @autoclosure () -> String) {
        let text = message()
        osLogger.error("\(text, privacy: .public)")
    }
}

// MARK: - Shared category loggers

extension Logger {
    /// Miner engine, supervisor, manager, and primary-state resolution.
    public static let engine = Logger(category: "Engine")
    /// GraphQL/HTTP traffic with Twitch.
    public static let api = Logger(category: "TwitchAPI")
    /// Device-code auth, token refresh, and client fingerprinting.
    public static let auth = Logger(category: "Auth")
    /// Campaign discovery, mapping, merging, and drops progress.
    public static let campaigns = Logger(category: "Campaigns")
    /// Campaign and game artwork resolution and caching.
    public static let artwork = Logger(category: "Artwork")
    /// Keychain, SQLite, and account persistence.
    public static let storage = Logger(category: "Storage")
    /// User notifications and unattended-incident reporting.
    public static let notifications = Logger(category: "Notifications")
    /// App lifecycle, window/menu setup, and the embedded local HTTP server.
    public static let app = Logger(category: "App")
}
