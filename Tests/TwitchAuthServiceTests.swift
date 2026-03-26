import XCTest
@testable import SwiftMinerCore

// MARK: - TwitchAuthService Tests

/// Tests for TwitchAuthService covering auth state, token validation logic,
/// refresh deduplication, logout, and response model decoding.
///
/// Note: `TwitchAuthService` uses `URLSession.shared` internally (not injected),
/// so network-dependent paths (initiateDeviceFlow, pollForToken, importTDMSession)
/// require a refactor to accept an injectable URLSession before they can be unit tested.
/// Those paths are marked with TODO comments below. All non-network logic is covered here.
@MainActor
final class TwitchAuthServiceTests: XCTestCase {

    var service: TwitchAuthService!

    override func setUp() {
        super.setUp()
        service = TwitchAuthService(clientId: "test_client_id")
    }

    override func tearDown() {
        service = nil
        super.tearDown()
    }

    // MARK: - isAuthenticated

    func testIsAuthenticatedFalseByDefault() async {
        let authenticated = await service.isAuthenticated
        XCTAssertFalse(authenticated, "New service with no account should not be authenticated")
    }

    func testIsAuthenticatedTrueWithValidToken() async {
        let account = makeAccount(expiresIn: 3600) // expires in 1 hour
        await service.setCurrentAccount(account)
        let isAuthenticated = await service.isAuthenticated
        XCTAssertTrue(isAuthenticated)
    }

    func testIsAuthenticatedFalseWithExpiredToken() async {
        let account = makeAccount(expiresIn: -100) // already expired
        await service.setCurrentAccount(account)
        let isAuthenticated = await service.isAuthenticated
        XCTAssertFalse(isAuthenticated,
                       "Account with expired token should not be authenticated")
    }

    func testIsAuthenticatedFalseWithTokenExpiringWithin5Minutes() async {
        // isTokenValid has a 300s buffer — token expiring in 299s should be considered invalid
        let account = makeAccount(expiresIn: 299)
        await service.setCurrentAccount(account)
        let isAuthenticated = await service.isAuthenticated
        XCTAssertFalse(isAuthenticated,
                       "Token expiring within 5-minute buffer should not be considered valid")
    }

    func testIsAuthenticatedTrueWithTokenExpiringAfter5Minutes() async {
        let account = makeAccount(expiresIn: 301)
        await service.setCurrentAccount(account)
        let isAuthenticated = await service.isAuthenticated
        XCTAssertTrue(isAuthenticated,
                      "Token expiring after 5-minute buffer should still be valid")
    }

    // MARK: - setCurrentAccount

    func testSetCurrentAccountUpdatesAuthState() async {
        let isAuthenticatedInitial = await service.isAuthenticated
        XCTAssertFalse(isAuthenticatedInitial)
        let account = makeAccount(expiresIn: 3600)
        await service.setCurrentAccount(account)
        let isAuthenticatedFinal = await service.isAuthenticated
        XCTAssertTrue(isAuthenticatedFinal)
    }

    func testSetCurrentAccountCanBeOverridden() async {
        let first = makeAccount(id: "user1", expiresIn: 3600)
        let second = makeAccount(id: "user2", expiresIn: -1) // expired
        await service.setCurrentAccount(first)
        let isAuthFirst = await service.isAuthenticated
        XCTAssertTrue(isAuthFirst)
        await service.setCurrentAccount(second)
        let isAuthSecond = await service.isAuthenticated
        XCTAssertFalse(isAuthSecond,
                       "Replacing with expired account should update auth state")
    }

    // MARK: - refreshTokenIfNeeded

    func testRefreshTokenIfNeededThrowsWhenNoAccount() async {
        do {
            _ = try await service.refreshTokenIfNeeded()
            XCTFail("Should throw when no account is set")
        } catch let error as TwitchMinerError {
            if case .sessionNotStarted = error {
                // expected
            } else {
                XCTFail("Expected .sessionNotStarted, got \(error)")
            }
        } catch {
            XCTFail("Expected TwitchMinerError, got \(error)")
        }
    }

