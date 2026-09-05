import Foundation
import CryptoKit
import SQLite3
import XCTest
import SwiftMinerCore
@testable import SwiftMinerService

final class EventEmitterServiceTests: XCTestCase {
    func testCampaignAnnouncementCarriesArtworkAndDedupesByCampaign() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftMiner-EventEmitterServiceTests-\(UUID().uuidString).sqlite")
        let manager = SQLiteManager(databaseURL: databaseURL)
        try await manager.open()
        // Close before unlinking: removing the file while SQLite still has it open makes
        // macOS log "database integrity compromised by API violation". `addTeardownBlock`
        // can await the close, which `defer` cannot.
        addTeardownBlock {
            await manager.close()
            try? FileManager.default.removeItem(at: databaseURL)
        }

        let service = EventEmitterService(manager: manager)
        let campaign = Campaign(
            id: "campaign-1",
            name: "Launch Drops",
            game: Game(
                id: "game-1",
                name: "THE FINALS",
                boxArtURL: URL(string: "https://example.com/finals-box.jpg")
            ),
            startDate: Date(timeIntervalSince1970: 1_800_000_000),
            endDate: Date(timeIntervalSince1970: 1_800_086_400),
            drops: [
                Drop(id: "drop-1", name: "One", imageURL: URL(string: "https://example.com/one.jpg"), requiredMinutes: 15),
                Drop(id: "drop-2", name: "Two", imageURL: URL(string: "https://example.com/two.jpg"), requiredMinutes: 30),
                Drop(id: "drop-3", name: "Three", imageURL: URL(string: "https://example.com/three.jpg"), requiredMinutes: 45),
                Drop(id: "drop-4", name: "Four", imageURL: URL(string: "https://example.com/four.jpg"), requiredMinutes: 60)
            ]
        )

        await service.emitSwiftMinerCampaignAnnounced(campaign: campaign)
        await service.emitSwiftMinerCampaignAnnounced(campaign: campaign)

