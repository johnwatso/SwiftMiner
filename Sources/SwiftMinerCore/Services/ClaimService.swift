import Foundation

public enum ClaimFailureKind: String, Sendable, Equatable {
    case transient
    case rateLimited
    case authentication
    case rejected
    case cancelled
    case unknown
}

/// Result of a claim operation
public struct ClaimResult: Sendable {
    public let dropInstanceId: String
    public let dropName: String
    public let campaignName: String
    public let success: Bool
    public let error: String?
    public let claimedAt: Date
    public let confirmedByInventory: Bool
    public let failureKind: ClaimFailureKind?
    public let retryAfter: TimeInterval?

    public init(
        dropInstanceId: String,
        dropName: String,
        campaignName: String,
        success: Bool,
        error: String? = nil,
        claimedAt: Date = Date(),
        confirmedByInventory: Bool = false,
        failureKind: ClaimFailureKind? = nil,
        retryAfter: TimeInterval? = nil
    ) {
        self.dropInstanceId = dropInstanceId
        self.dropName = dropName
        self.campaignName = campaignName
        self.success = success
        self.error = error
        self.claimedAt = claimedAt
        self.confirmedByInventory = confirmedByInventory
        self.failureKind = failureKind
        self.retryAfter = retryAfter
    }
}

/// Service for claiming drop rewards
public actor ClaimService {
    private let apiClient: TwitchAPIClient
    private let dropsService: DropsService?
    private let runtimeClock: RuntimeClock
    private let claimConfirmation: (@Sendable (Progress) async -> Bool)?
    private struct RetryState: Sendable {
        let attempts: Int
        let retryAtTick: UInt64
    }
    private var retryStateByDrop: [String: RetryState] = [:]

    public init(
        apiClient: TwitchAPIClient,
        dropsService: DropsService? = nil,
        runtimeClock: RuntimeClock = .continuous,
        claimConfirmation: (@Sendable (Progress) async -> Bool)? = nil
    ) {
        self.apiClient = apiClient
        self.dropsService = dropsService
        self.runtimeClock = runtimeClock
        self.claimConfirmation = claimConfirmation
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

        if let retryState = retryStateByDrop[progress.id],
           !runtimeClock.hasReached(retryState.retryAtTick) {
            return ClaimResult(
                dropInstanceId: progress.id,
                dropName: progress.dropName,
                campaignName: "",
                success: false,
                error: "Claim retry is cooling down",
                failureKind: .transient,
                retryAfter: max(1, runtimeClock.remainingSeconds(until: retryState.retryAtTick))
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

            if response.status == "CLAIMED" || response.status == "SUCCESS" {
                retryStateByDrop[progress.id] = nil
                return ClaimResult(
                    dropInstanceId: progress.id,
                    dropName: progress.dropName,
                    campaignName: campaignName,
                    success: true
                )
            }

            if await confirmClaim(progress) {
                retryStateByDrop[progress.id] = nil
                return ClaimResult(
                    dropInstanceId: progress.id,
                    dropName: progress.dropName,
                    campaignName: campaignName,
                    success: true,
                    confirmedByInventory: true
                )
            }

            return scheduleRetry(
                for: progress,
                campaignName: campaignName,
                kind: .rejected,
                message: "Twitch returned claim status \(response.status)",
                requestedDelay: nil
            )
        } catch {
            let classification = Self.classifyFailure(error)
            if classification.kind != .authentication,
               classification.kind != .rejected,
               classification.kind != .cancelled,
               await confirmClaim(progress) {
                retryStateByDrop[progress.id] = nil
                return ClaimResult(
                    dropInstanceId: progress.id,
                    dropName: progress.dropName,
                    campaignName: "",
                    success: true,
                    confirmedByInventory: true
                )
            }

            return scheduleRetry(
                for: progress,
                campaignName: "",
                kind: classification.kind,
                message: error.localizedDescription,
                requestedDelay: classification.retryAfter
            )
        }
    }

    static func classifyFailure(_ error: Error) -> (kind: ClaimFailureKind, retryAfter: TimeInterval?) {
        if error is CancellationError { return (.cancelled, nil) }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return (.cancelled, nil)
        }
        if let twitchError = error as? TwitchMinerError {
            switch twitchError {
            case .rateLimited(let retryAfter): return (.rateLimited, retryAfter)
            case .networkError: return (.transient, nil)
            case .apiError(let statusCode, _):
                if statusCode == 408 || statusCode == 425 || statusCode == 429 || (500...599).contains(statusCode) {
                    return (statusCode == 429 ? .rateLimited : .transient, nil)
                }
                if statusCode == 401 || statusCode == 403 { return (.authentication, nil) }
                return (.rejected, nil)
            case .tokenExpired, .authenticationFailed, .keychainError:
                return (.authentication, nil)
            case .dropAlreadyClaimed:
                return (.rejected, nil)
            default:
                return (.unknown, nil)
            }
        }
        if error is URLError { return (.transient, nil) }
        return (.unknown, nil)
    }

    private func scheduleRetry(
        for progress: Progress,
        campaignName: String,
        kind: ClaimFailureKind,
        message: String,
        requestedDelay: TimeInterval?
    ) -> ClaimResult {
        guard kind == .transient || kind == .rateLimited || kind == .unknown else {
            retryStateByDrop[progress.id] = nil
            return ClaimResult(
                dropInstanceId: progress.id,
                dropName: progress.dropName,
                campaignName: campaignName,
                success: false,
                error: message,
                failureKind: kind
            )
        }

        let attempts = retryStateByDrop[progress.id].map { $0.attempts + 1 } ?? 1
        let exponential = min(30 * pow(2, Double(attempts - 1)), 10 * 60)
        let delay = max(1, requestedDelay ?? exponential)
        retryStateByDrop[progress.id] = RetryState(
            attempts: attempts,
            retryAtTick: runtimeClock.deadline(after: delay)
        )
        return ClaimResult(
            dropInstanceId: progress.id,
            dropName: progress.dropName,
            campaignName: campaignName,
            success: false,
            error: message,
            failureKind: kind,
            retryAfter: delay
        )
    }

    private func confirmClaim(_ progress: Progress) async -> Bool {
        if let claimConfirmation {
            return await claimConfirmation(progress)
        }
        guard let dropsService else { return false }

        do {
            let inventoryService = await dropsService.getInventoryService()
            let result = try await inventoryService.fetchInventoryResult(forceRefresh: true)
            guard result.isAuthoritative else { return false }
            if result.snapshot.progress.contains(where: { $0.id == progress.id && $0.isClaimed }) {
                return true
            }

            guard let campaign = try? await dropsService.getCampaign(id: progress.campaignId),
                  let drop = campaign.drops.first(where: { $0.id == progress.dropId }) else {
                return false
            }
            let benefitIDs = drop.benefitIds.isEmpty
                ? (drop.benefitID.isEmpty ? [] : [drop.benefitID])
                : drop.benefitIds
            return benefitIDs.contains { result.snapshot.benefitIDs.contains($0) }
        } catch {
            return false
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
                do {
                    try await runtimeClock.sleep(nanoseconds: 500_000_000)
                } catch {
                    break
                }
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
                do {
                    try await runtimeClock.sleep(nanoseconds: 500_000_000)
                } catch {
                    break
                }
            }
        } catch {
            traceClaim("claimAllDrops(from:) failed fetching inventory: \(error.localizedDescription)")
        }

        return (successful, failed)
    }
}
