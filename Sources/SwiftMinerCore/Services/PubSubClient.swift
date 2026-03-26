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
    
    public init(type: PubSubMessageType, nonce: String? = nil, data: [String: AnyJSONValue]? = nil) {
        self.type = type
        self.nonce = nonce
        self.data = data
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

/// Client for Twitch PubSub (WebSocket)
public actor PubSubClient: NSObject {
    private let url = URL(string: "wss://pubsub-edge.twitch.tv/v1")!
    private var webSocketTask: URLSessionWebSocketTask?
    private var isConnected = false
    private var activeTopics: Set<String> = []
    private var accessToken: String?
    
    private let maxTopicsPerConnection = 50
    private let pingInterval: TimeInterval = 180 // 3 minutes
    private let pongTimeout: TimeInterval = 10 // 10 seconds
    
    // Exponential backoff for reconnects
    private var reconnectAttempt = 0
    private let maxReconnectDelay: TimeInterval = 60 // Max 60 seconds between attempts
    private let baseReconnectDelay: TimeInterval = 1 // Start with 1 second
    
    private var pingTask: Task<Void, Never>?
    private var listenTask: Task<Void, Never>?
    private var pongTimeoutTask: Task<Void, Never>?
    
    /// Delegate for handling received messages
    public var onMessage: (@Sendable (String, AnyJSONValue) -> Void)?
    
    /// Callback for connection state changes
    public var onConnectionStateChange: (@Sendable (Bool) -> Void)?
    
    /// Callback for debug logging
    public var onDebugLog: (@Sendable (String) -> Void)?

    /// Actor-safe setter for the message handler (use this from other actors).
    public func setMessageHandler(_ handler: @Sendable @escaping (String, AnyJSONValue) -> Void) {
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
        self.accessToken = accessToken
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

        let session = URLSession(configuration: .default)
        webSocketTask = session.webSocketTask(with: url)
        webSocketTask?.resume()

        isConnected = true
        reconnectAttempt = 0 // Reset reconnect counter on successful connect
        onConnectionStateChange?(true)

        startListening()
        startPingLoop()

        log("PubSub connected")
    }

    /// Disconnect from the PubSub server
    public func disconnect() async {
        log("Disconnecting from PubSub...")

        pingTask?.cancel()
        pingTask = nil
        listenTask?.cancel()
        listenTask = nil
        pongTimeoutTask?.cancel()
        pongTimeoutTask = nil

        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false

        onConnectionStateChange?(false)
        log("PubSub disconnected")
    }

    /// Subscribe to topics
    /// - Parameter topics: List of topics to listen to (e.g. ["user-drop-events.123"])
    public func listen(to topics: [String]) async throws {
        guard isConnected else {
            log("ERROR: Cannot listen - not connected")
            throw PubSubError.notConnected
        }

        // Filter out already active topics
        let newTopics = topics.filter { !activeTopics.contains($0) }
        guard !newTopics.isEmpty else { return }

        // Check topic limits
        if activeTopics.count + newTopics.count > maxTopicsPerConnection {
            throw PubSubError.tooManyTopics
        }

        let nonce = UUID().uuidString
        let data: [String: AnyJSONValue] = [
            "topics": .array(newTopics.map { .string($0) }),
            "auth_token": .string(accessToken ?? "")
        ]

        let message = PubSubMessage(type: .listen, nonce: nonce, data: data)
        try await sendMessage(message)

        // Add to active topics
        activeTopics.formUnion(newTopics)
        log("[PubSub] Subscribed to topics: \(newTopics.joined(separator: ", "))")
    }

    /// Unsubscribe from topics
    public func unlisten(from topics: [String]) async throws {
        guard isConnected else { throw PubSubError.notConnected }

        let nonce = UUID().uuidString
        let data: [String: AnyJSONValue] = [
            "topics": .array(topics.map { .string($0) })
        ]

        let message = PubSubMessage(type: .unlisten, nonce: nonce, data: data)
        try await sendMessage(message)

        // Remove from active topics
        for topic in topics {
            activeTopics.remove(topic)
        }
        log("[PubSub] Unsubscribed from topics: \(topics.joined(separator: ", "))")
    }
    
    /// Get currently active topics
    public var currentTopics: [String] {
        Array(activeTopics)
    }
    
    // MARK: - Private Methods

    private func log(_ message: String) {
        onDebugLog?("[PubSub] \(message)")
    }
    
    private func sendMessage(_ message: PubSubMessage) async throws {
        guard let webSocketTask = webSocketTask else { throw PubSubError.notConnected }
        
        let encoder = JSONEncoder()
        do {
            let data = try encoder.encode(message)
            let string = String(data: data, encoding: .utf8)!
            try await webSocketTask.send(.string(string))
        } catch {
            throw PubSubError.messageEncodingFailed(error)
        }
    }
    
    private func startListening() {
        listenTask = Task {
            while !Task.isCancelled {
                do {
                    guard let message = try await webSocketTask?.receive() else {
                        log("WebSocket receive returned nil")
                        break
                    }

                    switch message {
                    case .string(let text):
                        await handleReceivedText(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            await handleReceivedText(text)
                        }
                    @unknown default:
                        break
                    }
                } catch {
                    log("WebSocket error: \(error.localizedDescription)")
                    await handleConnectionError(error)
                    break
                }
            }
        }
    }

    private func handleReceivedText(_ text: String) async {
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
                log("[PubSub] PONG received")

            case .reconnect:
                // Server requested reconnect
                log("[PubSub] Server requested RECONNECT")
                await reconnectWithBackoff()

            case .message:
                if let data = message.data,
                   case .string(let topic) = data["topic"],
                   let payload = data["message"] {
                    // Forward message to listener
                    onMessage?(topic, payload)
                }
            default:
                break
            }
        } catch {
            // Ignore decoding errors for unknown messages
        }
    }

    private func startPingLoop() {
        pingTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(pingInterval * 1_000_000_000))
                    if Task.isCancelled { break }

                    log("[PubSub] → PING")
                    try await sendMessage(PubSubMessage(type: .ping))

                    // Start PONG timeout
                    startPongTimeout()

                } catch {
                    log("PING failed: \(error.localizedDescription)")
                    await handleConnectionError(error)
                    break
                }
            }
        }
    }

    private func startPongTimeout() {
        pongTimeoutTask?.cancel()
        pongTimeoutTask = Task {
            do {
                try await Task.sleep(nanoseconds: UInt64(pongTimeout * 1_000_000_000))
                // If we reach here, PONG was not received in time
                if !Task.isCancelled {
                    log("[PubSub] PONG timeout!")
                    await handleConnectionError(PubSubError.pongTimeout)
                }
            } catch {
                // Task was cancelled (PONG received)
            }
        }
    }
    
    private func handleConnectionError(_ error: Error) async {
        guard isConnected else { return }
        
        isConnected = false
        onConnectionStateChange?(false)
        
        // Attempt reconnect with exponential backoff
        await reconnectWithBackoff()
    }
    
    private func reconnectWithBackoff() async {
        // Calculate backoff delay: min(2^attempt * base, max)
        let delay = min(pow(2.0, Double(reconnectAttempt)) * baseReconnectDelay, maxReconnectDelay)
        reconnectAttempt += 1

        log("[PubSub] Reconnecting in \(Int(delay))s (attempt #\(reconnectAttempt))...")

        // Clean up current connection
        pingTask?.cancel()
        pingTask = nil
        listenTask?.cancel()
        listenTask = nil
        pongTimeoutTask?.cancel()
        pongTimeoutTask = nil

        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil

        // Wait before reconnecting
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))

        // Attempt reconnect
        let reconnectSession = URLSession(configuration: .default)
        webSocketTask = reconnectSession.webSocketTask(with: url)
        webSocketTask?.resume()

        isConnected = true
        onConnectionStateChange?(true)

        startListening()
        startPingLoop()

        // Re-subscribe to topics
        let topics = Array(activeTopics)
        if !topics.isEmpty {
            try? await listen(to: topics)
        }

        reconnectAttempt = 0
        log("[PubSub] Reconnected successfully")
    }
}
