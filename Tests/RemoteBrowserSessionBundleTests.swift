import XCTest
@testable import SwiftMinerCore

final class RemoteBrowserSessionBundleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func seed(
        capturedAt: Double = 1_700_000_000,
        expiresAt: Double = 1_700_003_600,
        cookieExpiresAt: Double = 1_700_086_000
    ) -> [String: Any] {
        [
            "version": 1,
            "bundle": [
                "version": 1,
                "captured_at": capturedAt,
                "expires_at": expiresAt,
                "user_agent": "Mozilla/5.0 Test Chrome",
                "headers": [
                    "authorization": "OAuth private-oauth_token",
                    "client-id": RemoteBrowserSessionBundle.twitchWebClientID,
                    "client-integrity": "private-integrity-token",
                    "client-version": "web-1",
                    "client-session-id": "session-1",
                    "x-device-id": "x-device-1",
                    "device-id": "device-1",
                    "accept-language": "en-NZ",
                ],
            ],
            "sdk_cookie": [
                "value": "private-sdk-cookie",
                "expires_at": cookieExpiresAt,
            ],
        ]
    }

    private func data(_ value: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }

    private func parse(_ value: Any) throws -> RemoteBrowserSessionBundle {
        try RemoteBrowserSessionBundle.parse(data(value), now: now)
    }

    func testParsesTDMVersionOneSeedAndSeparatesOAuthFromPersistentMaterial() throws {
        let bundle = try parse(seed())

        XCTAssertEqual(bundle.oauthToken, "private-oauth_token")
        XCTAssertEqual(bundle.xDeviceID, "x-device-1")
        XCTAssertEqual(bundle.deviceID, "device-1")
        XCTAssertEqual(bundle.integrityToken, "private-integrity-token")
        XCTAssertEqual(bundle.sdkCookieValue, "private-sdk-cookie")

        let context = try bundle.authenticationContext(generation: 7)
        guard case .browser(let browser) = context else {
            return XCTFail("Expected browser authentication context")
        }
        XCTAssertEqual(browser.schemaVersion, 1)
        XCTAssertEqual(browser.clientID, RemoteBrowserSessionBundle.twitchWebClientID)
        XCTAssertEqual(browser.origin, "https://www.twitch.tv")
        XCTAssertEqual(browser.userAgent, "Mozilla/5.0 Test Chrome")
        XCTAssertEqual(browser.xDeviceID, "x-device-1")
        XCTAssertEqual(browser.deviceID, "device-1")
        XCTAssertEqual(browser.clientSessionID, "session-1")
        XCTAssertEqual(browser.clientVersion, "web-1")
        XCTAssertEqual(browser.acceptLanguage, "en-NZ")
        XCTAssertEqual(browser.integrityToken, "private-integrity-token")
        XCTAssertEqual(browser.capturedAt, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(browser.expiresAt, Date(timeIntervalSince1970: 1_700_003_600))
        XCTAssertEqual(browser.sdkCookieValue, "private-sdk-cookie")
        XCTAssertEqual(browser.cookieExpiresAt, Date(timeIntervalSince1970: 1_700_086_000))
        XCTAssertEqual(browser.generation, 7)

        let persisted = String(decoding: try JSONEncoder().encode(context), as: UTF8.self)
        XCTAssertFalse(persisted.contains("private-oauth_token"))
        XCTAssertFalse(persisted.lowercased().contains("authorization"))
    }

    func testDescriptionNeverPrintsPrivateValues() throws {
        let bundle = try parse(seed())
        var dumped = ""
        dump(bundle, to: &dumped)
        let descriptions = [String(describing: bundle), String(reflecting: bundle), dumped]

        for description in descriptions {
            XCTAssertTrue(description.contains("<redacted>"))
            XCTAssertFalse(description.contains("private-oauth"))
            XCTAssertFalse(description.contains("private-integrity"))
            XCTAssertFalse(description.contains("private-sdk"))
        }
    }

    func testRejectsUnknownEnvelopeAndSessionFields() throws {
        var outer = seed()
        outer["destination"] = "https://evil.test"
        XCTAssertThrowsError(try parse(outer)) { error in
            XCTAssertEqual(error as? RemoteBrowserSessionBundleError, .invalidFormat)
        }

        var inner = seed()
        var session = inner["bundle"] as! [String: Any]
        session["cookie"] = "private"
        inner["bundle"] = session
        XCTAssertThrowsError(try parse(inner)) { error in
            XCTAssertEqual(error as? RemoteBrowserSessionBundleError, .invalidFormat)
        }
    }

    func testRejectsUnsupportedOrNonIntegerVersions() throws {
        var unsupported = seed()
        unsupported["version"] = 2
        XCTAssertThrowsError(try parse(unsupported)) { error in
            XCTAssertEqual(error as? RemoteBrowserSessionBundleError, .unsupportedVersion)
        }

        let floatingVersion = Data("""
        {"version":1.0,"bundle":{},"sdk_cookie":{}}
        """.utf8)
        XCTAssertThrowsError(try RemoteBrowserSessionBundle.parse(floatingVersion, now: now)) { error in
            XCTAssertEqual(error as? RemoteBrowserSessionBundleError, .invalidFormat)
        }

        var booleanVersion = seed()
        booleanVersion["version"] = true
        XCTAssertThrowsError(try parse(booleanVersion)) { error in
            XCTAssertEqual(error as? RemoteBrowserSessionBundleError, .invalidFormat)
        }
    }

    func testAcceptsOnlyTheFixedWebClientAndAllowlistedHeaders() throws {
        var wrongClient = seed()
        mutateHeaders(&wrongClient) { $0["client-id"] = "another-client" }
        XCTAssertThrowsError(try parse(wrongClient)) { error in
            XCTAssertEqual(error as? RemoteBrowserSessionBundleError, .invalidHeaders)
        }

        var cookieHeader = seed()
        mutateHeaders(&cookieHeader) { $0["cookie"] = "auth-token=must-not-pass" }
        XCTAssertThrowsError(try parse(cookieHeader)) { error in
            XCTAssertEqual(error as? RemoteBrowserSessionBundleError, .invalidHeaders)
        }

        var bearer = seed()
        mutateHeaders(&bearer) { $0["authorization"] = "Bearer private-oauth_token" }
        XCTAssertThrowsError(try parse(bearer)) { error in
            XCTAssertEqual(error as? RemoteBrowserSessionBundleError, .invalidHeaders)
        }
    }

    func testRequiresAtLeastOneDeviceHeaderButPreservesBothWhenPresent() throws {
        var noDevice = seed()
        mutateHeaders(&noDevice) {
            $0.removeValue(forKey: "x-device-id")
            $0.removeValue(forKey: "device-id")
        }
        XCTAssertThrowsError(try parse(noDevice)) { error in
            XCTAssertEqual(error as? RemoteBrowserSessionBundleError, .invalidHeaders)
        }

        var legacyDeviceOnly = seed()
        mutateHeaders(&legacyDeviceOnly) { $0.removeValue(forKey: "x-device-id") }
        let parsed = try parse(legacyDeviceOnly)
        XCTAssertNil(parsed.xDeviceID)
        XCTAssertEqual(parsed.deviceID, "device-1")
    }

    func testRejectsCRLFControlsAndNonASCIIInHeaderMaterial() throws {
        for invalidAuthorization in [
            "OAuth token\r\nCookie: injected",
            "OAuth token\u{7f}",
            "OAuth töken",
        ] {
            var candidate = seed()
            mutateHeaders(&candidate) { $0["authorization"] = invalidAuthorization }
            XCTAssertThrowsError(try parse(candidate))
        }

        var userAgent = seed()
        var session = userAgent["bundle"] as! [String: Any]
        session["user_agent"] = "Chrome\nInjected: true"
        userAgent["bundle"] = session
        XCTAssertThrowsError(try parse(userAgent)) { error in
            XCTAssertEqual(error as? RemoteBrowserSessionBundleError, .invalidHeaders)
        }
    }

    func testCookieContractCannotSelectAnotherCookieOrCarryCookieSyntax() throws {
        for invalidValue in [
            "private; other=value",
            "private\r\nInjected: true",
            "private cookie",
            "private\\cookie",
            "",
        ] {
            var candidate = seed()
            candidate["sdk_cookie"] = [
                "value": invalidValue,
                "expires_at": 1_700_086_000,
            ]
            XCTAssertThrowsError(try parse(candidate)) { error in
                XCTAssertEqual(error as? RemoteBrowserSessionBundleError, .invalidSDKCookie)
            }
        }

        var namedCookie = seed()
        namedCookie["sdk_cookie"] = [
            "name": "another-cookie",
            "value": "private-sdk-cookie",
            "expires_at": 1_700_086_000,
        ]
        XCTAssertThrowsError(try parse(namedCookie)) { error in
            XCTAssertEqual(error as? RemoteBrowserSessionBundleError, .invalidFormat)
        }

        var multipleCookies = seed()
        multipleCookies["sdk_cookie"] = [
            ["value": "one", "expires_at": 1_700_086_000],
            ["value": "two", "expires_at": 1_700_086_000],
        ]
        XCTAssertThrowsError(try parse(multipleCookies)) { error in
            XCTAssertEqual(error as? RemoteBrowserSessionBundleError, .invalidFormat)
        }
    }

    func testStructuralParseAllowsExpiredIntegrityForRenewalButFreshChecksAreExplicit() throws {
        let bundle = try parse(seed(
            capturedAt: 1_699_996_399,
            expiresAt: 1_699_999_999
        ))

        XCTAssertNoThrow(try bundle.requireFreshSDKCookie(at: now))
        XCTAssertThrowsError(try bundle.requireFresh(at: now)) { error in
            XCTAssertEqual(error as? RemoteBrowserSessionBundleError, .integrityExpired)
        }

        let expiredCookie = try parse(seed(cookieExpiresAt: now.timeIntervalSince1970))
        XCTAssertThrowsError(try expiredCookie.requireFreshSDKCookie(at: now)) { error in
            XCTAssertEqual(error as? RemoteBrowserSessionBundleError, .sdkCookieExpired)
        }
    }

    func testRejectsImplausibleTimestamps() throws {
        for candidate in [
            seed(capturedAt: now.timeIntervalSince1970 + 61),
            seed(capturedAt: 0),
            seed(expiresAt: now.timeIntervalSince1970),
            seed(expiresAt: now.timeIntervalSince1970 + 86_401),
        ] {
            XCTAssertThrowsError(try parse(candidate)) { error in
                XCTAssertEqual(error as? RemoteBrowserSessionBundleError, .invalidTimestamp)
            }
        }

        XCTAssertThrowsError(try parse(seed(cookieExpiresAt: -1))) { error in
            XCTAssertEqual(error as? RemoteBrowserSessionBundleError, .invalidSDKCookie)
        }
    }

    func testRejectsPayloadOver64KiBBeforeParsing() {
        let oversized = Data(repeating: 0x20, count: RemoteBrowserSessionBundle.maximumPayloadBytes + 1)
        XCTAssertThrowsError(try RemoteBrowserSessionBundle.parse(oversized, now: now)) { error in
            XCTAssertEqual(error as? RemoteBrowserSessionBundleError, .payloadTooLarge)
        }
    }

    func testGenerationMustBePositive() throws {
        let bundle = try parse(seed())
        XCTAssertThrowsError(try bundle.authenticationContext(generation: 0)) { error in
            XCTAssertEqual(error as? RemoteBrowserSessionBundleError, .invalidGeneration)
        }
    }

    private func mutateHeaders(
        _ root: inout [String: Any],
        mutation: (inout [String: Any]) -> Void
    ) {
        var session = root["bundle"] as! [String: Any]
        var headers = session["headers"] as! [String: Any]
        mutation(&headers)
        session["headers"] = headers
        root["bundle"] = session
    }
}
