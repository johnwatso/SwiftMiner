import MetricKit
import OSLog

/// Receives macOS-delivered performance and diagnostic reports for unattended installations.
///
/// MetricKit's reports are intentionally supplementary: the mining engine still uses immediate
/// heartbeats and request diagnostics for recovery, while MetricKit exposes system-observed hangs,
/// excessive energy use, and crashes that are otherwise difficult to reproduce remotely.
final class AppMetrics: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = AppMetrics()

    private static let logger = Logger(subsystem: "com.swiftminer", category: "MetricKit")
    private var isSubscribed = false

    func start() {
        guard !isSubscribed else { return }
        MXMetricManager.shared.add(self)
        isSubscribed = true
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        guard !payloads.isEmpty else { return }
        Self.logger.notice("MetricKit delivered \(payloads.count, privacy: .public) daily performance report(s)")
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        guard !payloads.isEmpty else { return }
        Self.logger.error("MetricKit delivered \(payloads.count, privacy: .public) diagnostic report(s); export logs for support analysis")
    }
}
