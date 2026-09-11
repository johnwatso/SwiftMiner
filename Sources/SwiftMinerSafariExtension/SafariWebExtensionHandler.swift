import Foundation
import SafariServices

/// Receives an already-scrubbed operation/hash pair from the extension's
/// background worker and places it in the shared candidate store. The handler
/// never receives or persists request headers, cookies, variables or responses.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private static let suiteName = "group.com.swiftminer.shared"
    private static let debugNotificationName = Notification.Name(
        "com.swiftminer.debug.query-hash-candidate"
    )
    private static let automaticDiscoveryKey = "TwitchQueryHash.automaticDiscovery"
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
        let accepted = storeCandidate(from: message)

        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: ["accepted": accepted]]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }

    private func storeCandidate(from message: [String: Any]?) -> Bool {
        guard let message,
              message["type"] as? String == "queryHashCandidate",
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
        guard let defaults = Self.sharedDefaults,
              defaults.bool(forKey: Self.automaticDiscoveryKey) else {
            return false
        }
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
