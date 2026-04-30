import Foundation
import SQLite3
import SwiftMinerCore

// MARK: - EventEmitterService

/// Emits the 4 projection-level events to `event_outbox` for delivery by `EventOutboxService`.
/// Stores the full schema-v2 event envelope in the payload column.
/// Call sites are responsible for determining when a projection state change has occurred.
public actor EventEmitterService {

    private let manager: SQLiteManager
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        return e
    }()

    public init(manager: SQLiteManager) {
        self.manager = manager
    }

    // MARK: - Projection event API

    /// Emit when the Discord user's projection `state` transitions.
    /// Idempotency key encodes both states and epoch, so repeated identical transitions don't re-fire.
    public func emitUserStateChanged(
        discordUserId: String,
        previousState: String,
        currentState: String,
        occurredAt: Date = Date()
    ) async {
        let epoch = Int(occurredAt.timeIntervalSince1970)
        let key = "user.stateChanged:discord:\(discordUserId):from:\(previousState):to:\(currentState):\(epoch)"
        await insert(envelope: makeEnvelope(
            eventType: "user.stateChanged",
            discordUserId: discordUserId,
            idempotencyKey: key,
            occurredAt: occurredAt,
            data: [
                "previousState": .string(previousState),
                "currentState": .string(currentState),
                "occurredAt": .string(iso8601(occurredAt))
            ]
        ))
    }

    /// Emit when the projection gains an actionable issue (e.g. account_not_linked).
    public func emitUserActionRequired(
        discordUserId: String,
        issueId: String,
        primaryIssueType: String,
        occurredAt: Date = Date()
    ) async {
        let key = "user.actionRequired:discord:\(discordUserId):issue:\(issueId)"
        await insert(envelope: makeEnvelope(
            eventType: "user.actionRequired",
            discordUserId: discordUserId,
            idempotencyKey: key,
            occurredAt: occurredAt,
            data: [
                "primaryIssueType": .string(primaryIssueType),
                "occurredAt": .string(iso8601(occurredAt))
            ]
        ))
    }

    /// Emit when a user-visible reward claim succeeds.
    public func emitUserDropClaimed(
        discordUserId: String,
        dropId: String,
        occurredAt: Date = Date()
    ) async {
        let key = "user.dropClaimed:discord:\(discordUserId):drop:\(dropId)"
        await insert(envelope: makeEnvelope(
            eventType: "user.dropClaimed",
            discordUserId: discordUserId,
            idempotencyKey: key,
            occurredAt: occurredAt,
            data: [
                "dropId": .string(dropId),
                "occurredAt": .string(iso8601(occurredAt))
            ]
        ))
    }

    /// Emit when the projection gains a meaningful campaign opportunity worth surfacing.
    public func emitUserOpportunityAvailable(
        discordUserId: String,
        campaignId: String,
        occurredAt: Date = Date()
    ) async {
        let key = "user.opportunityAvailable:discord:\(discordUserId):campaign:\(campaignId)"
        await insert(envelope: makeEnvelope(
            eventType: "user.opportunityAvailable",
            discordUserId: discordUserId,
            idempotencyKey: key,
            occurredAt: occurredAt,
            data: [
                "occurredAt": .string(iso8601(occurredAt))
            ]
        ))
    }

    // MARK: - Internal

    private func makeEnvelope(
        eventType: String,
        discordUserId: String,
        idempotencyKey: String,
        occurredAt: Date,
        data: [String: EventDataValue]
    ) -> EventEnvelope {
        EventEnvelope(
            eventId: "evt_\(UUID().uuidString)",
            eventType: eventType,
            occurredAt: iso8601(occurredAt),
            schemaVersion: 2,
            producer: "swiftminer",
            delivery: EventEnvelope.Delivery(idempotencyKey: idempotencyKey, attempt: 1),
            subject: EventEnvelope.Subject(discordUserId: discordUserId),
            data: data
        )
    }

    private func insert(envelope: EventEnvelope) async {
        guard let payloadData = try? encoder.encode(envelope),
              let payloadString = String(data: payloadData, encoding: .utf8) else { return }
        do {
            try await manager.execute { db in
                let sql = """
                INSERT OR IGNORE INTO event_outbox (id, event_type, payload, idempotency_key, status)
                VALUES (?, ?, ?, ?, 'pending');
                """
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_text(stmt, 1, envelope.eventId, -1, SQLITE_TRANSIENT_EMITTER)
                sqlite3_bind_text(stmt, 2, envelope.eventType, -1, SQLITE_TRANSIENT_EMITTER)
                sqlite3_bind_text(stmt, 3, payloadString, -1, SQLITE_TRANSIENT_EMITTER)
                sqlite3_bind_text(stmt, 4, envelope.delivery.idempotencyKey, -1, SQLITE_TRANSIENT_EMITTER)
                sqlite3_step(stmt)
            }
        } catch {}
    }

    private func iso8601(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

// MARK: - Event envelope types

/// Full schema-v2 event envelope stored in `event_outbox.payload` and POSTed verbatim to the webhook.
public struct EventEnvelope: Codable, Sendable {
    public let eventId: String
    public let eventType: String
    public let occurredAt: String
    public let schemaVersion: Int
    public let producer: String
    public let delivery: Delivery
    public let subject: Subject
    public let data: [String: EventDataValue]

    public struct Delivery: Codable, Sendable {
        public let idempotencyKey: String
        public let attempt: Int
    }

    public struct Subject: Codable, Sendable {
        public let discordUserId: String
    }
}

/// Typed JSON value for event `data` payloads. Covers all value types used by projection events.
public enum EventDataValue: Codable, Sendable, Equatable {
    case string(String)
    case int(Int)
    case bool(Bool)

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v):    try c.encode(v)
        case .bool(let v):   try c.encode(v)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self)   { self = .bool(v);   return }
        if let v = try? c.decode(Int.self)    { self = .int(v);    return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported EventDataValue type")
    }
}

private let SQLITE_TRANSIENT_EMITTER = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
