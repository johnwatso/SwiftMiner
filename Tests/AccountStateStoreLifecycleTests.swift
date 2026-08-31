import XCTest
@testable import SwiftMinerCore

/// `AccountStateStore.start` schedules an unbounded refresh loop. Nothing outside the store
/// cancels it, so if that loop holds a strong reference the store — and the service graph
/// behind it — survives account removal and keeps polling Twitch forever.
final class AccountStateStoreLifecycleTests: XCTestCase {
    private var session: URLSession!

    override func setUp() async throws {
        try await super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: configuration)
        // Answer every request immediately with a body Twitch would never send. The loop only
        // has to *run*, not succeed: `refresh()` records the failure and carries on, which is
        // the state it spends its life in. A transport error would instead be retried by the
        // request coordinator and take far longer to settle.
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (response, Data("{}".utf8))
        }
    }

    override func tearDown() async throws {
        MockURLProtocol.stubError = nil
        MockURLProtocol.requestHandler = nil
        MockURLProtocol.stubResponseData = nil
        session.invalidateAndCancel()
        try await super.tearDown()
    }

    @MainActor
    private func makeStore() -> AccountStateStore {
        let apiClient = TwitchAPIClient(
            authService: TwitchAuthService(clientId: "test", tokenStore: InMemoryTokenStore()),
            clientId: "test",
            session: session,
            persistsCampaignCaches: false
        )
        return AccountStateStore(
            accountId: "account-1",
            username: "miner",
            dropsService: DropsService(apiClient: apiClient)
        )
    }

    /// The loop is started with no initial delay and given time to finish its first refresh and
    /// park in the interval sleep — the state it is in for all but a second of every minute.
    /// Parked there, it must not be what keeps the store alive.
    @MainActor
    func testRunningRefreshLoopDoesNotKeepTheStoreAlive() async throws {
        weak var weakStore: AccountStateStore?

        do {
            let store = makeStore()
            weakStore = store
            store.start(initialDelay: 0)

            // Wait for the first refresh to settle, so the loop has reached its interval sleep.
            var waited = 0
            while store.lastError == nil && waited < 200 {
                try await Task.sleep(nanoseconds: 50_000_000)
                waited += 1
            }
            XCTAssertNotNil(store.lastError, "The first refresh should have run and failed")
        }

        await Task.yield()
        XCTAssertNil(weakStore, "A running refresh loop must not keep its own store alive")
    }

    @MainActor
    func testStopCancelsTheRefreshLoop() async throws {
        let store = makeStore()
        store.start(initialDelay: 3_600)
        XCTAssertNotNil(store.refreshTask)

        store.stop()
        XCTAssertNil(store.refreshTask, "stop() must cancel and clear the refresh task")
    }
}
