import Foundation
import Network

/// A process-wide request gate shared by every miner account.
///
/// Twitch limits are not isolated by `TwitchAPIClient` instance. Coordinating here prevents a
/// multi-account installation from multiplying its request burst, shares server-directed
/// cooldowns, and keeps miners from churning through recovery while the Mac is offline.
public actor TwitchRequestCoordinator {
    public static let shared = TwitchRequestCoordinator(
        connectivity: { NetworkAvailability.shared.isOnline }
    )

    private let maxRequests: Int
    private let windowNanoseconds: UInt64
    private let offlinePollNanoseconds: UInt64
    private let runtimeClock: RuntimeClock
    private let connectivity: @Sendable () -> Bool
    private var requestTicks: [UInt64] = []
    private var deferredUntilTick: UInt64?

    public init(
        maxRequests: Int = 5,
        per window: TimeInterval = 1,
        offlinePollInterval: TimeInterval = 2,
        runtimeClock: RuntimeClock = .continuous,
        connectivity: @escaping @Sendable () -> Bool = { true }
    ) {
        self.maxRequests = max(1, maxRequests)
        self.windowNanoseconds = Self.nanoseconds(window)
        self.offlinePollNanoseconds = Self.nanoseconds(offlinePollInterval)
        self.runtimeClock = runtimeClock
        self.connectivity = connectivity
    }

    /// Waits for connectivity, a shared `Retry-After` cooldown, and a global request slot.
    /// Cancellation is deliberately propagated so stopping a miner cannot leak another request.
    @discardableResult
    public func waitForPermit() async throws -> TimeInterval {
        let started = runtimeClock.nowNanoseconds()

        while !connectivity() {
            try Task.checkCancellation()
            try await runtimeClock.sleep(nanoseconds: offlinePollNanoseconds)
        }

        while true {
            try Task.checkCancellation()
            let now = runtimeClock.nowNanoseconds()

            if let deferredUntilTick, deferredUntilTick > now {
                try await runtimeClock.sleep(nanoseconds: deferredUntilTick - now)
                continue
            }
            self.deferredUntilTick = nil

            requestTicks.removeAll { tick in
                now >= tick && now - tick >= windowNanoseconds
            }

            if requestTicks.count < maxRequests {
                requestTicks.append(now)
                return Self.seconds(between: started, and: now)
            }

            guard let oldest = requestTicks.min() else { continue }
            let availableAt = oldest.addingReportingOverflow(windowNanoseconds)
            let deadline = availableAt.overflow ? UInt64.max : availableAt.partialValue
            try await runtimeClock.sleep(nanoseconds: deadline > now ? deadline - now : 1)
        }
    }

    /// Shares a server-directed cooldown with all accounts using this coordinator.
    public func deferRequests(for seconds: TimeInterval) {
        let duration = Self.nanoseconds(seconds)
        let now = runtimeClock.nowNanoseconds()
        let addition = now.addingReportingOverflow(duration)
        let proposed = addition.overflow ? UInt64.max : addition.partialValue
        deferredUntilTick = max(deferredUntilTick ?? 0, proposed)
    }

    private static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        guard seconds.isFinite, seconds > 0 else { return 1 }
        return UInt64(min(seconds * 1_000_000_000, Double(UInt64.max)))
    }

    private static func seconds(between start: UInt64, and end: UInt64) -> TimeInterval {
        guard end >= start else { return 0 }
        return TimeInterval(end - start) / 1_000_000_000
    }
}

/// Reachability is a recovery hint, not a claim that Twitch itself is healthy. It starts online
/// so launch is never held behind the first path callback, then suppresses request churn only when
/// macOS explicitly reports that no route is available.
private final class NetworkAvailability: @unchecked Sendable {
    static let shared = NetworkAvailability()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.swiftminer.network-path")
    private let lock = NSLock()
    private var online = true

    var isOnline: Bool {
        lock.withLock { online }
    }

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.lock.withLock {
                self?.online = path.status != .unsatisfied
            }
        }
        monitor.start(queue: queue)
    }
}
