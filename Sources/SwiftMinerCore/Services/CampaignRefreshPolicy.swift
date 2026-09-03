import Foundation

/// The fields of a `Campaign` that can stop the miner from working it.
///
/// Every one of these has, at some point, been erased by a single degraded Twitch response
/// and taken a campaign out of mining until a cache expired. The pattern kept recurring
/// because the rule was rediscovered field by field, one missed drop window at a time:
/// the campaign window and status first, then the approved-channel list after a missed
/// esports event, then drops and account link after the ALGS Split 2 PL charm was lost on
/// three consecutive match days.
///
/// So the rule is stated once here instead. Adding a case obliges you to declare its
/// `refreshPolicy` — the switch is exhaustive — and `CampaignRefreshPolicyTests` fails if a
/// new stored property appears on `Campaign` without being classified as gating or not.
public enum CampaignMiningGate: String, CaseIterable, Sendable {
    case status
    case startDate
    case endDate
    case drops
    case isAccountConnected
    case channels
    case allowIsEnabled

    /// What to do when a refresh disagrees with what we already knew.
    public enum RefreshPolicy: Sendable {
        /// Take the newest answer unconditionally. Correct only for fields carried by a
        /// source that is refetched every cycle and is authoritative — `ViewerDropsDashboard`
        /// supplies the window and status, so a campaign extension or a status correction
        /// must be able to land immediately.
        case trustNewest

        /// Keep the more capable of the two. A refresh may add a drop list, an ACL, or a
        /// confirmed link; it may not take one away. Twitch omitting a field is a lost
        /// response, not a statement that the campaign lost the thing.
        case neverRegress
    }

    public var refreshPolicy: RefreshPolicy {
        switch self {
        case .status, .startDate, .endDate:
            return .trustNewest
        case .drops, .isAccountConnected, .channels, .allowIsEnabled:
            return .neverRegress
        }
    }

    /// Stored properties of `Campaign` that cannot stop the miner: identity, display, and
    /// local user state. Listed so the reflection test can prove every property is
    /// classified rather than merely unmentioned.
    public static let nonGatingCampaignProperties: Set<String> = [
        "id",
        "name",
        "game",
        "isPrioritised"
    ]
}

/// What we last knew about a campaign, from whichever store holds it.
///
/// Deliberately a plain value: the reconciliation rule is worth testing on its own, without
/// a client, a cache, or a network in the way.
public struct RememberedCampaignFacts: Sendable {
    public var drops: [Drop]?
    public var channels: [Channel]?
    public var isAccountConnected: Bool?
    public var allowIsEnabled: Bool?

    public init(
        drops: [Drop]? = nil,
        channels: [Channel]? = nil,
        isAccountConnected: Bool? = nil,
        allowIsEnabled: Bool? = nil
    ) {
        self.drops = drops
        self.channels = channels
        self.isAccountConnected = isAccountConnected
        self.allowIsEnabled = allowIsEnabled
    }

    public var isEmpty: Bool {
        drops == nil && channels == nil && isAccountConnected == nil && allowIsEnabled == nil
    }
}

/// The single place a freshly fetched campaign is reconciled against the last good answer.
public enum CampaignRefreshPolicy {
    public struct Reconciliation: Sendable {
        public let campaign: Campaign
        /// Which gates had to be repaired, for logging. Empty is the normal case.
        public let repaired: [CampaignMiningGate]

        public var describesRepair: Bool { !repaired.isEmpty }
    }

    /// Applies `refreshPolicy` to every gate.
    ///
    /// The invariant: **a refresh may never leave a campaign less capable than the last good
    /// answer for it.** A campaign that comes back without its drops, without its approved
    /// channels, unlinked, or no longer flagged restricted has lost information, and acting
    /// on that loss is what strands a drop mid-window.
    ///
    /// Restoring stale facts cannot resurrect finished work: claimed state is recomputed
    /// from inventory benefit IDs on every merge — see `DropsService.mergeInventory` — so a
    /// reinstated drop list is re-marked against the account's real inventory before it is
    /// ever mined.
    public static func reconcile(
        fetched: Campaign,
        remembered: RememberedCampaignFacts
    ) -> Reconciliation {
        guard !remembered.isEmpty else {
            return Reconciliation(campaign: fetched, repaired: [])
        }

        var campaign = fetched
        var repaired: [CampaignMiningGate] = []

        // `status`, `startDate`, `endDate` are `.trustNewest`: nothing to do. They arrive
        // from the dashboard on every refresh, and `mergeBasicCampaign` already prefers that
        // copy over cached details for exactly this reason.

        // Restriction flag first: the approved-channel rule below reads it.
        //
        // `allowIsEnabled` has three states and only two of them are answers. `false` is
        // Twitch saying the campaign is open to everyone, and it is obeyed — a campaign that
        // genuinely opened up must not stay restricted. `nil` is the field being absent,
        // which says nothing at all, and treating that silence as "open" is what let the
        // ALGS campaigns be mined from the public directory: SwiftMiner watched an ordinary
        // Apex streamer that could never credit the drop, and the campaign took the
        // four-hour `campaignDetailsCacheTTL` instead of the twenty-minute restricted one.
        if campaign.allowIsEnabled == nil, remembered.allowIsEnabled == true {
            campaign = campaign.withAllowIsEnabled(true)
            repaired.append(.allowIsEnabled)
        }

        // An empty drop list is never Twitch reporting completion: a finished campaign
        // returns its drops with `isClaimed` set. On a campaign whose window has closed
        // there is nothing left to protect, so leave it alone.
        if campaign.drops.isEmpty,
           campaign.isTimeActive,
           let drops = remembered.drops,
           !drops.isEmpty {
            campaign = campaign.withDrops(drops)
            repaired.append(.drops)
        }

        // Only reinstate an ACL onto a campaign Twitch still flags as restricted. A campaign
        // that genuinely opened up must not be re-restricted to channels it no longer needs.
        if campaign.hasUnresolvedChannelRestrictions,
           let channels = remembered.channels,
           !channels.isEmpty {
            campaign = campaign.withChannels(channels)
            repaired.append(.channels)
        }

        // An unlinked campaign whose game is not prioritised is never attempted, so one
        // contrary answer is enough to retire it. The caller bounds how long a remembered
        // link stays usable — see `campaignLinkStateTTL` — so a real unlink still lands.
        if !campaign.isAccountConnected, remembered.isAccountConnected == true {
            campaign = campaign.withAccountConnected(true)
            repaired.append(.isAccountConnected)
        }

        return Reconciliation(campaign: campaign, repaired: repaired)
    }
}
