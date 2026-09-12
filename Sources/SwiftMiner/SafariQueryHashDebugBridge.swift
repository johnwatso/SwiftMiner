#if DEBUG
import Foundation
import SwiftMinerCore

/// Receives query-hash observations from the sandboxed Safari extension in an
/// ad-hoc local build. App Groups require an Apple Development identity, so
/// Release uses the shared container while Debug uses a payload-only local
/// notification and validates it again before touching SwiftMiner's store.
final class SafariQueryHashDebugBridge: @unchecked Sendable {
    static let notificationName = Notification.Name(
        "com.swiftminer.debug.query-hash-candidate"
    )

    private var observer: NSObjectProtocol?

    init() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Self.notificationName,
            object: nil,
            queue: nil
        ) { notification in
            guard let payload = notification.object as? String,
                  let separator = payload.firstIndex(of: ":"),
                  let query = GQLQuery(rawValue: String(payload[..<separator])),
                  TwitchQueryHashStore.isValidHash(
                    String(payload[payload.index(after: separator)...])
                  ) else {
                return
            }

            let hash = String(payload[payload.index(after: separator)...])
            let store = TwitchQueryHashStore.standard
            guard store.automaticDiscoveryEnabled else { return }
            store.recordObservation(hash, for: query)
        }
    }

    deinit {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }
}
#endif
