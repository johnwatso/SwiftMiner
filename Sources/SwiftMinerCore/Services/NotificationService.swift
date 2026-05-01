import Foundation
import UserNotifications
#if canImport(AppKit)
import AppKit
#endif

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

/// Service for managing local macOS notifications for drop claims and account-link issues.
/// Claim notifications remain user-configurable; critical account-link warnings can be surfaced immediately.
public actor NotificationService {
    public static let accountLinkRequiredCategoryId = "account_link_required"
    
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

    /// Send a notification when a game's drops are blocked by a missing account link.
    /// - Parameters:
    ///   - gameName: Name of the affected game
    ///   - sound: Whether to play a sound
    public func notifyAccountLinkRequired(
        gameName: String,
        sound: Bool = false
    ) async {
        guard isEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = "Link Required"
        content.body = "Link your Twitch account to \(gameName) to earn drops."
        content.categoryIdentifier = Self.accountLinkRequiredCategoryId
        content.badge = 1

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
            await setDockBadgeVisible(true)
        } catch {
            print("⚠️ Failed to send notification: \(error.localizedDescription)")
        }
    }

    /// Send a notification when a previously blocked game is now linked.
    /// - Parameters:
    ///   - gameName: Name of the affected game
    ///   - sound: Whether to play a sound
    public func notifyAccountLinked(
        gameName: String,
        sound: Bool = false
    ) async {
        guard isEnabled else { return }

        let content = UNMutableNotificationContent()
        content.title = "Account Linked"
        content.body = "\(gameName) drops can be mined now."
        content.categoryIdentifier = "account_linked"

        if sound {
            content.sound = .default
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        do {
            try await center.add(request)
            await setDockBadgeVisible(false)
        } catch {
            print("⚠️ Failed to send notification: \(error.localizedDescription)")
        }
    }
    
    /// Check if notifications are authorized by the user.
    public func isAuthorized() async -> Bool {
        let settings = await center.notificationSettings()
        return settings.authorizationStatus == .authorized
    }

    private func setDockBadgeVisible(_ visible: Bool) async {
#if canImport(AppKit)
        await MainActor.run {
            NSApplication.shared.dockTile.badgeLabel = visible ? "!" : nil
        }
#endif
        if #available(macOS 13.0, *) {
            UNUserNotificationCenter.current().setBadgeCount(visible ? 1 : 0) { error in
                guard let error else { return }
                print("⚠️ Failed to update notification badge count: \(error.localizedDescription)")
            }
        }
    }
}
