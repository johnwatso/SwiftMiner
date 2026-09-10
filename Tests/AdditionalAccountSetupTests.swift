import AppKit
import XCTest
import SwiftMinerService
@testable import SwiftMiner

@MainActor
final class AdditionalAccountSetupTests: XCTestCase {
    func testFirstAccountStartsExistingAuthenticationFlow() {
        XCTAssertFalse(AdditionalAccountSetup.shouldPresentChoice(
            existingAccountCount: 0,
            isReconnecting: false
        ))
    }

    func testSecondAccountPresentsPurposeChoice() {
        XCTAssertTrue(AdditionalAccountSetup.shouldPresentChoice(
            existingAccountCount: 1,
            isReconnecting: false
        ))
    }

    func testReconnectingAccountNeverPresentsPurposeChoice() {
        XCTAssertFalse(AdditionalAccountSetup.shouldPresentChoice(
            existingAccountCount: 2,
            isReconnecting: true
        ))
    }

    func testInviterUsesSelectedOperator() {
        XCTAssertEqual(AdditionalAccountSetup.inviterName(accounts: [
            (name: "first", isOperator: false),
            (name: "operator", isOperator: true)
        ]), "operator")
    }

    func testInviterFallsBackToFirstAccountWhenNoOperatorIsSelected() {
        XCTAssertEqual(
            AdditionalAccountSetup.inviterName(accounts: [
                (name: "first", isOperator: false),
                (name: "second", isOperator: false)
            ]),
            "first"
        )
    }

    func testInvitationUsesBrandedURLAndCleanNativeShareCopy() throws {
        let invitation = SwiftMinerInvitation(
            inviterName: "operator",
            deviceCode: "ABCD-EFGH",
            expiresAt: Date(timeIntervalSince1970: 2_000)
        )

        XCTAssertEqual(invitation.subject, "@operator invited you to SwiftMiner")
        XCTAssertTrue(invitation.invitationURL.absoluteString.hasPrefix("https://swiftminer.app/setup/?from=operator#invitation=v1."))
        XCTAssertFalse(invitation.invitationURL.absoluteString.contains("ABCD-EFGH"))
        XCTAssertTrue(invitation.plainText.contains("You've been invited to SwiftMiner"))
        XCTAssertTrue(invitation.plainText.contains("@operator has invited you to connect your Twitch account."))
        XCTAssertTrue(invitation.plainText.contains("credentials are never shared"))
        XCTAssertTrue(invitation.plainText.contains("expires in 30 minutes"))
        XCTAssertFalse(invitation.plainText.contains("ABCD-EFGH"))
        XCTAssertFalse(invitation.plainText.contains("twitch.tv/activate"))
        XCTAssertFalse(invitation.plainText.contains("1."))

        let fragment = try XCTUnwrap(URLComponents(url: invitation.invitationURL, resolvingAgainstBaseURL: false)?.fragment)
        let payload = try XCTUnwrap(fragment.removingPrefix("invitation="))
        let parts = payload.split(separator: ".").map(String.init)
        XCTAssertEqual(parts.count, 4)
        XCTAssertEqual(parts[0], "v1")
        XCTAssertEqual(parts[1], "2000")
        XCTAssertEqual(decodeBase64URL(parts[2]), "ABCD-EFGH")
        XCTAssertEqual(decodeBase64URL(parts[3]), "@operator")
    }

    func testPlainTextFallbackStaysCleanWhenInviterAlreadyHasAtSign() {
        let invitation = SwiftMinerInvitation(
            inviterName: "@operator",
            deviceCode: "ABCD-EFGH",
            expiresAt: Date(timeIntervalSince1970: 2_000)
        )

        XCTAssertEqual(invitation.inviterDisplayName, "@operator")
        XCTAssertTrue(invitation.plainText.contains("credentials are never shared"))
        XCTAssertFalse(invitation.plainText.contains("ABCD-EFGH"))
        XCTAssertFalse(invitation.plainText.contains("twitch.tv/activate"))
    }

