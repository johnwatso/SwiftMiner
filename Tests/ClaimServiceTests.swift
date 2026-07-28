import XCTest
@testable import SwiftMinerCore

@MainActor
final class ClaimServiceTests: XCTestCase {
    
    var mockSession: URLSession!
    var authService: TwitchAuthService!
    var apiClient: TwitchAPIClient!
    var dropsService: DropsService!
    var claimService: ClaimService!
    
    override func setUp() async throws {
        try await super.setUp()
        
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        mockSession = URLSession(configuration: config)
        
        authService = TwitchAuthService(clientId: "test_client", tokenStore: TestTokenStore())
        apiClient = TwitchAPIClient(authService: authService, clientId: "test_client", session: mockSession, persistsCampaignCaches: false)
        dropsService = DropsService(apiClient: apiClient)
        claimService = ClaimService(apiClient: apiClient, dropsService: dropsService)
    }
    
    override func tearDown() {
        MockURLProtocol.stubResponseData = nil
        MockURLProtocol.stubError = nil
        MockURLProtocol.lastRequest = nil
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }
    
    // MARK: - Claim Tests
    
    func testClaimDropSuccess() async throws {
        let progress = Progress(
            id: "instance123",
            dropId: "drop456",
            dropName: "Test Drop",
            campaignId: "camp789",
            currentMinutes: 60,
            requiredMinutes: 60,
            isClaimed: false
        )
        
        // Mirrors what Twitch actually returns for DropsPage_ClaimDropRewards.
        // This fixture used to be written from the parser instead of from real
        // traffic (claimDropBenefit), so it passed while every live claim failed.
        let successJson = "{\"data\": {\"claimDropRewards\": {\"id\": \"instance123\", \"status\": \"CLAIMED\"}}}"
        
        MockURLProtocol.requestHandler = { request in
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, successJson.data(using: .utf8)!)
        }
        
        let result = await claimService.claimDrop(progress)
        
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.dropInstanceId, "instance123")
        XCTAssertEqual(result.dropName, "Test Drop")
    }
    
    /// The status Twitch actually returns for a successful claim. Accepting only
    /// CLAIMED/SUCCESS reported every real claim as a failure.
    func testClaimDropTreatsEligibleForAllAsSuccess() async throws {
        let progress = Progress(
            id: "instance123",
            dropId: "drop456",
            dropName: "Test Drop",
            campaignId: "camp789",
            currentMinutes: 60,
            requiredMinutes: 60,
            isClaimed: false
        )

        let json = "{\"data\": {\"claimDropRewards\": {\"id\": \"instance123\", \"status\": \"ELIGIBLE_FOR_ALL\"}}}"
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json.data(using: .utf8)!)
        }

        let result = await claimService.claimDrop(progress)

        XCTAssertTrue(result.success, "ELIGIBLE_FOR_ALL is a successful claim, got error: \(result.error ?? "nil")")
    }

    /// A repeat claim of an instance Twitch already granted is still a success.
    func testClaimDropTreatsAlreadyClaimedInstanceAsSuccess() async throws {
        let progress = Progress(
            id: "instance123",
            dropId: "drop456",
            dropName: "Test Drop",
            campaignId: "camp789",
            currentMinutes: 60,
            requiredMinutes: 60,
            isClaimed: false
        )

        let json = "{\"data\": {\"claimDropRewards\": {\"id\": \"instance123\", \"status\": \"DROP_INSTANCE_ALREADY_CLAIMED\"}}}"
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json.data(using: .utf8)!)
        }

        let result = await claimService.claimDrop(progress)

        XCTAssertTrue(result.success, "Already-claimed instance should count as success, got error: \(result.error ?? "nil")")
    }

    /// Twitch has served `claimDropBenefit` historically; keep parsing it so a
    /// mixed rollout can't silently break claims again.
    func testClaimDropAcceptsLegacyBenefitKey() async throws {
        let progress = Progress(
            id: "instance123",
            dropId: "drop456",
            dropName: "Test Drop",
            campaignId: "camp789",
            currentMinutes: 60,
            requiredMinutes: 60,
            isClaimed: false
        )

        let legacyJson = "{\"data\": {\"claimDropBenefit\": {\"id\": \"instance123\", \"status\": \"CLAIMED\"}}}"
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, legacyJson.data(using: .utf8)!)
        }

        let result = await claimService.claimDrop(progress)

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.dropInstanceId, "instance123")
    }

    /// The regression that hid this bug: an unrecognised payload key must name
    /// the keys Twitch did return, rather than collapsing to "Invalid response".
    func testClaimDropUnknownPayloadKeyReportsReturnedKeys() async throws {
        let progress = Progress(
            id: "instance123",
            dropId: "drop456",
            dropName: "Test Drop",
            campaignId: "camp789",
            currentMinutes: 60,
            requiredMinutes: 60,
            isClaimed: false
        )

        let unknownJson = "{\"data\": {\"somethingElse\": {\"status\": \"CLAIMED\"}}}"
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, unknownJson.data(using: .utf8)!)
        }

        let result = await claimService.claimDrop(progress)

        XCTAssertFalse(result.success)
        let error = result.error ?? ""
        XCTAssertTrue(error.contains("somethingElse"), "Expected the returned key to be named, got: \(error)")
    }

    /// GraphQL failures arrive as HTTP 200 with an `errors` array, so the
    /// message has to be surfaced rather than discarded.
    func testClaimDropSurfacesGraphQLErrorMessage() async throws {
        let progress = Progress(
            id: "instance123",
            dropId: "drop456",
            dropName: "Test Drop",
            campaignId: "camp789",
            currentMinutes: 60,
            requiredMinutes: 60,
            isClaimed: false
        )

        let errorJson = "{\"errors\": [{\"message\": \"PersistedQueryNotFound\"}]}"
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, errorJson.data(using: .utf8)!)
        }

        let result = await claimService.claimDrop(progress)

        XCTAssertFalse(result.success)
        let error = result.error ?? ""
        XCTAssertTrue(error.contains("PersistedQueryNotFound"), "Expected the GraphQL message to surface, got: \(error)")
    }

    func testClaimDropAlreadyClaimedFails() async throws {
        let progress = Progress(
            id: "instance123",
            dropId: "drop456",
            dropName: "Test Drop",
            campaignId: "camp789",
            currentMinutes: 60,
            requiredMinutes: 60,
            isClaimed: true
        )
        
        let result = await claimService.claimDrop(progress)
        
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.error, "Drop already claimed")
    }
    
    func testClaimDropNotCompleteFails() async throws {
        let progress = Progress(
            id: "instance123",
            dropId: "drop456",
            dropName: "Test Drop",
            campaignId: "camp789",
            currentMinutes: 30,
            requiredMinutes: 60,
            isClaimed: false
        )
        
        let result = await claimService.claimDrop(progress)
        
        XCTAssertFalse(result.success)
        XCTAssertEqual(result.error, "Drop not ready to claim")
    }
    
    func testClaimDropApiError() async throws {
        let progress = Progress(
            id: "instance123",
            dropId: "drop456",
            dropName: "Test Drop",
            campaignId: "camp789",
            currentMinutes: 60,
            requiredMinutes: 60,
            isClaimed: false
        )
        
        MockURLProtocol.stubError = NSError(domain: "test", code: 500, userInfo: nil)
        
        let result = await claimService.claimDrop(progress)
        
        XCTAssertFalse(result.success)
        XCTAssertNotNil(result.error)
    }
}
