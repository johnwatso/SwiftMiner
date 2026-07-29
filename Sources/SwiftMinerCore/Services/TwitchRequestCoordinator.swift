import Foundation
import Network

/// A process-wide request gate shared by every miner account.
///
/// Twitch limits are not isolated by `TwitchAPIClient` instance. Coordinating here prevents a
/// multi-account installation from multiplying its request burst, shares server-directed
/// cooldowns, and keeps miners from churning through recovery while the Mac is offline.
public actor TwitchRequestCoordinator {
    public static let shared = TwitchRequestCoordinator(
        maxRequests: 20,
        maxRequestsPerClient: 5,
        connectivity: { NetworkAvailability.shared.isOnline },
        connectivityWaiter: { await NetworkAvailability.shared.waitUntilOnline() }
    )

    private let maxRequests: Int
    private let maxRequestsPerClient: Int?
    private let windowNanoseconds: UInt64
    private let offlinePollNanoseconds: UInt64
    private let runtimeClock: RuntimeClock
    private let connectivity: @Sendable () -> Bool
    private let connectivityWaiter: (@Sendable () async -> Void)?
    private var requestTicks: [UInt64] = []
    private var requestTicksByClient: [String: [UInt64]] = [:]
    private var deferredUntilTick: UInt64?

    public init(
        maxRequests: Int = 5,
        maxRequestsPerClient: Int? = nil,
        per window: TimeInterval = 1,
        offlinePollInterval: TimeInterval = 2,
        runtimeClock: RuntimeClock = .continuous,
        connectivity: @escaping @Sendable () -> Bool = { true },
        connectivityWaiter: (@Sendable () async -> Void)? = nil
    ) {
        self.maxRequests = max(1, maxRequests)
        self.maxRequestsPerClient = maxRequestsPerClient.map { max(1, $0) }
        self.windowNanoseconds = Self.nanoseconds(window)
        self.offlinePollNanoseconds = Self.nanoseconds(offlinePollInterval)
        self.runtimeClock = runtimeClock
        self.connectivity = connectivity
        self.connectivityWaiter = connectivityWaiter
    }

    /// Waits for connectivity, a shared `Retry-After` cooldown, and both fleet and client slots.
    /// Cancellation is deliberately propagated so stopping a miner cannot leak another request.
    @discardableResult
    public func waitForPermit(clientID: String? = nil) async throws -> TimeInterval {
        let started = runtimeClock.nowNanoseconds()

        while !connectivity() {
            try Task.checkCancellation()
            if let connectivityWaiter {
                await connectivityWaiter()
                try Task.checkCancellation()
            } else {
                // Keep the injectable polling fallback for deterministic tests and custom
                // coordinators. Production uses the NWPathMonitor waiter below and resumes as
                // soon as macOS reports a route again.
                try await runtimeClock.sleep(nanoseconds: offlinePollNanoseconds)
            }
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

            for trackedClientID in Array(requestTicksByClient.keys) {
                let liveTicks = requestTicksByClient[trackedClientID, default: []].filter { tick in
                    !(now >= tick && now - tick >= windowNanoseconds)
                }
                if liveTicks.isEmpty {
                    requestTicksByClient.removeValue(forKey: trackedClientID)
                } else {
                    requestTicksByClient[trackedClientID] = liveTicks
                }
            }

            let clientTicks = clientID.flatMap { requestTicksByClient[$0] } ?? []
            let clientHasCapacity = maxRequestsPerClient.map { clientTicks.count < $0 } ?? true
            if requestTicks.count < maxRequests, clientHasCapacity {
                requestTicks.append(now)
                if let clientID, maxRequestsPerClient != nil {
                    requestTicksByClient[clientID, default: []].append(now)
                }
                return Self.seconds(between: started, and: now)
            }

            let globalDeadline = requestTicks.count >= maxRequests
                ? Self.nextPermitTick(after: requestTicks.min(), windowNanoseconds: windowNanoseconds)
                : now
            let clientDeadline: UInt64
            if let maxRequestsPerClient, clientTicks.count >= maxRequestsPerClient {
                clientDeadline = Self.nextPermitTick(
                    after: clientTicks.min(),
                    windowNanoseconds: windowNanoseconds
                )
            } else {
                clientDeadline = now
            }
            let deadline = max(globalDeadline, clientDeadline)
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

    private static func nextPermitTick(after oldest: UInt64?, windowNanoseconds: UInt64) -> UInt64 {
        guard let oldest else { return 0 }
        let availableAt = oldest.addingReportingOverflow(windowNanoseconds)
        return availableAt.overflow ? UInt64.max : availableAt.partialValue
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
    private var onlineWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    var isOnline: Bool {
        lock.withLock { online }
    }

    func waitUntilOnline() async {
        guard !isOnline else { return }

        let waiterID = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resumeImmediately = lock.withLock { () -> Bool in
                    guard !online else { return true }
                    onlineWaiters[waiterID] = continuation
                    return false
                }
                if resumeImmediately {
                    continuation.resume()
                }
            }
        } onCancel: {
            let continuation = self.lock.withLock {
                self.onlineWaiters.removeValue(forKey: waiterID)
            }
            continuation?.resume()
        }
    }

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.updateAvailability(isOnline: path.status != .unsatisfied)
        }
        monitor.start(queue: queue)
    }

    private func updateAvailability(isOnline: Bool) {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            let becameOnline = !online && isOnline
            online = isOnline
            guard becameOnline else { return [] }
            let pending = Array(onlineWaiters.values)
            onlineWaiters.removeAll()
            return pending
        }
        waiters.forEach { $0.resume() }
    }
}
