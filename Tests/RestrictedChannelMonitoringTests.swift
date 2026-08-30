import XCTest
@testable import SwiftMinerCore

/// Restricted campaigns — esports drops — run on approved channels that go live for short
/// windows, and polling learns about it a minute late at best. Twitch pushes `stream-up` on
/// `video-playback-by-id`, so SwiftMiner listens to those channels while it waits.
///
/// These tests cover the subscription bookkeeping: what is listened to, what is released,
/// and that the channel being watched is never released by mistake.
final class RestrictedChannelMonitoringTests: XCTestCase {
    private func makeService(factory: MockSocketFactory) async -> DropEventsService {
        let client = PubSubClient(
            accessToken: "test-token",
            socketFactory: { factory.make(url: $0) },
            pingInterval: 600,
            pongTimeout: 600,
            baseReconnectDelay: 0.01,
            maxReconnectDelay: 0.08,
            runtimeClock: .continuous,
            reconnectJitterFactor: { 1 }
        )
        try? await client.connect()
        let service = DropEventsService(pubSubClient: client)
        await service.configure()
        return service
    }

    func testMonitoringSubscribesToTheApprovedChannelsGiven() async throws {
        let factory = MockSocketFactory()
        let service = await makeService(factory: factory)

        let monitored = try await service.startMonitoringChannels(["111", "222"], limit: 20)

        XCTAssertEqual(monitored, ["111", "222"])
    }

    /// The connection has a topic budget shared with the drop and watch subscriptions, so
    /// the tail is refused rather than silently dropped — the caller orders by urgency.
    func testMonitoringStopsAtTheLimitItIsGiven() async throws {
        let factory = MockSocketFactory()
        let service = await makeService(factory: factory)

        let monitored = try await service.startMonitoringChannels(["111", "222", "333"], limit: 2)

        XCTAssertEqual(monitored, ["111", "222"])
    }

    func testAChannelIsNotSubscribedTwice() async throws {
        let factory = MockSocketFactory()
        let service = await makeService(factory: factory)

        _ = try await service.startMonitoringChannels(["111"], limit: 20)
        let second = try await service.startMonitoringChannels(["111", "222"], limit: 20)

        XCTAssertEqual(second, ["222"])
    }

    /// Releasing the wait's subscriptions must not release the stream being watched: that
    /// topic carries the drop progress the session depends on.
    func testTheWatchedChannelSurvivesReleasingTheMonitoredOnes() async throws {
        let factory = MockSocketFactory()
        let service = await makeService(factory: factory)

        _ = try await service.startMonitoringChannels(["111", "222"], limit: 20)
        try await service.stopMonitoringChannels(except: "111")

        // 111 was kept, so re-monitoring it is a no-op; 222 was released and can be taken again.
        let reMonitored = try await service.startMonitoringChannels(["111", "222"], limit: 20)
        XCTAssertEqual(reMonitored, ["222"])
    }

    func testReleasingWithNothingMonitoredIsHarmless() async throws {
        let factory = MockSocketFactory()
        let service = await makeService(factory: factory)

        try await service.stopMonitoringChannels()
        try await service.stopMonitoringChannels(except: "111")
    }

    func testEmptyChannelIdsAreIgnored() async throws {
        let factory = MockSocketFactory()
        let service = await makeService(factory: factory)

        let monitored = try await service.startMonitoringChannels(["", "111"], limit: 20)

        XCTAssertEqual(monitored, ["111"])
    }
}
