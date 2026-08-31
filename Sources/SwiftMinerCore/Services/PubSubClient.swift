import Foundation

/// Errors related to PubSub (WebSocket) operations
public enum PubSubError: LocalizedError {
    case connectionFailed(Error)
    case messageEncodingFailed(Error)
    case messageDecodingFailed(Error)
    case notConnected
    case tooManyTopics
    case connectionClosed(URLSessionWebSocketTask.CloseCode, String?)
    case pongTimeout
    case topicRequestRejected(String)
    case topicResponseTimedOut
    
    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let error):
            return "PubSub connection failed: \(error.localizedDescription)"
        case .messageEncodingFailed(let error):
            return "Failed to encode message: \(error.localizedDescription)"
        case .messageDecodingFailed(let error):
            return "Failed to decode message: \(error.localizedDescription)"
        case .notConnected:
            return "Not connected to PubSub"
        case .tooManyTopics:
            return "Maximum number of topics reached for this connection"
        case .connectionClosed(let code, let reason):
            return "Connection closed with code \(code.rawValue) and reason: \(reason ?? "none")"
        case .pongTimeout:
            return "PONG timeout - server not responding"
        case .topicRequestRejected(let message):
            return "Twitch rejected the PubSub subscription request: \(message)"
        case .topicResponseTimedOut:
            return "Twitch did not acknowledge the PubSub subscription request in time"
        }
    }
}

/// PubSub message types
public enum PubSubMessageType: String, Codable, Sendable {
    case listen = "LISTEN"
    case unlisten = "UNLISTEN"
    case ping = "PING"
    case pong = "PONG"
    case message = "MESSAGE"
    case response = "RESPONSE"
    case reconnect = "RECONNECT"
}

/// Base structure for PubSub messages
public struct PubSubMessage: Codable, Sendable {
    public let type: PubSubMessageType
    public let nonce: String?
    public let data: [String: AnyJSONValue]?
    public let error: String?
    
    public init(
        type: PubSubMessageType,
        nonce: String? = nil,
        data: [String: AnyJSONValue]? = nil,
        error: String? = nil
    ) {
        self.type = type
        self.nonce = nonce
        self.data = data
        self.error = error
    }
}

/// AnyJSONValue for handling heterogeneous JSON in Codable
public enum AnyJSONValue: Codable, Sendable, Equatable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: AnyJSONValue])
    case array([AnyJSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let x = try? container.decode(String.self) {
            self = .string(x)
        } else if let x = try? container.decode(Double.self) {
            self = .number(x)
        } else if let x = try? container.decode(Bool.self) {
            self = .bool(x)
        } else if let x = try? container.decode([String: AnyJSONValue].self) {
            self = .object(x)
        } else if let x = try? container.decode([AnyJSONValue].self) {
            self = .array(x)
        } else if container.decodeNil() {
            self = .null
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Wrong type for AnyJSONValue")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let x): try container.encode(x)
        case .number(let x): try container.encode(x)
        case .bool(let x): try container.encode(x)
        case .object(let x): try container.encode(x)
        case .array(let x): try container.encode(x)
        case .null: try container.encodeNil()
        }
    }
}

/// Seam over the underlying WebSocket so reconnect behaviour is testable.
protocol PubSubSocket: Sendable {
    func resume()
    func send(_ text: String) async throws
    /// Next text frame; data frames are decoded as UTF-8, other frame kinds return nil.
    func receive() async throws -> String?
    func cancel()
}

typealias PubSubSocketFactory = @Sendable (URL) -> any PubSubSocket

final class URLSessionPubSubSocket: PubSubSocket, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(url: URL) {
        task = URLSession(configuration: .default).webSocketTask(with: url)
    }

    func resume() {
        task.resume()
    }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func receive() async throws -> String? {
        switch try await task.receive() {
        case .string(let text):
            return text
        case .data(let data):
            return String(data: data, encoding: .utf8)
        @unknown default:
            return nil
        }
    }

    func cancel() {
        task.cancel(with: .goingAway, reason: nil)
    }
}

