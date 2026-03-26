import Foundation

/// Token-bucket rate limiter for GQL requests.
/// Allows up to `maxRequests` per `windowInterval` (default: 5 req/s).
actor RateLimiter {

    private let maxRequests: Int
    private let windowInterval: TimeInterval
    /// Ring of timestamps for recent requests
    private var window: [Date] = []

    init(maxRequests: Int = 5, per windowInterval: TimeInterval = 1.0) {
        self.maxRequests = maxRequests
        self.windowInterval = windowInterval
    }

    /// Suspends the caller until a request slot is available, then claims one.
    func wait() async {
        let now = Date()
        // Evict timestamps outside the current window
        window = window.filter { now.timeIntervalSince($0) < windowInterval }

        if window.count >= maxRequests, let oldest = window.first {
            // Sleep until the oldest request leaves the window
            let delay = windowInterval - now.timeIntervalSince(oldest)
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            // Re-evict after sleep
            let after = Date()
            window = window.filter { after.timeIntervalSince($0) < windowInterval }
        }

        window.append(Date())
    }
}
