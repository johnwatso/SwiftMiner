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
    case allowIsEnabled
    case channels

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

        // Keep the implementation exhaustive as well as the policy declaration. Adding a
        // gate must add its reconciliation here; classifying a property alone is not enough.
        // `allCases` follows declaration order, which deliberately restores the restriction
        // flag before reconciling its approved-channel list.
        for gate in CampaignMiningGate.allCases {
            switch gate {
            case .status, .startDate, .endDate:
                // These values come from a validated dashboard shell on every refresh.
                precondition(gate.refreshPolicy == .trustNewest)

            case .allowIsEnabled:
                precondition(gate.refreshPolicy == .neverRegress)
                // Both true and false are answers. Nil means Twitch omitted the field, so
                // retain whichever explicit answer was most recently observed.
                if campaign.allowIsEnabled == nil,
                   let allowIsEnabled = remembered.allowIsEnabled {
                    campaign = campaign.withAllowIsEnabled(allowIsEnabled)
                    repaired.append(.allowIsEnabled)
                }

            case .drops:
                precondition(gate.refreshPolicy == .neverRegress)
                // Campaign definitions are stable for the campaign window. Restore missing
                // members as well as an entirely missing list; a response containing only
                // one tier must not erase another unfinished tier.
                if campaign.isTimeActive,
                   let rememberedDrops = remembered.drops,
                   !rememberedDrops.isEmpty {
                    let mergedDrops = neverRegressingDrops(
                        fetched: campaign.drops,
                        remembered: rememberedDrops
                    )
                    if mergedDrops != campaign.drops {
                        campaign = campaign.withDrops(mergedDrops)
                        repaired.append(.drops)
                    }
                }

            case .isAccountConnected:
                precondition(gate.refreshPolicy == .neverRegress)
                // The caller bounds the remembered answer with campaignLinkStateTTL.
                if !campaign.isAccountConnected, remembered.isAccountConnected == true {
                    campaign = campaign.withAccountConnected(true)
                    repaired.append(.isAccountConnected)
                }

            case .channels:
                precondition(gate.refreshPolicy == .neverRegress)
                // An explicit false above opens the campaign and suppresses both remembered
                // and contradictory returned ACL members. Otherwise retain missing members
                // of a restriction Twitch still reports.
                if campaign.allowIsEnabled == false {
                    if !campaign.channels.isEmpty {
                        campaign = campaign.withChannels([])
                        repaired.append(.channels)
                    }
                } else if campaign.hasChannelRestrictions,
                          let rememberedChannels = remembered.channels,
                          !rememberedChannels.isEmpty {
                    let mergedChannels = neverRegressingChannels(
                        fetched: campaign.channels,
                        remembered: rememberedChannels
                    )
                    if mergedChannels != campaign.channels {
                        campaign = campaign.withChannels(mergedChannels)
                        repaired.append(.channels)
                    }
                }
            }
        }

        return Reconciliation(campaign: campaign, repaired: repaired)
    }

    private static func neverRegressingDrops(fetched: [Drop], remembered: [Drop]) -> [Drop] {
        let fetchedIDs = Set(fetched.map(\.id))
        guard remembered.contains(where: { !fetchedIDs.contains($0.id) }) else { return fetched }

        let fetchedByID = Dictionary(fetched.map { ($0.id, $0) }, uniquingKeysWith: { newest, _ in newest })
        let rememberedIDs = Set(remembered.map(\.id))
        return remembered.map { fetchedByID[$0.id] ?? $0 }
            + fetched.filter { !rememberedIDs.contains($0.id) }
    }

    private static func neverRegressingChannels(fetched: [Channel], remembered: [Channel]) -> [Channel] {
        func identity(_ channel: Channel) -> String {
            let login = channel.login.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return login.isEmpty ? channel.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : login
        }

        let fetchedIdentities = Set(fetched.map(identity))
        guard remembered.contains(where: { !fetchedIdentities.contains(identity($0)) }) else { return fetched }

        let fetchedByIdentity = Dictionary(
            fetched.map { (identity($0), $0) },
            uniquingKeysWith: { newest, _ in newest }
        )
        let rememberedIdentities = Set(remembered.map(identity))
        return remembered.map { fetchedByIdentity[identity($0)] ?? $0 }
            + fetched.filter { !rememberedIdentities.contains(identity($0)) }
    }
}
