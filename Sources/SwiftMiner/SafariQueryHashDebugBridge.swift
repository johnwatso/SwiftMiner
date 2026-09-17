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
    static let sessionNotificationName = Notification.Name(
        "com.swiftminer.debug.query-hash-session"
    )

    private var candidateObserver: NSObjectProtocol?
    private var sessionObserver: NSObjectProtocol?

    init() {
        candidateObserver = DistributedNotificationCenter.default().addObserver(
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

        sessionObserver = DistributedNotificationCenter.default().addObserver(
            forName: Self.sessionNotificationName,
            object: nil,
            queue: nil
        ) { notification in
            guard let payload = notification.object as? String else { return }
            let parts = payload.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return }
            TwitchQueryHashStore.standard.recordSessionResult(
                succeeded: Self.queries(from: parts[0]),
                failed: Self.queries(from: parts[1])
            )
        }
    }

    deinit {
        if let candidateObserver {
            DistributedNotificationCenter.default().removeObserver(candidateObserver)
        }
        if let sessionObserver {
            DistributedNotificationCenter.default().removeObserver(sessionObserver)
        }
    }

    private static func queries(from value: Substring) -> [GQLQuery] {
        value.split(separator: ",").compactMap { GQLQuery(rawValue: String($0)) }
    }
}
#endif
