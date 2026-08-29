import Foundation
import SwiftMinerCore

/// Reclaims what the removed Steam artwork feature left behind on an existing install.
///
/// Steam artwork was dropped because Twitch box art is now requested at a usable resolution, and
/// Steam answered 200 with a blank grey placeholder for titles it had no library art for — so
/// preferring it could replace real artwork with nothing. Deleting the code stops new writes, but
/// an install that used it still holds a cache directory of downloaded JPEGs and three defaults
/// keys that nothing will ever read again. Nothing else would clear them, so this does, once.
///
/// Custom uploaded artwork is untouched: it lives in Application Support under `CustomArtwork`
/// and is addressed by `GamePreference.customArtworkURL`, neither of which this goes near.
enum LegacySteamArtworkCleanup {
    /// Set once the cleanup has run, so a launch on a clean install costs nothing.
    static let completedKey = "legacySteamArtworkCleanupCompletedAt"

    private static let defaultsKeys = [
        "preferSteamArtwork",
        "steamArtworkAppIdCache",
        "steamArtworkManualOverrides",
    ]

    static func runIfNeeded(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        guard defaults.object(forKey: completedKey) == nil else { return }

        for key in defaultsKeys where defaults.object(forKey: key) != nil {
            defaults.removeObject(forKey: key)
        }

        if let directory = cacheDirectory(fileManager: fileManager),
           fileManager.fileExists(atPath: directory.path) {
            do {
                try fileManager.removeItem(at: directory)
                Logger.artwork.info("Removed the unused Steam artwork cache at \(directory.path)")
            } catch {
                // Purely reclaimed disk space — a failure costs the user nothing beyond the bytes,
                // and the flag below still gets set so this is not retried on every launch.
                Logger.artwork.error("Could not remove the unused Steam artwork cache: \(error.localizedDescription)")
            }
        }

        defaults.set(Date(), forKey: completedKey)
    }

    /// The directory the removed `SteamArtworkService` downloaded into.
    private static func cacheDirectory(fileManager: FileManager) -> URL? {
        fileManager
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("SwiftMiner/SteamArtwork", isDirectory: true)
    }
}
