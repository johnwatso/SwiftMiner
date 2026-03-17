import Foundation

/// Result of a claim operation
public struct ClaimResult: Sendable {
    public let dropInstanceId: String
    public let dropName: String
    public let campaignName: String
    public let success: Bool
    public let error: String?
    public let claimedAt: Date

    public init(
        dropInstanceId: String,
        dropName: String,
        campaignName: String,
        success: Bool,
        error: String? = nil,
        claimedAt: Date = Date()
    ) {
        self.dropInstanceId = dropInstanceId
        self.dropName = dropName
        self.campaignName = campaignName
        self.success = success
        self.error = error
        self.claimedAt = claimedAt
    }
}

/// Service for claiming drop rewards
public actor ClaimService {
    private let apiClient: TwitchAPIClient
    private let dropsService: DropsService?

    public init(apiClient: TwitchAPIClient, dropsService: DropsService? = nil) {
        self.apiClient = apiClient
        self.dropsService = dropsService
    }

    /// Claim a single drop
    /// - Parameter progress: The drop progress to claim
    /// - Returns: ClaimResult with the outcome
    public func claimDrop(_ progress: Progress) async -> ClaimResult {
        // Validate the drop is ready to claim
        guard !progress.isClaimed else {
            return ClaimResult(
                dropInstanceId: progress.id,
                dropName: progress.dropName,
                campaignName: "",
                success: false,
                error: "Drop already claimed"
            )
        }

        guard progress.isComplete else {
            return ClaimResult(
                dropInstanceId: progress.id,
                dropName: progress.dropName,
                campaignName: "",
                success: false,
                error: "Drop not ready to claim"
            )
        }

        do {
            traceClaim("\(progress.dropName) (instanceId=\(progress.id))")
            let response = try await apiClient.claimDrop(dropInstanceId: progress.id)

            // Get campaign name for the result
            var campaignName = ""
            if let dropsService = dropsService {
                let campaign = try? await dropsService.getCampaign(id: progress.campaignId)
                campaignName = campaign?.name ?? ""
            }

            return ClaimResult(
                dropInstanceId: progress.id,
                dropName: progress.dropName,
                campaignName: campaignName,
                success: response.status == "CLAIMED" || response.status == "SUCCESS"
            )
        } catch {
            return ClaimResult(
                dropInstanceId: progress.id,
                dropName: progress.dropName,
                campaignName: "",
                success: false,
                error: error.localizedDescription
            )
        }
    }

    /// Claim all claimable drops
    /// - Returns: Array of ClaimResult for each attempt
    public func claimAllDrops() async -> [ClaimResult] {
        guard let dropsService = dropsService else {
            return []
        }

        do {
            let claimableDrops = try await dropsService.getClaimableDrops()

            if claimableDrops.isEmpty {
                return []
            }

            var results: [ClaimResult] = []

            for drop in claimableDrops {
                let result = await claimDrop(drop)
                results.append(result)

                // Small delay between claims to avoid rate limiting
                try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
            }

            return results
        } catch {
            return []
        }
    }

    /// Claim all drops from campaigns (for MinerEngine compatibility)
    public func claimAllDrops(from campaigns: [Campaign]) async -> (successful: [Drop], failed: [(Drop, Error)]) {
        var successful: [Drop] = []
        var failed: [(Drop, Error)] = []

        guard let dropsService = dropsService else {
            return (successful, failed)
        }

        do {
            let inventory = try await dropsService.fetchInventory()
            let claimableProgress = inventory.filter { $0.isComplete && !$0.isClaimed }

            for progress in claimableProgress {
                let result = await claimDrop(progress)
                if result.success {
                    // Find matching drop from campaigns
                    for campaign in campaigns {
                        if let drop = campaign.drops.first(where: { $0.id == progress.dropId }) {
                            successful.append(drop)
                            break
                        }
                    }
                } else {
                    // Find matching drop and add to failed
                    for campaign in campaigns {
                        if let drop = campaign.drops.first(where: { $0.id == progress.dropId }) {
                            failed.append((drop, TwitchMinerError.claimFailed(result.error ?? "Unknown error")))
                            break
                        }
                    }
                }

                // Small delay between claims
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        } catch {
            // Return empty on error
        }

        return (successful, failed)
    }
}
