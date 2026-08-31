import XCTest
@testable import SwiftMinerCore

/// In-memory PubSubSocket. Tests push incoming frames or errors; the client's
/// listen loop consumes them one at a time.
final class MockPubSubSocket: PubSubSocket, @unchecked Sendable {
    private let lock = NSLock()
    private var sentTexts: [String] = []
    private var sendError: Error?
    private var queued: [Result<String?, Error>] = []
    private var waiter: CheckedContinuation<String?, Error>?
    private var wasResumed = false
    private var wasCancelled = false
    private var automaticallyRespondsToTopicRequests = true
    private var topicResponseError: String?

    // MARK: Test controls

    var sent: [PubSubMessage] {
        lock.withLock { sentTexts }.compactMap {
            try? JSONDecoder().decode(PubSubMessage.self, from: Data($0.utf8))
        }
    }

    var resumed: Bool { lock.withLock { wasResumed } }
    var cancelled: Bool { lock.withLock { wasCancelled } }

    func setSendError(_ error: Error?) {
        lock.withLock { sendError = error }
    }

    func setAutomaticallyRespondsToTopicRequests(_ enabled: Bool) {
        lock.withLock { automaticallyRespondsToTopicRequests = enabled }
    }

    func setTopicResponseError(_ error: String?) {
        lock.withLock { topicResponseError = error }
    }

    /// Deliver an incoming text frame to the client.
    func push(_ text: String) {
        deliver(.success(text))
    }

    /// Fail the client's pending (or next) receive, as a dropped socket would.
    func failReceive(_ error: Error) {
        deliver(.failure(error))
    }

    private func deliver(_ result: Result<String?, Error>) {
        let pending: CheckedContinuation<String?, Error>? = lock.withLock {
            if let w = waiter {
                waiter = nil
                return w
            }
            queued.append(result)
            return nil
        }
        pending?.resume(with: result)
    }

    // MARK: PubSubSocket

    func resume() {
        lock.withLock { wasResumed = true }
    }

    func send(_ text: String) async throws {
        let state: (error: Error?, responds: Bool, responseError: String?) = lock.withLock {
            if sendError == nil { sentTexts.append(text) }
            return (sendError, automaticallyRespondsToTopicRequests, topicResponseError)
        }
        if let error = state.error { throw error }

        guard state.responds,
              let request = try? JSONDecoder().decode(PubSubMessage.self, from: Data(text.utf8)),
              request.type == .listen || request.type == .unlisten,
              let nonce = request.nonce,
              let responseData = try? JSONEncoder().encode(PubSubMessage(
                type: .response,
                nonce: nonce,
                error: state.responseError ?? ""
              )),
              let responseText = String(data: responseData, encoding: .utf8) else { return }
        deliver(.success(responseText))
    }

    func receive() async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            let ready: Result<String?, Error>? = lock.withLock {
                if queued.isEmpty {
                    waiter = continuation
                    return nil
                }
                return queued.removeFirst()
            }
            if let ready { continuation.resume(with: ready) }
        }
    }

    func cancel() {
        // Unblock any pending receive so cancelled sockets don't leak waiters.
        let pending: CheckedContinuation<String?, Error>? = lock.withLock {
            wasCancelled = true
            defer { waiter = nil }
            return waiter
        }
        pending?.resume(throwing: URLError(.cancelled))
    }
}

/// Records every socket the client creates, in order.
final class MockSocketFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var sockets: [MockPubSubSocket] = []
    private var newSocketsAutomaticallyRespond = true

    var count: Int { lock.withLock { sockets.count } }

    subscript(index: Int) -> MockPubSubSocket? {
        lock.withLock { sockets.indices.contains(index) ? sockets[index] : nil }
    }

    func setNewSocketsAutomaticallyRespond(_ enabled: Bool) {
        lock.withLock { newSocketsAutomaticallyRespond = enabled }
    }

    func make(url: URL) -> any PubSubSocket {
        let socket = MockPubSubSocket()
        let responds = lock.withLock { () -> Bool in
            sockets.append(socket)
            return newSocketsAutomaticallyRespond
        }
        socket.setAutomaticallyRespondsToTopicRequests(responds)
        return socket
    }
}

/// Thread-safe recorder for connection state callbacks.
final class ConnectionStateRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var changes: [Bool] = []

    var states: [Bool] { lock.withLock { changes } }

    func record(_ state: Bool) {
        lock.withLock { changes.append(state) }
    }
}

/// Thread-safe recorder used to prove that PubSub waits for an async message handler before
/// reading the next frame. This protects the event-ordering guarantee relied on by MinerEngine.
final class MessageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var topics: [String] = []

    func append(_ topic: String) {
        lock.withLock { topics.append(topic) }
    }

    var values: [String] { lock.withLock { topics } }
}