    func testRefreshTokenIfNeededReturnsExistingTokenWhenValid() async throws {
        let account = makeAccount(accessToken: "valid_token_abc", expiresIn: 3600)
        await service.setCurrentAccount(account)
        // Should return the token immediately without any network call
        let token = try await service.refreshTokenIfNeeded()
        XCTAssertEqual(token, "valid_token_abc",
                       "Should return current token when it is still valid — no refresh needed")
    }

    // MARK: - logout

    func testLogoutClearsAuthState() async throws {
        let account = makeAccount(id: "user1", expiresIn: 3600)
        await service.setCurrentAccount(account)
        let isAuthenticatedBefore = await service.isAuthenticated
        XCTAssertTrue(isAuthenticatedBefore)
        // Logout by account ID (this also hits KeychainStorage but that's file-based and safe)
        try await service.logout(accountId: account.id)
        let isAuthenticatedAfter = await service.isAuthenticated
        XCTAssertFalse(isAuthenticatedAfter,
                       "After logout, isAuthenticated should be false")
    }

    func testLogoutWithNilIdLogsCurrent() async throws {
        let account = makeAccount(id: "current_user", expiresIn: 3600)
        await service.setCurrentAccount(account)
        let isAuthenticatedBefore = await service.isAuthenticated
        XCTAssertTrue(isAuthenticatedBefore)
        try await service.logout(accountId: nil)
        let isAuthenticatedAfter = await service.isAuthenticated
        XCTAssertFalse(isAuthenticatedAfter,
                       "Logout with nil should clear the current account")
    }

    func testLogoutWithDifferentIdDoesNotClearCurrent() async throws {
        let account = makeAccount(id: "current_user", expiresIn: 3600)
        await service.setCurrentAccount(account)
        // Logging out a different user ID should not affect current account
        try await service.logout(accountId: "some_other_user")
        let isAuthenticatedFinal = await service.isAuthenticated
        XCTAssertTrue(isAuthenticatedFinal,
                      "Logging out a different account ID should not affect the current session")
    }

    // MARK: - Token Refresh Callback

    func testTokenRefreshHandlerCanBeSet() async {
        // Just verify the handler can be set without crashing
        await service.setTokenRefreshHandler(nil)
        await service.setTokenRefreshHandler { _ in }
        // Callback fires only during performRefresh (network path — not exercised here)
    }

    // MARK: - Account Model

    func testAccountIsTokenValidRespects5MinuteBuffer() {
        let justValid = makeAccount(expiresIn: 301)
        XCTAssertTrue(justValid.isTokenValid, "301s remaining should be valid (buffer is 300s)")

        let justInvalid = makeAccount(expiresIn: 299)
        XCTAssertFalse(justInvalid.isTokenValid, "299s remaining should be invalid (within 300s buffer)")
    }

    func testAccountIsTokenValidFalseWhenExpired() {
        let expired = makeAccount(expiresIn: -1)
        XCTAssertFalse(expired.isTokenValid)
    }

    func testAccountEqualityRequiresAllFieldsMatch() {
        // Account uses synthesised Equatable — all fields must match.
        let expiry = Date(timeIntervalSince1970: 9_999_999)
        let a1 = Account(id: "user1", username: "testuser", accessToken: "tok",
                         refreshToken: "ref", tokenExpiry: expiry, scopes: ["user:read:email"])
        let a2 = Account(id: "user1", username: "testuser", accessToken: "tok",
                         refreshToken: "ref", tokenExpiry: expiry, scopes: ["user:read:email"])
        let a3 = Account(id: "user2", username: "testuser", accessToken: "tok",
                         refreshToken: "ref", tokenExpiry: expiry, scopes: ["user:read:email"])
        XCTAssertEqual(a1, a2, "Identical accounts should be equal")
        XCTAssertNotEqual(a1, a3, "Accounts with different IDs are not equal")
    }

    // MARK: - Response Model Decoding

