import Foundation
import SQLite3
import SwiftMinerCore

// MARK: - EventEmitterService

/// Emits projection and SwiftMiner-level events to `event_outbox` for delivery by `EventOutboxService`.
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

    /// Emit when an operator requests SwiftBot drive a reauthentication flow for the user.
    /// Idempotency key folds the epoch second so repeated clicks within the same second collapse,
    /// but a user can re-request later if the first attempt failed.
    public func emitUserReauthRequested(
        discordUserId: String,
        twitchAccountId: String,
        occurredAt: Date = Date()
    ) async {
        let epoch = Int(occurredAt.timeIntervalSince1970)
        let key = "user.reauth_requested:discord:\(discordUserId):twitch:\(twitchAccountId):\(epoch)"
        await insert(envelope: makeEnvelope(
            eventType: "user.reauth_requested",
            discordUserId: discordUserId,
            idempotencyKey: key,
            occurredAt: occurredAt,
            data: [
                "twitchAccountId": .string(twitchAccountId),
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

    /// Emit when SwiftMiner discovers a new Twitch Drops campaign that should be
    /// announced in the configured server channel by SwiftBot.
    public func emitSwiftMinerCampaignAnnounced(
        campaign: Campaign,
        occurredAt: Date = Date()
    ) async {
        let artwork = campaign.drops
            .compactMap { drop -> EventDataValue? in
                let imageURL = drop.imageURL ?? drop.reward?.imageURL
                guard let imageURL else { return nil }
                return .object([
                    "dropId": .string(drop.id),
                    "name": .string(drop.name),
                    "imageURL": .string(imageURL.absoluteString)
                ])
            }
            .prefix(3)
            .map { $0 }

        var data: [String: EventDataValue] = [
            "campaignId": .string(campaign.id),
            "campaignName": .string(campaign.name),
            "gameId": .string(campaign.game.id),
            "gameName": .string(campaign.game.name),
            "status": .string(campaign.status.rawValue),
            "startsAt": .string(iso8601(campaign.startDate)),
            "endsAt": .string(iso8601(campaign.endDate)),
            "dropCount": .int(campaign.drops.count),
            "dropArtwork": .array(Array(artwork)),
            "occurredAt": .string(iso8601(occurredAt))
        ]
        if let gameArtworkURL = campaign.game.boxArtURL?.absoluteString {
            data["gameArtworkURL"] = .string(gameArtworkURL)
        }

        let key = "swiftminer.campaignAnnounced:campaign:\(campaign.id)"
        await insert(envelope: makeEnvelope(
            eventType: "swiftminer.campaignAnnounced",
            discordUserId: "swiftminer",
            idempotencyKey: key,
            occurredAt: occurredAt,
            data: data
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
        let payloadString: String
        do {
            let payloadData = try encoder.encode(envelope)
            guard let encoded = String(data: payloadData, encoding: .utf8) else {
                Logger.storage.error("Could not encode outbox event \(envelope.eventType) as UTF-8")
                return
            }
            payloadString = encoded
        } catch {
            Logger.storage.error("Could not encode outbox event \(envelope.eventType): \(error.localizedDescription)")
            return
        }
        do {
            let inserted = try await manager.execute { db in
                let sql = """
                INSERT OR IGNORE INTO event_outbox (id, event_type, payload, idempotency_key, status)
                VALUES (?, ?, ?, ?, 'pending');
                """
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                    throw eventEmitterSQLiteError(db, operation: "prepare outbox insert")
                }
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_text(stmt, 1, envelope.eventId, -1, SQLITE_TRANSIENT_EMITTER)
                sqlite3_bind_text(stmt, 2, envelope.eventType, -1, SQLITE_TRANSIENT_EMITTER)
                sqlite3_bind_text(stmt, 3, payloadString, -1, SQLITE_TRANSIENT_EMITTER)
                sqlite3_bind_text(stmt, 4, envelope.delivery.idempotencyKey, -1, SQLITE_TRANSIENT_EMITTER)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw eventEmitterSQLiteError(db, operation: "insert outbox event")
                }
                return sqlite3_changes(db) > 0
            }
            if inserted {
                NotificationCenter.default.post(name: EventOutboxService.eventEnqueued, object: manager)
            }
        } catch {
            Logger.storage.error("Failed to persist outbox event \(envelope.eventType): \(error.localizedDescription)")
        }
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
    case array([EventDataValue])
    case object([String: EventDataValue])

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .int(let v):    try c.encode(v)
        case .bool(let v):   try c.encode(v)
        case .array(let v):  try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Bool.self)   { self = .bool(v);   return }
        if let v = try? c.decode(Int.self)    { self = .int(v);    return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([EventDataValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: EventDataValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported EventDataValue type")
    }
}

private let SQLITE_TRANSIENT_EMITTER = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func eventEmitterSQLiteError(_ db: OpaquePointer?, operation: String) -> NSError {
    let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "database unavailable"
    return NSError(
        domain: "EventEmitterService",
        code: Int(sqlite3_errcode(db)),
        userInfo: [NSLocalizedDescriptionKey: "SQLite could not \(operation): \(message)"]
    )
}
