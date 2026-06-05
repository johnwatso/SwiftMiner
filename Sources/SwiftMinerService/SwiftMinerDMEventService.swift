import Foundation
import OSLog

private let dmEventLogger = Logger(subsystem: "com.swiftminer", category: "dm-events")

/// Lightweight event producer that emits rich typed DM requests to SwiftBot.
///
/// Responsibility: detect miner events → build typed payloads → emit.
/// Non-responsibility: notification lifecycle, suppression, UX orchestration.
/// Those remain centralized in SwiftBot.
public actor SwiftMinerDMEventService {
    private let connectionService: any SwiftBotConnectionService

    // MARK: - Dedup State (lightweight, event-side only)

    /// Campaign IDs we've already notified for (session-scoped). Campaigns stay completed.
    private var notifiedCampaignIds: Set<String> = []

    /// Campaign IDs we've already announced as newly detected (session-scoped).
    private var detectedCampaignIds: Set<String> = []

    /// Account IDs → last auth-failure notification time
    private var lastAuthFailure: [String: Date] = [:]

    /// Game names (lowercased) → last link-warning notification time
    private var lastLinkWarning: [String: Date] = [:]

    /// Account IDs → last welcome-back notification time
    private var lastWelcomeBack: [String: Date] = [:]

    /// Account IDs → last manual-attention notification time
    private var lastAccountActionRequired: [String: Date] = [:]

    // MARK: - Dedup Windows

    private let authFailureCooldown: TimeInterval = 300   // 5 min
    private let linkWarningCooldown: TimeInterval = 3600  // 1 hour
    private let welcomeBackCooldown: TimeInterval = 3600  // 1 hour
    private let accountActionCooldown: TimeInterval = 3600 // 1 hour

    // MARK: - Init

    public init(connectionService: any SwiftBotConnectionService) {
        self.connectionService = connectionService
    }

    // MARK: - Event Emitters

    public func emitCampaignCompleted(
        campaignId: String,
        campaignName: String,
        gameName: String?,
        gameArtworkURL: String?,
        discordUserId: String?,
        priorityGames: [String]
    ) async {
        guard let discordUserId else { return }
        guard !notifiedCampaignIds.contains(campaignId) else { return }
        notifiedCampaignIds.insert(campaignId)

        let request = SwiftBotDMRequest(
            messageType: .campaignCompleted,
            debug: false,
            twitchUsername: nil,
            priorityGames: priorityGames,
            affectedGame: gameName,
            campaignName: campaignName,
            gameArtworkURL: gameArtworkURL,
            eventId: "campaign:\(campaignId)"
        )

        dmEventLogger.info("Emitting campaignCompleted discordId=\(discordUserId, privacy: .private) campaign=\(campaignName)")
        _ = await connectionService.sendEventDM(to: discordUserId, request: request)
    }

    public func emitReauthRequired(
        accountId: String,
        discordUserId: String?,
        twitchUsername: String?,
        priorityGames: [String]
    ) async {
        guard let discordUserId else { return }
        guard !isRecentlyNotified(key: accountId, map: &lastAuthFailure, cooldown: authFailureCooldown) else { return }

        let request = SwiftBotDMRequest(
            messageType: .reauth,
            debug: false,
            twitchUsername: twitchUsername,
            priorityGames: priorityGames,
            eventId: "reauth:\(accountId):\(bucket(for: authFailureCooldown))"
        )

        dmEventLogger.info("Emitting reauth discordId=\(discordUserId, privacy: .private)")
        _ = await connectionService.sendEventDM(to: discordUserId, request: request)
    }

    public func emitPrioritisedGameNeedsLinking(
        gameName: String,
        discordUserId: String?,
        priorityGames: [String]
    ) async {
        guard let discordUserId else { return }
        let key = gameName.lowercased()
        guard !isRecentlyNotified(key: key, map: &lastLinkWarning, cooldown: linkWarningCooldown) else { return }

        let request = SwiftBotDMRequest(
            messageType: .prioritisedGameNeedsLinking,
            debug: false,
            twitchUsername: nil,
            priorityGames: priorityGames,
            affectedGame: gameName,
            eventId: "linkWarning:\(key):\(bucket(for: linkWarningCooldown))"
        )

        dmEventLogger.info("Emitting prioritisedGameNeedsLinking discordId=\(discordUserId, privacy: .private) game=\(gameName)")
        _ = await connectionService.sendEventDM(to: discordUserId, request: request)
    }

    public func emitWelcomeBack(
        accountId: String,
        discordUserId: String?,
        twitchUsername: String?,
        priorityGames: [String]
    ) async {
        guard let discordUserId else { return }
        guard !isRecentlyNotified(key: accountId, map: &lastWelcomeBack, cooldown: welcomeBackCooldown) else { return }

        let request = SwiftBotDMRequest(
            messageType: .welcomeBack,
            debug: false,
            twitchUsername: twitchUsername,
            priorityGames: priorityGames,
            eventId: "welcomeBack:\(accountId):\(bucket(for: welcomeBackCooldown))"
        )

        dmEventLogger.info("Emitting welcomeBack discordId=\(discordUserId, privacy: .private)")
        _ = await connectionService.sendEventDM(to: discordUserId, request: request)
    }

    public func emitCampaignDetected(
        campaignId: String,
        campaignName: String,
        gameName: String,
        gameArtworkURL: String?,
        discordUserId: String?,
        priorityGames: [String]
    ) async {
        guard let discordUserId else { return }
        guard !detectedCampaignIds.contains(campaignId) else { return }
        detectedCampaignIds.insert(campaignId)

        let request = SwiftBotDMRequest(
            messageType: .campaignDetected,
            debug: false,
            twitchUsername: nil,
            priorityGames: priorityGames,
            affectedGame: gameName,
            campaignName: campaignName,
            gameArtworkURL: gameArtworkURL,
            eventId: "campaignDetected:\(campaignId)"
        )

        dmEventLogger.info("Emitting campaignDetected discordId=\(discordUserId, privacy: .private) campaign=\(campaignName)")
        _ = await connectionService.sendEventDM(to: discordUserId, request: request)
    }

    public func emitAccountActionRequired(
        accountId: String,
        reason: String,
        discordUserId: String?,
        twitchUsername: String?,
        priorityGames: [String]
    ) async {
        guard let discordUserId else { return }
        guard !isRecentlyNotified(key: accountId, map: &lastAccountActionRequired, cooldown: accountActionCooldown) else { return }

        let request = SwiftBotDMRequest(
            messageType: .accountActionRequired,
            debug: false,
            twitchUsername: twitchUsername,
            priorityGames: priorityGames,
            recoveryReason: reason,
            eventId: "accountAction:\(accountId):\(stableHash(reason)):\(bucket(for: accountActionCooldown))"
        )

        dmEventLogger.info("Emitting accountActionRequired discordId=\(discordUserId, privacy: .private) reason=\(reason)")
        _ = await connectionService.sendEventDM(to: discordUserId, request: request)
    }

    // MARK: - Dedup Helpers

    private func isRecentlyNotified(key: String, map: inout [String: Date], cooldown: TimeInterval) -> Bool {
        if let last = map[key], Date().timeIntervalSince(last) < cooldown {
            return true
        }
        map[key] = Date()
        return false
    }

    /// Time bucket index for the current cooldown window. Matches across SwiftMiner
    /// restarts so SwiftBot can dedupe events that fire again within the same window.
    private func bucket(for cooldown: TimeInterval) -> Int {
        Int(Date().timeIntervalSince1970 / cooldown)
    }

    /// Stable, process-independent hash for embedding free-form strings (e.g. recovery
    /// reasons) inside an `eventId`. FNV-1a 32-bit, hex-encoded.
    private func stableHash(_ string: String) -> String {
        var hash: UInt32 = 0x811c9dc5
        for byte in string.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x01000193
        }
        return String(hash, radix: 16)
    }
}
