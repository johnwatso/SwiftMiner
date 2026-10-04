import SwiftMinerCore
import WebKit
import XCTest
@testable import SwiftMiner

@MainActor
final class OperatorBrowserLoginTests: XCTestCase {
    private final class BlockNavigation: NSObject, WKNavigationDelegate {
        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            decisionHandler(.cancel)
        }
    }

    private func cookie(domain: String = ".twitch.tv", value: String = "test-session") -> HTTPCookie {
        HTTPCookie(properties: [
            .domain: domain, .path: "/", .name: "auth-token", .value: value, .secure: "TRUE",
        ])!
    }

    private func account() -> Account {
        Account(id: "123", username: "operator", accessToken: "test-session", refreshToken: "", tokenExpiry: .distantFuture, scopes: [], isOperator: true)
    }

    func testAuthenticationCookieRequiresTwitchDomainAndNonemptyToken() {
        XCTAssertNil(OperatorBrowserLoginService.authenticationCookie(in: [cookie(domain: "nottwitch.tv")]))
        XCTAssertNil(OperatorBrowserLoginService.authenticationCookie(in: [cookie(domain: "twitch.tv.evil.example")]))
        XCTAssertNil(OperatorBrowserLoginService.authenticationCookie(in: [cookie(value: "")]))
        for domain in ["twitch.tv", ".twitch.tv", "www.twitch.tv"] {
            XCTAssertEqual(OperatorBrowserLoginService.authenticationCookie(in: [cookie(domain: domain)])?.value, "test-session")
        }
    }

    func testLoginCookieAutomaticallyVerifiesOnce() async throws {
        let store = WKWebsiteDataStore.nonPersistent()
        let navigation = BlockNavigation()
        let verified = expectation(description: "Automatic account validation")
        var attempts = 0
        let expectedAccount = account()
        let service = OperatorBrowserLoginService(dataStore: store) {
            attempts += 1
            verified.fulfill()
            return expectedAccount
        }
        service.webView.navigationDelegate = navigation
        service.start()
        await store.httpCookieStore.setCookie(cookie())
        await fulfillment(of: [verified], timeout: 3)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(service.state, .succeeded(expectedAccount))
        XCTAssertEqual(attempts, 1)
        service.connect()
        XCTAssertEqual(attempts, 1)
        service.cancel()
    }

    func testFailedTokenDoesNotLoopButNewLoginIsDetected() async throws {
        struct Rejected: Error {}
        let store = WKWebsiteDataStore.nonPersistent()
        let navigation = BlockNavigation()
        let firstAttempt = expectation(description: "Initial validation")
        let nextLogin = expectation(description: "Changed login validation")
        var attempts = 0
        let service = OperatorBrowserLoginService(dataStore: store) {
            attempts += 1
            if attempts == 1 { firstAttempt.fulfill() } else { nextLogin.fulfill() }
            throw Rejected()
        }
        service.webView.navigationDelegate = navigation
        service.start()
        await store.httpCookieStore.setCookie(cookie())
        await fulfillment(of: [firstAttempt], timeout: 3)
        await store.httpCookieStore.setCookie(HTTPCookie(properties: [
            .domain: ".twitch.tv", .path: "/", .name: "unrelated", .value: "changed",
        ])!)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(attempts, 1)
        await store.httpCookieStore.setCookie(cookie(value: "new-session"))
        await fulfillment(of: [nextLogin], timeout: 3)
        XCTAssertEqual(attempts, 2)
        service.cancel()
    }

    func testCancellationStopsCookieDetection() async throws {
        let store = WKWebsiteDataStore.nonPersistent()
        let navigation = BlockNavigation()
        var attempts = 0
        let expectedAccount = account()
        let service = OperatorBrowserLoginService(dataStore: store) {
            attempts += 1
            return expectedAccount
        }
        service.webView.navigationDelegate = navigation
        service.start()
        service.cancel()
        await store.httpCookieStore.setCookie(cookie())
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(attempts, 0)
    }

    func testCancelledValidationCannotComplete() async throws {
        let started = expectation(description: "Verification started")
        var resume: CheckedContinuation<Account, Never>?
        let service = OperatorBrowserLoginService(dataStore: .nonPersistent()) {
            started.fulfill()
            return await withCheckedContinuation { resume = $0 }
        }
        service.connect()
        await fulfillment(of: [started], timeout: 3)
        service.cancel()
        resume?.resume(returning: account())
        try await Task.sleep(for: .milliseconds(100))
        if case .succeeded = service.state { XCTFail("Cancelled verification saved an account") }
    }
}
