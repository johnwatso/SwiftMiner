import Foundation

// MARK: - GameAggregate

/// Aggregated game-level progress across all campaigns and accounts.
///
/// Deduplicates campaigns by `campaign.id` and drops by `drop.id`.
/// - A drop is **earned** if `progress?.isComplete == true`.
/// - A drop is **claimable** if `isClaimable == true`.
/// - A drop is **claimed** if `isClaimed == true`.
/// - Progress is calculated as `earnedDrops / totalDrops`.
public struct GameAggregate: Identifiable, Sendable, Equatable {
    public let id: String
    public let gameName: String
    public let artworkURL: URL?
    public let totalDrops: Int
    public let earnedDrops: Int
    public let claimedDrops: Int
    public let claimableDrops: Int

    public var progressFraction: Double {
        guard totalDrops > 0 else { return 0 }
        return Double(earnedDrops) / Double(totalDrops)
    }

    public var progressPercentage: Double {
        progressFraction * 100
    }

    public var isCompleted: Bool {
        totalDrops > 0 && claimedDrops == totalDrops
    }

    public var isFinalizing: Bool {
        totalDrops > 0 && earnedDrops == totalDrops && claimedDrops < totalDrops
    }

    public init(
        id: String,
        gameName: String,
        artworkURL: URL? = nil,
        totalDrops: Int,
        earnedDrops: Int,
        claimedDrops: Int,
        claimableDrops: Int = 0
    ) {
        self.id = id
        self.gameName = gameName
        self.artworkURL = artworkURL
        self.totalDrops = totalDrops
        self.earnedDrops = earnedDrops
        self.claimedDrops = claimedDrops
        self.claimableDrops = claimableDrops
    }
}

// MARK: - GameAggregateBuilder

/// Builds `GameAggregate` models from a list of campaigns.
public enum GameAggregateBuilder {
    /// Creates a deduplicated, game-level aggregation from campaigns.
    ///
    /// Rules:
    /// 1. Campaigns are deduplicated by `campaign.id`.
    /// 2. Drops are deduplicated by `drop.id` across all campaigns for the same game.
    /// 3. A drop is **earned** if `progress?.isComplete == true`.
    /// 4. A drop is **claimable** if `isClaimable == true`.
    /// 5. A drop is **claimed** if `isClaimed == true`.
    /// 6. Game progress is `earnedDrops / totalDrops`.
    /// 7. `isClaimable` is exposed separately but does NOT affect progress.
    public static func build(from campaigns: [Campaign]) -> [GameAggregate] {
        // 0. Hard exclude "Just Chatting" before any grouping or deduplication.
        let filteredCampaigns = campaigns.filter { !isJustChatting($0) }

        // 1. Deduplicate campaigns by ID — keep the richest drop set.
        var uniqueCampaignsById: [String: Campaign] = [:]
        for campaign in filteredCampaigns {
            let existing = uniqueCampaignsById[campaign.id]
            if existing == nil {
                uniqueCampaignsById[campaign.id] = campaign
            } else if campaign.drops.count > (existing?.drops.count ?? 0) {
                uniqueCampaignsById[campaign.id] = campaign
            }
        }
        let uniqueCampaigns = Array(uniqueCampaignsById.values)

        // 2. Group by game.
        var campaignsByGame: [String: [Campaign]] = [:]
        for campaign in uniqueCampaigns {
            let key = gameKey(for: campaign.game)
            campaignsByGame[key, default: []].append(campaign)
        }

        // 3. Build aggregates.
        return campaignsByGame.map { (key, gameCampaigns) in
            var gameName = ""
            var artworkURL: URL?
            var dropsById: [String: Drop] = [:]

            for campaign in gameCampaigns {
                if gameName.isEmpty {
                    gameName = campaign.game.name
                }
                if artworkURL == nil {
                    artworkURL = campaign.game.boxArtURL
                }

                for drop in campaign.drops {
                    let trimmedId = drop.id.trimmingCharacters(in: .whitespacesAndNewlines)
                    let dropKey = trimmedId.isEmpty
                        ? "name:\(drop.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
                        : "id:\(trimmedId)"

                    if let existing = dropsById[dropKey] {
                        dropsById[dropKey] = mergeDrop(existing, drop)
                    } else {
                        dropsById[dropKey] = drop
                    }
                }
            }

            let totalDrops = dropsById.count
            let earnedDrops = dropsById.values.filter { isProgressComplete($0) }.count
            let claimedDrops = dropsById.values.filter { $0.isClaimed }.count
            let claimableDrops = dropsById.values.filter { $0.isClaimable }.count

            return GameAggregate(
                id: key,
                gameName: gameName,
                artworkURL: artworkURL,
                totalDrops: totalDrops,
                earnedDrops: earnedDrops,
                claimedDrops: claimedDrops,
                claimableDrops: claimableDrops
            )
        }
        .sorted { $0.gameName < $1.gameName }
    }

    // MARK: - Private Helpers

    private static func isJustChatting(_ campaign: Campaign) -> Bool {
        let name = campaign.game.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = campaign.game.id.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.localizedCaseInsensitiveCompare("Just Chatting") == .orderedSame
            || id == "509658"
    }

    private static func gameKey(for game: Game) -> String {
        let trimmedId = game.id.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedId.isEmpty {
            return "id:\(trimmedId)"
        }
        let trimmedName = game.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty {
            return "name:\(trimmedName.lowercased())"
        }
        return "fallback:unknown-game"
    }

    private static func isProgressComplete(_ drop: Drop) -> Bool {
        drop.progress?.isComplete ?? false
    }

    private static func mergeDrop(_ existing: Drop, _ incoming: Drop) -> Drop {
        Drop(
            id: existing.id.isEmpty ? incoming.id : existing.id,
            name: existing.name.isEmpty ? incoming.name : existing.name,
            description: existing.description ?? incoming.description,
            imageURL: existing.imageURL ?? incoming.imageURL,
            requiredMinutes: max(existing.requiredMinutes, incoming.requiredMinutes),
            benefitID: existing.benefitID.isEmpty ? incoming.benefitID : existing.benefitID,
            reward: existing.reward ?? incoming.reward,
            progress: mergeProgress(existing.progress, incoming.progress),
            isClaimed: existing.isClaimed || incoming.isClaimed,
            benefitIds: Array(Set(existing.benefitIds + incoming.benefitIds)),
            preconditionDrops: existing.preconditionDrops.isEmpty ? incoming.preconditionDrops : existing.preconditionDrops,
            dropStartDate: existing.dropStartDate ?? incoming.dropStartDate,
            dropEndDate: existing.dropEndDate ?? incoming.dropEndDate
        )
    }

    private static func mergeProgress(_ existing: Progress?, _ incoming: Progress?) -> Progress? {
        guard let existing = existing else { return incoming }
        guard let incoming = incoming else { return existing }

        return Progress(
            id: existing.id.isEmpty ? incoming.id : existing.id,
            dropId: existing.dropId.isEmpty ? incoming.dropId : existing.dropId,
            dropName: existing.dropName.isEmpty ? incoming.dropName : existing.dropName,
            campaignId: existing.campaignId.isEmpty ? incoming.campaignId : existing.campaignId,
            currentMinutes: max(existing.currentMinutes, incoming.currentMinutes),
            requiredMinutes: max(existing.requiredMinutes, incoming.requiredMinutes),
            isClaimed: existing.isClaimed || incoming.isClaimed
        )
    }
}
