import Foundation

/// Low-overhead performance counters used by diagnostic exports.
///
/// The actor keeps only aggregate timings plus a small list of slow recent
/// requests/cycles, so it can run during normal mining without growing forever.
public actor PerformanceDiagnostics {
    public static let shared = PerformanceDiagnostics()

    public struct RequestOperation: Sendable, Equatable {
        public let operation: String
        public let requestCount: Int
        public let successCount: Int
        public let failureCount: Int
        public let retryCount: Int
        public let tokenRefreshCount: Int
        public let rateLimitWaitSeconds: TimeInterval
        public let averageLatencySeconds: TimeInterval
        public let p95LatencySeconds: TimeInterval
        public let maxLatencySeconds: TimeInterval
        public let lastAt: Date?
        public let lastError: String?
    }

    public struct RecentRequest: Sendable, Equatable {
        public let operation: String
        public let finishedAt: Date
        public let durationSeconds: TimeInterval
        public let succeeded: Bool
        public let retryCount: Int
        public let error: String?
    }

    /// URLSession's lower-level view of Twitch transport. Operation metrics include rate-limit
    /// coordination and retries; these timings identify where the final HTTP transaction spent
    /// time when an operation itself is slow.
    public struct TransportHost: Sendable, Equatable {
        public let host: String
        public let requestCount: Int
        public let reusedConnectionCount: Int
        public let averageTaskSeconds: TimeInterval
        public let averageDNSSeconds: TimeInterval?
        public let averageConnectSeconds: TimeInterval?
        public let averageTLSSeconds: TimeInterval?
        public let averageResponseSeconds: TimeInterval?
        public let protocols: [String]
    }

    public struct MiningCycleTiming: Sendable, Equatable {
        public let minerId: String
        public let minerLabel: String
        public let startedAt: Date
        public let finishedAt: Date
        public let outcome: String
        public let totalSeconds: TimeInterval
        public let campaignFetchSeconds: TimeInterval
        public let claimCheckSeconds: TimeInterval
        public let channelSelectionSeconds: TimeInterval
        public let watchStartupSeconds: TimeInterval
        public let candidateCount: Int
        public let selectedCampaign: String?
        public let selectedChannel: String?

        public init(
            minerId: String,
            minerLabel: String,
            startedAt: Date,
            finishedAt: Date,
            outcome: String,
            totalSeconds: TimeInterval,
            campaignFetchSeconds: TimeInterval,
            claimCheckSeconds: TimeInterval,
            channelSelectionSeconds: TimeInterval,
            watchStartupSeconds: TimeInterval,
            candidateCount: Int,
            selectedCampaign: String? = nil,
            selectedChannel: String? = nil
        ) {
            self.minerId = minerId
            self.minerLabel = minerLabel
            self.startedAt = startedAt
            self.finishedAt = finishedAt
            self.outcome = outcome
            self.totalSeconds = totalSeconds
            self.campaignFetchSeconds = campaignFetchSeconds
            self.claimCheckSeconds = claimCheckSeconds
            self.channelSelectionSeconds = channelSelectionSeconds
            self.watchStartupSeconds = watchStartupSeconds
            self.candidateCount = candidateCount
            self.selectedCampaign = selectedCampaign
            self.selectedChannel = selectedChannel
        }
    }

    public struct MiningCycleSummary: Sendable, Equatable {
        public let minerId: String
        public let minerLabel: String
        public let cycleCount: Int
        public let averageSeconds: TimeInterval
        public let p95Seconds: TimeInterval
        public let maxSeconds: TimeInterval
        public let lastCycle: MiningCycleTiming
        public let slowCycles: [MiningCycleTiming]
    }

    public enum EventOutboxDeliveryOutcome: String, Sendable, Equatable {
        case succeeded
        case retryableFailure
        case terminalFailure
    }

    public struct EventOutboxSummary: Sendable, Equatable {
        public let observedAt: Date
        public let pendingCount: Int
        public let deliveringCount: Int
        public let retryableCount: Int
        public let terminalCount: Int
        public let sentCount: Int
        public let oldestUndeliveredAgeSeconds: TimeInterval?
        public let deliveryAttemptCount: Int
        public let successfulDeliveryCount: Int
        public let retryableFailureCount: Int
        public let terminalFailureCount: Int
        public let averageNetworkSeconds: TimeInterval
        public let maxNetworkSeconds: TimeInterval
        public let averageEndToEndSeconds: TimeInterval
        public let maxEndToEndSeconds: TimeInterval
    }

    public struct Snapshot: Sendable, Equatable {
        public let generatedAt: Date
        public let requestOperations: [RequestOperation]
        public let slowRequests: [RecentRequest]
        public let miningCycles: [MiningCycleSummary]
        public let transportHosts: [TransportHost]
        public let eventOutbox: EventOutboxSummary?
    }

    private struct RequestAccumulator {
        var requestCount = 0
        var successCount = 0
        var failureCount = 0
        var retryCount = 0
        var tokenRefreshCount = 0
        var rateLimitWaitSeconds: TimeInterval = 0
        var totalLatencySeconds: TimeInterval = 0
        var maxLatencySeconds: TimeInterval = 0
        var latencies: [TimeInterval] = []
        var lastAt: Date?
        var lastError: String?
    }

    private struct MiningAccumulator {
        var minerLabel: String = ""
        var cycleCount = 0
        var totalSeconds: TimeInterval = 0
        var durations: [TimeInterval] = []
        var maxSeconds: TimeInterval = 0
        var lastCycle: MiningCycleTiming?
        var slowCycles: [MiningCycleTiming] = []
    }

    private struct TransportAccumulator {
        var requestCount = 0
        var reusedConnectionCount = 0
        var totalTaskSeconds: TimeInterval = 0
        var dnsSamples: [TimeInterval] = []
        var connectSamples: [TimeInterval] = []
        var tlsSamples: [TimeInterval] = []
        var responseSamples: [TimeInterval] = []
        var protocols: Set<String> = []
        var lastRecordedOrder: UInt64 = 0
    }

    private struct EventOutboxAccumulator {
        var observedAt: Date?
        var pendingCount = 0
        var deliveringCount = 0
        var retryableCount = 0
        var terminalCount = 0
        var sentCount = 0
        var oldestUndeliveredAgeSeconds: TimeInterval?
        var deliveryAttemptCount = 0
        var successfulDeliveryCount = 0
        var retryableFailureCount = 0
        var terminalFailureCount = 0
        var totalNetworkSeconds: TimeInterval = 0
        var maxNetworkSeconds: TimeInterval = 0
        var totalEndToEndSeconds: TimeInterval = 0
        var maxEndToEndSeconds: TimeInterval = 0
    }

    private var requestsByOperation: [String: RequestAccumulator] = [:]
    private var slowRequests: [RecentRequest] = []
    private var miningByMiner: [String: MiningAccumulator] = [:]
    private var transportByHost: [String: TransportAccumulator] = [:]
    private var eventOutbox = EventOutboxAccumulator()
    private var transportRecordOrder: UInt64 = 0

    private let maxLatencySamplesPerOperation = 200
    private let maxSlowRequests = 20
    private let maxDurationsPerMiner = 100
    private let maxSlowCyclesPerMiner = 5
    private let maxTransportHosts = 20
    private let maxTransportSamplesPerHost = 200
    private let maxProtocolsPerHost = 8

    private init() {}

    public func reset() {
        requestsByOperation.removeAll(keepingCapacity: true)
        slowRequests.removeAll(keepingCapacity: true)
        miningByMiner.removeAll(keepingCapacity: true)
        transportByHost.removeAll(keepingCapacity: true)
        eventOutbox = EventOutboxAccumulator()
        transportRecordOrder = 0
    }

    public func recordRequest(
        operation: String,
        durationSeconds: TimeInterval,
        succeeded: Bool,
        retryCount: Int = 0,
        tokenRefreshCount: Int = 0,
        rateLimitWaitSeconds: TimeInterval = 0,
        error: String? = nil,
        finishedAt: Date = Date()
    ) {
        let normalizedOperation = operation.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = normalizedOperation.isEmpty ? "unknown" : normalizedOperation
        let duration = max(0, durationSeconds)

        var accumulator = requestsByOperation[key, default: RequestAccumulator()]
        accumulator.requestCount += 1
        if succeeded {
            accumulator.successCount += 1
        } else {
            accumulator.failureCount += 1
        }
        accumulator.retryCount += max(0, retryCount)
        accumulator.tokenRefreshCount += max(0, tokenRefreshCount)
        accumulator.rateLimitWaitSeconds += max(0, rateLimitWaitSeconds)
        accumulator.totalLatencySeconds += duration
        accumulator.maxLatencySeconds = max(accumulator.maxLatencySeconds, duration)
        accumulator.latencies.append(duration)
        if accumulator.latencies.count > maxLatencySamplesPerOperation {
            accumulator.latencies.removeFirst(accumulator.latencies.count - maxLatencySamplesPerOperation)
        }
        accumulator.lastAt = finishedAt
        accumulator.lastError = error
        requestsByOperation[key] = accumulator

        let recent = RecentRequest(
            operation: key,
            finishedAt: finishedAt,
            durationSeconds: duration,
            succeeded: succeeded,
            retryCount: retryCount,
            error: error
        )
        slowRequests.append(recent)
        slowRequests.sort {
            if $0.durationSeconds == $1.durationSeconds {
                return $0.finishedAt > $1.finishedAt
            }
            return $0.durationSeconds > $1.durationSeconds
        }
        if slowRequests.count > maxSlowRequests {
            slowRequests.removeLast(slowRequests.count - maxSlowRequests)
        }
    }

    public func recordTokenRefresh(operation: String) {
        let key = operation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "unknown" : operation
        var accumulator = requestsByOperation[key, default: RequestAccumulator()]
        accumulator.tokenRefreshCount += 1
        accumulator.lastAt = Date()
        requestsByOperation[key] = accumulator
    }

    func recordTransport(_ timing: HTTPTransportTiming) {
        let host = timing.host.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = host.isEmpty ? "unknown" : host
        if transportByHost[key] == nil, transportByHost.count >= maxTransportHosts,
           let oldestHost = transportByHost.min(by: { $0.value.lastRecordedOrder < $1.value.lastRecordedOrder })?.key {
            transportByHost.removeValue(forKey: oldestHost)
        }
        var accumulator = transportByHost[key, default: TransportAccumulator()]
        accumulator.requestCount += 1
        accumulator.reusedConnectionCount += timing.reusedConnection ? 1 : 0
        accumulator.totalTaskSeconds += timing.taskSeconds
        if let dnsSeconds = timing.dnsSeconds {
            Self.appendTransportSample(dnsSeconds, to: &accumulator.dnsSamples, limit: maxTransportSamplesPerHost)
        }
        if let connectSeconds = timing.connectSeconds {
            Self.appendTransportSample(connectSeconds, to: &accumulator.connectSamples, limit: maxTransportSamplesPerHost)
        }
        if let tlsSeconds = timing.tlsSeconds {
            Self.appendTransportSample(tlsSeconds, to: &accumulator.tlsSamples, limit: maxTransportSamplesPerHost)
        }
        if let responseSeconds = timing.responseSeconds {
            Self.appendTransportSample(responseSeconds, to: &accumulator.responseSamples, limit: maxTransportSamplesPerHost)
        }
        if let networkProtocol = timing.networkProtocol,
           !networkProtocol.isEmpty,
           accumulator.protocols.contains(networkProtocol) || accumulator.protocols.count < maxProtocolsPerHost {
            accumulator.protocols.insert(networkProtocol)
        }
        transportRecordOrder &+= 1
        accumulator.lastRecordedOrder = transportRecordOrder
        transportByHost[key] = accumulator
    }

    public func recordMiningCycle(_ timing: MiningCycleTiming) {
        let key = timing.minerId.isEmpty ? "unknown" : timing.minerId
        var accumulator = miningByMiner[key, default: MiningAccumulator()]
        accumulator.minerLabel = timing.minerLabel
        accumulator.cycleCount += 1
        accumulator.totalSeconds += max(0, timing.totalSeconds)
        accumulator.maxSeconds = max(accumulator.maxSeconds, timing.totalSeconds)
        accumulator.durations.append(max(0, timing.totalSeconds))
        if accumulator.durations.count > maxDurationsPerMiner {
            accumulator.durations.removeFirst(accumulator.durations.count - maxDurationsPerMiner)
        }
        accumulator.lastCycle = timing
        accumulator.slowCycles.append(timing)
        accumulator.slowCycles.sort {
            if $0.totalSeconds == $1.totalSeconds {
                return $0.finishedAt > $1.finishedAt
            }
            return $0.totalSeconds > $1.totalSeconds
        }
        if accumulator.slowCycles.count > maxSlowCyclesPerMiner {
            accumulator.slowCycles.removeLast(accumulator.slowCycles.count - maxSlowCyclesPerMiner)
        }
        miningByMiner[key] = accumulator
    }

    public func recordEventOutboxQueue(
        pendingCount: Int,
        deliveringCount: Int,
        retryableCount: Int,
        terminalCount: Int,
        sentCount: Int,
        oldestUndeliveredAt: Date?,
        observedAt: Date = Date()
    ) {
        eventOutbox.observedAt = observedAt
        eventOutbox.pendingCount = max(0, pendingCount)
        eventOutbox.deliveringCount = max(0, deliveringCount)
        eventOutbox.retryableCount = max(0, retryableCount)
        eventOutbox.terminalCount = max(0, terminalCount)
        eventOutbox.sentCount = max(0, sentCount)
        eventOutbox.oldestUndeliveredAgeSeconds = oldestUndeliveredAt.map {
            max(0, observedAt.timeIntervalSince($0))
        }
    }

    public func recordEventOutboxDelivery(
        networkSeconds: TimeInterval,
        queuedAt: Date,
        outcome: EventOutboxDeliveryOutcome,
        finishedAt: Date = Date()
    ) {
        let networkDuration = max(0, networkSeconds)
        let endToEndDuration = max(0, finishedAt.timeIntervalSince(queuedAt))
        eventOutbox.deliveryAttemptCount += 1
        switch outcome {
        case .succeeded:
            eventOutbox.successfulDeliveryCount += 1
        case .retryableFailure:
            eventOutbox.retryableFailureCount += 1
        case .terminalFailure:
            eventOutbox.terminalFailureCount += 1
        }
        eventOutbox.totalNetworkSeconds += networkDuration
        eventOutbox.maxNetworkSeconds = max(eventOutbox.maxNetworkSeconds, networkDuration)
        eventOutbox.totalEndToEndSeconds += endToEndDuration
        eventOutbox.maxEndToEndSeconds = max(eventOutbox.maxEndToEndSeconds, endToEndDuration)
    }

    public func totalRequestCount() -> Int {
        requestsByOperation.values.reduce(0) { $0 + $1.requestCount }
    }

    public func snapshot() -> Snapshot {
        let requestOperations = requestsByOperation.map { operation, accumulator in
            RequestOperation(
                operation: operation,
                requestCount: accumulator.requestCount,
                successCount: accumulator.successCount,
                failureCount: accumulator.failureCount,
                retryCount: accumulator.retryCount,
                tokenRefreshCount: accumulator.tokenRefreshCount,
                rateLimitWaitSeconds: accumulator.rateLimitWaitSeconds,
                averageLatencySeconds: accumulator.requestCount == 0 ? 0 : accumulator.totalLatencySeconds / Double(accumulator.requestCount),
                p95LatencySeconds: Self.percentile95(accumulator.latencies),
                maxLatencySeconds: accumulator.maxLatencySeconds,
                lastAt: accumulator.lastAt,
                lastError: accumulator.lastError
            )
        }.sorted {
            if $0.requestCount == $1.requestCount {
                return $0.operation < $1.operation
            }
            return $0.requestCount > $1.requestCount
        }

        let miningCycles = miningByMiner.map { minerId, accumulator in
            MiningCycleSummary(
                minerId: minerId,
                minerLabel: accumulator.minerLabel,
                cycleCount: accumulator.cycleCount,
                averageSeconds: accumulator.cycleCount == 0 ? 0 : accumulator.totalSeconds / Double(accumulator.cycleCount),
                p95Seconds: Self.percentile95(accumulator.durations),
                maxSeconds: accumulator.maxSeconds,
                lastCycle: accumulator.lastCycle ?? MiningCycleTiming(
                    minerId: minerId,
                    minerLabel: accumulator.minerLabel,
                    startedAt: .distantPast,
                    finishedAt: .distantPast,
                    outcome: "unknown",
                    totalSeconds: 0,
                    campaignFetchSeconds: 0,
                    claimCheckSeconds: 0,
                    channelSelectionSeconds: 0,
                    watchStartupSeconds: 0,
                    candidateCount: 0
                ),
                slowCycles: accumulator.slowCycles
            )
        }.sorted {
            if $0.lastCycle.finishedAt == $1.lastCycle.finishedAt {
                return $0.minerLabel < $1.minerLabel
            }
            return $0.lastCycle.finishedAt > $1.lastCycle.finishedAt
        }

        let transportHosts = transportByHost.map { host, accumulator in
            TransportHost(
                host: host,
                requestCount: accumulator.requestCount,
                reusedConnectionCount: accumulator.reusedConnectionCount,
                averageTaskSeconds: accumulator.requestCount == 0 ? 0 : accumulator.totalTaskSeconds / Double(accumulator.requestCount),
                averageDNSSeconds: Self.average(accumulator.dnsSamples),
                averageConnectSeconds: Self.average(accumulator.connectSamples),
                averageTLSSeconds: Self.average(accumulator.tlsSamples),
                averageResponseSeconds: Self.average(accumulator.responseSamples),
                protocols: accumulator.protocols.sorted()
            )
        }.sorted { $0.host < $1.host }

        let outboxSummary = eventOutbox.observedAt.map { observedAt in
            EventOutboxSummary(
                observedAt: observedAt,
                pendingCount: eventOutbox.pendingCount,
                deliveringCount: eventOutbox.deliveringCount,
                retryableCount: eventOutbox.retryableCount,
                terminalCount: eventOutbox.terminalCount,
                sentCount: eventOutbox.sentCount,
                oldestUndeliveredAgeSeconds: eventOutbox.oldestUndeliveredAgeSeconds,
                deliveryAttemptCount: eventOutbox.deliveryAttemptCount,
                successfulDeliveryCount: eventOutbox.successfulDeliveryCount,
                retryableFailureCount: eventOutbox.retryableFailureCount,
                terminalFailureCount: eventOutbox.terminalFailureCount,
                averageNetworkSeconds: eventOutbox.deliveryAttemptCount == 0
                    ? 0
                    : eventOutbox.totalNetworkSeconds / Double(eventOutbox.deliveryAttemptCount),
                maxNetworkSeconds: eventOutbox.maxNetworkSeconds,
                averageEndToEndSeconds: eventOutbox.deliveryAttemptCount == 0
                    ? 0
                    : eventOutbox.totalEndToEndSeconds / Double(eventOutbox.deliveryAttemptCount),
                maxEndToEndSeconds: eventOutbox.maxEndToEndSeconds
            )
        }

        return Snapshot(
            generatedAt: Date(),
            requestOperations: requestOperations,
            slowRequests: slowRequests,
            miningCycles: miningCycles,
            transportHosts: transportHosts,
            eventOutbox: outboxSummary
        )
    }

    private static func percentile95(_ values: [TimeInterval]) -> TimeInterval {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        return sorted[max(0, index)]
    }

    private static func average(_ values: [TimeInterval]) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private static func appendTransportSample(
        _ value: TimeInterval,
        to samples: inout [TimeInterval],
        limit: Int
    ) {
        samples.append(value)
        if samples.count > limit {
            samples.removeFirst(samples.count - limit)
        }
    }
}
