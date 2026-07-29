import Foundation
import XCTest
@testable import SwiftMinerCore

private final class ChaosClock: @unchecked Sendable {
    private let lock = NSLock()
    private var tick: UInt64 = 0
    private var sleeps: [UInt64] = []
    var onSleep: (@Sendable (Int) -> Void)?

    lazy var clock = RuntimeClock(
        nowNanoseconds: { [weak self] in self?.lock.withLock { self?.tick ?? 0 } ?? 0 },
        sleepNanoseconds: { [weak self] nanoseconds in
            guard let self else { return }
            try Task.checkCancellation()
            let count = self.lock.withLock { () -> Int in
                self.tick &+= nanoseconds
                self.sleeps.append(nanoseconds)
                return self.sleeps.count
            }
            self.onSleep?(count)
            await Task.yield()
            try Task.checkCancellation()
        }
    )

    var now: UInt64 { lock.withLock { tick } }
    var requestedSleeps: [UInt64] { lock.withLock { sleeps } }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool
    init(_ value: Bool) { self.value = value }
    func get() -> Bool { lock.withLock { value } }
    func set(_ value: Bool) { lock.withLock { self.value = value } }
}

private final class LockedInt: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int { lock.withLock { value += 1; return value } }
    func get() -> Int { lock.withLock { value } }
}

private final class ConnectivityGate: @unchecked Sendable {
    private let lock = NSLock()
    private var online = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isOnline: Bool { lock.withLock { online } }
    var waiterCount: Int { lock.withLock { waiters.count } }

    func waitUntilOnline() async {
        guard !isOnline else { return }
        await withCheckedContinuation { continuation in
            let resumeImmediately = lock.withLock { () -> Bool in
                guard !online else { return true }
                waiters.append(continuation)
                return false
            }
            if resumeImmediately { continuation.resume() }
        }
    }

    func restoreConnectivity() {
        let pending = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            online = true
            defer { waiters.removeAll() }
            return waiters
        }
        pending.forEach { $0.resume() }
    }
}

@MainActor
final class MiningReliabilityChaosTests: XCTestCase {
    private var session: URLSession!
    private var authService: TwitchAuthService!

