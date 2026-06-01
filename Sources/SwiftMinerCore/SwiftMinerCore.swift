// SwiftMinerCore - A native Swift Twitch drops miner

// Models
@_exported import struct Foundation.Date
@_exported import struct Foundation.URL

import Foundation

// Public API
public struct SwiftMinerCore {
    /// Version of the library
    public static let version = "1.0.0"
    
    /// Minimum supported macOS version
    public static let minimumMacOSVersion = "26.0"
}

// MARK: - Notifications

public extension Notification.Name {
    /// Posted by MiningDataCoordinator when Steam artwork enrichment completes.
    static let steamArtworkDidUpdate = Notification.Name("com.swiftminer.steamArtworkDidUpdate")

    /// Posted when the cached Drops campaign feed has been refreshed.
    static let dropsCampaignsDidUpdate = Notification.Name("com.swiftminer.dropsCampaignsDidUpdate")
}
