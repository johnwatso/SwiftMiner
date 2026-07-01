import Foundation

/// Lightweight trace logger for diagnosing Twitch API changes.
///
/// When `isEnabled` is `true`, services emit categorised lines like:
///
///     [GraphQL] ViewerDropsDashboard
///     [PubSub]  drop-progress (user-drop-events.123)
///     [Spade]   minute-watched → channel=shroud broadcast=1234567
///     [Claim]   Dropping The Ball — SUCCESS
///
/// Traces are forwarded to a single `@Sendable` callback so they flow into
/// the same log console as regular engine messages.
public actor DebugTrace {

    // MARK: - Shared instance

    public static let shared = DebugTrace()

    // MARK: - State

    /// Enable/disable trace output globally.
    public var isEnabled: Bool = false

    /// Optional handler; if nil, traces are printed to stdout.
    public var handler: (@Sendable (String) -> Void)?

    // MARK: - API

    public func setHandler(_ h: (@Sendable (String) -> Void)?) {
        handler = h
    }

    public func enable()  { isEnabled = true }
    public func disable() { isEnabled = false }

    /// Emit a trace line if tracing is enabled.
    public func emit(_ category: Category, _ message: String) {
        emitLazy(category) { message }
    }

    /// Emit a lazily-built trace line if tracing is enabled.
    public func emitLazy(_ category: Category, _ message: @Sendable () -> String) {
        guard isEnabled else { return }
        let line = "[\(category.rawValue)] \(message())"
        if let h = handler {
            h(line)
        } else {
            print(line)
        }
    }

    // MARK: - Categories

    public enum Category: String, Sendable {
        case graphQL = "GraphQL"
        case pubSub  = "PubSub"
        case spade   = "Spade"
        case claim   = "Claim"
        case auth    = "Auth"
    }
}

// MARK: - Convenience free functions (nonisolated, fire-and-forget)

/// Emit a GraphQL trace line.
public func traceGQL(_ operationName: String) {
    Task { await DebugTrace.shared.emit(.graphQL, operationName) }
}

/// Emit a PubSub trace line.
public func tracePubSub(_ event: String) {
    Task { await DebugTrace.shared.emit(.pubSub, event) }
}

/// Emit a Spade beacon trace line.
public func traceSpade(_ detail: String) {
    Task { await DebugTrace.shared.emit(.spade, detail) }
}

/// Emit a claim trace line.
public func traceClaim(_ detail: String) {
    Task { await DebugTrace.shared.emit(.claim, detail) }
}
