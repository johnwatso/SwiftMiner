import Foundation

/// Identifies stock profile images supplied by Twitch and Discord.
///
/// A provider may return a valid, downloadable image even when its user has
/// not chosen a picture. Those images are useful on the provider's own site,
/// but they obscure SwiftMiner's more helpful status/initial fallback and can
/// prevent a custom picture from the other linked service from being used.
public enum MinerAvatarURL {
    /// Returns `nil` for a missing, insecure, or provider-default profile image.
    public static func usable(_ url: URL?) -> URL? {
        guard let url,
              url.scheme?.lowercased() == "https",
              !isProviderPlaceholder(url) else {
            return nil
        }
        return url
    }

    public static func isProviderPlaceholder(_ url: URL) -> Bool {
        isGenericTwitchProfileImage(url) || isGenericDiscordProfileImage(url)
    }

    /// Twitch's stock `404_user` image is returned for accounts without a
    /// configured profile picture.
    public static func isGenericTwitchProfileImage(_ url: URL) -> Bool {
        url.path.lowercased().contains("/xarth/404_user_")
    }

    /// Discord's `/embed/avatars` images are generated defaults, not pictures
    /// selected by the user. SwiftBot returns them when Discord supplies no
    /// avatar hash, so they must be filtered by consumers.
    public static func isGenericDiscordProfileImage(_ url: URL) -> Bool {
        let host = url.host?.lowercased() ?? ""
        return host.hasSuffix("discordapp.com")
            && url.path.lowercased().contains("/embed/avatars/")
    }
}
