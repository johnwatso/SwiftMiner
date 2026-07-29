import Foundation

// MARK: - Event Types

/// Carries progress data received from a `drop-progress` PubSub event.
public struct DropProgressEvent: Sendable {
    /// The drop ID being earned
    public let dropId: String
    /// Minutes watched so far (server-authoritative)
    public let currentMinutes: Int
    /// Total minutes required for this drop
    public let requiredMinutes: Int
}

/// Carries claim data received from a `drop-claim` PubSub event.
public struct DropClaimEvent: Sendable {
    /// The drop instance ID to pass to the ClaimDrop GQL mutation
    public let dropInstanceId: String
    /// The drop definition ID
    public let dropId: String
    /// Channel ID where the drop was earned (may be empty if not provided)
    public let channelId: String
}

/// Carries stream state data from a `video-playback-by-id` PubSub topic.
public struct StreamStateEvent: Sendable {
    public enum Kind: Sendable {
        case up
        case down
        case viewcount(Int)
        case commercial(duration: Int)
    }

    public let channelId: String
    public let kind: Kind
}

// MARK: - Service

/// Routes Twitch PubSub events to typed callbacks.
///
/// **Responsibilities:**
/// - Subscribe / unsubscribe to `user-drop-events.<userId>` and
///   `video-playback-by-id.<channelId>` PubSub topics
/// - Parse the double-encoded JSON payloads Twitch sends
/// - Dispatch `drop-progress`, `drop-claim`, and stream-state events to callers
///
/// **Usage:**
/// ```swift
/// let service = DropEventsService(pubSubClient: pubSubClient)
/// await service.configure()   // wire up the onMessage callback
/// service.onDropProgress = { event in ... }
/// service.onDropClaim    = { event in ... }
/// service.onStreamDown   = { channelId in ... }
/// try await service.startWatching(userId: "123", channelId: "456")
/// ```
public actor DropEventsService {

    // MARK: - Callbacks (set before calling startWatching)

    /// Called when Twitch reports updated drop progress via PubSub.
    public var onDropProgress: (@Sendable (DropProgressEvent) async -> Void)?

    /// Called when Twitch signals a drop is claimable (`drop-claim` event).
    public var onDropClaim: (@Sendable (DropClaimEvent) async -> Void)?

    /// Called when the watched stream goes offline (`stream-down` event).
    public var onStreamDown: (@Sendable (String) async -> Void)?

    /// Called when any stream-state event arrives.
    public var onStreamState: (@Sendable (StreamStateEvent) -> Void)?

    // MARK: - Private state

    private let pubSubClient: PubSubClient
    private var subscribedUserId: String?
    private var subscribedChannelIds: Set<String> = []

    // MARK: - Init

    public init(pubSubClient: PubSubClient) {
        self.pubSubClient = pubSubClient
    }
    
    // MARK: - Callback Setters
    
    public func setDropProgressHandler(_ handler: (@Sendable (DropProgressEvent) async -> Void)?) {
        self.onDropProgress = handler
    }
    
    public func setDropClaimHandler(_ handler: (@Sendable (DropClaimEvent) async -> Void)?) {
        self.onDropClaim = handler
    }
    
    public func setStreamDownHandler(_ handler: (@Sendable (String) async -> Void)?) {
        self.onStreamDown = handler
    }
    
    public func setStreamStateHandler(_ handler: (@Sendable (StreamStateEvent) -> Void)?) {
        self.onStreamState = handler
    }

    /// Wire up the PubSubClient callback. Call this once after creating the service.
    /// Must be called from an async context before subscribing to any topics.
    public func configure() async {
        let service = self  // strong capture — actors are Sendable reference types
        await pubSubClient.setMessageHandler { @Sendable topic, payload in
            await service.handleMessage(topic: topic, payload: payload)
        }
    }

    // MARK: - Subscription management

    /// Subscribe to drop events for `userId` and stream state for `channelId`.
    public func startWatching(userId: String, channelId: String) async throws {
        let dropTopic   = "user-drop-events.\(userId)"
        let streamTopic = "video-playback-by-id.\(channelId)"

        try await pubSubClient.listen(to: [dropTopic, streamTopic])
        subscribedUserId = userId
        subscribedChannelIds.insert(channelId)
    }

    /// Stop tracking stream state for a specific channel.
    public func stopWatchingChannel(_ channelId: String) async throws {
        let topic = "video-playback-by-id.\(channelId)"
        try await pubSubClient.unlisten(from: [topic])
        subscribedChannelIds.remove(channelId)
    }

    /// Unsubscribe from all active topics.
    public func stopWatching() async throws {
        var topics: [String] = []
        if let uid = subscribedUserId { topics.append("user-drop-events.\(uid)") }
        for cid in subscribedChannelIds { topics.append("video-playback-by-id.\(cid)") }

        subscribedUserId = nil
        subscribedChannelIds = []

        guard !topics.isEmpty else { return }
        try await pubSubClient.unlisten(from: topics)
    }

    // MARK: - Message dispatch

    private func handleMessage(topic: String, payload: AnyJSONValue) async {
        // Twitch PubSub sends the inner event as a JSON-encoded string (double-encoded).
        let jsonString: String
        switch payload {
        case .string(let s):
            jsonString = s
        default:
            guard let data = try? JSONEncoder().encode(payload),
                  let str = String(data: data, encoding: .utf8) else { return }
            jsonString = str
        }

        guard
            let data = jsonString.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = json["type"] as? String
        else { return }

        if topic.hasPrefix("user-drop-events.") {
            await handleDropEvent(type: type, data: json["data"] as? [String: Any] ?? [:])
        } else if topic.hasPrefix("video-playback-by-id.") {
            let channelId = String(topic.dropFirst("video-playback-by-id.".count))
            await handleStreamEvent(type: type, channelId: channelId, json: json)
        }
    }

    // MARK: - Drop event parsing

    private func handleDropEvent(type: String, data: [String: Any]) async {
        switch type {
        case "drop-progress":
            let rawDropId = data["drop_id"]
            let rawCurrent = data["current_progress_min"]
            let rawRequired = data["required_progress_min"]
            guard
                let dropId = rawDropId as? String,
                let current = rawCurrent as? Int,
                let required = rawRequired as? Int
            else {
                tracePubSub(
                    "drop-progress parse-failed drop=\(String(describing: rawDropId)) " +
                    "rawCurrent=\(String(describing: rawCurrent)) rawRequired=\(String(describing: rawRequired))"
                )
                return
            }

            tracePubSub(
                "drop-progress parsed drop=\(dropId) rawCurrent=\(String(describing: rawCurrent)) " +
                "parsedCurrent=\(current) rawRequired=\(String(describing: rawRequired)) parsedRequired=\(required)"
            )

            await onDropProgress?(DropProgressEvent(
                dropId: dropId,
                currentMinutes: current,
                requiredMinutes: required
            ))

        case "drop-claim":
            // Twitch sends either snake_case or camelCase depending on client version
            let instanceId = (data["drop_instance_id"] ?? data["dropInstanceId"]) as? String ?? ""
            let dropId     = (data["drop_id"]           ?? data["dropId"])         as? String ?? ""
            let channelId  = (data["channel_id"]        ?? data["channelId"])      as? String ?? ""
            guard !instanceId.isEmpty else { return }

            await onDropClaim?(DropClaimEvent(
                dropInstanceId: instanceId,
                dropId: dropId,
                channelId: channelId
            ))

        default:
            break
        }
    }

    // MARK: - Stream state event parsing

    private func handleStreamEvent(type: String, channelId: String, json: [String: Any]) async {
        switch type {
        case "stream-up":
            onStreamState?(StreamStateEvent(channelId: channelId, kind: .up))

        case "stream-down":
            await onStreamDown?(channelId)
            onStreamState?(StreamStateEvent(channelId: channelId, kind: .down))

        case "viewcount":
            let viewers = json["viewers"] as? Int ?? 0
            onStreamState?(StreamStateEvent(channelId: channelId, kind: .viewcount(viewers)))

        case "commercial":
            let duration = json["length"] as? Int ?? 0
            onStreamState?(StreamStateEvent(channelId: channelId, kind: .commercial(duration: duration)))

        default:
            break
        }
    }
}
