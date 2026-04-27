import Foundation
import CryptoKit
import SQLite3
import SwiftMinerCore

// MARK: - EventOutboxService

/// Polls `event_outbox` for pending events and delivers them to the configured
/// webhook URL using HMAC-SHA256 signed HTTP POST requests.
public actor EventOutboxService {

    private let manager: SQLiteManager
    private var webhookURL: URL?
    private var hmacSecret: String
    private var pollingTask: Task<Void, Never>?

    // Backoff per retry_count (index = attempt number after first failure)
    fileprivate static let backoffIntervals: [TimeInterval] = [30, 120, 600, 3_600, 21_600, 86_400]
    private static let maxRetries = backoffIntervals.count

    public init(manager: SQLiteManager, webhookURL: URL?, hmacSecret: String) {
        self.manager = manager
        self.webhookURL = webhookURL
        self.hmacSecret = hmacSecret
    }

    public func updateConfig(webhookURL: URL?, hmacSecret: String) {
        self.webhookURL = webhookURL
        self.hmacSecret = hmacSecret
    }

    public func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task {
            await self.runPollingLoop()
        }
    }

    public func stop() {
        pollingTask?.cancel()
        pollingTask = nil
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
            lastAttempt: nil
        )
        let outcome = await attemptDelivery(event: testEvent, to: webhookURL)
        return outcome == .success
    }

    // MARK: - Polling loop

    private func runPollingLoop() async {
        while !Task.isCancelled {
            await pollAndDeliver()
            try? await Task.sleep(for: .seconds(10))
        }
    }

    private func pollAndDeliver() async {
        guard let webhookURL else { return }
        let events = await fetchDeliverableEvents()
        for event in events {
            guard !Task.isCancelled else { return }
            await deliver(event: event, to: webhookURL)
        }
    }

    // MARK: - Fetch

    private func fetchDeliverableEvents() async -> [OutboxRow] {
        do {
            return try await manager.query { db in
                var rows: [OutboxRow] = []

                // Pending events — deliver immediately
                let pendingSql = """
                SELECT id, event_type, payload, retry_count, idempotency_key, last_attempt
                FROM event_outbox
                WHERE status = 'pending'
                ORDER BY created_at ASC
                LIMIT 10;
                """
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, pendingSql, -1, &stmt, nil) == SQLITE_OK {
                    defer { sqlite3_finalize(stmt) }
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        if let row = OutboxRow(statement: stmt) { rows.append(row) }
                    }
                }

                // Retryable events — include all, filter by backoff window in Swift
                let retryableSql = """
                SELECT id, event_type, payload, retry_count, idempotency_key, last_attempt
                FROM event_outbox
                WHERE status = 'failed_retryable'
                ORDER BY last_attempt ASC
                LIMIT 20;
                """
                var retryStmt: OpaquePointer?
                if sqlite3_prepare_v2(db, retryableSql, -1, &retryStmt, nil) == SQLITE_OK {
                    defer { sqlite3_finalize(retryStmt) }
                    while sqlite3_step(retryStmt) == SQLITE_ROW {
                        if let row = OutboxRow(statement: retryStmt), row.isBackoffElapsed {
                            rows.append(row)
                        }
                    }
                }

                return rows
            }
        } catch {
            return []
        }
    }

    // MARK: - Delivery

    private func deliver(event: OutboxRow, to webhookURL: URL) async {
        await updateStatus(id: event.id, status: "delivering")

        let outcome = await attemptDelivery(event: event, to: webhookURL)
        let newRetryCount = event.retryCount + 1

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

    private enum DeliveryOutcome { case success, retryable, terminal }

    private func attemptDelivery(event: OutboxRow, to webhookURL: URL) async -> DeliveryOutcome {
        guard let payloadData = event.payload.data(using: .utf8) else { return .terminal }

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
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return .retryable }
            let code = http.statusCode
            if (200..<300).contains(code) || code == 409 { return .success }
            if code == 408 || code == 429 || (500..<600).contains(code) { return .retryable }
            return .terminal
        } catch {
            return .retryable
        }
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
                var stmt: OpaquePointer?
                if let retryCount {
                    sql = """
                    UPDATE event_outbox
                    SET status = ?, retry_count = ?, last_attempt = CURRENT_TIMESTAMP
                    WHERE id = ?;
                    """
                    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
                    defer { sqlite3_finalize(stmt) }
                    sqlite3_bind_text(stmt, 1, status, -1, SQLITE_TRANSIENT_LOCAL)
                    sqlite3_bind_int(stmt, 2, Int32(retryCount))
                    sqlite3_bind_text(stmt, 3, id, -1, SQLITE_TRANSIENT_LOCAL)
                } else {
                    sql = """
                    UPDATE event_outbox
                    SET status = ?, last_attempt = CURRENT_TIMESTAMP
                    WHERE id = ?;
                    """
                    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
                    defer { sqlite3_finalize(stmt) }
                    sqlite3_bind_text(stmt, 1, status, -1, SQLITE_TRANSIENT_LOCAL)
                    sqlite3_bind_text(stmt, 2, id, -1, SQLITE_TRANSIENT_LOCAL)
                }
                sqlite3_step(stmt)
            }
        } catch {}
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

    init(id: String, eventType: String, payload: String, retryCount: Int, idempotencyKey: String?, lastAttempt: Date?) {
        self.id = id
        self.eventType = eventType
        self.payload = payload
        self.retryCount = retryCount
        self.idempotencyKey = idempotencyKey
        self.lastAttempt = lastAttempt
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
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            lastAttempt = formatter.date(from: String(cString: lastAttemptPtr))
        } else {
            lastAttempt = nil
        }
    }

    var isBackoffElapsed: Bool {
        guard let lastAttempt else { return true }
        let index = min(retryCount - 1, EventOutboxService.backoffIntervals.count - 1)
        let interval = EventOutboxService.backoffIntervals[max(0, index)]
        return Date().timeIntervalSince(lastAttempt) >= interval
    }
}

private let SQLITE_TRANSIENT_LOCAL = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