    func testRichBodyFormatsTheInvitationWithoutLeakingTheDeviceCode() throws {
        let invitation = SwiftMinerInvitation(
            inviterName: "operator",
            deviceCode: "ABCD-EFGH",
            expiresAt: Date(timeIntervalSince1970: 2_000)
        )
        let body = invitation.richBody

        XCTAssertEqual(body.string, invitation.plainText)
        XCTAssertFalse(body.string.contains("ABCD-EFGH"))
        XCTAssertFalse(body.string.contains("twitch.tv/activate"))

        // Mail appends the separately shared URL after the body, so the copy
        // has to end on the line that introduces the link.
        XCTAssertTrue(body.string.hasSuffix(invitation.linkIntroduction + "\n"))
        XCTAssertFalse(body.string.contains(invitation.invitationURL.absoluteString))

        let headlineFont = body.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let footnoteLocation = body.string.distance(
            from: body.string.startIndex,
            to: try XCTUnwrap(body.string.range(of: invitation.reassurance)).lowerBound
        )
        let footnoteFont = body.attribute(.font, at: footnoteLocation, effectiveRange: nil) as? NSFont

        XCTAssertEqual(headlineFont, NSFont.boldSystemFont(ofSize: 17))
        XCTAssertEqual(footnoteFont, NSFont.systemFont(ofSize: 11))
    }

    func testEmailBodyCarriesTheInvitationWithoutLeakingTheDeviceCode() {
        let expiresAt = Date().addingTimeInterval(30 * 60)
        let invitation = SwiftMinerInvitation(
            inviterName: "operator",
            deviceCode: "ABCD-EFGH",
            expiresAt: expiresAt
        )
        let html = InvitationEmailBody.html(for: invitation)

        XCTAssertTrue(html.contains("You&rsquo;ve been invited to SwiftMiner"))
        XCTAssertTrue(html.contains("@operator has invited you to connect your Twitch account."))
        XCTAssertTrue(html.contains("Connect to SwiftMiner"))
        XCTAssertTrue(html.contains(InvitationEmailBody.iconURL))
        XCTAssertTrue(html.contains("This invitation expires in 30 minutes."))
        // The recipient gets a route to the honest explainer, not a summary of it.
        XCTAssertTrue(html.contains(InvitationEmailBody.explainerURL))
        // The button lands on swiftminer.app, not Twitch — say so, or the mail
        // reads like a phishing attempt to anyone who checks where links go.
        XCTAssertTrue(html.contains("This opens swiftminer.app, not Twitch."))

        // The CTA and the fallback line both point at the real invitation.
        let escapedURL = invitation.invitationURL.absoluteString.replacingOccurrences(of: "&", with: "&amp;")
        XCTAssertTrue(html.contains("href=\"\(escapedURL)\""))

        // The device code only ever travels inside the URL fragment.
        XCTAssertFalse(html.contains("ABCD-EFGH"))
        XCTAssertFalse(html.contains("twitch.tv/activate"))
    }

    func testEmailBodyEscapesTheInviterName() {
        let invitation = SwiftMinerInvitation(
            inviterName: "<img src=x onerror=alert(1)>",
            deviceCode: "ABCD-EFGH",
            expiresAt: Date().addingTimeInterval(600)
        )
        let html = InvitationEmailBody.html(for: invitation)

        XCTAssertFalse(html.contains("<img src=x"))
        XCTAssertTrue(html.contains("&lt;img src=x onerror=alert(1)&gt;"))
    }

    func testExpiryLineCountsDownAndReportsExpiry() {
        let now = Date(timeIntervalSince1970: 100_000)
        func invitation(secondsFromNow: TimeInterval) -> SwiftMinerInvitation {
            SwiftMinerInvitation(
                inviterName: "operator",
                deviceCode: "ABCD-EFGH",
                expiresAt: now.addingTimeInterval(secondsFromNow)
            )
        }

        XCTAssertEqual(
            InvitationEmailBody.expiryLine(for: invitation(secondsFromNow: 1_800), now: now),
            "This invitation expires in 30 minutes."
        )
        XCTAssertEqual(
            InvitationEmailBody.expiryLine(for: invitation(secondsFromNow: 30), now: now),
            "This invitation expires in 1 minute."
        )
        XCTAssertEqual(
            InvitationEmailBody.expiryLine(for: invitation(secondsFromNow: -1), now: now),
            "This invitation has expired."
        )
    }

    func testCountdownUsesMinuteSecondFormattingAndStopsAtZero() {
        XCTAssertEqual(AdditionalAccountSetup.countdownText(remainingSeconds: 1_800), "30:00")
        XCTAssertEqual(AdditionalAccountSetup.countdownText(remainingSeconds: 61), "01:01")
        XCTAssertEqual(AdditionalAccountSetup.countdownText(remainingSeconds: 0), "00:00")
        XCTAssertEqual(AdditionalAccountSetup.countdownText(remainingSeconds: -1), "00:00")
    }

