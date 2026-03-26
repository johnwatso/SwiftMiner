import Foundation
import os.log

/// Debug tracer for logging protocol-level events.
/// Helps diagnose Twitch API changes and connection issues.
public actor DebugTracer {
    
    // MARK: - Types
    
    public enum EventType: String, Sendable, CaseIterable {
        case graphql = "[GraphQL]"
        case pubsub = "[PubSub]"
        case spade = "[Spade]"
        case claim = "[Claim]"
        case auth = "[Auth]"
        case network = "[Network]"
        case engine = "[Engine]"
        
        public var displayName: String { rawValue }
    }
    
    public struct TraceEvent: Identifiable, Sendable {
        public let id = UUID()
        public let timestamp: Date
        public let type: EventType
        public let message: String
        public let details: String?
        
        public init(type: EventType, message: String, details: String? = nil) {
            self.timestamp = Date()
            self.type = type
            self.message = message
            self.details = details
        }
        
        public var formatted: String {
            let time = ISO8601DateFormatter().string(from: timestamp)
            if let details = details {
                return "\(time) \(type.displayName) \(message) | \(details)"
            } else {
                return "\(time) \(type.displayName) \(message)"
            }
        }
    }
    
    // MARK: - Properties
    
    /// Whether debug tracing is enabled
    public var isEnabled: Bool = false
    
    /// Which event types to trace (nil = all)
    public var filteredTypes: Set<EventType>?
    
    /// Maximum number of events to keep in memory
    public var maxEvents: Int = 1000
    
    /// Callback for new trace events
    public var onEvent: (@Sendable (TraceEvent) -> Void)?
    
    /// History of recent events
    private var eventHistory: [TraceEvent] = []
    

    
    // MARK: - Shared Instance
    
    public static let shared = DebugTracer()
    
    // MARK: - Initialization
    
    private init() {}
    
    // MARK: - Tracing Methods
    
    /// Log a GraphQL request/response
    public func traceGraphQL(operation: String, variables: [String: Any]? = nil, response: String? = nil) {
        guard isEnabled, shouldTrace(.graphql) else { return }
        
        var details: [String] = []
        if let vars = variables {
            details.append("vars: \(vars)")
        }
        if let resp = response {
            details.append("resp: \(resp.prefix(200))")
        }
        
        let event = TraceEvent(
            type: .graphql,
            message: operation,
            details: details.isEmpty ? nil : details.joined(separator: " | ")
        )
        
        logEvent(event)
    }
    
    /// Log a PubSub message
    public func tracePubSub(topic: String, message: String) {
        guard isEnabled, shouldTrace(.pubsub) else { return }
        
        let event = TraceEvent(
            type: .pubsub,
            message: topic,
            details: String(message.prefix(500))
        )
        
        logEvent(event)
    }
    
    /// Log a Spade beacon
    public func traceSpade(channelId: String, broadcastId: String, payload: String) {
        guard isEnabled, shouldTrace(.spade) else { return }
        
        let event = TraceEvent(
            type: .spade,
            message: "minute-watched",
            details: "channel:\(channelId) broadcast:\(broadcastId) payload:\(payload.prefix(100))"
        )
        
        logEvent(event)
    }
    
    /// Log a drop claim
    public func traceClaim(dropInstanceId: String, status: String) {
        guard isEnabled, shouldTrace(.claim) else { return }
        
        let event = TraceEvent(
            type: .claim,
            message: "drop claimed",
            details: "instance:\(dropInstanceId) status:\(status)"
        )
        
        logEvent(event)
    }
    
    /// Log auth events
    public func traceAuth(message: String) {
        guard isEnabled, shouldTrace(.auth) else { return }
        
        let event = TraceEvent(
            type: .auth,
            message: message,
            details: nil
        )
        
        logEvent(event)
    }
    
    /// Log network events
    public func traceNetwork(method: String, url: String, statusCode: Int? = nil, error: String? = nil) {
        guard isEnabled, shouldTrace(.network) else { return }
        
        var details = ["\(method) \(url)"]
        if let code = statusCode {
            details.append("status:\(code)")
        }
        if let err = error {
            details.append("error:\(err)")
        }
        
        let event = TraceEvent(
            type: .network,
            message: "request",
            details: details.joined(separator: " ")
        )
        
        logEvent(event)
    }
    
    /// Log engine events
    public func traceEngine(message: String, details: String? = nil) {
        guard isEnabled, shouldTrace(.engine) else { return }
        
        let event = TraceEvent(
            type: .engine,
            message: message,
            details: details
        )
        
        logEvent(event)
    }
    
    // MARK: - Event History
    
    /// Get all events in history
    public func getHistory() -> [TraceEvent] {
        eventHistory
    }
    
    /// Get events filtered by type
    public func getHistory(type: EventType) -> [TraceEvent] {
        eventHistory.filter { $0.type == type }
    }
    
    /// Clear event history
    public func clearHistory() {
        eventHistory.removeAll()
    }

    /// Export history as formatted text
    public func exportHistory() -> String {
        eventHistory.map { $0.formatted }.joined(separator: "\n")
    }

    // MARK: - Control Methods

    /// Enable debug tracing
    public func enable() {
        isEnabled = true
    }

    /// Disable debug tracing
    public func disable() {
        isEnabled = false
    }

    /// Set the event handler
    public func setHandler(_ handler: (@Sendable (TraceEvent) -> Void)?) {
        self.onEvent = handler
    }
    
    // MARK: - Private Methods
    
    private func shouldTrace(_ type: EventType) -> Bool {
        guard let filtered = filteredTypes else { return true }
        return filtered.contains(type)
    }
    
    private func logEvent(_ event: TraceEvent) {
        // Add to history
        eventHistory.append(event)
        
        // Trim history if needed
        if eventHistory.count > maxEvents {
            eventHistory.removeFirst(eventHistory.count - maxEvents)
        }
        
        // Notify callback
        onEvent?(event)
    }
}

// MARK: - Extensions for Easy Tracing

public extension TwitchAPIClient {
    /// Enable debug tracing for this client
    func enableDebugTracing() async {
        await DebugTracer.shared.traceEngine(message: "API Client initialized")
    }
}

public extension PubSubClient {
    /// Enable debug tracing for this client
    func enableDebugTracing() {
        setDebugLogHandler { message in
            Task {
                await DebugTracer.shared.traceEngine(message: message)
            }
        }
    }
}