        let rows = try await manager.query { db in
            var results: [(eventType: String, payload: String, idempotencyKey: String)] = []
            let sql = """
            SELECT event_type, payload, idempotency_key
            FROM event_outbox
            WHERE event_type = 'swiftminer.campaignAnnounced'
            ORDER BY created_at ASC;
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return results }
            defer { sqlite3_finalize(stmt) }
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let typePtr = sqlite3_column_text(stmt, 0),
                      let payloadPtr = sqlite3_column_text(stmt, 1),
                      let keyPtr = sqlite3_column_text(stmt, 2) else { continue }
                results.append((
                    eventType: String(cString: typePtr),
                    payload: String(cString: payloadPtr),
                    idempotencyKey: String(cString: keyPtr)
                ))
            }
            return results
        }

        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.idempotencyKey, "swiftminer.campaignAnnounced:campaign:campaign-1")

        let payloadData = try XCTUnwrap(rows.first?.payload.data(using: .utf8))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: payloadData) as? [String: Any])
        XCTAssertEqual(payload["eventType"] as? String, "swiftminer.campaignAnnounced")
        let data = try XCTUnwrap(payload["data"] as? [String: Any])
        XCTAssertEqual(data["campaignName"] as? String, "Launch Drops")
        XCTAssertEqual(data["gameName"] as? String, "THE FINALS")
        XCTAssertEqual(data["gameArtworkURL"] as? String, "https://example.com/finals-box.jpg")
        XCTAssertEqual(data["dropCount"] as? Int, 4)
        let dropArtwork = try XCTUnwrap(data["dropArtwork"] as? [[String: Any]])
        XCTAssertEqual(dropArtwork.count, 3)
        XCTAssertEqual(dropArtwork.map { $0["name"] as? String }, ["One", "Two", "Three"])
    }

    func testOutboxPollRecordsQueueDepthAndDeliveryLatency() async throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftMiner-EventOutboxMetrics-\(UUID().uuidString).sqlite")
        let manager = SQLiteManager(databaseURL: databaseURL)
        try await manager.open()
        await PerformanceDiagnostics.shared.reset()

        addTeardownBlock {
            await PerformanceDiagnostics.shared.reset()
            await manager.close()
            try? FileManager.default.removeItem(at: databaseURL)
        }

        try await manager.execute { db in
            let sql = """
            INSERT INTO event_outbox
                (id, event_type, payload, idempotency_key, status, created_at)
            VALUES
                ('queued-1', 'system.test', '{"value":1}', 'queued-1', 'pending', datetime('now', '-2 minutes')),
                ('terminal-1', 'system.test', '{"value":2}', 'terminal-1', 'failed_terminal', datetime('now', '-3 minutes'));
            """
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw NSError(domain: "EventOutboxMetricsTests", code: 1)
            }
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 204,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data())
        }
        defer {
            MockURLProtocol.requestHandler = nil
            session.invalidateAndCancel()
        }

        let service = EventOutboxService(
            manager: manager,
            webhookURL: URL(string: "https://swiftminer.example.com/events"),
            hmacSecret: "test-secret",
            urlSession: session
        )
        await service.pollOnce()

        let snapshot = await PerformanceDiagnostics.shared.snapshot()
        let outbox = try XCTUnwrap(snapshot.eventOutbox)
        XCTAssertEqual(outbox.pendingCount, 0)
        XCTAssertEqual(outbox.deliveringCount, 0)
        XCTAssertEqual(outbox.retryableCount, 0)
        XCTAssertEqual(outbox.terminalCount, 1)
        XCTAssertEqual(outbox.sentCount, 1)
        XCTAssertNil(outbox.oldestUndeliveredAgeSeconds)
        XCTAssertEqual(outbox.deliveryAttemptCount, 1)
        XCTAssertEqual(outbox.successfulDeliveryCount, 1)
        XCTAssertEqual(outbox.retryableFailureCount, 0)
        XCTAssertEqual(outbox.terminalFailureCount, 0)
        XCTAssertGreaterThanOrEqual(outbox.averageEndToEndSeconds, 119)

        let deliveredStatus = try await manager.query { db -> String? in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                "SELECT status FROM event_outbox WHERE id = 'queued-1';",
                -1,
                &stmt,
                nil
            ) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW,
                  let value = sqlite3_column_text(stmt, 0) else { return nil }
            return String(cString: value)
        }
        XCTAssertEqual(deliveredStatus, "sent")
    }

    func testDueRetryIsNotHiddenBehindTwentyWaitingRowsAndKeepsSignedPayload() async throws {
        let manager = try await makeOutboxDatabase()
        try await manager.execute("""
        WITH RECURSIVE numbers(n) AS (VALUES(1) UNION ALL SELECT n + 1 FROM numbers WHERE n < 21)
        INSERT INTO event_outbox (id, event_type, payload, status, retry_count, last_attempt)
        SELECT 'waiting-' || n, 'system.test', '{}', 'failed_retryable', 5, datetime('now', '-2 hours')
        FROM numbers;
        INSERT INTO event_outbox (id, event_type, payload, idempotency_key, status, retry_count, last_attempt)
        VALUES ('due', 'system.test', '{"idempotency":"unchanged"}', 'due-key', 'failed_retryable', 1, datetime('now', '-1 minute'));
        """)
        let session = makeOutboxSession { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-SwiftMiner-Event-Id"), "due")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-SwiftMiner-Delivery-Attempt"), "2")
            let body = try XCTUnwrap(request.httpBody)
            XCTAssertEqual(String(data: body, encoding: .utf8), #"{"idempotency":"unchanged"}"#)
            let timestamp = try XCTUnwrap(request.value(forHTTPHeaderField: "X-SwiftMiner-Timestamp"))
            let message = Data("\(timestamp).\(String(decoding: body, as: UTF8.self))".utf8)
            let signature = HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: Data("test-secret".utf8)))
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-SwiftMiner-Signature"),
                           "v1=" + signature.map { String(format: "%02x", $0) }.joined())
            return (HTTPURLResponse(url: request.url!, statusCode: 409, httpVersion: nil, headerFields: nil)!, Data())
        }
        let service = makeOutboxService(manager: manager, session: session)
        await service.pollOnce()

        let snapshot = await PerformanceDiagnostics.shared.snapshot()
        XCTAssertEqual(snapshot.eventOutbox?.sentCount, 1)
        XCTAssertEqual(snapshot.eventOutbox?.retryableCount, 21)
        XCTAssertEqual(snapshot.eventOutbox?.deliveryAttemptCount, 1)
    }

    func testEndpointOutagePausesBatchWithoutConsumingOtherEventsRetriesAndConfigRecovers() async throws {
        let manager = try await makeOutboxDatabase()
        try await manager.execute("""
        INSERT INTO event_outbox (id, event_type, payload, status)
        VALUES ('one', 'system.test', '{}', 'pending'),
               ('two', 'system.test', '{}', 'pending'),
               ('three', 'system.test', '{}', 'pending');
        """)
        let session = makeOutboxSession { request in
            let status = request.value(forHTTPHeaderField: "X-SwiftMiner-Event-Id") == "one" ? 503 : 204
            return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                    headerFields: ["Retry-After": "120"])!, Data())
        }
        let service = makeOutboxService(manager: manager, session: session)
        await service.pollOnce()
        await service.pollOnce()

        var snapshot = await PerformanceDiagnostics.shared.snapshot()
        XCTAssertEqual(snapshot.eventOutbox?.deliveryAttemptCount, 1)
        XCTAssertEqual(snapshot.eventOutbox?.pendingCount, 2)
        XCTAssertEqual(snapshot.eventOutbox?.retryableCount, 1)

        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
        }
        try await manager.execute("UPDATE event_outbox SET last_attempt = datetime('now', '-1 minute') WHERE status = 'failed_retryable';")
        await service.updateConfig(webhookURL: URL(string: "https://swiftminer.example.com/events"), hmacSecret: "updated-secret")
        await service.pollOnce()
        snapshot = await PerformanceDiagnostics.shared.snapshot()
        XCTAssertEqual(snapshot.eventOutbox?.deliveryAttemptCount, 4)
        XCTAssertEqual(snapshot.eventOutbox?.sentCount, 3)
        XCTAssertEqual(snapshot.eventOutbox?.retryableCount, 0)
        XCTAssertEqual(snapshot.eventOutbox?.terminalCount, 0)
    }

    func testExhaustedRetryCountsAsTerminalFailure() async throws {
        let manager = try await makeOutboxDatabase()
        try await manager.execute("""
        INSERT INTO event_outbox (id, event_type, payload, status, retry_count, last_attempt)
        VALUES ('exhausted', 'system.test', '{}', 'failed_retryable', 5, datetime('now', '-7 hours'));
        """)
        let session = makeOutboxSession { request in
            (HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, Data())
        }
        await makeOutboxService(manager: manager, session: session).pollOnce()
        let snapshot = await PerformanceDiagnostics.shared.snapshot()
        XCTAssertEqual(snapshot.eventOutbox?.terminalCount, 1)
        XCTAssertEqual(snapshot.eventOutbox?.terminalFailureCount, 1)
        XCTAssertEqual(snapshot.eventOutbox?.retryableFailureCount, 0)
    }

    func testEnqueueWakesIdleOutboxAndConfigurationWakesDisabledOutbox() async throws {
        let manager = try await makeOutboxDatabase()
        let delivered = expectation(description: "new event delivered without waiting for fallback scan")
        let session = makeOutboxSession { request in
            delivered.fulfill()
            return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
        }
        let service = makeOutboxService(manager: manager, session: session)
        addTeardownBlock { await service.stop() }
        await service.start()
        try await waitForOutboxObservation()
        await EventEmitterService(manager: manager).emitUserDropClaimed(discordUserId: "user", dropId: "drop")
        await fulfillment(of: [delivered], timeout: 2)
        await service.stop()

        await PerformanceDiagnostics.shared.reset()
        let disabledService = EventOutboxService(manager: manager, webhookURL: nil, hmacSecret: "test-secret", urlSession: session)
        addTeardownBlock { await disabledService.stop() }
        await disabledService.start()
        try await waitForOutboxObservation()
        await EventEmitterService(manager: manager).emitUserDropClaimed(discordUserId: "user", dropId: "second-drop")
        let enabledDelivery = expectation(description: "configuration change triggers delivery")
        MockURLProtocol.requestHandler = { request in
            enabledDelivery.fulfill()
            return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
        }
        await disabledService.updateConfig(webhookURL: URL(string: "https://swiftminer.example.com/events"), hmacSecret: "test-secret")
        await fulfillment(of: [enabledDelivery], timeout: 2)
        await disabledService.stop()
    }

    func testOutboxSchedulerSleepsUntilUsefulWorkWithBoundedExternalWriterFallback() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(EventOutboxService.nextPollDelay(now: now, nextDueAt: nil, endpointRetryAt: nil, isConfigured: true), 60)
        XCTAssertEqual(EventOutboxService.nextPollDelay(now: now, nextDueAt: now, endpointRetryAt: nil, isConfigured: false), 60)
        XCTAssertEqual(EventOutboxService.nextPollDelay(now: now, nextDueAt: now.addingTimeInterval(12), endpointRetryAt: nil, isConfigured: true), 12)
        XCTAssertEqual(EventOutboxService.nextPollDelay(now: now, nextDueAt: now, endpointRetryAt: now.addingTimeInterval(30), isConfigured: true), 30)
        XCTAssertEqual(EventOutboxService.nextPollDelay(now: now, nextDueAt: now.addingTimeInterval(600), endpointRetryAt: nil, isConfigured: true), 60)
        XCTAssertEqual(EventOutboxService.nextPollDelay(now: now, nextDueAt: now, endpointRetryAt: nil, isConfigured: true), 0.1)
        XCTAssertEqual(EventOutboxService.retryAfterDelay("120", now: now), 120)
        XCTAssertEqual(EventOutboxService.retryAfterDelay("Fri, 15 Jan 2027 08:02:00 GMT", now: now), 120)
        XCTAssertNil(EventOutboxService.retryAfterDelay("invalid", now: now))
        XCTAssertNil(EventOutboxService.retryAfterDelay("-1", now: now))
    }

    private func makeOutboxDatabase() async throws -> SQLiteManager {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SwiftMiner-Outbox-\(UUID().uuidString).sqlite")
        let manager = SQLiteManager(databaseURL: url)
        try await manager.open()
        await PerformanceDiagnostics.shared.reset()
        addTeardownBlock {
            await PerformanceDiagnostics.shared.reset()
            await manager.close()
            try? FileManager.default.removeItem(at: url)
        }
        return manager
    }

    private func makeOutboxSession(
        handler: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        MockURLProtocol.requestHandler = handler
        addTeardownBlock {
            MockURLProtocol.requestHandler = nil
            session.invalidateAndCancel()
        }
        return session
    }

    private func makeOutboxService(manager: SQLiteManager, session: URLSession) -> EventOutboxService {
        EventOutboxService(manager: manager, webhookURL: URL(string: "https://swiftminer.example.com/events"),
                           hmacSecret: "test-secret", urlSession: session)
    }

    private func waitForOutboxObservation() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await PerformanceDiagnostics.shared.snapshot().eventOutbox == nil {
            guard ContinuousClock.now < deadline else {
                XCTFail("Outbox did not finish its initial scan")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
