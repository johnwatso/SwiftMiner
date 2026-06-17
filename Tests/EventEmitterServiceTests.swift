import Foundation
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
        defer {
            Task {
                await manager.close()
                try? FileManager.default.removeItem(at: databaseURL)
            }
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
}
