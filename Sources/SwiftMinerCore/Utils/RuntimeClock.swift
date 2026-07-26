import Foundation

/// Small injectable monotonic clock used for runtime deadlines and retry delays.
///
/// Wall-clock `Date` values remain appropriate for persisted diagnostics, but they can jump
/// when the system clock is corrected. Mining stalls and reconnect delays must only move
/// forwards, so those decisions use this clock instead.
public struct RuntimeClock: Sendable {
    private let nowProvider: @Sendable () -> UInt64
    private let sleepProvider: @Sendable (UInt64) async throws -> Void

    public init(
        nowNanoseconds: @escaping @Sendable () -> UInt64,
        sleepNanoseconds: @escaping @Sendable (UInt64) async throws -> Void
    ) {
        self.nowProvider = nowNanoseconds
        self.sleepProvider = sleepNanoseconds
    }

    public static let continuous = RuntimeClock(
        nowNanoseconds: { DispatchTime.now().uptimeNanoseconds },
        sleepNanoseconds: { nanoseconds in
            try await Task<Never, Never>.sleep(nanoseconds: nanoseconds)
        }
    )

    public func nowNanoseconds() -> UInt64 {
        nowProvider()
    }

    public func elapsedSeconds(since start: UInt64) -> TimeInterval {
        let current = nowProvider()
        guard current >= start else { return 0 }
        return TimeInterval(current - start) / 1_000_000_000
    }

    public func sleep(nanoseconds: UInt64) async throws {
        try await sleepProvider(nanoseconds)
    }

    public func deadline(after seconds: TimeInterval) -> UInt64 {
        let duration = Self.nanoseconds(seconds)
        let result = nowProvider().addingReportingOverflow(duration)
        return result.overflow ? UInt64.max : result.partialValue
    }

    public func hasReached(_ deadline: UInt64) -> Bool {
        nowProvider() >= deadline
    }

    public func remainingSeconds(until deadline: UInt64) -> TimeInterval {
        let current = nowProvider()
        guard deadline > current else { return 0 }
        return TimeInterval(deadline - current) / 1_000_000_000
    }

    public static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return UInt64(min(seconds * 1_000_000_000, Double(UInt64.max)))
    }
}

public struct RuntimeTimeoutError: LocalizedError, Sendable, Equatable {
    public let operation: String
    public let seconds: TimeInterval

    public var errorDescription: String? {
        "\(operation) timed out after \(Int(seconds)) seconds"
    }
}

/// Runs a cooperative async operation under a monotonic deadline.
public func withRuntimeTimeout<T: Sendable>(
    operationName: String,
    seconds: TimeInterval,
    clock: RuntimeClock = .continuous,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await clock.sleep(nanoseconds: RuntimeClock.nanoseconds(seconds))
            throw RuntimeTimeoutError(operation: operationName, seconds: seconds)
        }

        guard let first = try await group.next() else {
            throw CancellationError()
        }
        group.cancelAll()
        return first
    }
}
