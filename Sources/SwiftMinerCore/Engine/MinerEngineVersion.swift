import Foundation

/// Version stamp for the mining engine itself, independent of the app's
/// marketing version.
///
/// `MARKETING_VERSION` moves for website, documentation, and UI work, and
/// `CURRENT_PROJECT_VERSION` moves for every build, so neither answers the
/// question this stamp exists for: did the mining logic in the running copy
/// actually change? This number moves only when the engine does.
///
/// The numbering was applied retroactively from the engine's own history, with
/// each major marking a structural era:
///
/// - `1.x` — 2026-03-26. The original single-actor `MinerEngine` alongside
///   `MinerManager` and `MiningDataCoordinator`.
/// - `2.x` — 2026-05-08. `MinerSupervisor` took over the worker lifecycle.
/// - `3.x` — 2026-07-22. Channel selection and drop progress moved out into
///   their own files, as did the `MinerManager` helpers.
/// - `4.x` — 2026-08-30. Full decomposition into the current `MinerEngine+*`
///   layout (mining loop, events, claiming, callbacks, campaign warnings,
///   presentation).
///
/// The minor counts engine-changing commits within the era, so `4.14` is the
/// fourteenth engine change since that decomposition.
///
/// Every version listed above, and every one since, is described in
/// `Documentation/EngineChangelog.md`. Bumping this number and adding an entry
/// there are one step, and an agent obligation rather than a request the user has
/// to make — see the "Engine versioning" section of `AGENTS.md`.
public enum MinerEngineVersion {
    /// Bumped whenever anything under `Sources/SwiftMinerCore/Engine` changes
    /// mining behaviour.
    public static let current = "4.14"

    /// The date `current` last moved, as `yyyy-MM-dd`.
    public static let updated = "2026-09-05"

    /// `"4.14 · updated 2026-09-05"` — the form used wherever the surrounding
    /// context already says this is the engine.
    public static var summary: String { "\(current) · updated \(updated)" }

    /// `"Engine 4.14 · updated 2026-09-05"`, for lines that stand alone.
    public static var label: String { "Engine \(summary)" }
}
