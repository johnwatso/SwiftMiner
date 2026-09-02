import Foundation
import ServiceManagement
import SwiftUI
import SwiftMinerCore

public struct SettingsBackup: Codable, Sendable {
    public let schemaVersion: Int
    public let exportedAt: Date
    public let autoClaimEnabled: Bool
    public let autoClaimPointsEnabled: Bool
    public let logLevel: String
    public let maxLogEntries: Int
    public let appPresenceMode: String
    public let autoStartOnLaunch: Bool
    public let startMinimized: Bool
    public let enableBadgesEmotes: Bool
    public let mineIRLCampaigns: Bool?
    public let avoidDuplicateStreams: Bool
    public let antiStallRecoveryEnabled: Bool
    public let prioritiseFollowedStreamers: Bool
    public let syncMinersState: Bool
    /// Optional: backups written before miner avatars were selectable have no value.
    public let minerAvatarSource: String?
    /// Optional: backups written before the picture choice became per-account have
    /// no value, and fall back to `minerAvatarSource` on import.
    public let accountAvatarSourcesData: String?
    public let runInBackground: Bool
    public let selectedDropsFiltersData: String
    public let selectedEventFiltersData: String
    public let preferredQuality: String
    public let showClaimNotifications: Bool
    public let ignoredWarningsData: String
    public let twitchClientId: String
    public let swiftBotEnabled: Bool
    public let swiftBotEndpoint: String
    public let swiftBotWebhookURL: String
    public let swiftMinerAPIEndpoint: String
    public let swiftBotHmacSecret: String
    public let swiftMinerAPIKey: String
    public let dmCampaignCompletedEnabled: Bool
    public let dmConnectionExpiredEnabled: Bool
    public let dmWelcomeBackEnabled: Bool
    public let dmLinkRequiredEnabled: Bool
    public let dmCampaignDetectedEnabled: Bool
    public let dmAccountActionRequiredEnabled: Bool
    public let quietHoursEnabled: Bool
    public let quietHoursStartMinute: Int
    public let quietHoursEndMinute: Int
    public let gamePreferencesData: String
    public let miningStrategy: String

    public init(
        schemaVersion: Int = 1,
        exportedAt: Date,
        autoClaimEnabled: Bool,
        autoClaimPointsEnabled: Bool,
        logLevel: String,
        maxLogEntries: Int,
        appPresenceMode: String,
        autoStartOnLaunch: Bool,
        startMinimized: Bool,
        enableBadgesEmotes: Bool,
        mineIRLCampaigns: Bool? = false,
        avoidDuplicateStreams: Bool,
        antiStallRecoveryEnabled: Bool,
        prioritiseFollowedStreamers: Bool,
        syncMinersState: Bool,
        minerAvatarSource: String? = nil,
        accountAvatarSourcesData: String? = nil,
        runInBackground: Bool,
        selectedDropsFiltersData: String,
        selectedEventFiltersData: String,
        preferredQuality: String,
        showClaimNotifications: Bool,
        ignoredWarningsData: String,
        twitchClientId: String,
        swiftBotEnabled: Bool,
        swiftBotEndpoint: String,
        swiftBotWebhookURL: String,
        swiftMinerAPIEndpoint: String,
        swiftBotHmacSecret: String,
        swiftMinerAPIKey: String,
        dmCampaignCompletedEnabled: Bool,
        dmConnectionExpiredEnabled: Bool,
        dmWelcomeBackEnabled: Bool,
        dmLinkRequiredEnabled: Bool,
        dmCampaignDetectedEnabled: Bool,
        dmAccountActionRequiredEnabled: Bool,
        quietHoursEnabled: Bool,
        quietHoursStartMinute: Int,
        quietHoursEndMinute: Int,
        gamePreferencesData: String,
        miningStrategy: String
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.autoClaimEnabled = autoClaimEnabled
        self.autoClaimPointsEnabled = autoClaimPointsEnabled
        self.logLevel = logLevel
        self.maxLogEntries = maxLogEntries
        self.appPresenceMode = appPresenceMode
        self.autoStartOnLaunch = autoStartOnLaunch
        self.startMinimized = startMinimized
        self.enableBadgesEmotes = enableBadgesEmotes
        self.mineIRLCampaigns = mineIRLCampaigns
        self.avoidDuplicateStreams = avoidDuplicateStreams
        self.antiStallRecoveryEnabled = antiStallRecoveryEnabled
        self.prioritiseFollowedStreamers = prioritiseFollowedStreamers
        self.syncMinersState = syncMinersState
        self.minerAvatarSource = minerAvatarSource
        self.accountAvatarSourcesData = accountAvatarSourcesData
        self.runInBackground = runInBackground
        self.selectedDropsFiltersData = selectedDropsFiltersData
        self.selectedEventFiltersData = selectedEventFiltersData
        self.preferredQuality = preferredQuality
        self.showClaimNotifications = showClaimNotifications
        self.ignoredWarningsData = ignoredWarningsData
        self.twitchClientId = twitchClientId
        self.swiftBotEnabled = swiftBotEnabled
        self.swiftBotEndpoint = swiftBotEndpoint
        self.swiftBotWebhookURL = swiftBotWebhookURL
        self.swiftMinerAPIEndpoint = swiftMinerAPIEndpoint
        self.swiftBotHmacSecret = swiftBotHmacSecret
        self.swiftMinerAPIKey = swiftMinerAPIKey
        self.dmCampaignCompletedEnabled = dmCampaignCompletedEnabled
        self.dmConnectionExpiredEnabled = dmConnectionExpiredEnabled
        self.dmWelcomeBackEnabled = dmWelcomeBackEnabled
        self.dmLinkRequiredEnabled = dmLinkRequiredEnabled
        self.dmCampaignDetectedEnabled = dmCampaignDetectedEnabled
        self.dmAccountActionRequiredEnabled = dmAccountActionRequiredEnabled
        self.quietHoursEnabled = quietHoursEnabled
        self.quietHoursStartMinute = quietHoursStartMinute
        self.quietHoursEndMinute = quietHoursEndMinute
        self.gamePreferencesData = gamePreferencesData
        self.miningStrategy = miningStrategy
    }
}

