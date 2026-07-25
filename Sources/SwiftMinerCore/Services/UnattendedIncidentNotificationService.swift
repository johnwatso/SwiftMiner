import Foundation
import UserNotifications

public actor UnattendedIncidentNotificationService {
    public static let categoryIdentifier = "unattended_action_required"

    private let store: UnattendedHealthStore
    private let center: NotificationCenterProtocol
    private let now: @Sendable () -> Date

    public init(
        store: UnattendedHealthStore,
        center: NotificationCenterProtocol = UNUserNotificationCenter.current(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        self.center = center
        self.now = now
    }

    public func deliverPendingNotifications() async {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized else { return }

        let pending = await store.incidentsAwaitingNotification()
        for item in pending where Self.shouldNotify(for: item.incident.kind) {
            do {
                try await center.add(Self.makeRequest(
                    incident: item.incident,
                    displayName: item.displayName
                ))
                try await store.record(.notificationSent(
                    minerID: item.incident.minerID,
                    kind: item.incident.kind,
                    at: now()
                ))
            } catch {
                Logger.notifications.error("Failed to send unattended health notification: \(error.localizedDescription)")
            }
        }
    }

    public static func makeRequest(
        incident: HealthIncident,
        displayName: String
    ) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = title(for: incident.kind)
        content.body = body(for: incident, displayName: displayName)
        content.categoryIdentifier = categoryIdentifier
        content.threadIdentifier = "unattended-health-\(incident.minerID)"
        content.userInfo = [
            "incidentID": incident.id,
            "minerID": incident.minerID,
            "kind": incident.kind.rawValue
        ]
        if incident.severity == .critical {
            content.sound = .default
        }

        return UNNotificationRequest(
            identifier: "swiftminer-health-\(incident.id)",
            content: content,
            trigger: nil
        )
    }

    private static func shouldNotify(for kind: HealthIncident.Kind) -> Bool {
        switch kind {
        case .authenticationExpired,
             .recoveryExhausted,
             .progressStalled,
             .webDashboardUnavailable,
             .automaticUpdateFailed:
            return true
        // Not-earning is surfaced in the app and the diagnostic report but does not notify.
        // How often watching-without-earning is a genuine fault rather than there being
        // nothing worth mining is still unmeasured — the earning ledger only started
        // producing trustworthy numbers in 1.34.4. Promoting it to a notification is a
        // one-line change once that data shows it is precise enough to be worth waking
        // someone for.
        case .notEarning, .accountLinkRequired, .other:
            return false
        }
    }

    private static func title(for kind: HealthIncident.Kind) -> String {
        switch kind {
        case .authenticationExpired:
            return "Twitch Sign-In Required"
        case .recoveryExhausted:
            return "Automatic Recovery Stopped"
        case .progressStalled:
            return "Mining Progress Stalled"
        case .notEarning:
            return "Watching Without Earning"
        case .webDashboardUnavailable:
            return "Dashboard Unavailable"
        case .automaticUpdateFailed:
            return "Automatic Update Failed"
        case .accountLinkRequired:
            return "Account Link Required"
        case .other:
            return "SwiftMiner Needs Attention"
        }
    }

    private static func body(
        for incident: HealthIncident,
        displayName: String
    ) -> String {
        let action = incident.recommendedAction.map { " \($0)." } ?? ""
        return "\(displayName): \(incident.summary).\(action)"
    }
}
