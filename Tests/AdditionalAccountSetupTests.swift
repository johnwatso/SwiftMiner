import XCTest
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
        XCTAssertTrue(invitation.plainText.contains("@operator has invited you to connect your Twitch account to SwiftMiner"))
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
