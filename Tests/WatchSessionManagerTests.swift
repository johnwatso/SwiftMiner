import XCTest
@testable import SwiftTwitchMiner

@MainActor
final class WatchSessionManagerTests: XCTestCase {
    
    var mockSession: URLSession!
    var authService: TwitchAuthService!
    var apiClient: TwitchAPIClient!
    var manager: WatchSessionManager!
    
    override func setUp() async throws {
        try await super.setUp()
        
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        mockSession = URLSession(configuration: config)
        
        authService = TwitchAuthService(clientId: "test_client")
        apiClient = TwitchAPIClient(authService: authService, clientId: "test_client", session: mockSession)
        
        // Use a very short interval for testing heartbeats (0.1s)
        manager = WatchSessionManager(apiClient: apiClient, urlSession: mockSession, heartbeatInterval: 0.1)
        await manager.setUserId("12345")
    }
    
    override func tearDown() {
        MockURLProtocol.stubResponseData = nil
        MockURLProtocol.stubError = nil
        MockURLProtocol.lastRequest = nil
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    // MARK: - Session Management Tests
    
    func testStartWatchingSuccess() async throws {
        // Mock GQL for playback access token
        let playbackTokenJson = "{\"data\": {\"streamPlaybackAccessToken\": {\"value\": \"test_token\", \"signature\": \"test_sig\"}}}"
        
        // Mock GQL for broadcast ID
        let broadcastIdJson = "{\"data\": {\"user\": {\"stream\": {\"id\": \"broadcast_789\"}}}}"
        
        // Mock GQL for Community Points Context (needed by CommunityPointsService)
        let pointsContextJson = "{\"data\": {\"community\": {\"channel\": {\"communityPoints\": {\"balance\": 100, \"user\": {\"self\": {\"communityPointsAvailableClaim\": null}}}}}}}"

        // Since startWatching makes multiple GQL calls, we need a way to handle sequential mocks.
        // For now, let's just make sure it starts and we can verify heartbeats.
        // MockURLProtocol needs to return different things for different URLs.
        
        MockURLProtocol.requestHandler = { request in
            let url = request.url?.absoluteString ?? ""
            
            if url.contains("twitch.tv/testchannel") {
                // Channel page for Spade URL extraction
                let html = "<html><body><script>var spade_url = \"https://spade.twitch.tv/track\";</script></body></html>"
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, html.data(using: .utf8)!)
            } else if url.contains("spade.twitch.tv/track") {
                // Spade beacon POST
                return (HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, Data())
            } else {
                // GQL calls
                return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, playbackTokenJson.data(using: .utf8)!)
            }
        }
        
        let channel = Channel(id: "ch123", login: "testchannel", displayName: "TestChannel")
        
        let session = try await manager.startWatching(channel: channel, campaignId: "camp456")
        
        XCTAssertEqual(session.channelId, "ch123")
        XCTAssertEqual(session.campaignId, "camp456")
        
        let isWatching = await manager.isWatching
        XCTAssertEqual(isWatching, true)
        
        // Wait for at least one heartbeat (interval is 0.1s)
        try await Task.sleep(nanoseconds: 200_000_000) // 0.2s
        
        let watchTime = await manager.totalWatchTime
        XCTAssertGreaterThan(watchTime, 0)
        
        await manager.stopWatching()
        
        let isWatchingAfterStop = await manager.isWatching
        XCTAssertEqual(isWatchingAfterStop, false)
    }
    
    func testStartWatchingFailsIfAlreadyWatching() async throws {
        let playbackTokenJson = "{\"data\": {\"streamPlaybackAccessToken\": {\"value\": \"t\", \"signature\": \"s\"}}}"
        MockURLProtocol.stubResponseData = playbackTokenJson.data(using: .utf8)
        
        let channel = Channel(id: "ch1", login: "l1", displayName: "d1")
        _ = try await manager.startWatching(channel: channel, campaignId: "c1")
        
        do {
            _ = try await manager.startWatching(channel: channel, campaignId: "c2")
            XCTFail("Should have thrown error")
        } catch TwitchMinerError.watchSessionFailed(let message) {
            XCTAssertEqual(message, "Session already active")
        }
    }
    
    func testPauseAndResume() async throws {
        let playbackTokenJson = "{\"data\": {\"streamPlaybackAccessToken\": {\"value\": \"t\", \"signature\": \"s\"}}}"
        MockURLProtocol.stubResponseData = playbackTokenJson.data(using: .utf8)
        
        let channel = Channel(id: "ch1", login: "l1", displayName: "d1")
        _ = try await manager.startWatching(channel: channel, campaignId: "c1")
        
        try await manager.pauseWatching()
        let isWatchingPaused = await manager.isWatching
        XCTAssertEqual(isWatchingPaused, false)
        
        try await manager.resumeWatching()
        let isWatchingResumed = await manager.isWatching
        XCTAssertEqual(isWatchingResumed, true)
    }
}
