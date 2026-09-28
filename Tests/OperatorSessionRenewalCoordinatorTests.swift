import XCTest
@testable import SwiftMiner
@testable import SwiftMinerCore

@MainActor
final class OperatorSessionRenewalCoordinatorTests: XCTestCase {
    func testScheduleRenewsFiveMinutesBeforeIntegrityExpiry() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let browser = makeBrowser(
            now: now,
            integrityExpiry: now.addingTimeInterval(3_600),
            cookieExpiry: now.addingTimeInterval(7_200)
        )

        XCTAssertEqual(
            OperatorSessionRenewalSchedule.renewalDate(for: browser),
            now.addingTimeInterval(3_300)
        )
    }

    func testScheduleRenewsBeforeCookieBecomesTheLimitingCredential() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let browser = makeBrowser(
            now: now,
            integrityExpiry: now.addingTimeInterval(3_600),
            cookieExpiry: now.addingTimeInterval(1_200)
        )

        XCTAssertEqual(
            OperatorSessionRenewalSchedule.renewalDate(for: browser),
            now.addingTimeInterval(600)
        )
    }

    func testNotDueLeavesTheStoredGenerationUntouched() async throws {
        let now = Date()
        let account = makeAccount(
            browser: makeBrowser(
                now: now,
                integrityExpiry: now.addingTimeInterval(3_600),
                cookieExpiry: now.addingTimeInterval(7_200)
            )
        )
        let store = InMemoryTokenStore(accounts: [account])
        let manager = MinerManager(clientId: "test", tokenStore: store)
        let issuer = StubBrowserIntegrityIssuer(issuance: makeIssuance(now: now))
        let coordinator = OperatorSessionRenewalCoordinator(
            minerManager: manager,
            issuer: issuer,
            validator: StubBrowserIntegrityValidator()
        )

        let outcome = try await coordinator.renewNowIfNeeded(now: now)

        guard case .notDue = outcome else {
            return XCTFail("Expected a scheduled renewal, got \(outcome)")
        }
        XCTAssertEqual(issuer.callCount, 0)
        let stored = await store.loadAccount(twitchUserId: account.id)
        guard case .browser(let browser) = stored?.authenticationContext else {
            return XCTFail("Expected browser context")
        }
        XCTAssertEqual(browser.generation, 1)
    }

    func testForcedRenewalPersistsRotatedTokenCookieAndGeneration() async throws {
        let now = Date()
        let originalBrowser = makeBrowser(
            now: now,
            integrityExpiry: now.addingTimeInterval(600),
            cookieExpiry: now.addingTimeInterval(3_600)
        )
        let account = makeAccount(browser: originalBrowser)
        let issuance = makeIssuance(now: now)
        let store = InMemoryTokenStore(accounts: [account])
        let manager = MinerManager(clientId: "test", tokenStore: store)
        let issuer = StubBrowserIntegrityIssuer(issuance: issuance)
        let coordinator = OperatorSessionRenewalCoordinator(
            minerManager: manager,
            issuer: issuer,
            validator: StubBrowserIntegrityValidator()
        )

        let outcome = try await coordinator.renewNowIfNeeded(now: now, force: true)

        XCTAssertEqual(outcome, .renewed(generation: 2))
        XCTAssertEqual(issuer.callCount, 1)
        XCTAssertEqual(issuer.lastPreviousCookie, TwitchBrowserSDKCookie(
            value: originalBrowser.sdkCookieValue,
            expiresAt: originalBrowser.cookieExpiresAt
        ))
        let stored = await store.loadAccount(twitchUserId: account.id)
        guard case .browser(let browser) = stored?.authenticationContext else {
            return XCTFail("Expected browser context")
        }
        XCTAssertEqual(browser.integrityToken, issuance.token)
        XCTAssertEqual(browser.expiresAt, issuance.expiresAt)
        XCTAssertEqual(browser.sdkCookieValue, issuance.sdkCookieValue)
        XCTAssertEqual(browser.cookieExpiresAt, issuance.cookieExpiresAt)
        XCTAssertEqual(browser.generation, 2)
        XCTAssertEqual(browser.userAgent, originalBrowser.userAgent)
        XCTAssertEqual(stored?.accessToken, account.accessToken)
    }

    func testIntegrityRejectionRenewsImmediatelyOncePerWindow() async throws {
        let now = Date()
        // Not due for another hour on schedule; the rejection is what forces it.
        let browser = makeBrowser(
            now: now,
            integrityExpiry: now.addingTimeInterval(3_600),
            cookieExpiry: now.addingTimeInterval(7_200)
        )
        let account = makeAccount(browser: browser)
        let store = InMemoryTokenStore(accounts: [account])
        let manager = MinerManager(clientId: "test", tokenStore: store)
        manager.miners = [MinerManager.ManagedMiner(
            id: "operator-miner",
            accountId: account.id,
            username: account.username,
            status: .idle,
            isRunning: true,
            isOperator: true
        )]
        let logged = OperatorLogRecorder()
        manager.onLogMessage = { _, message in logged.append(message) }
        let issuer = StubBrowserIntegrityIssuer(issuance: makeIssuance(now: now))
        let coordinator = OperatorSessionRenewalCoordinator(
            minerManager: manager,
            issuer: issuer,
            validator: StubBrowserIntegrityValidator()
        )

        await coordinator.integrityWasRejected(accountId: account.id, now: now)
        // Every request that carried the refused token reports it; one renewal is enough.
        await coordinator.integrityWasRejected(accountId: account.id, now: now.addingTimeInterval(30))

        XCTAssertEqual(issuer.callCount, 1)
        let stored = await store.loadAccount(twitchUserId: account.id)
        guard case .browser(let renewed) = stored?.authenticationContext else {
            return XCTFail("Expected browser context")
        }
        XCTAssertEqual(renewed.generation, 2)
        XCTAssertTrue(logged.messages.contains { $0.contains("Renewed browser security check") })
    }

    func testIntegrityRejectionForAnotherAccountLeavesTheOperatorAlone() async throws {
        let now = Date()
        let account = makeAccount(browser: makeBrowser(
            now: now,
            integrityExpiry: now.addingTimeInterval(3_600),
            cookieExpiry: now.addingTimeInterval(7_200)
        ))
        let manager = MinerManager(clientId: "test", tokenStore: InMemoryTokenStore(accounts: [account]))
        manager.miners = [MinerManager.ManagedMiner(
            id: "operator-miner",
            accountId: account.id,
            username: account.username,
            status: .idle,
            isRunning: true,
            isOperator: true
        )]
        let issuer = StubBrowserIntegrityIssuer(issuance: makeIssuance(now: now))
        let coordinator = OperatorSessionRenewalCoordinator(
            minerManager: manager,
            issuer: issuer,
            validator: StubBrowserIntegrityValidator()
        )

        await coordinator.integrityWasRejected(accountId: "someone-else", now: now)

        XCTAssertEqual(issuer.callCount, 0)
    }

    /// Twitch commonly re-issues the SDK cookie with the same expiry. Requiring it to advance
    /// discarded every working renewal (live log, 2026-09-29: "Twitch did not advance the
    /// browser renewal cookie"), leaving the Operator unable to read the Drops dashboard.
    func testRenewalAcceptsACookieWhoseExpiryDidNotMove() async throws {
        let now = Date()
        let originalBrowser = makeBrowser(
            now: now,
            integrityExpiry: now.addingTimeInterval(600),
            cookieExpiry: now.addingTimeInterval(7_200)
        )
        let account = makeAccount(browser: originalBrowser)
        let issuance = TwitchBrowserIntegrityIssuance(
            token: "new-integrity",
            expiresAt: now.addingTimeInterval(3_600),
            sdkCookieValue: originalBrowser.sdkCookieValue,
            cookieExpiresAt: originalBrowser.cookieExpiresAt
        )
        let store = InMemoryTokenStore(accounts: [account])
        let manager = MinerManager(clientId: "test", tokenStore: store)
        let coordinator = OperatorSessionRenewalCoordinator(
            minerManager: manager,
            issuer: StubBrowserIntegrityIssuer(issuance: issuance),
            validator: StubBrowserIntegrityValidator()
        )

        let outcome = try await coordinator.renewNowIfNeeded(now: now, force: true)

        XCTAssertEqual(outcome, .renewed(generation: 2))
        let stored = await store.loadAccount(twitchUserId: account.id)
        guard case .browser(let browser) = stored?.authenticationContext else {
            return XCTFail("Expected browser context")
        }
        XCTAssertEqual(browser.integrityToken, "new-integrity")
        XCTAssertEqual(browser.cookieExpiresAt, originalBrowser.cookieExpiresAt)
    }

    func testRenewalRefusesACookieThatHasExpired() async throws {
        let now = Date()
        let originalBrowser = makeBrowser(
            now: now,
            integrityExpiry: now.addingTimeInterval(600),
            cookieExpiry: now.addingTimeInterval(7_200)
        )
        let account = makeAccount(browser: originalBrowser)
        let expiredCookie = TwitchBrowserIntegrityIssuance(
            token: "new-integrity",
            expiresAt: now.addingTimeInterval(3_600),
            sdkCookieValue: "expired-cookie",
            cookieExpiresAt: now.addingTimeInterval(-60)
        )
        let store = InMemoryTokenStore(accounts: [account])
        let manager = MinerManager(clientId: "test", tokenStore: store)
        let coordinator = OperatorSessionRenewalCoordinator(
            minerManager: manager,
            issuer: StubBrowserIntegrityIssuer(issuance: expiredCookie),
            validator: StubBrowserIntegrityValidator()
        )

        do {
            _ = try await coordinator.renewNowIfNeeded(now: now, force: true)
            XCTFail("Expected the expired cookie to be refused")
        } catch OperatorSessionRenewalCoordinator.RenewalError.expiredSDKCookie {
            // Expected.
        }

        let stored = await store.loadAccount(twitchUserId: account.id)
        guard case .browser(let browser) = stored?.authenticationContext else {
            return XCTFail("Expected browser context")
        }
        XCTAssertEqual(browser.generation, 1)
    }

    /// Once a renewal inside the cookie's lead window has left its expiry where it was, the
    /// schedule must stop chasing that deadline or WebKit would re-run on every check.
    func testScheduleStopsChasingACookieThatRenewalDidNotExtend() {
        let now = Date()
        let integrityExpiry = now.addingTimeInterval(3_600)
        let browser = TwitchAuthenticationContext.Browser(
            clientID: TwitchClientIDs.web,
            origin: TwitchClientIDs.webOrigin,
            userAgent: "Browser UA",
            integrityToken: "token",
            capturedAt: now,
            expiresAt: integrityExpiry,
            sdkCookieValue: "cookie",
            cookieExpiresAt: now.addingTimeInterval(5 * 60),
            generation: 3
        )

        XCTAssertEqual(
            OperatorSessionRenewalSchedule.renewalDate(for: browser),
            integrityExpiry.addingTimeInterval(-OperatorSessionRenewalSchedule.integrityLeadTime)
        )
    }

    func testRenewalRejectsAReplayedIntegrityToken() async throws {
        let now = Date()
        let originalBrowser = makeBrowser(
            now: now,
            integrityExpiry: now.addingTimeInterval(600),
            cookieExpiry: now.addingTimeInterval(7_200)
        )
        let account = makeAccount(browser: originalBrowser)
        let replayedIssuance = TwitchBrowserIntegrityIssuance(
            token: originalBrowser.integrityToken,
            expiresAt: now.addingTimeInterval(3_600),
            sdkCookieValue: "new-cookie",
            cookieExpiresAt: now.addingTimeInterval(10_800)
        )
        let store = InMemoryTokenStore(accounts: [account])
        let manager = MinerManager(clientId: "test", tokenStore: store)
        let coordinator = OperatorSessionRenewalCoordinator(
            minerManager: manager,
            issuer: StubBrowserIntegrityIssuer(issuance: replayedIssuance),
            validator: StubBrowserIntegrityValidator()
        )

        do {
            _ = try await coordinator.renewNowIfNeeded(now: now, force: true)
            XCTFail("Expected the replayed integrity token to be rejected")
        } catch OperatorSessionRenewalCoordinator.RenewalError.replayedIntegrity {
            // Expected.
        }

        let stored = await store.loadAccount(twitchUserId: account.id)
        guard case .browser(let browser) = stored?.authenticationContext else {
            return XCTFail("Expected browser context")
        }
        XCTAssertEqual(browser.generation, 1)
        XCTAssertEqual(browser.integrityToken, originalBrowser.integrityToken)
    }

    func testRenewalRejectsAnExpiryThatDoesNotAdvance() async throws {
        let now = Date()
        let originalBrowser = makeBrowser(
            now: now,
            integrityExpiry: now.addingTimeInterval(3_600),
            cookieExpiry: now.addingTimeInterval(7_200)
        )
        let account = makeAccount(browser: originalBrowser)
        let regressedIssuance = TwitchBrowserIntegrityIssuance(
            token: "different-integrity",
            expiresAt: originalBrowser.expiresAt,
            sdkCookieValue: "new-cookie",
            cookieExpiresAt: now.addingTimeInterval(10_800)
        )
        let store = InMemoryTokenStore(accounts: [account])
        let manager = MinerManager(clientId: "test", tokenStore: store)
        let coordinator = OperatorSessionRenewalCoordinator(
            minerManager: manager,
            issuer: StubBrowserIntegrityIssuer(issuance: regressedIssuance),
            validator: StubBrowserIntegrityValidator()
        )

        do {
            _ = try await coordinator.renewNowIfNeeded(now: now, force: true)
            XCTFail("Expected the non-advancing expiry to be rejected")
        } catch OperatorSessionRenewalCoordinator.RenewalError.replayedIntegrity {
            // Expected.
        }

        let stored = await store.loadAccount(twitchUserId: account.id)
        guard case .browser(let browser) = stored?.authenticationContext else {
            return XCTFail("Expected browser context")
        }
        XCTAssertEqual(browser.generation, 1)
        XCTAssertEqual(browser.expiresAt, originalBrowser.expiresAt)
    }

    func testManualReconnectWinsWhileRenewalIsInFlight() async throws {
        let now = Date()
        let originalBrowser = makeBrowser(
            now: now,
            integrityExpiry: now.addingTimeInterval(600),
            cookieExpiry: now.addingTimeInterval(7_200)
        )
        let account = makeAccount(browser: originalBrowser)
        let reconnectedBrowser = TwitchAuthenticationContext.Browser(
            clientID: originalBrowser.clientID,
            origin: originalBrowser.origin,
            userAgent: originalBrowser.userAgent,
            xDeviceID: originalBrowser.xDeviceID,
            deviceID: originalBrowser.deviceID,
            clientSessionID: originalBrowser.clientSessionID,
            clientVersion: originalBrowser.clientVersion,
            acceptLanguage: originalBrowser.acceptLanguage,
            integrityToken: "manual-integrity",
            capturedAt: now,
            expiresAt: now.addingTimeInterval(8_000),
            sdkCookieValue: "manual-cookie",
            cookieExpiresAt: now.addingTimeInterval(12_000),
            generation: 2
        )
        let reconnectedAccount = makeAccount(browser: reconnectedBrowser)
        let store = InMemoryTokenStore(accounts: [account])
        let manager = MinerManager(clientId: "test", tokenStore: store)
        let issuer = StubBrowserIntegrityIssuer(issuance: makeIssuance(now: now)) {
            await store.save(account: reconnectedAccount)
        }
        let coordinator = OperatorSessionRenewalCoordinator(
            minerManager: manager,
            issuer: issuer,
            validator: StubBrowserIntegrityValidator()
        )

        let outcome = try await coordinator.renewNowIfNeeded(now: now, force: true)

        XCTAssertEqual(outcome, .superseded)
        let stored = await store.loadAccount(twitchUserId: account.id)
        guard case .browser(let browser) = stored?.authenticationContext else {
            return XCTFail("Expected browser context")
        }
        XCTAssertEqual(browser.generation, 2)
        XCTAssertEqual(browser.integrityToken, "manual-integrity")
        XCTAssertEqual(browser.sdkCookieValue, "manual-cookie")
    }

    func testRejectedCandidateDoesNotReplaceWorkingGeneration() async throws {
        let now = Date()
        let originalBrowser = makeBrowser(
            now: now,
            integrityExpiry: now.addingTimeInterval(600),
            cookieExpiry: now.addingTimeInterval(7_200)
        )
        let account = makeAccount(browser: originalBrowser)
        let store = InMemoryTokenStore(accounts: [account])
        let manager = MinerManager(clientId: "test", tokenStore: store)
        let validator = StubBrowserIntegrityValidator(error: TestValidationError.rejected)
        let coordinator = OperatorSessionRenewalCoordinator(
            minerManager: manager,
            issuer: StubBrowserIntegrityIssuer(issuance: makeIssuance(now: now)),
            validator: validator
        )

        do {
            _ = try await coordinator.renewNowIfNeeded(now: now, force: true)
            XCTFail("Expected the candidate to be rejected")
        } catch TestValidationError.rejected {
            // Expected.
        }

        XCTAssertEqual(validator.callCount, 1)
        let stored = await store.loadAccount(twitchUserId: account.id)
        guard case .browser(let browser) = stored?.authenticationContext else {
            return XCTFail("Expected browser context")
        }
        XCTAssertEqual(browser.generation, 1)
        XCTAssertEqual(browser.integrityToken, originalBrowser.integrityToken)
    }

    private func makeAccount(browser: TwitchAuthenticationContext.Browser) -> Account {
        Account(
            id: "operator-id",
            username: "operator",
            accessToken: "oauth-token",
            refreshToken: "",
            tokenExpiry: Date().addingTimeInterval(86_400),
            scopes: [],
            isOperator: true,
            authenticationContext: .browser(browser)
        )
    }

    private func makeBrowser(
        now: Date,
        integrityExpiry: Date,
        cookieExpiry: Date
    ) -> TwitchAuthenticationContext.Browser {
        TwitchAuthenticationContext.Browser(
            clientID: TwitchClientIDs.web,
            origin: TwitchClientIDs.webOrigin,
            userAgent: "Browser UA",
            xDeviceID: "device-id",
            acceptLanguage: "en-NZ",
            integrityToken: "old-integrity",
            capturedAt: now,
            expiresAt: integrityExpiry,
            sdkCookieValue: "old-cookie",
            cookieExpiresAt: cookieExpiry,
            generation: 1
        )
    }

    private func makeIssuance(now: Date) -> TwitchBrowserIntegrityIssuance {
        TwitchBrowserIntegrityIssuance(
            token: "new-integrity",
            expiresAt: now.addingTimeInterval(7_200),
            sdkCookieValue: "new-cookie",
            cookieExpiresAt: now.addingTimeInterval(10_800)
        )
    }
}

