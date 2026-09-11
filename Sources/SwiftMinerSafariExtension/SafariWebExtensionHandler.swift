import Foundation
import SafariServices

/// Receives an already-scrubbed operation/hash pair from the extension's
/// background worker and places it in the shared candidate store. The handler
/// never receives or persists request headers, cookies, variables or responses.
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private static let suiteName = "group.com.swiftminer.shared"
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
              Self.isValidHash(hash),
              let defaults = Self.sharedDefaults,
              defaults.bool(forKey: Self.automaticDiscoveryKey) else {
            return false
        }

        defaults.set(hash, forKey: "TwitchQueryHash.candidate.\(operation)")
        defaults.set(
            Date().timeIntervalSince1970,
            forKey: "TwitchQueryHash.candidateDate.\(operation)"
        )
        return true
    }

    private static func isValidHash(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }

    /// Local Debug builds deliberately carry no protected App Group entitlement,
    /// so they can be built with Xcode's ad-hoc identity. The unsandboxed test
    /// extension writes into the containing app's preferences domain instead.
    private static var sharedDefaults: UserDefaults? {
        #if DEBUG
        UserDefaults(suiteName: "com.swiftminer.app")
        #else
        UserDefaults(suiteName: suiteName)
        #endif
    }
}
