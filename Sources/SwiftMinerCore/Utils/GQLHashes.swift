import Foundation

/// Central registry for Twitch GraphQL persisted query hashes.
/// Storing these in one place allows for easier updates when Twitch changes their API.
public enum GQLHashes {
    /// Redirects a game name to its slug
    public static let directoryGameRedirect = "1f0300090caceec51f33c5e20647aceff9017f740f223c3c532ba6fa59f6b6cc"
    
    /// Fetches available drop campaigns (basic info only)
    public static let viewerDropsDashboard = "5a4da2ab3d5b47c9f9ce864e727b2cb346af1e3ea8b897fe8f704a97ff017619"
    
    /// Fetches detailed drop campaign info including timeBasedDrops
    public static let dropCampaignDetails = "039277bf98f3130929262cc7c6efd9c141ca3749cb6dca442fc8ead9a53f77c1"
    
    /// Fetches current user's drop inventory and progress
    public static let inventory = "d86775d0ef16a63a33ad52e80eaff963b2d5b72fada7c991504a57496e1d8e4b"
    
    /// Claims a pending drop reward
    public static let dropsPage_ClaimDropRewards = "a455deea71bdc9015b78eb49f4acfbce8baa7ccbedd28e549bb025bd0f751930"
    
    /// Obtains an access token for stream playback
    public static let playbackAccessToken = "ed230aa1e33e07eebb8928504583da78a5173989fadfb1ac94be06a04f3cdbe9"
    
    /// Fetches live channels for a specific game directory
    public static let directoryPage_Game = "76cb069d835b8a02914c08dc42c421d0dafda8af5b113a3f19141824b901402f"
    
    /// Fetches broadcast and stream info for a channel
    public static let videoPlayerStreamInfoOverlayChannel = "198492e0857f6aedead9665c81c5a06d67b25b58034649687124083ff288597d"
    
    /// Fetches current drop session progress for a channel
    public static let currentDrop = "4d06b702d25d652afb9ef835d2a550031f1cf762b193523a92166f40ea3d142b"
    
    /// Fetches drops available for a specific channel
    public static let availableDrops = "782dad0f032942260171d2d80a654f88bdd0c5a9dddc392e9bc92218a0f42d20"
    
    /// Fetches channel points balance and available claims
    public static let channelPointsContext = "374314de591e69925fce3ddc2bcf085796f56ebb8cad67a0daa3165c03adc345"
    
    /// Claims a community points bonus
    public static let claimCommunityPoints = "46aaeebe02c99afdf4fc97c7c0cba964124bf6b0af229395f1f6d1feed05b3d0"
    
    /// Deletes a notification from the Twitch inbox
    public static let notificationsDelete = "6088c5e34f1c69a334884c618589c99c73b606c721ae7c96d43bbbf1226a146b"
}
