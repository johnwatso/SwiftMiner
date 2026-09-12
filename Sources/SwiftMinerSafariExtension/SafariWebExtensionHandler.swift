import Foundation
import SafariServices

/// Receives already-scrubbed operation/hash pairs from the extension's background
/// worker during a SwiftMiner update session, plus the summary when that session
/// ends. The handler never receives or persists request headers, cookies,
/// variables or responses.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private static let suiteName = "group.com.swiftminer.shared"
    private static let debugNotificationName = Notification.Name(
        "com.swiftminer.debug.query-hash-candidate"
    )
    private static let debugSessionNotificationName = Notification.Name(
        "com.swiftminer.debug.query-hash-session"
    )
    private static let allowedOperations: Set<String> = [
        "DirectoryGameRedirect",
        "ViewerDropsDashboard",
        "DropCampaignDetails",
        "Inventory",
        "DropsPage_ClaimDropRewards",
        "PlaybackAccessToken",
        "DirectoryPage_Game",
        "VideoPlayerStreamInfoOverlayChannel",
        "DropCurrentSessionContext",
        "DropsHighlightService_AvailableDrops",
        "ChannelPointsContext",
        "ClaimCommunityPoints"
    ]

    func beginRequest(with context: NSExtensionContext) {
        let item = context.inputItems.first as? NSExtensionItem
        let message = item?.userInfo?[SFExtensionMessageKey] as? [String: Any]

        let accepted: Bool
        switch message?["type"] as? String {
        case "queryHashCandidate":
            accepted = storeCandidate(from: message)
        case "queryHashSessionFinished":
            accepted = storeSessionResult(from: message)
        default:
            accepted = false
        }

        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: ["accepted": accepted]]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }

    /// Records how an update session ended so SwiftMiner can report it without having to
    /// infer success from the absence of observations.
    private func storeSessionResult(from message: [String: Any]?) -> Bool {
        guard let message else { return false }
        let succeeded = (message["succeeded"] as? [String] ?? [])
            .filter(Self.allowedOperations.contains)
        let failed = (message["failed"] as? [String] ?? [])
            .filter(Self.allowedOperations.contains)

        #if DEBUG
        DistributedNotificationCenter.default().postNotificationName(
            Self.debugSessionNotificationName,
            object: "\(succeeded.joined(separator: ","))|\(failed.joined(separator: ","))",
            userInfo: nil,
            options: [.deliverImmediately]
        )
        return true
        #else
        guard let defaults = Self.sharedDefaults else { return false }
        defaults.set(succeeded, forKey: "TwitchQueryHash.session.succeeded")
        defaults.set(failed, forKey: "TwitchQueryHash.session.failed")
        defaults.set(Date().timeIntervalSince1970, forKey: "TwitchQueryHash.session.finishedDate")
        return true
        #endif
    }

    private func storeCandidate(from message: [String: Any]?) -> Bool {
        guard let message,
              let operation = message["operationName"] as? String,
              Self.allowedOperations.contains(operation),
              let hash = message["sha256Hash"] as? String,
              Self.isValidHash(hash) else {
            return false
        }

        #if DEBUG
        // Sandboxed local builds cannot use the Release App Group when signed
        // ad hoc. A distributed notification may carry no userInfo from a
        // sandbox, so the two allow-listed values travel in the object string.
        DistributedNotificationCenter.default().postNotificationName(
            Self.debugNotificationName,
            object: "\(operation):\(hash)",
            userInfo: nil,
            options: [.deliverImmediately]
        )
        // The extension cannot synchronously know whether discovery is enabled
        // in the host. Declining keeps the background worker willing to retry.
        return false
        #else
        // No discovery-toggle check: a hash only reaches here inside a session SwiftMiner
        // itself started, so the request to observe has already been made explicitly.
        guard let defaults = Self.sharedDefaults else { return false }
        defaults.set(hash, forKey: "TwitchQueryHash.observed.\(operation)")
        defaults.set(
            Date().timeIntervalSince1970,
            forKey: "TwitchQueryHash.observedDate.\(operation)"
        )
        defaults.set(hash, forKey: "TwitchQueryHash.candidate.\(operation)")
        defaults.set(
            Date().timeIntervalSince1970,
            forKey: "TwitchQueryHash.candidateDate.\(operation)"
        )
        return true
        #endif
    }

    private static func isValidHash(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    private static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }
}