/// Client for Twitch PubSub (WebSocket)
public actor PubSubClient: NSObject {
    private let url = URL(string: "wss://pubsub-edge.twitch.tv/v1")!
    private let socketFactory: PubSubSocketFactory
    private var socket: (any PubSubSocket)?
    private var isConnected = false
    /// Topics the caller wants to remain subscribed to across socket reconnects.
    private var activeTopics: Set<String> = []
    /// Topics submitted on the current socket. This is cleared whenever the socket changes.
    private var submittedTopics: Set<String> = []
    private var accessToken: String?

    private let maxTopicsPerConnection = 50
    static let topicBatchSize = 20
    private let pingInterval: TimeInterval
    private let pongTimeout: TimeInterval
    private let topicResponseTimeout: TimeInterval
    private let runtimeClock: RuntimeClock
    private let reconnectJitterFactor: @Sendable () -> Double

    // Exponential backoff for reconnects
    private var reconnectAttempt = 0
    private let maxReconnectDelay: TimeInterval
    private let baseReconnectDelay: TimeInterval
    
    private var pingTask: Task<Void, Never>?
    private var listenTask: Task<Void, Never>?
    private var pongTimeoutTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var shouldRemainConnected = false
    private var connectionGeneration: UInt64 = 0
    private var pendingTopicResponses: [String: (
        generation: UInt64,
        continuation: CheckedContinuation<Void, Error>
    )] = [:]
    private var topicResponseTimeoutTasks: [String: Task<Void, Never>] = [:]
    
    /// Delegate for handling received messages
    /// Awaited so a consumer can preserve WebSocket delivery order without spawning one
    /// unstructured task per message.
    public var onMessage: (@Sendable (String, AnyJSONValue) async -> Void)?
    
    /// Callback for connection state changes
    public var onConnectionStateChange: (@Sendable (Bool) -> Void)?
    
    /// Callback for debug logging
    public var onDebugLog: (@Sendable (String) -> Void)?

    /// Actor-safe setter for the message handler (use this from other actors).
    public func setMessageHandler(_ handler: @Sendable @escaping (String, AnyJSONValue) async -> Void) {
        onMessage = handler
    }
    
    /// Actor-safe setter for connection state changes
    public func setConnectionStateHandler(_ handler: @Sendable @escaping (Bool) -> Void) {
        onConnectionStateChange = handler
    }
    
    /// Actor-safe setter for debug logging
    public func setDebugLogHandler(_ handler: @Sendable @escaping (String) -> Void) {
        onDebugLog = handler
    }

    public init(accessToken: String? = nil) {
        self.init(
            accessToken: accessToken,
            socketFactory: { URLSessionPubSubSocket(url: $0) }
        )
    }

    /// Test seam: inject the socket implementation and timing. Production code
    /// uses the public initializer, which keeps Twitch's real intervals.
    init(
        accessToken: String? = nil,
        socketFactory: @escaping PubSubSocketFactory,
        pingInterval: TimeInterval = 180, // 3 minutes
        pongTimeout: TimeInterval = 10,
        topicResponseTimeout: TimeInterval = 15,
        baseReconnectDelay: TimeInterval = 1,
        maxReconnectDelay: TimeInterval = 60,
        runtimeClock: RuntimeClock = .continuous,
        reconnectJitterFactor: @escaping @Sendable () -> Double = { Double.random(in: 0.8...1.2) }
    ) {
        self.accessToken = accessToken
        self.socketFactory = socketFactory
        self.pingInterval = pingInterval
        self.pongTimeout = pongTimeout
        self.topicResponseTimeout = topicResponseTimeout
        self.baseReconnectDelay = baseReconnectDelay
        self.maxReconnectDelay = maxReconnectDelay
        self.runtimeClock = runtimeClock
        self.reconnectJitterFactor = reconnectJitterFactor
        super.init()
    }
    
    /// Update the access token for authenticated requests
    public func updateAccessToken(_ token: String) {
        self.accessToken = token
    }
    
    /// Connect to the PubSub server
    public func connect() async throws {
        guard !isConnected else { 
            log("Already connected, skipping connect()")
            return
        }

        log("Connecting to PubSub...")
        shouldRemainConnected = true
        reconnectTask?.cancel()
        reconnectTask = nil

        do {
            try await establishConnection()
            reconnectAttempt = 0
        } catch {
            shouldRemainConnected = false
            throw error
        }

        log("PubSub connected")
    }

    /// Disconnect from the PubSub server
    public func disconnect() async {
        log("Disconnecting from PubSub...")
        shouldRemainConnected = false
        reconnectTask?.cancel()
        reconnectTask = nil
        connectionGeneration &+= 1
        tearDownSocket(reportDisconnected: true)
        log("PubSub disconnected")
    }

    /// Subscribe to topics
    /// - Parameter topics: List of topics to listen to (e.g. ["user-drop-events.123"])
    public func listen(to topics: [String]) async throws {
        guard isConnected else {
            log("ERROR: Cannot listen - not connected")
            throw PubSubError.notConnected
        }

        let requestedTopics = Set(topics)
        let newTopics = requestedTopics.subtracting(activeTopics)

        // Check topic limits
        if activeTopics.count + newTopics.count > maxTopicsPerConnection {
            throw PubSubError.tooManyTopics
        }

        // Record intent before sending. If a send fails, these topics remain queued and
        // will be replayed on the next socket instead of being silently lost.
        activeTopics.formUnion(newTopics)
        do {
            try await submitPendingSubscriptions()
        } catch {
            // The caller must not believe a rejected new subscription is active. Existing
            // desired topics remain intact and will still be restored on the replacement socket.
            activeTopics.subtract(newTopics)
            requestReconnect(generation: connectionGeneration)
            throw error
        }
    }

    /// Unsubscribe from topics
    public func unlisten(from topics: [String]) async throws {
        let requestedTopics = Set(topics)
        activeTopics.subtract(requestedTopics)

        let topicsOnCurrentSocket = requestedTopics.intersection(submittedTopics)
        guard !topicsOnCurrentSocket.isEmpty else { return }

        guard isConnected else {
            submittedTopics.subtract(topicsOnCurrentSocket)
            return
        }

        do {
            for batch in Self.topicBatches(Array(topicsOnCurrentSocket)) {
                try await sendTopicRequest(
                    type: .unlisten,
                    topics: batch,
                    generation: connectionGeneration
                )
                submittedTopics.subtract(batch)
                log("Unsubscribed from topics: \(batch.joined(separator: ", "))")
            }
        } catch {
            requestReconnect(generation: connectionGeneration)
            throw error
        }
    }
    
    /// Get currently active topics
    public var currentTopics: [String] {
        Array(activeTopics)
    }

    /// Twitch permits 50 topics per connection, but LISTEN/UNLISTEN messages are kept
    /// smaller and deterministic so reconnect restoration cannot exceed frame limits.
    static func topicBatches(_ topics: [String], batchSize: Int = topicBatchSize) -> [[String]] {
        guard batchSize > 0 else { return [] }
        let ordered = Array(Set(topics)).sorted()
        return stride(from: 0, to: ordered.count, by: batchSize).map { start in
            Array(ordered[start..<min(start + batchSize, ordered.count)])
        }
    }

    static func pendingTopicSubscriptions(
        desired: Set<String>,
        submitted: Set<String>
    ) -> [String] {
        Array(desired.subtracting(submitted)).sorted()
    }
    
    // MARK: - Private Methods

    private func log(_ message: String) {
        onDebugLog?("[PubSub] \(message)")
    }
    
    private func sendMessage(_ message: PubSubMessage) async throws {
        guard let socket else { throw PubSubError.notConnected }
        
        let encoder = JSONEncoder()
        do {
            let data = try encoder.encode(message)
            let string = String(data: data, encoding: .utf8)!
            try await socket.send(string)
        } catch {
            throw PubSubError.messageEncodingFailed(error)
        }
    }

    private func topicMessage(type: PubSubMessageType, topics: [String]) -> PubSubMessage {
        let data: [String: AnyJSONValue] = [
            "topics": .array(topics.map { .string($0) }),
            "auth_token": .string(accessToken ?? "")
        ]
        return PubSubMessage(type: type, nonce: UUID().uuidString, data: data)
    }

    /// Sends a LISTEN/UNLISTEN only after registering its nonce, then waits until Twitch
    /// explicitly accepts or rejects it. Registering first closes the race where a fast
    /// RESPONSE arrives while the socket send is still suspended.
    private func sendTopicRequest(
        type: PubSubMessageType,
        topics: [String],
        generation: UInt64
    ) async throws {
        let message = topicMessage(type: type, topics: topics)
        guard let nonce = message.nonce else {
            throw PubSubError.topicRequestRejected("SwiftMiner generated a topic request without a nonce")
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingTopicResponses[nonce] = (generation, continuation)

                let clock = runtimeClock
                let timeout = topicResponseTimeout
                topicResponseTimeoutTasks[nonce] = Task { [weak self] in
                    do {
                        try await clock.sleep(nanoseconds: RuntimeClock.nanoseconds(timeout))
                    } catch {
                        return
                    }
                    await self?.completeTopicResponse(
                        nonce: nonce,
                        generation: generation,
                        error: PubSubError.topicResponseTimedOut
                    )
                }

                Task { [weak self] in
                    await self?.transmitTopicRequest(
                        message,
                        nonce: nonce,
                        generation: generation
                    )
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.completeTopicResponse(
                    nonce: nonce,
                    generation: generation,
                    error: CancellationError()
                )
            }
        }
    }

    private func transmitTopicRequest(
        _ message: PubSubMessage,
        nonce: String,
        generation: UInt64
    ) async {
        guard generation == connectionGeneration, pendingTopicResponses[nonce] != nil else { return }
        do {
            try await sendMessage(message)
        } catch {
            completeTopicResponse(nonce: nonce, generation: generation, error: error)
        }
    }

    private func completeTopicResponse(
        nonce: String,
        generation: UInt64,
        error: Error?
    ) {
        guard let pending = pendingTopicResponses[nonce], pending.generation == generation else { return }
        pendingTopicResponses[nonce] = nil
        topicResponseTimeoutTasks.removeValue(forKey: nonce)?.cancel()
        if let error {
            pending.continuation.resume(throwing: error)
        } else {
            pending.continuation.resume()
        }
    }

    private func failAllPendingTopicResponses(with error: Error) {
        let pending = Array(pendingTopicResponses.values)
        pendingTopicResponses.removeAll()
        for task in topicResponseTimeoutTasks.values { task.cancel() }
        topicResponseTimeoutTasks.removeAll()
        for response in pending { response.continuation.resume(throwing: error) }
    }

    private func submitPendingSubscriptions() async throws {
        let pending = Self.pendingTopicSubscriptions(
            desired: activeTopics,
            submitted: submittedTopics
        )

        for batch in Self.topicBatches(pending) {
            try await sendTopicRequest(
                type: .listen,
                topics: batch,
                generation: connectionGeneration
            )
            submittedTopics.formUnion(batch)
            log("Subscribed to topics: \(batch.joined(separator: ", "))")
        }
    }
    
    private func establishConnection() async throws {
        tearDownSocket(reportDisconnected: false)
        connectionGeneration &+= 1
        let generation = connectionGeneration

        let newSocket = socketFactory(url)
        socket = newSocket
        newSocket.resume()
        isConnected = true

        startListening(generation: generation)
        startPingLoop(generation: generation)

        do {
            // A caller may reconnect this client without rebuilding its desired topic list.
            try await submitPendingSubscriptions()
        } catch {
            tearDownSocket(reportDisconnected: false)
            throw error
        }

        onConnectionStateChange?(true)
    }

    private func tearDownSocket(reportDisconnected: Bool) {
        let wasConnected = isConnected
        pingTask?.cancel()
        pingTask = nil
        listenTask?.cancel()
        listenTask = nil
        pongTimeoutTask?.cancel()
        pongTimeoutTask = nil
        failAllPendingTopicResponses(with: PubSubError.notConnected)
        socket?.cancel()
        socket = nil
        isConnected = false
        submittedTopics.removeAll()

        if reportDisconnected && wasConnected {
            onConnectionStateChange?(false)
        }
    }

    private func startListening(generation: UInt64) {
        listenTask = Task {
            while !Task.isCancelled {
                do {
                    guard let socket else {
                        log("WebSocket receive with no socket")
                        break
                    }
                    if let text = try await socket.receive() {
                        guard generation == connectionGeneration else { break }
                        await handleReceivedText(text, generation: generation)
                    }
                } catch {
                    // A cancelled loop belongs to a socket that was already torn
                    // down (reconnect or disconnect). Treating its wakeup as a
                    // connection error caused cascading spurious reconnects.
                    if Task.isCancelled || error is CancellationError
                        || (error as? URLError)?.code == .cancelled {
                        break
                    }
                    log("WebSocket error: \(error.localizedDescription)")
                    await handleConnectionError(error, generation: generation)
                    break
                }
            }
        }
    }

    private func handleReceivedText(_ text: String, generation: UInt64) async {
        guard generation == connectionGeneration else { return }
        log("[PubSub] ← \(text.prefix(200))")

        guard let data = text.data(using: .utf8) else { return }

        do {
            let decoder = JSONDecoder()
            let message = try decoder.decode(PubSubMessage.self, from: data)

            switch message.type {
            case .pong:
                // Cancel pong timeout
                pongTimeoutTask?.cancel()
                pongTimeoutTask = nil
                reconnectAttempt = 0
                log("[PubSub] PONG received")

            case .reconnect:
                // Server requested reconnect
                log("[PubSub] Server requested RECONNECT")
                requestReconnect(generation: generation)

            case .message:
                reconnectAttempt = 0
                if let data = message.data,
                   case .string(let topic) = data["topic"],
                   let payload = data["message"] {
                    // Forward message to listener
                    await onMessage?(topic, payload)
                }
            case .response:
                guard let nonce = message.nonce else {
                    log("PubSub RESPONSE omitted its nonce")
                    return
                }
                let responseError = message.error?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if responseError.isEmpty {
                    completeTopicResponse(nonce: nonce, generation: generation, error: nil)
                    // Only an accepted request proves the replacement socket is healthy.
                    reconnectAttempt = 0
                } else {
                    log("PubSub topic request rejected: \(responseError)")
                    completeTopicResponse(
                        nonce: nonce,
                        generation: generation,
                        error: PubSubError.topicRequestRejected(responseError)
                    )
                }
            default:
                break
            }
        } catch {
            // Ignore decoding errors for unknown messages
        }
    }

    private func startPingLoop(generation: UInt64) {
        pingTask = Task {
            while !Task.isCancelled {
                do {
                    try await runtimeClock.sleep(nanoseconds: UInt64(pingInterval * 1_000_000_000))
                    if Task.isCancelled || generation != connectionGeneration { break }

                    log("[PubSub] → PING")
                    try await sendMessage(PubSubMessage(type: .ping))

                    // Start PONG timeout
                    startPongTimeout(generation: generation)

                } catch {
                    // See the listen loop: a cancelled sleep is teardown, not a
                    // connection failure.
                    if Task.isCancelled || error is CancellationError
                        || (error as? URLError)?.code == .cancelled {
                        break
                    }
                    log("PING failed: \(error.localizedDescription)")
                    await handleConnectionError(error, generation: generation)
                    break
                }
            }
        }
    }

    private func startPongTimeout(generation: UInt64) {
        pongTimeoutTask?.cancel()
        pongTimeoutTask = Task {
            do {
                try await runtimeClock.sleep(nanoseconds: UInt64(pongTimeout * 1_000_000_000))
                // If we reach here, PONG was not received in time
                if !Task.isCancelled && generation == connectionGeneration {
                    log("[PubSub] PONG timeout!")
                    await handleConnectionError(PubSubError.pongTimeout, generation: generation)
                }
            } catch {
                // Task was cancelled (PONG received)
            }
        }
    }
    
    private func handleConnectionError(_ error: Error, generation: UInt64) async {
        guard generation == connectionGeneration, isConnected else { return }
        requestReconnect(generation: generation)
    }

    private func requestReconnect(generation: UInt64) {
        guard shouldRemainConnected, generation == connectionGeneration else { return }
        tearDownSocket(reportDisconnected: true)
        guard reconnectTask == nil else { return }

        reconnectTask = Task { [weak self] in
            await self?.runReconnectLoop()
        }
    }

    private func runReconnectLoop() async {
        while shouldRemainConnected && !Task.isCancelled {
            let baseDelay = min(
                pow(2.0, Double(reconnectAttempt)) * baseReconnectDelay,
                maxReconnectDelay
            )
            reconnectAttempt += 1
            let jitter = min(1.2, max(0.8, reconnectJitterFactor()))
            let delay = baseDelay * jitter
            log("[PubSub] Reconnecting in \(String(format: "%.1f", delay))s (attempt #\(reconnectAttempt))...")

            do {
                try await runtimeClock.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                reconnectTask = nil
                return
            }

            guard shouldRemainConnected, !Task.isCancelled else {
                reconnectTask = nil
                return
            }

            do {
                try await establishConnection()
                reconnectTask = nil
                log("[PubSub] Reconnected successfully")
                return
            } catch {
                log("Could not restore PubSub connection: \(error.localizedDescription)")
            }
        }

        reconnectTask = nil
    }
}
