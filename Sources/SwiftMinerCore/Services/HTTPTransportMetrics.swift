import Foundation

/// Transport timings collected by URLSession below the Twitch operation layer. These explain
/// whether a slow request spent time in DNS, connecting, TLS, or waiting for Twitch to reply.
struct HTTPTransportTiming: Sendable {
    let host: String
    let taskSeconds: TimeInterval
    let dnsSeconds: TimeInterval?
    let connectSeconds: TimeInterval?
    let tlsSeconds: TimeInterval?
    let responseSeconds: TimeInterval?
    let reusedConnection: Bool
    let networkProtocol: String?

    init(
        host: String,
        taskSeconds: TimeInterval,
        dnsSeconds: TimeInterval? = nil,
        connectSeconds: TimeInterval? = nil,
        tlsSeconds: TimeInterval? = nil,
        responseSeconds: TimeInterval? = nil,
        reusedConnection: Bool = false,
        networkProtocol: String? = nil
    ) {
        self.host = host
        self.taskSeconds = max(0, taskSeconds)
        self.dnsSeconds = dnsSeconds.map { max(0, $0) }
        self.connectSeconds = connectSeconds.map { max(0, $0) }
        self.tlsSeconds = tlsSeconds.map { max(0, $0) }
        self.responseSeconds = responseSeconds.map { max(0, $0) }
        self.reusedConnection = reusedConnection
        self.networkProtocol = networkProtocol
    }

    init(task: URLSessionTask, metrics: URLSessionTaskMetrics) {
        let transaction = metrics.transactionMetrics.last
        self.init(
            host: task.currentRequest?.url?.host ?? task.originalRequest?.url?.host ?? "unknown",
            taskSeconds: metrics.taskInterval.duration,
            dnsSeconds: Self.duration(transaction?.domainLookupStartDate, transaction?.domainLookupEndDate),
            connectSeconds: Self.duration(transaction?.connectStartDate, transaction?.connectEndDate),
            tlsSeconds: Self.duration(transaction?.secureConnectionStartDate, transaction?.secureConnectionEndDate),
            responseSeconds: Self.duration(transaction?.requestStartDate, transaction?.responseEndDate),
            reusedConnection: transaction?.isReusedConnection ?? false,
            networkProtocol: transaction?.networkProtocolName
        )
    }

    private static func duration(_ start: Date?, _ end: Date?) -> TimeInterval? {
        guard let start, let end else { return nil }
        return max(0, end.timeIntervalSince(start))
    }
}

/// A URLSession delegate used only for the production Twitch client. Tests that inject their own
/// URLSession keep full control of their transport and simply omit these optional diagnostics.
final class TwitchHTTPTransportMetricsCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        let timing = HTTPTransportTiming(task: task, metrics: metrics)
        Task {
            await PerformanceDiagnostics.shared.recordTransport(timing)
        }
    }
}
