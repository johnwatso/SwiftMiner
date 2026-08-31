import XCTest
@testable import SwiftMinerCore

/// Real-time drop progress rides Twitch's legacy PubSub edge. Mining survives without it — the
/// reconcile tick keeps progress correct — but a transport that dies quietly is exactly what
/// once let a whole fleet look healthy while earning nothing, so a sustained outage has to be
/// reported and withdrawn.
final class RealtimeEventsHealthTests: XCTestCase {
    private actor EventLog {
        private(set) var events: [MinerEngine.OperationalEvent] = []
        func append(_ event: MinerEngine.OperationalEvent) { events.append(event) }
    }

    private func makeEngine(grace: TimeInterval, log: EventLog) async -> MinerEngine {
        let engine = MinerEngine(clientId: "test_client")
        await engine.setRealtimeEventsOutageGrace(grace)
        await engine.setOperationalEventHandler { event in
            Task { await log.append(event) }
        }
        return engine
    }

    private func waitForEvents(_ log: EventLog, count: Int) async -> [MinerEngine.OperationalEvent] {
        for _ in 0..<200 {
            let events = await log.events
            if events.count >= count { return events }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await log.events
    }

    func testSustainedOutageIsReportedOnceAndWithdrawnOnReconnect() async throws {
        let log = EventLog()
        let engine = await makeEngine(grace: 0.05, log: log)

        await engine.noteRealtimeEvents(connected: false, detail: "socket closed")
        // A retry storm must not re-arm the report.
        await engine.noteRealtimeEvents(connected: false, detail: "socket closed")

        let offline = await waitForEvents(log, count: 1)
        guard case .realtimeEventsOffline(let detail)? = offline.first else {
            return XCTFail("Expected a realtimeEventsOffline event, got \(offline)")
        }
        XCTAssertTrue(detail.contains("socket closed"), "The report should carry the cause: \(detail)")
        XCTAssertEqual(offline.count, 1, "One outage must produce one report")

        await engine.noteRealtimeEvents(connected: true)
        let restored = await waitForEvents(log, count: 2)
        XCTAssertEqual(restored.last, .realtimeEventsRestored)
    }

    /// An ordinary reconnect inside the grace window is routine — nothing should be reported,
    /// and nothing should be withdrawn either.
    func testBriefDropIsNotReported() async throws {
        let log = EventLog()
        let engine = await makeEngine(grace: 60, log: log)

        await engine.noteRealtimeEvents(connected: false, detail: "blip")
        await engine.noteRealtimeEvents(connected: true)

        try await Task.sleep(nanoseconds: 100_000_000)
        let events = await log.events
        XCTAssertTrue(events.isEmpty, "A reconnect inside the grace window should stay silent, got \(events)")
    }
}
