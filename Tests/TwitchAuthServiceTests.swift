import XCTest
@testable import SwiftMinerCore

// MARK: - TwitchAuthService Tests

/// Tests for TwitchAuthService covering auth state, token validation logic,
/// refresh deduplication, logout, and response model decoding.
@MainActor
final class TwitchAuthServiceTests: XCTestCase {

    var service: TwitchAuthService!
    var tokenStore: TestTokenStore!
    var mockSession: URLSession!

    func testRejectedSavedSessionErrorNamesTheRejectedOperation() {
        let error = TwitchAPIClient.rejectedSavedSessionError(operation: "ViewerDropCampaigns")
        guard case .authenticationFailed(let detail) = error else {
            return XCTFail("Expected an authentication failure")
        }
        XCTAssertTrue(detail.contains("ViewerDropCampaigns"))
        XCTAssertTrue(detail.contains("HTTP 401"))
    }

    override func setUp() async throws {
        try await super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        mockSession = URLSession(configuration: configuration)
        tokenStore = TestTokenStore()
        service = TwitchAuthService(
            clientId: "test_client_id",
            tokenStore: tokenStore,
            urlSession: mockSession
        )
    }

    override func tearDown() async throws {
        MockURLProtocol.stubResponseData = nil
        MockURLProtocol.stubError = nil
        MockURLProtocol.lastRequest = nil
        MockURLProtocol.requestHandler = nil
        service = nil
        tokenStore = nil
        mockSession.invalidateAndCancel()
        mockSession = nil
        try await super.tearDown()
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

    // MARK: - Refresh outcome classification

    func testARefusedGrantSendsUsToRevalidateRatherThanRetiringTheAccount() {
        // Twitch refusing the grant retires the refresh token, not the access token.
        // A web-client login (expires_in = 0, invented expiry) hits this on every launch
        // once the invented window lapses, while mining continues perfectly.
        XCTAssertEqual(TwitchAuthService.refreshOutcome(forStatusCode: 400), .grantRefused)
        XCTAssertEqual(TwitchAuthService.refreshOutcome(forStatusCode: 401), .grantRefused)
    }

    func testTransientTwitchFailuresKeepTheExistingToken() {
        // Every one of these used to map to tokenExpired, which asked the user to
        // re-authenticate over a rate limit or a bad minute at Twitch.
        for status in [403, 429, 500, 502, 503, 504] {
            XCTAssertEqual(
                TwitchAuthService.refreshOutcome(forStatusCode: status),
                .transientFailure,
                "HTTP \(status) says nothing about whether the token is still good"
            )
        }
    }

    func testSuccessfulRefreshProceeds() {
        XCTAssertEqual(TwitchAuthService.refreshOutcome(forStatusCode: 200), .proceed)
    }

    func testUnverifiedTokenWindowIsShorterThanAConfirmedOne() {
        // A token Twitch would not confirm gets a window only long enough to stop it
        // re-probing on every launch — it must never claim the confirmed lifetime.
        XCTAssertLessThan(
            TwitchAuthService.unverifiedTokenRecheckInterval,
            TwitchAuthService.assumedTokenLifetime
        )
        XCTAssertGreaterThan(TwitchAuthService.unverifiedTokenRecheckInterval, 300)
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

    // MARK: - Device authorisation scopes

    func testDeviceAuthorisationRequestsNoScopesByDefault() {
        XCTAssertEqual(
            TwitchAuthService.deviceAuthorizationScopes(includeFollowedChannels: false),
            []
        )
    }

    func testDeviceAuthorisationRequestsOnlyFollowScopeWhenOptedIn() {
        XCTAssertEqual(
            TwitchAuthService.deviceAuthorizationScopes(includeFollowedChannels: true),
            ["user:read:follows"]
        )
    }

    // MARK: - Client ID

    func testAndroidClientIdConstant() {
        // The Android client ID is critical — must match TDM's ANDROID_APP client ID exactly
        XCTAssertEqual(TwitchAuthService.twitchAndroidClientId, "kd1unb4b3q4t58fwlpcbzcbnm76a8fp",
                       "Android client ID must match TDM's ANDROID_APP exactly (kd1unb4b3q4t58fwlpcbzcbnm76a8fp)")
    }

    // MARK: - Network behavior

    func testInitiateDeviceFlowBuildsExpectedRequestAndDecodesResponse() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            let data = #"{"device_code":"device_abc","expires_in":1800,"interval":5,"user_code":"ABCD-1234","verification_uri":"https://www.twitch.tv/activate"}"#.data(using: .utf8)!
            return (response, data)
        }

        let response = try await service.initiateDeviceFlow(includeFollowedChannels: true)
        let request = try XCTUnwrap(MockURLProtocol.lastRequest)
        let body = String(data: try XCTUnwrap(request.httpBody), encoding: .utf8) ?? ""

        XCTAssertEqual(response.deviceCode, "device_abc")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://www.twitch.tv")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Device-Id")?.count, 32)
        XCTAssertFalse(request.value(forHTTPHeaderField: "User-Agent")?.isEmpty ?? true)
        XCTAssertTrue(body.contains("client_id=test_client_id"))
        XCTAssertTrue(body.contains("scopes=user:read:follows"))
    }

