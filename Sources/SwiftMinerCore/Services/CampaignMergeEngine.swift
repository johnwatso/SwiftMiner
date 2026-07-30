import Foundation

/// Engine responsible for merging fresh API data with persistent cache.
/// Implements John's "Merge Rules" (Phase 4) to ensure data stability.
public enum CampaignMergeEngine {
    
    /// Merges fresh campaigns from the API with existing cached campaigns.
    /// - Parameters:
    ///   - fresh: The fresh campaigns just returned by Twitch.
    ///   - cached: The campaigns currently stored in the disk cache.
    ///   - inventory: The authoritative user inventory (for preservation rules).
    /// - Returns: The final merged list of campaigns.
    public static func merge(
        fresh: [Campaign],
        cached: [Campaign],
        inventory: InventorySnapshot?
    ) -> [Campaign] {
        // CRITICAL (Part 4): Never overwrite cache with an empty API response.
        // This protects against transient API failures or empty responses clearing the UI.
        guard !fresh.isEmpty else {
            Logger.campaigns.warning("API returned empty results; preserving entire cache.")
            return cached
        }
        
        var merged = fresh
        let freshIds = Set(fresh.map { $0.id })

        // ViewerDropsDashboard deliberately contains no time-based drop details.
        // While a campaign is active, Twitch follows it with a details lookup. Once
        // it ends, that lookup is not made and the fresh record becomes an empty
        // shell. Preserve the cached reward metadata so Ended can still show the
        // drop artwork. It lives in the normal per-account campaign cache and is
        // therefore removed along with the campaign by the usual retention cleanup.
        let cachedByID = Dictionary(cached.map { ($0.id, $0) }, uniquingKeysWith: {
            $0.drops.count >= $1.drops.count ? $0 : $1
        })
        merged = fresh.map { freshCampaign in
            guard let cachedCampaign = cachedByID[freshCampaign.id] else {
                return freshCampaign
            }
            return preserveCachedDropsIfNeeded(
                forEndedCampaign: freshCampaign,
                cached: cachedCampaign
            )
        }
        
        // Preserve campaigns NOT in the fresh response if they meet preservation rules.
        for cachedCampaign in cached {
            if !freshIds.contains(cachedCampaign.id) {
                if shouldPreserve(cachedCampaign, inventory: inventory) {
                    Logger.campaigns.info("Preserving campaign not in API: \(cachedCampaign.name)")
                    merged.append(cachedCampaign)
                } else {
                    Logger.campaigns.info("Dropping expired/unlinked campaign: \(cachedCampaign.name)")
                }
            }
        }
        
        return merged
    }

    private static func preserveCachedDropsIfNeeded(
        forEndedCampaign fresh: Campaign,
        cached: Campaign
    ) -> Campaign {
        guard fresh.endDate <= Date(),
              fresh.drops.isEmpty,
              !cached.drops.isEmpty
        else {
            return fresh
        }

        Logger.campaigns.info("Preserving \(cached.drops.count) cached reward(s) for ended campaign: \(fresh.name)")
        return Campaign(
            id: fresh.id,
            name: fresh.name,
            game: fresh.game,
            status: fresh.status,
            startDate: fresh.startDate,
            endDate: fresh.endDate,
            drops: cached.drops,
            channels: fresh.channels,
            isAccountConnected: fresh.isAccountConnected,
            allowIsEnabled: fresh.allowIsEnabled,
            isPrioritised: fresh.isPrioritised
        )
    }
    
    /// Determines if a campaign missing from the fresh API response should be preserved.
    /// Rule: Preserve if it exists in inventory OR it expired within the last 14 days.
    /// Exception: Evict if status is EXPIRED and all drops are claimed (campaign fully complete).
    private static func shouldPreserve(_ campaign: Campaign, inventory: InventorySnapshot?) -> Bool {
        // 1. Check if it exists in inventory (any drop benefit ID present)
        let inInventory = campaign.drops.contains { drop in
            inventory?.benefitIDs.contains(drop.benefitID) ?? false
        }

        if inInventory { return true }

        // 2. If Twitch no longer returns a completed campaign, keep local history.
        // This is intentionally only used for missing campaigns; fresh Twitch data
        // still wins whenever a campaign ID appears in the API response.
        if campaign.isFullyComplete {
            return true
        }

        // 3. Check if it expired recently (last 14 days)
        let fourteenDays: TimeInterval = 14 * 24 * 3600
        let expirationCutoff = Date().addingTimeInterval(-fourteenDays)

        if campaign.endDate > expirationCutoff {
            return true
        }

        return false
    }
}
