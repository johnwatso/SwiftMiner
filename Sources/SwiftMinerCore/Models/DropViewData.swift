import Foundation

/// One miner account's state for a reward inside an aggregated campaign.
public struct DropAccountState: Codable, Sendable, Identifiable, Equatable {
    public var id: String { accountID }
    public let accountID: String
    public let currentMinutes: Int
    public let progress: Double
    public let isClaimed: Bool
    public let isClaimable: Bool
    public let isEarnable: Bool

    public init(
        accountID: String,
        currentMinutes: Int,
        progress: Double,
        isClaimed: Bool,
        isClaimable: Bool,
        isEarnable: Bool
    ) {
        self.accountID = accountID
        self.currentMinutes = currentMinutes
        self.progress = progress
        self.isClaimed = isClaimed
        self.isClaimable = isClaimable
        self.isEarnable = isEarnable
    }

    fileprivate func merging(with incoming: DropAccountState) -> DropAccountState {
        DropAccountState(
            accountID: accountID,
            currentMinutes: max(currentMinutes, incoming.currentMinutes),
            progress: max(progress, incoming.progress),
            isClaimed: isClaimed || incoming.isClaimed,
            isClaimable: isClaimable || incoming.isClaimable,
            isEarnable: isEarnable || incoming.isEarnable
        )
    }
}

/// UI-ready data model for a single drop.
/// Provides final, computed state for granular drop display.
public struct DropViewData: Codable, Sendable, Identifiable, Equatable {
    /// The unique drop ID
    public let id: String
    /// The name of the drop (reward name)
    public let name: String
    /// Description of the drop
    public let description: String?
    /// URL for the drop reward image
    public let imageURL: URL?
    /// Type of reward (inGame, badge, emote)
    public let rewardType: RewardType
    /// Minutes required to earn this drop
    public let requiredMinutes: Int
    /// Current minutes watched toward this drop
    public let currentMinutes: Int
    /// Progress percentage (0.0 to 1.0)
    public let progress: Double
    /// Whether the drop has been claimed
    public let isClaimed: Bool
    /// Whether the drop is ready to be claimed (100% progress but not yet claimed)
    public let isClaimable: Bool
    /// Whether the drop is currently earnable (linked, preconditions met, not yet claimed)
    public let isEarnable: Bool
    /// Whether this drop requires purchasing Twitch subscriptions.
    public let isSubscriptionRequired: Bool
    /// Per-miner reward state retained by the multi-account aggregation layer.
    /// Nil means this is still an account-local or legacy projection.
    public let accountStates: [DropAccountState]?

    /// Accounts whose inventory confirms this specific reward was claimed.
    public var claimedAccountIDs: [String]? {
        accountStates?
            .filter(\.isClaimed)
            .map(\.accountID)
            .sorted()
    }

    public init(
        id: String,
        name: String,
        description: String?,
        imageURL: URL?,
        rewardType: RewardType,
        requiredMinutes: Int,
        currentMinutes: Int,
        progress: Double,
        isClaimed: Bool,
        isClaimable: Bool,
        isEarnable: Bool,
        isSubscriptionRequired: Bool = false,
        accountStates: [DropAccountState]? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.imageURL = imageURL
        self.rewardType = rewardType
        self.requiredMinutes = requiredMinutes
        self.currentMinutes = currentMinutes
        self.progress = progress
        self.isClaimed = isClaimed
        self.isClaimable = isClaimable
        self.isEarnable = isEarnable
        self.isSubscriptionRequired = isSubscriptionRequired
        self.accountStates = accountStates
    }

    /// Merge the same logical reward from another account or duplicate campaign entry.
    public func merging(with incoming: DropViewData) -> DropViewData {
        DropViewData(
            id: id,
            name: name.isEmpty ? incoming.name : name,
            description: description ?? incoming.description,
            imageURL: imageURL ?? incoming.imageURL,
            rewardType: rewardType,
            requiredMinutes: max(requiredMinutes, incoming.requiredMinutes),
            currentMinutes: max(currentMinutes, incoming.currentMinutes),
            progress: max(progress, incoming.progress),
            isClaimed: isClaimed || incoming.isClaimed,
            isClaimable: isClaimable || incoming.isClaimable,
            isEarnable: isEarnable || incoming.isEarnable,
            isSubscriptionRequired: isSubscriptionRequired || incoming.isSubscriptionRequired,
            accountStates: Self.mergeAccountStates(accountStates, incoming.accountStates)
        )
    }

    /// Replace fleet-wide reward state with one selected miner's state.
    public func projected(forAccountID accountID: String) -> DropViewData {
        guard let accountStates else { return self }
        let state = accountStates.first { $0.accountID == accountID }

        return DropViewData(
            id: id,
            name: name,
            description: description,
            imageURL: imageURL,
            rewardType: rewardType,
            requiredMinutes: requiredMinutes,
            currentMinutes: state?.currentMinutes ?? 0,
            progress: state?.progress ?? 0,
            isClaimed: state?.isClaimed ?? false,
            isClaimable: state?.isClaimable ?? false,
            isEarnable: state?.isEarnable ?? false,
            isSubscriptionRequired: isSubscriptionRequired,
            accountStates: state.map { [$0] } ?? []
        )
    }

    private static func mergeAccountStates(
        _ existing: [DropAccountState]?,
        _ incoming: [DropAccountState]?
    ) -> [DropAccountState]? {
        guard existing != nil || incoming != nil else { return nil }

        var statesByAccount: [String: DropAccountState] = [:]
        for state in (existing ?? []) + (incoming ?? []) {
            if let current = statesByAccount[state.accountID] {
                statesByAccount[state.accountID] = current.merging(with: state)
            } else {
                statesByAccount[state.accountID] = state
            }
        }
        return statesByAccount.values.sorted { $0.accountID < $1.accountID }
    }
}