    override func setUp() async throws {
        try await super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: configuration)
        authService = TwitchAuthService(clientId: "test-client", tokenStore: TestTokenStore())
        MockURLProtocol.requestHandler = nil
        MockURLProtocol.stubError = nil
        MockURLProtocol.stubResponseData = nil
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        MockURLProtocol.stubError = nil
        MockURLProtocol.stubResponseData = nil
        session.invalidateAndCancel()
        super.tearDown()
    }

    func testOfflineThen503Then429RecoversWithoutFatalError() async throws {
        let clock = ChaosClock()
        let online = LockedFlag(false)
        clock.onSleep = { count in
            if count == 1 { online.set(true) }
        }
        let coordinator = TwitchRequestCoordinator(
            maxRequests: 100,
            offlinePollInterval: 2,
            runtimeClock: clock.clock,
            connectivity: { online.get() }
        )
        let client = TwitchAPIClient(
            authService: authService,
            clientId: "test-client",
            session: session,
            requestCoordinator: coordinator,
            runtimeClock: clock.clock,
            retryJitterFactor: { 1 },
            persistsCampaignCaches: false
        )
        let attempts = LockedInt()
        MockURLProtocol.requestHandler = { request in
            let attempt = attempts.increment()
            if attempt == 1 {
                return (HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, Data())
            }
            if attempt == 2 {
                return (HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "1"])!, Data())
            }
            let body = #"{"data":[{"id":"1","login":"miner","display_name":"Miner","type":"","broadcaster_type":"","description":"","profile_image_url":"","offline_image_url":"","view_count":0,"created_at":"2020-01-01T00:00:00Z"}]}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }

        let user = try await client.getCurrentUser()

        XCTAssertEqual(user.id, "1")
        XCTAssertEqual(attempts.get(), 3)
        XCTAssertGreaterThanOrEqual(clock.now, 5_000_000_000)
    }

    func testLongRetryAfterIsSharedWithAnotherClient() async throws {
        let clock = ChaosClock()
        let coordinator = TwitchRequestCoordinator(
            maxRequests: 100,
            runtimeClock: clock.clock
        )
        let first = TwitchAPIClient(
            authService: authService,
            clientId: "test-client",
            session: session,
            requestCoordinator: coordinator,
            runtimeClock: clock.clock,
            retryJitterFactor: { 1 },
            persistsCampaignCaches: false
        )
        let second = TwitchAPIClient(
            authService: authService,
            clientId: "test-client",
            session: session,
            requestCoordinator: coordinator,
            runtimeClock: clock.clock,
            retryJitterFactor: { 1 },
            persistsCampaignCaches: false
        )
        let attempts = LockedInt()
        MockURLProtocol.requestHandler = { request in
            if attempts.increment() == 1 {
                return (HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "45"])!, Data())
            }
            let body = #"{"data":[{"id":"2","login":"peer","display_name":"Peer","type":"","broadcaster_type":"","description":"","profile_image_url":"","offline_image_url":"","view_count":0,"created_at":"2020-01-01T00:00:00Z"}]}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }

        do {
            _ = try await first.getCurrentUser()
            XCTFail("long Retry-After should be surfaced")
        } catch let error as TwitchMinerError {
            guard case .rateLimited(let retryAfter) = error else {
                return XCTFail("expected rateLimited, got \(error)")
            }
            XCTAssertEqual(retryAfter, 45)
        }

        _ = try await second.getCurrentUser()
        XCTAssertGreaterThanOrEqual(clock.now, 45_000_000_000)
    }

    func testCoordinatorKeepsPerClientLimitInsideLargerFleetBudget() async throws {
        let clock = ChaosClock()
        let coordinator = TwitchRequestCoordinator(
            maxRequests: 4,
            maxRequestsPerClient: 2,
            per: 1,
            runtimeClock: clock.clock
        )

        _ = try await coordinator.waitForPermit(clientID: "a")
        _ = try await coordinator.waitForPermit(clientID: "a")
        _ = try await coordinator.waitForPermit(clientID: "b")
        XCTAssertEqual(clock.now, 0)

        _ = try await coordinator.waitForPermit(clientID: "a")
        XCTAssertGreaterThanOrEqual(clock.now, 1_000_000_000)
    }

    func testCoordinatorUsesConnectivitySignalInsteadOfPolling() async throws {
        let clock = ChaosClock()
        let gate = ConnectivityGate()
        let coordinator = TwitchRequestCoordinator(
            maxRequests: 1,
            offlinePollInterval: 60,
            runtimeClock: clock.clock,
            connectivity: { gate.isOnline },
            connectivityWaiter: { await gate.waitUntilOnline() }
        )

        let permit = Task { try await coordinator.waitForPermit() }
        for _ in 0..<20 where gate.waiterCount == 0 {
            await Task.yield()
        }
        XCTAssertEqual(gate.waiterCount, 1)
        XCTAssertTrue(clock.requestedSleeps.isEmpty, "the coordinator should wait for NWPath, not poll")

        gate.restoreConnectivity()
        _ = try await permit.value
        XCTAssertEqual(clock.now, 0)
    }

    func testAmbiguousClaimIsAcceptedWhenFreshInventoryConfirmsIt() async throws {
        let clock = ChaosClock()
        let coordinator = TwitchRequestCoordinator(maxRequests: 100, runtimeClock: clock.clock)
        let client = TwitchAPIClient(
            authService: authService,
            clientId: "test-client",
            session: session,
            requestCoordinator: coordinator,
            runtimeClock: clock.clock,
            retryJitterFactor: { 1 },
            persistsCampaignCaches: false
        )
        MockURLProtocol.stubError = URLError(.networkConnectionLost)
        let service = ClaimService(
            apiClient: client,
            runtimeClock: clock.clock,
            claimConfirmation: { _ in true }
        )
        let progress = Progress(
            id: "instance",
            dropId: "drop",
            dropName: "Reward",
            campaignId: "campaign",
            currentMinutes: 60,
            requiredMinutes: 60,
            isClaimed: false
        )

        let result = await service.claimDrop(progress)

        XCTAssertTrue(result.success)
        XCTAssertTrue(result.confirmedByInventory)
        XCTAssertNil(result.failureKind)
    }

    func testTransientClaimFailureUsesBackoffInsteadOfHammeringTwitch() async throws {
        let clock = ChaosClock()
        let coordinator = TwitchRequestCoordinator(maxRequests: 100, runtimeClock: clock.clock)
        let attempts = LockedInt()
        MockURLProtocol.requestHandler = { _ in
            _ = attempts.increment()
            throw URLError(.networkConnectionLost)
        }
        let client = TwitchAPIClient(
            authService: authService,
            clientId: "test-client",
            session: session,
            requestCoordinator: coordinator,
            runtimeClock: clock.clock,
            retryJitterFactor: { 1 },
            persistsCampaignCaches: false
        )
        let service = ClaimService(
            apiClient: client,
            runtimeClock: clock.clock,
            claimConfirmation: { _ in false }
        )
        let progress = Progress(
            id: "retry-instance",
            dropId: "drop",
            dropName: "Reward",
            campaignId: "campaign",
            currentMinutes: 60,
            requiredMinutes: 60,
            isClaimed: false
        )

        let first = await service.claimDrop(progress)
        let requestsAfterFirst = attempts.get()
        let second = await service.claimDrop(progress)

        XCTAssertEqual(first.failureKind, .transient)
        XCTAssertEqual(first.retryAfter, 30)
        XCTAssertEqual(second.failureKind, .transient)
        XCTAssertEqual(attempts.get(), requestsAfterFirst, "cooldown should suppress another claim request")
    }

    func testDeterministicMultiClientSoakSurvivesIntermittent503s() async throws {
        let clock = ChaosClock()
        let coordinator = TwitchRequestCoordinator(
            maxRequests: 5,
            per: 1,
            runtimeClock: clock.clock
        )
        let clients = (0..<3).map { index in
            TwitchAPIClient(
                authService: authService,
                clientId: "test-client-\(index)",
                session: session,
                requestCoordinator: coordinator,
                runtimeClock: clock.clock,
                retryJitterFactor: { 1 },
                persistsCampaignCaches: false
            )
        }
        let attempts = LockedInt()
        MockURLProtocol.requestHandler = { request in
            let attempt = attempts.increment()
            if attempt.isMultiple(of: 9) {
                return (HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, Data())
            }
            let body = #"{"data":[{"id":"soak","login":"miner","display_name":"Miner","type":"","broadcaster_type":"","description":"","profile_image_url":"","offline_image_url":"","view_count":0,"created_at":"2020-01-01T00:00:00Z"}]}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }

        for cycle in 0..<30 {
            let user = try await clients[cycle % clients.count].getCurrentUser()
            XCTAssertEqual(user.id, "soak")
        }

        XCTAssertGreaterThan(attempts.get(), 30)
        XCTAssertGreaterThan(clock.now, 0, "shared rate and retry waits should advance the monotonic clock")
    }

    func testRuntimeTimeoutCancelsHungOperation() async {
        let clock = ChaosClock()
        do {
            _ = try await withRuntimeTimeout(
                operationName: "test recovery",
                seconds: 5,
                clock: clock.clock
            ) {
                try await Task<Never, Never>.sleep(nanoseconds: 60_000_000_000)
                return true
            }
            XCTFail("operation should time out")
        } catch let error as RuntimeTimeoutError {
            XCTAssertEqual(error.operation, "test recovery")
            XCTAssertEqual(error.seconds, 5)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRetryAfterParsesHTTPDate() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(
            TwitchAPIClient.retryAfterSeconds(from: "Thu, 01 Jan 1970 00:00:12 GMT", now: now),
            12
        )
    }
}
