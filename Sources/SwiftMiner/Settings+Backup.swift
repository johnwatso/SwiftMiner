import Foundation
import SwiftMinerCore

// Export and import of the settings backup file.
//
// Split out of Settings.swift, which had grown past the point where one file could be read.
// `SettingsBackup` itself lives in SettingsSupportingTypes.swift; this is the mapping between
// it and the live settings, which is the part that has to be revisited whenever a setting is
// added, removed, or renamed.

extension Settings {
    public func exportBackupData(includeSecrets: Bool = false) throws -> Data {
        let backup = SettingsBackup(
            exportedAt: Date(),
            autoClaimEnabled: autoClaimEnabled,
            autoClaimPointsEnabled: autoClaimPointsEnabled,
            logLevel: logLevel.rawValue,
            maxLogEntries: maxLogEntries,
            appPresenceMode: appPresenceMode.rawValue,
            autoStartOnLaunch: autoStartOnLaunch,
            startMinimized: startMinimized,
            enableBadgesEmotes: enableBadgesEmotes,
            mineIRLCampaigns: mineIRLCampaigns,
            avoidDuplicateStreams: avoidDuplicateStreams,
            antiStallRecoveryEnabled: antiStallRecoveryEnabled,
            prioritiseFollowedStreamers: prioritiseFollowedStreamers,
            syncMinersState: syncMinersState,
            minerAvatarSource: minerAvatarSource.rawValue,
            accountAvatarSourcesData: accountAvatarSourcesData,
            runInBackground: runInBackground,
            selectedDropsFiltersData: selectedDropsFiltersData,
            selectedEventFiltersData: selectedEventFiltersData,
            preferredQuality: preferredQuality.rawValue,
            showClaimNotifications: showClaimNotifications,
            ignoredWarningsData: ignoredWarningsData,
            twitchClientId: includeSecrets ? twitchClientId : "",
            swiftBotEnabled: swiftBotEnabled,
            swiftBotEndpoint: swiftBotEndpoint,
            swiftBotWebhookURL: swiftBotWebhookURL,
            swiftMinerAPIEndpoint: swiftMinerAPIEndpoint,
            swiftBotHmacSecret: includeSecrets ? swiftBotHmacSecret : "",
            swiftMinerAPIKey: includeSecrets ? swiftMinerAPIKey : "",
            dmCampaignCompletedEnabled: dmCampaignCompletedEnabled,
            dmConnectionExpiredEnabled: dmConnectionExpiredEnabled,
            dmWelcomeBackEnabled: dmWelcomeBackEnabled,
            dmLinkRequiredEnabled: dmLinkRequiredEnabled,
            dmCampaignDetectedEnabled: dmCampaignDetectedEnabled,
            dmAccountActionRequiredEnabled: dmAccountActionRequiredEnabled,
            quietHoursEnabled: quietHoursEnabled,
            quietHoursStartMinute: quietHoursStartMinute,
            quietHoursEndMinute: quietHoursEndMinute,
            gamePreferencesData: gamePreferencesData,
            miningStrategy: miningStrategy.rawValue
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(backup)
    }

    public func importBackupData(_ data: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup = try decoder.decode(SettingsBackup.self, from: data)

        autoClaimEnabled = backup.autoClaimEnabled
        autoClaimPointsEnabled = backup.autoClaimPointsEnabled
        logLevel = Settings.LogLevel(rawValue: backup.logLevel) ?? .info
        maxLogEntries = backup.maxLogEntries
        appPresenceMode = AppPresenceMode(rawValue: backup.appPresenceMode) ?? .dockOnly
        autoStartOnLaunch = backup.autoStartOnLaunch
        startMinimized = backup.startMinimized
        enableBadgesEmotes = backup.enableBadgesEmotes
        mineIRLCampaigns = backup.mineIRLCampaigns ?? false
        avoidDuplicateStreams = backup.avoidDuplicateStreams
        antiStallRecoveryEnabled = backup.antiStallRecoveryEnabled
        prioritiseFollowedStreamers = backup.prioritiseFollowedStreamers
        syncMinersState = backup.syncMinersState
        minerAvatarSource = backup.minerAvatarSource.flatMap(MinerAvatarSource.init(rawValue:)) ?? .automatic
        // A backup from before per-account pictures carries none; leaving the map
        // empty lets every account inherit `defaultAvatarSource`, which the
        // legacy value just above still drives.
        accountAvatarSourcesData = backup.accountAvatarSourcesData ?? "{}"
        runInBackground = backup.runInBackground
        selectedDropsFiltersData = backup.selectedDropsFiltersData
        selectedEventFiltersData = backup.selectedEventFiltersData
        preferredQuality = Settings.StreamQuality(rawValue: backup.preferredQuality) ?? .auto
        showClaimNotifications = backup.showClaimNotifications
        ignoredWarningsData = backup.ignoredWarningsData
        if !backup.twitchClientId.isEmpty { twitchClientId = backup.twitchClientId }
        swiftBotEnabled = backup.swiftBotEnabled
        swiftBotEndpoint = backup.swiftBotEndpoint
        swiftBotWebhookURL = backup.swiftBotWebhookURL
        swiftMinerAPIEndpoint = backup.swiftMinerAPIEndpoint
        if !backup.swiftBotHmacSecret.isEmpty { swiftBotHmacSecret = backup.swiftBotHmacSecret }
        if !backup.swiftMinerAPIKey.isEmpty { swiftMinerAPIKey = backup.swiftMinerAPIKey }
        dmCampaignCompletedEnabled = backup.dmCampaignCompletedEnabled
        dmConnectionExpiredEnabled = backup.dmConnectionExpiredEnabled
        dmWelcomeBackEnabled = backup.dmWelcomeBackEnabled
        dmLinkRequiredEnabled = backup.dmLinkRequiredEnabled
        dmCampaignDetectedEnabled = backup.dmCampaignDetectedEnabled
        dmAccountActionRequiredEnabled = backup.dmAccountActionRequiredEnabled
        quietHoursEnabled = backup.quietHoursEnabled
        quietHoursStartMinute = normalizedMinute(backup.quietHoursStartMinute)
        quietHoursEndMinute = normalizedMinute(backup.quietHoursEndMinute)
        gamePreferencesData = backup.gamePreferencesData
        miningStrategy = MiningStrategy(rawValue: backup.miningStrategy) ?? .mineAll
    }

    func normalizedMinute(_ minute: Int) -> Int {
        min(max(minute, 0), 23 * 60 + 59)
    }

    public func ensureSwiftBotSecrets() {
        if swiftMinerAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).count < 32 ||
            swiftMinerAPIKey == "dev-key-change-in-production" {
            swiftMinerAPIKey = Self.generateSecret()
        }
        if swiftBotHmacSecret.trimmingCharacters(in: .whitespacesAndNewlines).count < 32 {
            swiftBotHmacSecret = Self.generateSecret()
        }
    }

    private static func generateSecret(byteCount: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess {
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        return UUID().uuidString.replacingOccurrences(of: "-", with: "") +
            UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }
}
