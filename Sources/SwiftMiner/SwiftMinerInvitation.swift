import Foundation

/// The native share-sheet content for one temporary friend setup session.
///
/// The device code is carried inside the URL fragment so it is decoded by the
/// SwiftMiner setup page without being sent to the website host or exposed in
/// the human-readable share copy.
struct SwiftMinerInvitation: Equatable, Sendable {
    let inviterDisplayName: String
    let invitationURL: URL
    let expiresAt: Date

    init(inviterName: String, deviceCode: String, expiresAt: Date) {
        let inviterDisplayName = Self.displayName(for: inviterName)
        let expiresAtSeconds = Int(expiresAt.timeIntervalSince1970)
        let payload = [
            "v1",
            String(expiresAtSeconds),
            Self.base64URLString(deviceCode),
            Self.base64URLString(inviterDisplayName)
        ].joined(separator: ".")

        let setupURL = URL(string: "https://swiftminer.app/setup/")!
        var components = URLComponents(url: setupURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "from", value: inviterDisplayName.trimmingCharacters(in: CharacterSet(charactersIn: "@")))
        ]
        components.fragment = "invitation=\(payload)"

        self.inviterDisplayName = inviterDisplayName
        self.invitationURL = components.url ?? setupURL
        self.expiresAt = expiresAt
    }

    var subject: String {
        "\(inviterDisplayName) invited you to SwiftMiner"
    }

    /// Context passed through ShareLink's native `message` channel. The URL is
    /// shared as the primary item, so it is not repeated here.
    var plainText: String {
        """
        \(inviterDisplayName) has invited you to connect your Twitch account to SwiftMiner.

        You'll connect your Twitch account directly. Your credentials are never shared with the person who invited you.

        This invitation expires in 30 minutes.
        """
    }

    private static func displayName(for inviterName: String) -> String {
        let trimmedName = inviterName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return "A friend" }
        return trimmedName.hasPrefix("@") ? trimmedName : "@\(trimmedName)"
    }

    private static func base64URLString(_ value: String) -> String {
        Data(value.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