@Observable
@MainActor
public final class LoginItemSettings {
    public private(set) var isEnabled: Bool = false
    public private(set) var requiresApproval: Bool = false
    public private(set) var errorMessage: String?

    public init() {
        refresh()
    }

    public func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        requiresApproval = status == .requiresApproval
    }

    public func setEnabled(_ enabled: Bool) {
        errorMessage = nil

        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        refresh()
    }
}

// MARK: - Extensions

public enum AppPresenceMode: String, CaseIterable, Identifiable {
    case dockOnly
    case dockAndMenuBar
    case menuBarWhenClosed

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dockOnly:
            return "Dock only"
        case .dockAndMenuBar:
            return "Dock + menu bar icon"
        case .menuBarWhenClosed:
            return "Minimise to menu bar"
        }
    }

    public var detail: String {
        switch self {
        case .dockOnly:
            return "Default macOS app behavior with no menu bar icon."
        case .dockAndMenuBar:
            return "Keep SwiftMiner visible in the Dock and add a menu bar icon."
        case .menuBarWhenClosed:
            return "Show the Dock icon while a window is open, then keep SwiftMiner in the menu bar when windows are closed or minimised."
        }
    }

    public var showsMenuBarExtra: Bool {
        switch self {
        case .dockOnly:
            return false
        case .dockAndMenuBar, .menuBarWhenClosed:
            return true
        }
    }
}

extension Settings.LogLevel {
    /// Check if this log level should display messages of a given level
    func shouldDisplay(_ level: Settings.LogLevel) -> Bool {
        let order: [Settings.LogLevel] = [.debug, .info, .warning, .error]
        guard let selfIndex = order.firstIndex(of: self),
              let levelIndex = order.firstIndex(of: level) else {
            return true
        }
        return levelIndex >= selfIndex
    }
}


/// The retired global picture preference, kept only so stored preferences and
/// settings backups written before `AccountAvatarSource` still decode. Its one
/// remaining job is seeding `Settings.defaultAvatarSource` for accounts that
/// never made an explicit choice.
public enum MinerAvatarSource: String, Sendable {
    /// Use the miner's own custom Twitch picture, then a custom linked Discord
    /// picture. Provider-default images never count as a picture.
    case automatic
    /// The Discord account the miner is linked to, resolved through SwiftBot.
    case discord
    /// The miner's own Twitch account.
    case twitch
}

/// The preferred profile-picture service for one Twitch account. Either choice
/// keeps the other as its automatic fallback: a linked Discord user may have no
/// custom avatar, and a Twitch account may still be on the stock 404-user image.
public enum AccountAvatarSource: String, CaseIterable, Identifiable, Codable, Sendable {
    case twitch
    case discord

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .twitch: return "Twitch"
        case .discord: return "Discord"
        }
    }

    public var detail: String {
        switch self {
        case .twitch:
            return "Uses this Twitch account's picture, or the linked Discord one when Twitch has none."
        case .discord:
            return "Uses the linked Discord avatar, or Twitch when unavailable."
        }
    }

    /// Resolves the requested service, falling back to the other rather than
    /// displaying a provider-generated placeholder or dropping to the initial.
    public func resolve(discord: URL?, twitch: URL?) -> URL? {
        let customDiscord = MinerAvatarURL.usable(discord)
        let twitch = MinerAvatarURL.usable(twitch)
        switch self {
        case .twitch: return twitch ?? customDiscord
        case .discord: return customDiscord ?? twitch
        }
    }
}

/// When automatically downloaded updates are installed.
public enum AutoUpdateInstallPolicy: String, CaseIterable, Identifiable {
    /// Install (and relaunch) as soon as the download finishes.
    case immediate
    /// Wait until no miner is actively mining. Stalled, errored, or
    /// auth-blocked miners count as idle — an update may be the fix.
    case whenIdle
    /// Wait for a fixed hour of day.
    case scheduled

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .immediate: return "Immediately"
        case .whenIdle: return "When miners are idle"
        case .scheduled: return "At a scheduled time"
        }
    }
}
