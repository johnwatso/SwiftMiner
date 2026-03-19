import XCTest
@testable import SwiftTwitchMiner

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
        
        authService = TwitchAuthService(clientId: "test_client")
        apiClient = TwitchAPIClient(authService: authService, clientId: "test_client", session: mockSession)
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
        
        // Mock successful claim response — key must match TwitchAPIClient parsing (claimDropBenefit)
        let successJson = "{\"data\": {\"claimDropBenefit\": {\"id\": \"instance123\", \"status\": \"CLAIMED\"}}}"
        
        MockURLProtocol.requestHandler = { request in
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, successJson.data(using: .utf8)!)
        }
        
        let result = await claimService.claimDrop(progress)
        
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.dropInstanceId, "instance123")
        XCTAssertEqual(result.dropName, "Test Drop")
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
