import Foundation

// Claiming ready drops, and the heuristics that keep Twitch's internal test campaigns from
// being mistaken for real progress.
//
// Split out of MinerEngine.swift, which had grown past the point where one file could be read.

extension MinerEngine {
    func claimReadyDrops() async -> Bool {
        // Always ask inventory for claimable drops. Twitch can expose a ready claim there
        // after the campaign disappears from dashboard data or local campaign state.
        var didClaimAnyDrop = false
        do {
            let inventoryService = await dropsService.getInventoryService()
            let snapshot = try await inventoryService.fetchInventory(forceRefresh: true)
            onOperationalEvent?(.successfulPoll)
            onOperationalEvent?(.inventoryRefresh)
            syncCampaigns(with: snapshot)

            let claimedDropIds = Set(
                allCampaigns
                    .flatMap(\.drops)
                    .filter(\.isClaimed)
                    .map(\.id)
            )
            let claimable = snapshot.progress.filter {
                $0.isComplete
                    && !$0.isClaimed
                    && !claimedDropIds.contains($0.dropId)
                    && !isLikelyInternalTestProgress($0)
            }
            let skippedInternalTestDrops = snapshot.progress.filter {
                $0.isComplete
                    && !$0.isClaimed
                    && !claimedDropIds.contains($0.dropId)
                    && isLikelyInternalTestProgress($0)
            }.count

            if claimable.isEmpty {
                log("No claimable drops found in inventory")
            } else {
                log("Found \(claimable.count) claimable drop(s): \(claimable.map { $0.dropName }.joined(separator: ", "))")
            }
            if skippedInternalTestDrops > 0 {
                log("Skipped \(skippedInternalTestDrops) internal/test claimable drop(s)")
            }

            for progress in claimable {
                let result = await claimService.claimDrop(progress)
                if result.success {
                    let confirmation = result.confirmedByInventory ? " (confirmed by fresh inventory)" : ""
                    log("Claimed drop: \(result.dropName)\(confirmation)")

                    // TDM PARITY: Delete notification after successful claim
                    try? await apiClient.deleteNotification(id: progress.id)

                    let drop = Drop(
                        id: progress.dropId,
                        name: progress.dropName,
                        requiredMinutes: progress.requiredMinutes
                    )
                    _ = progressEventTracker.markClaimed(
                        campaignId: progress.campaignId,
                        dropId: progress.dropId,
                        dropLabel: progress.dropName.isEmpty ? dropLabel(for: progress.dropId, campaignId: progress.campaignId) : progress.dropName
                    )
                    recordActivityEvent(.dropClaimed, "Claimed \(result.dropName)")
                    onDropClaimed?(drop)
                    session?.dropsClaimed += 1
                    didClaimAnyDrop = true

                    // Send local notification if enabled
                    if showClaimNotifications, let notificationService = notificationService {
                        await notificationService.notifyDropClaimed(
                            campaignName: result.campaignName,
                            dropName: result.dropName
                        )
                    }
                } else {
                    let reason = result.error.map { " (\($0))" } ?? ""
                    let retry = result.retryAfter.map { " — retry in \(Int($0))s" } ?? ""
                    log("Warning: Drop claim returned not-success for \(progress.dropName)\(reason)\(retry)")
                }

                // Small delay between claims
                do {
                    try await runtimeClock.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    return didClaimAnyDrop
                }
            }

            if didClaimAnyDrop {
                let refreshedSnapshot = try await inventoryService.fetchInventory(forceRefresh: true)
                onOperationalEvent?(.successfulPoll)
                onOperationalEvent?(.inventoryRefresh)
                syncCampaigns(with: refreshedSnapshot)
            }
        } catch {
            log("Error fetching claimable drops: \(error.localizedDescription)")
        }

        return didClaimAnyDrop
    }

    private func isLikelyInternalTestProgress(_ progress: Progress) -> Bool {
        if progress.isLikelyInternalTestProgress {
            return true
        }

        guard let campaign = allCampaigns.first(where: { $0.id == progress.campaignId }) else {
            return false
        }

        if campaign.isLikelyInternalTestCampaign {
            return true
        }

        return campaign.drops.first(where: { $0.id == progress.dropId })?.isLikelyInternalTestDrop ?? false
    }

    func isLikelyInternalTestDropEvent(dropId: String, campaignId: String?) -> Bool {
        guard let campaignId,
              let campaign = allCampaigns.first(where: { $0.id == campaignId }) else {
            return false
        }

        if campaign.isLikelyInternalTestCampaign {
            return true
        }

        return campaign.drops.first(where: { $0.id == dropId })?.isLikelyInternalTestDrop ?? false
    }
}