@MainActor
private final class StubBrowserIntegrityIssuer: TwitchBrowserIntegrityIssuing {
    private let issuance: TwitchBrowserIntegrityIssuance
    private let beforeReturning: (() async throws -> Void)?
    private(set) var callCount = 0
    private(set) var lastPreviousCookie: TwitchBrowserSDKCookie?

    init(
        issuance: TwitchBrowserIntegrityIssuance,
        beforeReturning: (() async throws -> Void)? = nil
    ) {
        self.issuance = issuance
        self.beforeReturning = beforeReturning
    }

    func issue(
        oauthToken: String,
        clientID: String,
        deviceID: String,
        previousCookie: TwitchBrowserSDKCookie?
    ) async throws -> TwitchBrowserIntegrityIssuance {
        callCount += 1
        lastPreviousCookie = previousCookie
        try await beforeReturning?()
        return issuance
    }
}

@MainActor
private final class StubBrowserIntegrityValidator: TwitchBrowserIntegrityValidating {
    private let error: Error?
    private(set) var callCount = 0

    init(error: Error? = nil) {
        self.error = error
    }

    func validate(
        account: Account,
        browser: TwitchAuthenticationContext.Browser,
        issuance: TwitchBrowserIntegrityIssuance
    ) async throws {
        callCount += 1
        if let error { throw error }
    }
}

private final class OperatorLogRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    var messages: [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private enum TestValidationError: Error {
    case rejected
}
