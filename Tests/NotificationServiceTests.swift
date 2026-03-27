import XCTest
import UserNotifications
@testable import SwiftMinerCore

final class NotificationServiceTests: XCTestCase {
    
    // MARK: - Mocks
    
    struct MockNotificationSettings: NotificationSettingsProtocol {
        var authorizationStatus: UNAuthorizationStatus
    }
    
    final class MockNotificationCenter: NotificationCenterProtocol, @unchecked Sendable {
        var addCalled = false
        var lastRequest: UNNotificationRequest?
        var authorizationRequested = false
        var authOptions: UNAuthorizationOptions?
        var stubSettings = MockNotificationSettings(authorizationStatus: .notDetermined)
        
        func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
            authorizationRequested = true
            authOptions = options
            return true
        }
        
        func notificationSettings() async -> NotificationSettingsProtocol {
            return stubSettings
        }
        
        func add(_ request: UNNotificationRequest) async throws {
            addCalled = true
            lastRequest = request
        }
    }
    
    // MARK: - Tests
    
    func test_NotificationService_InitiallyDisabled() async {
        let mockCenter = MockNotificationCenter()
        let service = NotificationService(center: mockCenter)
        
        await service.notifyDropClaimed(campaignName: "Test", dropName: "Drop")
        
        XCTAssertFalse(mockCenter.addCalled, "Should not send notifications when disabled")
    }
    
    func test_NotificationService_Enabled_SendsNotification() async {
        let mockCenter = MockNotificationCenter()
        let service = NotificationService(center: mockCenter)
        
        await service.configure(enabled: true)
        await service.notifyDropClaimed(campaignName: "Overwatch 2", dropName: "Skin")
        
        XCTAssertTrue(mockCenter.addCalled)
        XCTAssertEqual(mockCenter.lastRequest?.content.title, "Drop Claimed! 🎉")
        XCTAssertEqual(mockCenter.lastRequest?.content.body, "Skin from Overwatch 2")
    }
    
    func test_NotificationService_NotifyDropClaimable() async {
        let mockCenter = MockNotificationCenter()
        let service = NotificationService(center: mockCenter)
        
        await service.configure(enabled: true)
        await service.notifyDropClaimable(campaignName: "Valorant", dropName: "Spray")
        
        XCTAssertTrue(mockCenter.addCalled)
        XCTAssertEqual(mockCenter.lastRequest?.content.title, "Drop Ready to Claim! ✨")
        XCTAssertEqual(mockCenter.lastRequest?.content.body, "Spray from Valorant is ready!")
    }

    func test_NotificationService_NotifyAccountLinkRequired() async {
        let mockCenter = MockNotificationCenter()
        let service = NotificationService(center: mockCenter)

        await service.configure(enabled: true)
        await service.notifyAccountLinkRequired(gameName: "The Finals")

        XCTAssertTrue(mockCenter.addCalled)
        XCTAssertEqual(mockCenter.lastRequest?.content.title, "Link Required")
        XCTAssertEqual(
            mockCenter.lastRequest?.content.body,
            "Link your Twitch account to The Finals to earn drops."
        )
    }
    
    func test_NotificationService_ConfigurationRequestsAuth() async {
        let mockCenter = MockNotificationCenter()
        let service = NotificationService(center: mockCenter)
        
        await service.configure(enabled: true)
        
        XCTAssertTrue(mockCenter.authorizationRequested)
        XCTAssertEqual(mockCenter.authOptions, [.alert, .sound, .badge])
    }
    
    func test_NotificationService_IsAuthorized_ReflectsSettings() async {
        let mockCenter = MockNotificationCenter()
        let service = NotificationService(center: mockCenter)
        
        mockCenter.stubSettings = MockNotificationSettings(authorizationStatus: .authorized)
        let authorized = await service.isAuthorized()
        XCTAssertTrue(authorized)
        
        mockCenter.stubSettings = MockNotificationSettings(authorizationStatus: .denied)
        let denied = await service.isAuthorized()
        XCTAssertFalse(denied)
    }
}