    func testCountdownRoundsUpPartialSecondsAndExpiresAtZero() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            AdditionalAccountSetup.remainingSeconds(expiresAt: now.addingTimeInterval(1.1), now: now),
            2
        )
        XCTAssertEqual(
            AdditionalAccountSetup.remainingSeconds(expiresAt: now.addingTimeInterval(-0.1), now: now),
            0
        )
    }

    private func decodeBase64URL(_ value: String) -> String? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count))
    }
}

/// The SwiftBot invitation DM must describe the invitation without naming the
/// Twitch device code or an activation URL.
@MainActor
final class SwiftBotFriendInvitationTests: XCTestCase {
    func testRecipientPickerExcludesDiscordMembersAlreadyInSwiftMiner() {
        let members = [
            SwiftBotDiscordUser(id: "already-linked", displayName: "Linked User"),
            SwiftBotDiscordUser(id: "available", displayName: "Available User")
        ]

        let eligible = SwiftBotInvitationEligibility.eligibleMembers(
            from: members,
            excluding: ["already-linked"]
        )

        XCTAssertEqual(eligible.map(\.id), ["available"])
    }

    func testFriendInvitationDMCarriesOnlyTheSetupLink() async {
        let service = RecordingFriendInvitationService()
        let invitation = SwiftMinerInvitation(
            inviterName: "operator",
            deviceCode: "ABCD-EFGH",
            expiresAt: Date(timeIntervalSince1970: 2_000)
        )

        let sent = await service.sendFriendInvitationDM(
            to: "123456789012345678",
            invitationURL: invitation.invitationURL.absoluteString,
            inviterDisplayName: invitation.inviterDisplayName,
            expiresAt: Date().addingTimeInterval(30 * 60)
        )
        XCTAssertTrue(sent)

        let request = await service.lastRequest
        XCTAssertEqual(request?.messageType, .friendInvitation)
        XCTAssertEqual(request?.debug, false)
        XCTAssertEqual(request?.inviterDisplayName, "@operator")
        XCTAssertEqual(request?.activationExpiresInMinutes, 30)
        XCTAssertNotNil(request?.activationExpiresAt)
        XCTAssertEqual(request?.activationURL, invitation.invitationURL.absoluteString)
        XCTAssertEqual(request?.helpURL, "https://swiftminer.app/help/invited-to-swiftminer/")
        XCTAssertNil(request?.activationCode)
        XCTAssertFalse(request?.activationURL?.contains("twitch.tv") ?? true)
    }

    /// SwiftBot decodes `activation_expires_at` with a plain `try` against
    /// `String`. A numeric date here would fail its decode of the whole payload,
    /// so the DM would vanish rather than merely lose its countdown.
    func testExpiryIsSentAsAnISO8601StringNotANumber() throws {
        let request = SwiftBotDMRequest(
            messageType: .friendInvitation,
            debug: false,
            activationExpiresAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: RestSwiftBotConnectionService.dmEncoder.encode(request)
            ) as? [String: Any]
        )

        let expiry = try XCTUnwrap(json["activation_expires_at"] as? String)
        XCTAssertEqual(expiry, "2027-01-15T08:00:00Z")
    }

    func testFriendInvitationDMEncodesTheInviterForSwiftBot() throws {
        let request = SwiftBotDMRequest(
            messageType: .friendInvitation,
            debug: false,
            activationExpiresInMinutes: 30,
            activationURL: "https://swiftminer.app/setup/",
            inviterDisplayName: "@operator"
        )
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
        )

        XCTAssertEqual(json["message_type"] as? String, "friend_invitation")
        XCTAssertEqual(json["inviter_display_name"] as? String, "@operator")
        XCTAssertEqual(json["activation_expires_in_minutes"] as? Int, 30)
    }
}

private actor RecordingFriendInvitationService: SwiftBotConnectionService {
    private(set) var lastRequest: SwiftBotDMRequest?

    func updateEndpoint(_ urlString: String) async {}
    func checkHealth() async -> SwiftBotConnectionState { .connected }
    func sendTestEvent() async -> Bool { true }
    func fetchDiscordUsers() async -> [SwiftBotDiscordUser] { [] }
    func sendLinkedDM(to discordUserId: String, twitchUsername: String?, priorityGames: [String], portalBase: String?) async -> Bool { true }
    func sendDebugDM(to discordUserId: String, request: SwiftBotDMRequest) async -> Bool { true }

    func sendEventDM(to discordUserId: String, request: SwiftBotDMRequest) async -> Bool {
        lastRequest = request
        return true
    }
}
