import Foundation

/// Token-bucket rate limiter for GQL requests.
/// Allows up to `maxRequests` per `windowInterval` (default: 5 req/s).
actor RateLimiter {

    private let maxRequests: Int
    private let windowNanoseconds: UInt64
    private let runtimeClock: RuntimeClock
    /// Ring of timestamps for recent requests
    private var window: [UInt64] = []

    init(
        maxRequests: Int = 5,
        per windowInterval: TimeInterval = 1.0,
        runtimeClock: RuntimeClock = .continuous
    ) {
        self.maxRequests = maxRequests
        self.windowNanoseconds = RuntimeClock.nanoseconds(windowInterval)
        self.runtimeClock = runtimeClock
    }

    /// Suspends the caller until a request slot is available, then claims one.
    func wait() async throws {
        while true {
            try Task.checkCancellation()
            let now = runtimeClock.nowNanoseconds()
            window.removeAll { tick in
                now >= tick && now - tick >= windowNanoseconds
            }

            if window.count < maxRequests {
                window.append(now)
                return
            }

            guard let oldest = window.min() else { continue }
            let deadline = oldest.addingReportingOverflow(windowNanoseconds)
            let availableAt = deadline.overflow ? UInt64.max : deadline.partialValue
            try await runtimeClock.sleep(nanoseconds: availableAt > now ? availableAt - now : 1)
        }
    }
}