    func testInitiateDeviceFlowPropagatesAPIError() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 400, httpVersion: nil, headerFields: nil
            )!
            return (response, #"{"message":"invalid client"}"#.data(using: .utf8)!)
        }

        do {
            _ = try await service.initiateDeviceFlow()
            XCTFail("Expected the device endpoint failure to propagate")
        } catch let TwitchMinerError.apiError(statusCode, message) {
            XCTAssertEqual(statusCode, 400)
            XCTAssertTrue(message.contains("invalid client"))
        } catch {
            XCTFail("Expected apiError, got \(error)")
        }
    }

    func testValidateTokenUsesOAuthHeaderAndReturnsIdentity() async throws {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            let data = #"{"client_id":"test_client_id","login":"miner","scopes":[],"user_id":"u1","expires_in":3600}"#.data(using: .utf8)!
            return (response, data)
        }

        let identity = try await service.validateToken("secret-token")

        XCTAssertEqual(identity.userId, "u1")
        XCTAssertEqual(identity.login, "miner")
        XCTAssertEqual(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization"), "OAuth secret-token")
    }

    func testValidateTokenMapsUnauthorizedResponseToAuthenticationFailure() async {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil
            )!
            return (response, #"{"message":"invalid access token"}"#.data(using: .utf8)!)
        }

        do {
            _ = try await service.validateToken("expired-token")
            XCTFail("Expected token rejection")
        } catch let TwitchMinerError.authenticationFailed(message) {
            XCTAssertTrue(message.contains("rejected"))
        } catch {
            XCTFail("Expected authenticationFailed, got \(error)")
        }
    }

    func testPollForTokenContinuesAfterPendingThenPersistsSuccess() async throws {
        let requests = LockedRequestCounter()
        MockURLProtocol.requestHandler = { request in
            let response: (Int) -> HTTPURLResponse = { status in
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            }
            if request.url?.path == "/oauth2/validate" {
                let data = #"{"client_id":"test_client_id","login":"miner","scopes":[],"user_id":"u1","expires_in":3600}"#.data(using: .utf8)!
                return (response(200), data)
            }
            if requests.increment() == 1 {
                return (response(400), #"{"message":"authorization_pending"}"#.data(using: .utf8)!)
            }
            let data = #"{"access_token":"new-token","refresh_token":"new-refresh","expires_in":3600,"scope":[],"token_type":"bearer"}"#.data(using: .utf8)!
            return (response(200), data)
        }

        let account = try await service.pollForToken(deviceCode: "device-code", interval: 0)

        XCTAssertEqual(account.accessToken, "new-token")
        XCTAssertEqual(requests.value, 2)
        let savedAccount = try await tokenStore.loadAccount(twitchUserId: "u1")
        XCTAssertEqual(savedAccount, account)
    }

    func testConcurrentExpiredTokenRefreshesShareOneRequestAndFireCallback() async throws {
        let requests = LockedRequestCounter()
        let refreshedToken = LockedStringRecorder()
        await service.setCurrentAccount(makeAccount(expiresIn: -1))
        await service.setTokenRefreshHandler { token in
            refreshedToken.record(token)
        }
        MockURLProtocol.requestHandler = { request in
            _ = requests.increment()
            Thread.sleep(forTimeInterval: 0.05)
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            let data = #"{"access_token":"refreshed-token","refresh_token":"refreshed-refresh","expires_in":3600,"scope":[],"token_type":"bearer"}"#.data(using: .utf8)!
            return (response, data)
        }

        let authService = try XCTUnwrap(service)
        async let first = authService.refreshTokenIfNeeded()
        async let second = authService.refreshTokenIfNeeded()
        let tokens = try await [first, second]

        XCTAssertEqual(tokens, ["refreshed-token", "refreshed-token"])
        XCTAssertEqual(requests.value, 1)
        XCTAssertEqual(refreshedToken.value, "refreshed-token")
    }

    // MARK: - Re-authentication

    /// Signing in again must not cost the account its Discord owner: the app
    /// resolves profile pictures and the Discord picture source through
    /// `ownerDiscordId`, so losing it silently unlinks the miner.
    func testReAuthenticationKeepsTheStoredDiscordOwnerNicknameAndOperatorFlag() async throws {
        let store = TestTokenStore()
        try await store.save(account: Account(
            id: "user123",
            username: "testuser",
            nickname: "Ruff",
            ownerDiscordId: "412378964087275541",
            accessToken: "old_token",
            refreshToken: "old_refresh",
            tokenExpiry: Date().addingTimeInterval(-60),
            scopes: ["user:read:email"],
            isOperator: true
        ))
        let service = TwitchAuthService(clientId: "test_client_id", tokenStore: store)

        // What a fresh sign-in produces: only what Twitch returned.
        let merged = await service.mergingStoredIdentity(into: makeAccount(
            accessToken: "new_token",
            refreshToken: "new_refresh",
            expiresIn: 3600
        ))

        XCTAssertEqual(merged.ownerDiscordId, "412378964087275541")
        XCTAssertEqual(merged.nickname, "Ruff")
        XCTAssertTrue(merged.isOperator)
        XCTAssertEqual(merged.accessToken, "new_token")
        XCTAssertEqual(merged.refreshToken, "new_refresh")
    }

    /// A first-time sign-in has nothing stored to merge with.
    func testFirstSignInKeepsTheAccountAsAuthenticated() async {
        let service = TwitchAuthService(clientId: "test_client_id", tokenStore: TestTokenStore())
        let fresh = makeAccount(expiresIn: 3600)

        let merged = await service.mergingStoredIdentity(into: fresh)

        XCTAssertNil(merged.ownerDiscordId)
        XCTAssertNil(merged.nickname)
        XCTAssertFalse(merged.isOperator)
        XCTAssertEqual(merged.accessToken, fresh.accessToken)
    }
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

private final class LockedRequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class LockedStringRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedValue: String?

    func record(_ value: String) {
        lock.lock()
        recordedValue = value
        lock.unlock()
    }

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return recordedValue
    }
}