/// Deterministic sleeper used to prove reconnect does not create a socket until its
/// backoff has actually elapsed. Tests release waits explicitly.
final class ControlledRuntimeSleeper: @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<Void, Error>] = []
    private var requested: [UInt64] = []

    var requestCount: Int { lock.withLock { requested.count } }
    var requestedNanoseconds: [UInt64] { lock.withLock { requested } }

    lazy var clock = RuntimeClock(
        nowNanoseconds: { 0 },
        sleepNanoseconds: { [weak self] nanoseconds in
            guard let self else { return }
            // PubSub uses the same clock for its long-running PING/PONG timers. Let those
            // use normal cancellation; only reconnect-sized waits are manually controlled.
            if nanoseconds > 10_000_000_000 {
                try await Task<Never, Never>.sleep(nanoseconds: nanoseconds)
                return
            }
            try await withCheckedThrowingContinuation { continuation in
                self.lock.withLock {
                    self.requested.append(nanoseconds)
                    self.continuations.append(continuation)
                }
            }
        }
    )

    func releaseNext() {
        let continuation: CheckedContinuation<Void, Error>? = lock.withLock {
            guard !continuations.isEmpty else { return nil }
            return continuations.removeFirst()
        }
        continuation?.resume()
    }
}

final class PubSubClientTests: XCTestCase {

