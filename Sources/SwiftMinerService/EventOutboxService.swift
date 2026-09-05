import Foundation
import CryptoKit
import SQLite3
import SwiftMinerCore

// MARK: - EventOutboxService

/// Delivers `event_outbox` events when enqueued or due for retry, with a bounded
/// fallback scan for other SQLite writers. Sends to the configured
/// webhook URL using HMAC-SHA256 signed HTTP POST requests.
public actor EventOutboxService {

    private let manager: SQLiteManager
    private var webhookURL: URL?
    private var hmacSecret: String
    private let urlSession: URLSession
    private var pollingTask: Task<Void, Never>?
    private var sleepTask: Task<Void, Never>?
    private var enqueueObserver: NSObjectProtocol?
    private var runID: UUID?
    private var wakeRevision: UInt64 = 0
    private var endpointRetryAt: Date?
    private var consecutiveEndpointFailures = 0
    private var isDelivering = false

    static let eventEnqueued = Notification.Name("SwiftMiner.eventOutboxEnqueued")
    static let fallbackInterval: TimeInterval = 60

    // Backoff per retry_count (index = attempt number after first failure)
    fileprivate static let backoffIntervals: [TimeInterval] = [30, 120, 600, 3_600, 21_600, 86_400]
    private static let maxRetries = backoffIntervals.count

    // Use the same expression for fetching and scheduling so rows cannot be hidden
    // behind a LIMIT while a different event's longer backoff is still running.
    private static let retryDelaySQL = "CASE " + backoffIntervals.enumerated().map {
        "WHEN retry_count <= \($0.offset + 1) THEN \(Int($0.element))"
    }.joined(separator: " ") + " ELSE \(Int(backoffIntervals.last!)) END"
    private static let retryDueSQL = "COALESCE(unixepoch(last_attempt) + (\(retryDelaySQL)), 0)"

    public init(
        manager: SQLiteManager,
        webhookURL: URL?,
        hmacSecret: String,
        urlSession: URLSession = .shared
    ) {
        self.manager = manager
        self.webhookURL = webhookURL
        self.hmacSecret = hmacSecret
        self.urlSession = urlSession
    }

    public func updateConfig(webhookURL: URL?, hmacSecret: String) {
        let changed = self.webhookURL != webhookURL || self.hmacSecret != hmacSecret
        self.webhookURL = webhookURL
        self.hmacSecret = hmacSecret
        if changed {
            endpointRetryAt = nil
            consecutiveEndpointFailures = 0
            wake()
        }
    }

    public func start() {
        guard pollingTask == nil else { return }
        let id = UUID()
        runID = id
        enqueueObserver = NotificationCenter.default.addObserver(
            forName: Self.eventEnqueued,
            object: manager,
            queue: nil
        ) { [weak self] _ in
            Task { await self?.wake() }
        }
        pollingTask = Task {
            await self.runPollingLoop(id: id)
        }
    }

    public func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        runID = nil
        sleepTask?.cancel()
        sleepTask = nil
        if let enqueueObserver {
            NotificationCenter.default.removeObserver(enqueueObserver)
            self.enqueueObserver = nil
        }
    }

    /// Sends a one-off test event to the webhook URL.
    public func sendTestWebhook() async -> Bool {
        guard let webhookURL else { return false }
        let testEvent = OutboxRow(
            id: "test-" + UUID().uuidString.prefix(8),
            eventType: "system.test",
            payload: #"{"message": "Hello from SwiftMiner!", "timestamp": "\#(Date().formatted(.iso8601))"}"#,
            retryCount: 0,
            idempotencyKey: nil,
            lastAttempt: nil,
            createdAt: Date()
        )
        let outcome = await attemptDelivery(event: testEvent, to: webhookURL)
        return outcome == .success
    }

    // MARK: - Polling loop

    private func wake() {
        wakeRevision &+= 1
        sleepTask?.cancel()
    }

    private func runPollingLoop(id: UUID) async {
        while !Task.isCancelled, runID == id {
            let revision = wakeRevision
            let nextDueAt = await pollAndDeliver()
            guard !Task.isCancelled, runID == id else { return }
            // An enqueue/config change during delivery must not be lost just
            // because there wasn't yet a sleep task to cancel.
            guard revision == wakeRevision else { continue }
            let delay = Self.nextPollDelay(
                now: Date(), nextDueAt: nextDueAt,
                endpointRetryAt: endpointRetryAt, isConfigured: webhookURL != nil
            )
            let sleeper = Task<Void, Never> {
                do { try await Task.sleep(for: .seconds(delay)) } catch { }
            }
            sleepTask = sleeper
            await sleeper.value
            guard runID == id else { return }
            sleepTask = nil
        }
    }

    static func nextPollDelay(
        now: Date, nextDueAt: Date?, endpointRetryAt: Date?, isConfigured: Bool
    ) -> TimeInterval {
        guard isConfigured else { return fallbackInterval }
        let due = max(nextDueAt ?? now.addingTimeInterval(fallbackInterval), endpointRetryAt ?? now)
        return min(fallbackInterval, max(0.1, due.timeIntervalSince(now)))
    }

    private func pollAndDeliver() async -> Date? {
        guard !isDelivering else { return nil }
        isDelivering = true
        defer { isDelivering = false }
        guard let webhookURL else {
            return await recordQueueObservation()
        }
        if endpointRetryAt.map({ $0 > Date() }) != true {
            let events = await fetchDeliverableEvents()
            for event in events {
                guard !Task.isCancelled else { return nil }
                // Configuration can change while an HTTP request is in flight.
                guard self.webhookURL == webhookURL else { break }
                await deliver(event: event, to: webhookURL)
                if endpointRetryAt.map({ $0 > Date() }) == true { break }
            }
        }
        return await recordQueueObservation()
    }

    /// Performs one queue observation and delivery pass. Kept internal for deterministic
    /// integration tests and for callers that need an immediate flush after configuration.
    func pollOnce() async {
        _ = await pollAndDeliver()
    }

    // MARK: - Fetch

    private func fetchDeliverableEvents() async -> [OutboxRow] {
        do {
            return try await manager.query { db in
                var rows: [OutboxRow] = []

                // Pending events — deliver immediately
                let pendingSql = """
                SELECT id, event_type, payload, retry_count, idempotency_key, last_attempt, created_at
                FROM event_outbox
                WHERE status = 'pending'
                ORDER BY created_at ASC
                LIMIT 10;
                """
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, pendingSql, -1, &stmt, nil) == SQLITE_OK else {
                    throw eventOutboxSQLiteError(db, operation: "prepare pending-event query")
                }
                defer { sqlite3_finalize(stmt) }
                var pendingStep = sqlite3_step(stmt)
                while pendingStep == SQLITE_ROW {
                    if let row = OutboxRow(statement: stmt) { rows.append(row) }
                    pendingStep = sqlite3_step(stmt)
                }
                guard pendingStep == SQLITE_DONE else {
                    throw eventOutboxSQLiteError(db, operation: "read pending events")
                }

                // Filter before limiting: an older, long-backoff row must not
                // prevent a newer row whose short backoff has elapsed from retrying.
                let retryableSql = """
                SELECT id, event_type, payload, retry_count, idempotency_key, last_attempt, created_at
                FROM event_outbox
                WHERE status = 'failed_retryable'
                  AND \(Self.retryDueSQL) <= unixepoch('now')
                ORDER BY \(Self.retryDueSQL) ASC
                LIMIT 20;
                """
                var retryStmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, retryableSql, -1, &retryStmt, nil) == SQLITE_OK else {
                    throw eventOutboxSQLiteError(db, operation: "prepare retryable-event query")
                }
                defer { sqlite3_finalize(retryStmt) }
                var retryableStep = sqlite3_step(retryStmt)
                while retryableStep == SQLITE_ROW {
                    if let row = OutboxRow(statement: retryStmt) {
                        rows.append(row)
                    }
                    retryableStep = sqlite3_step(retryStmt)
                }
                guard retryableStep == SQLITE_DONE else {
                    throw eventOutboxSQLiteError(db, operation: "read retryable events")
                }

                let staleDeliveringSql = """
                SELECT id, event_type, payload, retry_count, idempotency_key, last_attempt, created_at
                FROM event_outbox
                WHERE status = 'delivering'
                  AND (last_attempt IS NULL OR last_attempt <= datetime('now', '-5 minutes'))
                ORDER BY COALESCE(last_attempt, created_at) ASC
                LIMIT 10;
                """
                var staleStmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, staleDeliveringSql, -1, &staleStmt, nil) == SQLITE_OK else {
                    throw eventOutboxSQLiteError(db, operation: "prepare stale-delivery query")
                }
                defer { sqlite3_finalize(staleStmt) }
                var staleStep = sqlite3_step(staleStmt)
                while staleStep == SQLITE_ROW {
                    if let row = OutboxRow(statement: staleStmt) {
                        rows.append(row)
                    }
                    staleStep = sqlite3_step(staleStmt)
                }
                guard staleStep == SQLITE_DONE else {
                    throw eventOutboxSQLiteError(db, operation: "read stale deliveries")
                }

                return rows
            }
        } catch {
            Logger.storage.error("Failed to read the event outbox: \(error.localizedDescription)")
            return []
        }
    }

    private func fetchQueueObservation() async -> OutboxQueueObservation? {
        do {
            return try await manager.query { db in
                let sql = """
                SELECT status, COUNT(*), MIN(created_at), MIN(CASE status
                    WHEN 'pending' THEN 0
                    WHEN 'failed_retryable' THEN \(Self.retryDueSQL)
                    WHEN 'delivering' THEN COALESCE(unixepoch(last_attempt) + 300, 0)
                    ELSE NULL END)
                FROM event_outbox
                GROUP BY status;
                """
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                    throw eventOutboxSQLiteError(db, operation: "prepare queue observation")
                }
                defer { sqlite3_finalize(stmt) }

                var observation = OutboxQueueObservation()
                var step = sqlite3_step(stmt)
                while step == SQLITE_ROW {
                    guard let statusPointer = sqlite3_column_text(stmt, 0) else {
                        step = sqlite3_step(stmt)
                        continue
                    }
                    let status = String(cString: statusPointer)
                    let count = Int(sqlite3_column_int64(stmt, 1))
                    if sqlite3_column_type(stmt, 3) != SQLITE_NULL {
                        let dueAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
                        observation.nextDueAt = observation.nextDueAt.map { min($0, dueAt) } ?? dueAt
                    }
                    let oldest = sqlite3_column_text(stmt, 2).flatMap {
                        parseEventOutboxSQLiteDate(String(cString: $0))
                    }

                    switch status {
                    case "pending":
                        observation.pendingCount = count
                        observation.includeUndelivered(oldest)
                    case "delivering":
                        observation.deliveringCount = count
                        observation.includeUndelivered(oldest)
                    case "failed_retryable":
                        observation.retryableCount = count
                        observation.includeUndelivered(oldest)
                    case "failed_terminal":
                        observation.terminalCount = count
                    case "sent":
                        observation.sentCount = count
                    default:
                        break
                    }
                    step = sqlite3_step(stmt)
                }
                guard step == SQLITE_DONE else {
                    throw eventOutboxSQLiteError(db, operation: "read queue observation")
                }
                return observation
            }
        } catch {
            Logger.storage.error("Failed to inspect the event outbox: \(error.localizedDescription)")
            return nil
        }
    }

    private func recordQueueObservation() async -> Date? {
        guard let observation = await fetchQueueObservation() else { return nil }
        await PerformanceDiagnostics.shared.recordEventOutboxQueue(
            pendingCount: observation.pendingCount,
            deliveringCount: observation.deliveringCount,
            retryableCount: observation.retryableCount,
            terminalCount: observation.terminalCount,
            sentCount: observation.sentCount,
            oldestUndeliveredAt: observation.oldestUndeliveredAt
        )
        return observation.nextDueAt
    }

    // MARK: - Delivery

    private func deliver(event: OutboxRow, to webhookURL: URL) async {
        await updateStatus(id: event.id, status: "delivering")

        let deliveryStartedAt = Date()
        let configurationSecret = hmacSecret
        let outcome = await attemptDelivery(event: event, to: webhookURL)
        let deliveryFinishedAt = Date()
        let newRetryCount = event.retryCount + 1
        let diagnosticOutcome: PerformanceDiagnostics.EventOutboxDeliveryOutcome = switch outcome {
        case .success: .succeeded
        case .retryable: newRetryCount >= Self.maxRetries ? .terminalFailure : .retryableFailure
        case .terminal: .terminalFailure
        }
        await PerformanceDiagnostics.shared.recordEventOutboxDelivery(
            networkSeconds: deliveryFinishedAt.timeIntervalSince(deliveryStartedAt),
            queuedAt: event.createdAt,
            outcome: diagnosticOutcome,
            finishedAt: deliveryFinishedAt,
            failure: outcome.failureReason
        )
        // One failing endpoint should not burn the retry budget of every queued
        // event in a burst. Keep untouched events queued until the endpoint recovers.
        if self.webhookURL == webhookURL, hmacSecret == configurationSecret {
            switch outcome {
            case .success:
                consecutiveEndpointFailures = 0
                endpointRetryAt = nil
            case .retryable(let retryAfter, _):
                consecutiveEndpointFailures += 1
                let index = min(consecutiveEndpointFailures - 1, Self.backoffIntervals.count - 1)
                let delay = max(min(3_600, Self.backoffIntervals[index]), retryAfter ?? 0)
                endpointRetryAt = deliveryFinishedAt.addingTimeInterval(delay)
            case .terminal:
                break
            }
        }

        switch outcome {
        case .success:
            await updateStatus(id: event.id, status: "sent")
        case .retryable:
            let nextStatus = newRetryCount >= Self.maxRetries ? "failed_terminal" : "failed_retryable"
            await updateStatus(id: event.id, status: nextStatus, retryCount: newRetryCount)
        case .terminal:
            await updateStatus(id: event.id, status: "failed_terminal", retryCount: newRetryCount)
        }
    }

    private enum DeliveryOutcome: Equatable {
        case success
        case retryable(retryAfter: TimeInterval? = nil, reason: String? = nil)
        case terminal(reason: String? = nil)

        /// Status or transport code only. Response bodies, endpoint URLs and error
        /// descriptions can carry credentials or user data, so none of them reach here.
        var failureReason: String? {
            switch self {
            case .success: return nil
            case .retryable(_, let reason): return reason
            case .terminal(let reason): return reason
            }
        }
    }

    private func attemptDelivery(event: OutboxRow, to webhookURL: URL) async -> DeliveryOutcome {
        guard let payloadData = event.payload.data(using: .utf8) else {
            return .terminal(reason: "payload was not valid UTF-8")
        }

        let timestamp = Int(Date().timeIntervalSince1970)
        let signature = sign(body: payloadData, timestamp: timestamp)

        var request = URLRequest(url: webhookURL)
        request.httpMethod = "POST"
        request.httpBody = payloadData
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(event.id, forHTTPHeaderField: "X-SwiftMiner-Event-Id")
        request.setValue(event.eventType, forHTTPHeaderField: "X-SwiftMiner-Event-Type")
        request.setValue("\(event.retryCount + 1)", forHTTPHeaderField: "X-SwiftMiner-Delivery-Attempt")
        request.setValue("\(timestamp)", forHTTPHeaderField: "X-SwiftMiner-Timestamp")
        request.setValue(signature, forHTTPHeaderField: "X-SwiftMiner-Signature")

        do {
            let (_, response) = try await urlSession.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                Logger.storage.warning("Event delivery failed: non-HTTP response")
                return .retryable(reason: "non-HTTP response")
            }
            let code = http.statusCode
            if (200..<300).contains(code) || code == 409 { return .success }
            // Response bodies, endpoint URLs, request payloads and error descriptions
            // can contain credentials/user data. Log only a numeric status/code.
            Logger.storage.warning("Event delivery failed: HTTP \(code)")
            if code == 408 || code == 429 || (500..<600).contains(code) {
                return .retryable(
                    retryAfter: Self.retryAfterDelay(http.value(forHTTPHeaderField: "Retry-After")),
                    reason: "HTTP \(code)"
                )
            }
            return .terminal(reason: "HTTP \(code)")
        } catch {
            let code = (error as NSError).code
            Logger.storage.warning("Event delivery failed: transport error code \(code)")
            return .retryable(reason: "transport error \(code)")
        }
    }

    static func retryAfterDelay(_ header: String?, now: Date = Date()) -> TimeInterval? {
        guard let header else { return nil }
        let value = header.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 {
            return min(seconds, 86_400)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        guard let date = formatter.date(from: value) else { return nil }
        return min(86_400, max(0, date.timeIntervalSince(now)))
    }

    // MARK: - Signing

    private func sign(body: Data, timestamp: Int) -> String {
        let message = "\(timestamp).\(String(data: body, encoding: .utf8) ?? "")"
        let key = SymmetricKey(data: Data(hmacSecret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
        return "v1=" + mac.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - State updates

    private func updateStatus(id: String, status: String, retryCount: Int? = nil) async {
        do {
            try await manager.execute { db in
                let sql: String
                if retryCount != nil {
                    sql = """
                    UPDATE event_outbox
                    SET status = ?, retry_count = ?, last_attempt = CURRENT_TIMESTAMP
                    WHERE id = ?;
                    """
                } else {
                    sql = """
                    UPDATE event_outbox
                    SET status = ?, last_attempt = CURRENT_TIMESTAMP
                    WHERE id = ?;
                    """
                }
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                    throw eventOutboxSQLiteError(db, operation: "prepare status update")
                }
                defer { sqlite3_finalize(stmt) }
                if let retryCount {
                    sqlite3_bind_text(stmt, 1, status, -1, SQLITE_TRANSIENT_LOCAL)
                    sqlite3_bind_int(stmt, 2, Int32(retryCount))
                    sqlite3_bind_text(stmt, 3, id, -1, SQLITE_TRANSIENT_LOCAL)
                } else {
                    sqlite3_bind_text(stmt, 1, status, -1, SQLITE_TRANSIENT_LOCAL)
                    sqlite3_bind_text(stmt, 2, id, -1, SQLITE_TRANSIENT_LOCAL)
                }
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw eventOutboxSQLiteError(db, operation: "update event status")
                }
            }
        } catch {
            Logger.storage.error("Failed to mark outbox event \(id) as \(status): \(error.localizedDescription)")
        }
    }
}

// MARK: - Supporting types

private struct OutboxRow {
    let id: String
    let eventType: String
    let payload: String
    let retryCount: Int
    let idempotencyKey: String?
    let lastAttempt: Date?
    let createdAt: Date

    init(
        id: String,
        eventType: String,
        payload: String,
        retryCount: Int,
        idempotencyKey: String?,
        lastAttempt: Date?,
        createdAt: Date
    ) {
        self.id = id
        self.eventType = eventType
        self.payload = payload
        self.retryCount = retryCount
        self.idempotencyKey = idempotencyKey
        self.lastAttempt = lastAttempt
        self.createdAt = createdAt
    }

    init?(statement: OpaquePointer?) {
        guard let stmt = statement,
              let idPtr = sqlite3_column_text(stmt, 0),
              let typePtr = sqlite3_column_text(stmt, 1),
              let payloadPtr = sqlite3_column_text(stmt, 2) else { return nil }
        id = String(cString: idPtr)
        eventType = String(cString: typePtr)
        payload = String(cString: payloadPtr)
        retryCount = Int(sqlite3_column_int(stmt, 3))
        idempotencyKey = sqlite3_column_text(stmt, 4).map { String(cString: $0) }

        if let lastAttemptPtr = sqlite3_column_text(stmt, 5) {
            lastAttempt = parseEventOutboxSQLiteDate(String(cString: lastAttemptPtr))
        } else {
            lastAttempt = nil
        }
        if let createdAtPtr = sqlite3_column_text(stmt, 6),
           let parsed = parseEventOutboxSQLiteDate(String(cString: createdAtPtr)) {
            createdAt = parsed
        } else {
            createdAt = Date()
        }
    }

}

private struct OutboxQueueObservation: Sendable {
    var pendingCount = 0
    var deliveringCount = 0
    var retryableCount = 0
    var terminalCount = 0
    var sentCount = 0
    var oldestUndeliveredAt: Date?
    var nextDueAt: Date?

    mutating func includeUndelivered(_ date: Date?) {
        guard let date else { return }
        oldestUndeliveredAt = oldestUndeliveredAt.map { min($0, date) } ?? date
    }
}

/// Parses SQLite's `CURRENT_TIMESTAMP` / `datetime()` text form, which is always UTC and
/// Gregorian. The POSIX locale keeps parsing independent of the user's region calendar.
private func parseEventOutboxSQLiteDate(_ value: String) -> Date? {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.calendar = Calendar(identifier: .gregorian)
    return formatter.date(from: value)
}

private let SQLITE_TRANSIENT_LOCAL = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private func eventOutboxSQLiteError(_ db: OpaquePointer?, operation: String) -> NSError {
    let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "database unavailable"
    return NSError(
        domain: "EventOutboxService",
        code: Int(sqlite3_errcode(db)),
        userInfo: [NSLocalizedDescriptionKey: "SQLite could not \(operation): \(message)"]
    )
}
