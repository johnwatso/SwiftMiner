import AppKit
import Foundation

/// The native share-sheet content for one temporary friend setup session.
///
/// The device code is carried inside the URL fragment so it is decoded by the
/// SwiftMiner setup page without being sent to the website host or exposed in
/// the human-readable share copy.
struct SwiftMinerInvitation: Equatable, Sendable, Identifiable {
    /// Each regenerated invitation carries a fresh device code, so the URL
    /// identifies one invitation for SwiftUI presentation.
    var id: URL { invitationURL }

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

    /// The email subject line. Mail fills its Subject field from the sharing
    /// service's `subject`; destinations without a subject ignore it.
    var subject: String {
        "\(inviterDisplayName) invited you to SwiftMiner"
    }

    var headline: String { "You've been invited to SwiftMiner" }

    var invitationLine: String {
        "\(inviterDisplayName) has invited you to connect your Twitch account."
    }

    var reassurance: String {
        "You'll sign in directly with Twitch. Your Twitch credentials are never shared with the person who invited you."
    }

    var expiryNote: String { "This invitation expires in 30 minutes." }

    var linkIntroduction: String { "Open your invitation:" }

    /// The formatted invitation body handed to the share sheet.
    ///
    /// Mail composes this as the message body and appends the invitation URL,
    /// which is shared alongside it as its own item, so the copy deliberately
    /// ends on the line that introduces that link.
    var richBody: NSAttributedString {
        let body = NSMutableAttributedString()

        func append(_ text: String, _ attributes: [NSAttributedString.Key: Any]) {
            body.append(NSAttributedString(string: text, attributes: attributes))
        }

        let headlineAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 17)
        ]
        let bodyAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13)
        ]
        let footnoteAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        append(headline + "\n", headlineAttributes)
        append(invitationLine + "\n\n", bodyAttributes)
        append(reassurance + "\n", footnoteAttributes)
        append(expiryNote + "\n\n", footnoteAttributes)
        append(linkIntroduction + "\n", bodyAttributes)

        return body
    }

    /// The same copy without formatting, for destinations and tests that only
    /// need the words.
    var plainText: String { richBody.string }

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
