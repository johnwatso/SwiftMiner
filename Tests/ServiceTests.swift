import XCTest
@testable import SwiftTwitchMiner

@MainActor
final class ServiceTests: XCTestCase {
    
    var mockSession: URLSession!
    var authService: TwitchAuthService!
    var apiClient: TwitchAPIClient!
    
    override func setUp() {
        super.setUp()
        
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        mockSession = URLSession(configuration: config)
        
        authService = TwitchAuthService(clientId: "test_client")
        apiClient = TwitchAPIClient(authService: authService, clientId: "test_client", session: mockSession)
    }
    
    override func tearDown() {
        MockURLProtocol.stubResponseData = nil
        MockURLProtocol.stubError = nil
        MockURLProtocol.lastRequest = nil
        super.tearDown()
    }
    
    // MARK: - TwitchAPIClient Tests
    
    func testGetCurrentUser() async throws {
        let jsonString = """
        {
            "data": [
                {
                    "id": "12345",
                    "login": "testuser",
                    "display_name": "TestUser",
                    "type": "",
                    "broadcaster_type": "",
                    "description": "Test bio",
                    "profile_image_url": "https://example.com/img.png",
                    "offline_image_url": "",
                    "view_count": 100,
                    "created_at": "2020-01-01T00:00:00Z"
                }
            ]
        }
        """
        MockURLProtocol.stubResponseData = jsonString.data(using: .utf8)
        
        let user = try await apiClient.getCurrentUser()
        
        XCTAssertEqual(user.id, "12345")
        XCTAssertEqual(user.login, "testuser")
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/helix/users")
    }
    
    func testGetGameSlug() async throws {
        let jsonString = """
        {
            "data": {
                "game": {
                    "name": "fortnite"
                }
            }
        }
        """
        MockURLProtocol.stubResponseData = jsonString.data(using: .utf8)
        
        let slug = try await apiClient.getGameSlug(name: "Fortnite")
        
        XCTAssertEqual(slug, "fortnite")
        
        let lastRequest = MockURLProtocol.lastRequest
        XCTAssertNotNil(lastRequest)
        
        let bodyData = lastRequest?.httpBody
        XCTAssertNotNil(bodyData)
        
        if let bodyData = bodyData,
           let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
           let variables = json["variables"] as? [String: Any] {
            XCTAssertEqual(variables["name"] as? String, "Fortnite")
        }
    }
    
    // MARK: - CommunityPointsService Tests
    
    func testCommunityPointsAutoClaim() async throws {
        let pointsService = CommunityPointsService(apiClient: apiClient)
        
        // Mock GQL response for context
        let contextJson = """
        {
            "data": {
                "community": {
                    "channel": {
                        "communityPoints": {
                            "balance": 500,
                            "user": {
                                "self": {
                                    "communityPointsAvailableClaim": {
                                        "id": "claim_123"
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        """
        MockURLProtocol.stubResponseData = contextJson.data(using: .utf8)
        
        // Start auto-claim
        await pointsService.startAutoClaim(channelLogin: "testchannel", channelId: "999")
        
        // Wait a bit for the first poll
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        
        // Verify a request was made
        XCTAssertNotNil(MockURLProtocol.lastRequest)
        
        await pointsService.stopAutoClaim()
    }
}

// MARK: - Mocking Infrastructure

class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var stubResponseData: Data?
    nonisolated(unsafe) static var stubError: Error?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    
    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }
    
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }
    
    override func startLoading() {
        MockURLProtocol.lastRequest = request
        
        if let error = MockURLProtocol.stubError {
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            
            if let data = MockURLProtocol.stubResponseData {
                client?.urlProtocol(self, didLoad: data)
            }
            
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    
    override func stopLoading() {}
}
