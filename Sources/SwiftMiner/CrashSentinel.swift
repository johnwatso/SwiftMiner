import Foundation
import SwiftMinerCore

/// Detects launches that follow an unclean exit (crash, kill -9, power loss).
///
/// A sentinel file is written when the app launches and removed on orderly
/// termination; if the file already exists at launch, the previous run never
/// reached its clean-shutdown path. A crash and a force-quit are
/// indistinguishable here, so user-facing wording stays neutral
/// ("quit unexpectedly").
@MainActor
enum CrashSentinel {
    private static var sentinelURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SwiftMiner", isDirectory: true)
        return base.appendingPathComponent("unclean-exit.sentinel")
    }

    /// Call once at launch. Returns true when the previous run ended without a
    /// clean shutdown, then arms the sentinel for the current run.
    ///
    /// Disabled under tests (the test host never terminates cleanly) and in
    /// DEBUG (stopping a run from Xcode is always an "unclean" exit).
    static func armAndCheckPreviousExit() -> Bool {
        #if DEBUG
        return false
        #else
        guard !SwiftMinerRuntime.isRunningTests else { return false }
        let fm = FileManager.default
        let wasUnclean = fm.fileExists(atPath: sentinelURL.path)
        try? fm.createDirectory(at: sentinelURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: sentinelURL.path, contents: Data())
        return wasUnclean
        #endif
    }

    /// Call from the app's orderly-termination path.
    static func markCleanExit() {
        try? FileManager.default.removeItem(at: sentinelURL)
    }
}