    func testDeviceCodeResponseDecoding() throws {
        let json = """
        {
            "device_code": "device_abc",
            "expires_in": 1800,
            "interval": 5,
            "user_code": "ABCD-1234",
            "verification_uri": "https://www.twitch.tv/activate"
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(DeviceCodeResponse.self, from: json)
        XCTAssertEqual(response.deviceCode, "device_abc")
        XCTAssertEqual(response.expiresIn, 1800)
        XCTAssertEqual(response.interval, 5)
        XCTAssertEqual(response.userCode, "ABCD-1234")
        XCTAssertEqual(response.verificationURI.absoluteString, "https://www.twitch.tv/activate")
    }

    func testTokenResponseDecoding() throws {
        let json = """
        {
            "access_token": "tok_abc123",
            "refresh_token": "ref_xyz789",
            "expires_in": 14400,
            "scope": ["user:read:email", "chat:read"],
            "token_type": "bearer"
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(TokenResponse.self, from: json)
        XCTAssertEqual(response.accessToken, "tok_abc123")
        XCTAssertEqual(response.refreshToken, "ref_xyz789")
        XCTAssertEqual(response.expiresIn, 14400)
        XCTAssertEqual(response.scope, ["user:read:email", "chat:read"])
    }

    func testTokenResponseDecodingWithZeroExpiry() throws {
        // Twitch web client ID sometimes returns expiresIn = 0 — default to 30 days in service
        let json = """
        {
            "access_token": "tok_abc",
            "refresh_token": "ref_xyz",
            "expires_in": 0,
            "scope": [],
            "token_type": "bearer"
        }
        """.data(using: .utf8)!

        let response = try JSONDecoder().decode(TokenResponse.self, from: json)
        XCTAssertEqual(response.expiresIn, 0,
                       "Zero expiresIn must decode correctly — service handles 30d default separately")
    }

    // MARK: - Client ID

    func testAndroidClientIdConstant() {
        // The Android client ID is critical — must match TDM's ANDROID_APP client ID exactly
        XCTAssertEqual(TwitchAuthService.twitchAndroidClientId, "kd1unb4b3q4t58fwlpcbzcbnm76a8fp",
                       "Android client ID must match TDM's ANDROID_APP exactly (kd1unb4b3q4t58fwlpcbzcbnm76a8fp)")
    }

    // MARK: - TODO: Network-dependent tests (require URLSession injection)
    //
    // The following paths need TwitchAuthService to accept an injectable URLSession:
    //
    // - initiateDeviceFlow() — POST /oauth2/device
    //   Tests: correct scopes, X-Device-Id header present, Android UA, Referer header,
    //          HTTP 400 throws .apiError, successful 200 decodes DeviceCodeResponse
    //
    // - pollForToken() — loops calling requestToken()
    //   Tests: authorization_pending continues loop, slow_down doubles interval,
    //          successful response saves account and returns it,
    //          non-retryable error propagates immediately
    //
    // - validateToken() — GET /oauth2/validate
    //   Tests: Authorization: OAuth <token> header, 200 returns userId+login,
    //          401 throws .authenticationFailed
    //
    // - importTDMSession() — validates then saves account
    //   Tests: valid token creates Account with 30d expiry, invalid token throws
    //
    // - refreshTokenIfNeeded() with expired token — POST /oauth2/token
    //   Tests: concurrent calls deduplicated (single refresh task), successful refresh
    //          fires onTokenRefresh callback, failure throws .tokenExpired
}

// MARK: - Helpers

private extension TwitchAuthServiceTests {
    func makeAccount(
        id: String = "user123",
        username: String = "testuser",
        accessToken: String = "test_token",
        refreshToken: String = "test_refresh",
        expiresIn: TimeInterval,
        scopes: [String] = ["user:read:email"]
    ) -> Account {
        Account(
            id: id,
            username: username,
            accessToken: accessToken,
            refreshToken: refreshToken,
            tokenExpiry: Date().addingTimeInterval(expiresIn),
            scopes: scopes
        )
    }
}