    private func makeClient(factory: MockSocketFactory,
                            pingInterval: TimeInterval = 600,
                            pongTimeout: TimeInterval = 600,
                            topicResponseTimeout: TimeInterval = 15,
                            runtimeClock: RuntimeClock = .continuous,
                            baseReconnectDelay: TimeInterval = 0.01) -> PubSubClient {
        PubSubClient(
            accessToken: "test-token",
            socketFactory: { factory.make(url: $0) },
            pingInterval: pingInterval,
            pongTimeout: pongTimeout,
            topicResponseTimeout: topicResponseTimeout,
            baseReconnectDelay: baseReconnectDelay,
            maxReconnectDelay: max(0.05, baseReconnectDelay * 8),
            runtimeClock: runtimeClock,
            reconnectJitterFactor: { 1 }
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        _ description: String,
        condition: @escaping @Sendable () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for: \(description)")
    }

    private static func topics(of message: PubSubMessage) -> [String] {
        guard case .array(let values)? = message.data?["topics"] else { return [] }
        return values.compactMap {
            if case .string(let topic) = $0 { return topic }
            return nil
        }
    }

    // MARK: - Pure helpers

    func testTopicBatchesAreSortedDeduplicatedAndSized() {
        let batches = PubSubClient.topicBatches(["b", "a", "b", "c"], batchSize: 2)
        XCTAssertEqual(batches, [["a", "b"], ["c"]])
        XCTAssertEqual(PubSubClient.topicBatches([], batchSize: 2), [])
        XCTAssertEqual(PubSubClient.topicBatches(["a"], batchSize: 0), [])
    }

    func testPendingTopicSubscriptionsExcludesAlreadySubmitted() {
        let pending = PubSubClient.pendingTopicSubscriptions(
            desired: ["a", "b", "c"],
            submitted: ["b"]
        )
        XCTAssertEqual(pending, ["a", "c"])
    }

    // MARK: - Listen / unlisten

    func testListenSendsListenMessageWithAuthToken() async throws {
        let factory = MockSocketFactory()
        let client = makeClient(factory: factory)

        try await client.connect()
        try await client.listen(to: ["user-drop-events.1", "user-drop-events.2"])

        let socket = try XCTUnwrap(factory[0])
        XCTAssertTrue(socket.resumed)
        try await waitUntil("LISTEN sent") { socket.sent.contains { $0.type == .listen } }

        let listen = try XCTUnwrap(socket.sent.first { $0.type == .listen })
        XCTAssertEqual(Self.topics(of: listen), ["user-drop-events.1", "user-drop-events.2"])
        if case .string(let token)? = listen.data?["auth_token"] {
            XCTAssertEqual(token, "test-token")
        } else {
            XCTFail("LISTEN carried no auth token")
        }
        await client.disconnect()
    }

    func testListenWhileDisconnectedThrows() async throws {
        let factory = MockSocketFactory()
        let client = makeClient(factory: factory)

        do {
            try await client.listen(to: ["user-drop-events.1"])
            XCTFail("Expected PubSubError.notConnected")
        } catch let error as PubSubError {
            guard case .notConnected = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testRejectedListenThrowsAndDoesNotRemainActive() async throws {
        let factory = MockSocketFactory()
        let client = makeClient(factory: factory)

        try await client.connect()
        let socket = try XCTUnwrap(factory[0])
        socket.setTopicResponseError("ERR_BADAUTH")

        do {
            try await client.listen(to: ["topic.rejected"])
            XCTFail("Expected Twitch's rejected LISTEN to throw")
        } catch let error as PubSubError {
            guard case .topicRequestRejected("ERR_BADAUTH") = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let topicsAfterRejection = await client.currentTopics
        XCTAssertFalse(topicsAfterRejection.contains("topic.rejected"))
        await client.disconnect()
    }

    func testMissingListenResponseTimesOutAndDoesNotRemainActive() async throws {
        let factory = MockSocketFactory()
        let client = makeClient(factory: factory, topicResponseTimeout: 0.05)

        try await client.connect()
        let socket = try XCTUnwrap(factory[0])
        socket.setAutomaticallyRespondsToTopicRequests(false)

        do {
            try await client.listen(to: ["topic.silent"])
            XCTFail("Expected an unacknowledged LISTEN to time out")
        } catch let error as PubSubError {
            guard case .topicResponseTimedOut = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let topicsAfterTimeout = await client.currentTopics
        XCTAssertFalse(topicsAfterTimeout.contains("topic.silent"))
        await client.disconnect()
    }

    // MARK: - Reconnect behaviour

    func testSocketErrorTriggersReconnectAndResubscribes() async throws {
        let factory = MockSocketFactory()
        let recorder = ConnectionStateRecorder()
        let client = makeClient(factory: factory)
        await client.setConnectionStateHandler { recorder.record($0) }

        try await client.connect()
        try await client.listen(to: ["topic.a", "topic.b"])

        try XCTUnwrap(factory[0]).failReceive(URLError(.networkConnectionLost))

        try await waitUntil("second socket created") { factory.count == 2 }
        let second = try XCTUnwrap(factory[1])
        try await waitUntil("topics replayed on new socket") {
            second.sent.contains { $0.type == .listen }
        }

        let listen = try XCTUnwrap(second.sent.first { $0.type == .listen })
        XCTAssertEqual(Self.topics(of: listen), ["topic.a", "topic.b"])
        XCTAssertEqual(recorder.states, [true, false, true])
        await client.disconnect()
    }

    func testServerReconnectRequestCreatesNewSocket() async throws {
        let factory = MockSocketFactory()
        let client = makeClient(factory: factory)

        try await client.connect()
        try await client.listen(to: ["topic.a"])

        try XCTUnwrap(factory[0]).push(#"{"type":"RECONNECT"}"#)

        try await waitUntil("reconnect socket created") { factory.count == 2 }
        let second = try XCTUnwrap(factory[1])
        try await waitUntil("topics replayed after RECONNECT") {
            second.sent.contains { Self.topics(of: $0) == ["topic.a"] }
        }
        await client.disconnect()
    }

    func testUnlistenedTopicsAreNotResubscribedAfterReconnect() async throws {
        let factory = MockSocketFactory()
        let client = makeClient(factory: factory)

        try await client.connect()
        try await client.listen(to: ["topic.a", "topic.b"])
        try await client.unlisten(from: ["topic.a"])

        let first = try XCTUnwrap(factory[0])
        try await waitUntil("UNLISTEN sent") { first.sent.contains { $0.type == .unlisten } }

        first.failReceive(URLError(.networkConnectionLost))

        try await waitUntil("second socket created") { factory.count == 2 }
        let second = try XCTUnwrap(factory[1])
        try await waitUntil("topics replayed on new socket") {
            second.sent.contains { $0.type == .listen }
        }

        let listen = try XCTUnwrap(second.sent.first { $0.type == .listen })
        XCTAssertEqual(Self.topics(of: listen), ["topic.b"])
        await client.disconnect()
    }

    func testPongTimeoutForcesReconnect() async throws {
        let factory = MockSocketFactory()
        let client = makeClient(factory: factory, pingInterval: 0.05, pongTimeout: 0.05)

        try await client.connect()

        try await waitUntil("PING sent") {
            factory[0]?.sent.contains { $0.type == .ping } ?? false
        }
        // No PONG is ever pushed, so the timeout must tear the socket down.
        try await waitUntil("reconnect after PONG timeout") { factory.count >= 2 }
        await client.disconnect()
    }

    func testPongCancelsTimeoutAndKeepsSocket() async throws {
        let factory = MockSocketFactory()
        let client = makeClient(factory: factory, pingInterval: 0.05, pongTimeout: 1.0)

        try await client.connect()
        try await waitUntil("PING sent") {
            factory[0]?.sent.contains { $0.type == .ping } ?? false
        }
        try XCTUnwrap(factory[0]).push(#"{"type":"PONG"}"#)

        // Give the (answered) pong timeout a chance to fire if it were broken.
        try await Task.sleep(nanoseconds: 1_200_000_000)
        XCTAssertEqual(factory.count, 1, "PONG should keep the original socket alive")
        await client.disconnect()
    }

    func testReconnectWaitsForBackoffBeforeCreatingSocket() async throws {
        let factory = MockSocketFactory()
        let sleeper = ControlledRuntimeSleeper()
        let client = makeClient(
            factory: factory,
            runtimeClock: sleeper.clock,
            baseReconnectDelay: 2
        )

        try await client.connect()
        try XCTUnwrap(factory[0]).failReceive(URLError(.networkConnectionLost))

        try await waitUntil("reconnect backoff requested") { sleeper.requestCount == 1 }
        XCTAssertEqual(factory.count, 1, "reconnect must not bypass its backoff")
        XCTAssertEqual(sleeper.requestedNanoseconds, [2_000_000_000])

        sleeper.releaseNext()
        try await waitUntil("socket created after backoff") { factory.count == 2 }
        await client.disconnect()
    }

    func testDisconnectDuringBackoffPreventsReconnect() async throws {
        let factory = MockSocketFactory()
        let sleeper = ControlledRuntimeSleeper()
        let client = makeClient(
            factory: factory,
            runtimeClock: sleeper.clock,
            baseReconnectDelay: 2
        )

        try await client.connect()
        try XCTUnwrap(factory[0]).failReceive(URLError(.networkConnectionLost))
        try await waitUntil("reconnect backoff requested") { sleeper.requestCount == 1 }

        await client.disconnect()
        sleeper.releaseNext()
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(factory.count, 1, "an intentional disconnect must cancel pending reconnects")
    }

    func testReconnectBackoffKeepsGrowingUntilTwitchResponds() async throws {
        let factory = MockSocketFactory()
        let sleeper = ControlledRuntimeSleeper()
        let client = makeClient(
            factory: factory,
            runtimeClock: sleeper.clock,
            baseReconnectDelay: 1
        )

        try await client.connect()
        try XCTUnwrap(factory[0]).failReceive(URLError(.networkConnectionLost))
        try await waitUntil("first reconnect wait") { sleeper.requestCount == 1 }
        sleeper.releaseNext()
        try await waitUntil("first replacement socket") { factory.count == 2 }

        // Merely creating/resuming a URLSession socket is not proof of a healthy Twitch
        // round-trip. With no RESPONSE/PONG/MESSAGE received, the next failure must back off.
        try XCTUnwrap(factory[1]).failReceive(URLError(.networkConnectionLost))
        try await waitUntil("second reconnect wait") { sleeper.requestCount == 2 }
        XCTAssertEqual(sleeper.requestedNanoseconds, [1_000_000_000, 2_000_000_000])

        await client.disconnect()
        sleeper.releaseNext()
    }

    // MARK: - Message delivery

    func testIncomingMessagesAreForwardedWithTopic() async throws {
        let factory = MockSocketFactory()
        let client = makeClient(factory: factory)
        let expectation = expectation(description: "message forwarded")
        await client.setMessageHandler { topic, _ in
            if topic == "user-drop-events.1" { expectation.fulfill() }
        }

        try await client.connect()
        try XCTUnwrap(factory[0]).push(
            #"{"type":"MESSAGE","data":{"topic":"user-drop-events.1","message":"{}"}}"#
        )

        await fulfillment(of: [expectation], timeout: 3)
        await client.disconnect()
    }

    func testIncomingMessagesAwaitHandlerAndPreserveSocketOrder() async throws {
        let factory = MockSocketFactory()
        let client = makeClient(factory: factory)
        let recorder = MessageRecorder()
        let firstStarted = expectation(description: "first handler started")
        let secondFinished = expectation(description: "second handler finished")

        await client.setMessageHandler { topic, _ in
            if topic == "user-drop-events.1" {
                firstStarted.fulfill()
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            recorder.append(topic)
            if topic == "user-drop-events.2" {
                secondFinished.fulfill()
            }
        }

        try await client.connect()
        let socket = try XCTUnwrap(factory[0])
        socket.push(#"{"type":"MESSAGE","data":{"topic":"user-drop-events.1","message":"{}"}}"#)
        socket.push(#"{"type":"MESSAGE","data":{"topic":"user-drop-events.2","message":"{}"}}"#)

        await fulfillment(of: [firstStarted], timeout: 3)
        XCTAssertFalse(recorder.values.contains("user-drop-events.2"))
        await fulfillment(of: [secondFinished], timeout: 3)
        XCTAssertEqual(recorder.values, ["user-drop-events.1", "user-drop-events.2"])
        await client.disconnect()
    }

    func testDisconnectCancelsSocketAndReportsState() async throws {
        let factory = MockSocketFactory()
        let recorder = ConnectionStateRecorder()
        let client = makeClient(factory: factory)
        await client.setConnectionStateHandler { recorder.record($0) }

        try await client.connect()
        await client.disconnect()

        XCTAssertEqual(recorder.states, [true, false])
        XCTAssertEqual(try XCTUnwrap(factory[0]).cancelled, true)
    }
}
