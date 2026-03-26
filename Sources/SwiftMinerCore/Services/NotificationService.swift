import Foundation
import UserNotifications

/// Protocol for Notification Settings to allow mocking
public protocol NotificationSettingsProtocol: Sendable {
    var authorizationStatus: UNAuthorizationStatus { get }
}

extension UNNotificationSettings: NotificationSettingsProtocol {}

/// Protocol for UserNotificationCenter to allow mocking in tests
public protocol NotificationCenterProtocol: Sendable {
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func notificationSettings() async -> NotificationSettingsProtocol
    func add(_ request: UNNotificationRequest) async throws
}

extension UNUserNotificationCenter: NotificationCenterProtocol {
    public func notificationSettings() async -> NotificationSettingsProtocol {
        let settings: UNNotificationSettings = await self.notificationSettings()
        return settings
    }
}

/// Service for managing local macOS notifications for drop claims and other events.
/// Disabled by default — users must explicitly opt-in via settings.
public actor NotificationService {
    
    private let center: NotificationCenterProtocol
    private var isEnabled: Bool = false
    
    public init(center: NotificationCenterProtocol = UNUserNotificationCenter.current()) {
        self.center = center
    }
    
    /// Configure the notification service.
    /// - Parameter enabled: Whether notifications are enabled by user preference
    public func configure(enabled: Bool) async {
        self.isEnabled = enabled
        
        if enabled {
            // Request authorization if not already granted
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                do {
                    _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                } catch {
                    print("⚠️ Notification authorization failed: \(error.localizedDescription)")
                }
            }
        }
    }
    
    /// Send a notification when a drop is claimed.
    /// - Parameters:
    ///   - campaignName: Name of the campaign
    ///   - dropName: Name of the claimed drop
    ///   - sound: Whether to play a sound
    public func notifyDropClaimed(
        campaignName: String,
        dropName: String,
        sound: Bool = true
    ) async {
        guard isEnabled else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "Drop Claimed! 🎉"
        content.body = "\(dropName) from \(campaignName)"
        content.categoryIdentifier = "drop_claim"
        
        if sound {
            content.sound = .default
        }
        
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // Deliver immediately
        )
        
        do {
            try await center.add(request)
        } catch {
            print("⚠️ Failed to send notification: \(error.localizedDescription)")
        }
    }
    
    /// Send a notification when a drop becomes claimable (ready to claim).
    /// - Parameters:
    ///   - campaignName: Name of the campaign
    ///   - dropName: Name of the claimable drop
    ///   - sound: Whether to play a sound
    public func notifyDropClaimable(
        campaignName: String,
        dropName: String,
        sound: Bool = true
    ) async {
        guard isEnabled else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "Drop Ready to Claim! ✨"
        content.body = "\(dropName) from \(campaignName) is ready!"
        content.categoryIdentifier = "drop_claimable"
        
        if sound {
            content.sound = .default
        }
        
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil // Deliver immediately
        )
        
        do {
            try await center.add(request)
        } catch {
            print("⚠️ Failed to send notification: \(error.localizedDescription)")
        }
    }
    
    /// Check if notifications are authorized by the user.
    public func isAuthorized() async -> Bool {
        let settings = await center.notificationSettings()
        return settings.authorizationStatus == .authorized
    }
}
