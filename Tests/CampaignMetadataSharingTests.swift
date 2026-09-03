import XCTest
@testable import SwiftMinerCore

/// The cross-miner campaign metadata cache lets one account's fetch serve the rest, which is
/// most of SwiftMiner's Twitch traffic. It is only safe while the shared copy carries no
/// account-specific state and reconstruction never downgrades an account's link state — a
/// campaign wrongly marked unlinked drops out of mining entirely.
final class CampaignMetadataSharingTests: XCTestCase {
    private func drop(id: String, claimed: Bool, minutes: Int?) -> Drop {
        Drop(
            id: id,
            name: "Drop \(id)",
            requiredMinutes: 60,
            benefitID: "benefit-\(id)",
            progress: minutes.map {
                Progress(
                    id: "progress-\(id)",
                    dropId: id,
                    dropName: "Drop \(id)",
                    campaignId: "campaign",
                    currentMinutes: $0,
                    requiredMinutes: 60
                )
            },
            isClaimed: claimed
        )
    }

    private func campaign(
        connected: Bool,
        prioritised: Bool = false,
        claimed: Bool = false,
        minutes: Int? = nil
    ) -> Campaign {
        Campaign(
            id: "campaign",
            name: "Season 4 Launch",
            game: Game(id: "1", name: "Battlefield 6"),
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_600_000),
            drops: [drop(id: "a", claimed: claimed, minutes: minutes)],
            channels: [Channel(id: "c1", login: "streamer", displayName: "Streamer")],
            isAccountConnected: connected,
            allowIsEnabled: true,
            isPrioritised: prioritised
        )
    }

    /// Nothing account-specific may be published to a cache other accounts read from.
    func testSharedMetadataStripsAccountSpecificState() {
        let source = campaign(connected: true, prioritised: true, claimed: true, minutes: 42)

        let shared = TwitchAPIClient.sharedCampaignMetadata(from: source)

        XCTAssertFalse(shared.isAccountConnected)
        XCTAssertEqual(shared.drops.count, 1)
        XCTAssertFalse(shared.drops[0].isClaimed)
        XCTAssertNil(shared.drops[0].progress)

        // Campaign-global facts must survive, or the cache would be useless.
        XCTAssertEqual(shared.name, "Season 4 Launch")
        XCTAssertEqual(shared.game.name, "Battlefield 6")
        XCTAssertEqual(shared.startDate, source.startDate)
        XCTAssertEqual(shared.endDate, source.endDate)
        XCTAssertEqual(shared.channels.map(\.id), ["c1"])
        XCTAssertEqual(shared.drops[0].requiredMinutes, 60)
        XCTAssertEqual(shared.allowIsEnabled, true)
    }

    /// The reason the shared path was previously restricted to already-linked campaigns:
    /// a linked account whose dashboard entry does not say so must not be served a copy
    /// that reports it unlinked.
    func testReconstructionDoesNotDowngradeKnownLinkState() {
        let shared = TwitchAPIClient.sharedCampaignMetadata(from: campaign(connected: true))
        let dashboardSaysUnlinked = campaign(connected: false, prioritised: true)

        let rebuilt = TwitchAPIClient.campaign(
            fromSharedMetadata: shared,
            accountContext: dashboardSaysUnlinked,
            // What a real fetch previously established for this account.
            isAccountConnected: true
        )

        XCTAssertTrue(rebuilt.isAccountConnected)
        XCTAssertTrue(rebuilt.isPrioritised, "user preference comes from the account context")
    }

    func testReconstructionKeepsUnlinkedWhenNeitherSourceKnowsBetter() {
        let shared = TwitchAPIClient.sharedCampaignMetadata(from: campaign(connected: true))
        let context = campaign(connected: false)

        let rebuilt = TwitchAPIClient.campaign(
            fromSharedMetadata: shared,
            accountContext: context,
            isAccountConnected: false
        )

        XCTAssertFalse(rebuilt.isAccountConnected)
    }

    /// A shared copy must never leak one account's claim or progress state into another's.
    func testReconstructionDoesNotInheritAnotherAccountsProgress() {
        let shared = TwitchAPIClient.sharedCampaignMetadata(
            from: campaign(connected: true, claimed: true, minutes: 59)
        )

        let rebuilt = TwitchAPIClient.campaign(
            fromSharedMetadata: shared,
            accountContext: campaign(connected: false),
            isAccountConnected: true
        )

        XCTAssertFalse(rebuilt.drops[0].isClaimed)
        XCTAssertNil(rebuilt.drops[0].progress)
    }

    /// Slow campaign metadata may outlive mutable account state, but link state itself must
    /// remain bounded so linking or unlinking is detected promptly.
    func testCacheTTLsSeparateSharedMetadataFromMutableLinkState() async {
        let client = TwitchAPIClient(
            authService: TwitchAuthService(clientId: "test", tokenStore: InMemoryTokenStore()),
            clientId: "test",
            persistsCampaignCaches: false
        )
        let campaignCheckInterval: TimeInterval = 5 * 60

        let detailsTTL = await client.campaignDetailsCacheTTL
        let linkStateTTL = await client.campaignLinkStateTTL
        let sharedMetadataTTL = await client.sharedCampaignMetadataTTL
        XCTAssertGreaterThan(detailsTTL, campaignCheckInterval)
        XCTAssertGreaterThan(linkStateTTL, campaignCheckInterval)
        XCTAssertLessThanOrEqual(linkStateTTL, detailsTTL)
        XCTAssertGreaterThan(sharedMetadataTTL, detailsTTL)
    }

    /// A campaign whose approved-channel list gates who can mine it keeps the short window:
    /// for a scarce esports campaign that list is the difference between catching a match
    /// window and missing it, and the long window exists only to spare relaunches the
    /// re-fetch of campaigns anyone can watch anywhere.
    func testRestrictedCampaignsKeepTheShortDetailsWindow() async {
        let client = TwitchAPIClient(
            authService: TwitchAuthService(clientId: "test", tokenStore: InMemoryTokenStore()),
            clientId: "test",
            persistsCampaignCaches: false
        )

        let openCampaign = Self.campaign(channels: [], allowIsEnabled: nil)
        let restrictedByList = Self.campaign(
            channels: [Channel(id: "1", login: "ow_esports", displayName: "OWCS")],
            allowIsEnabled: nil
        )
        let restrictedByFlag = Self.campaign(channels: [], allowIsEnabled: true)

        let longWindow = await client.campaignDetailsCacheTTL
        let shortWindow = await client.restrictedCampaignDetailsCacheTTL
        XCTAssertLessThan(shortWindow, longWindow)

        let openTTL = await client.detailsCacheTTL(for: openCampaign)
        let listTTL = await client.detailsCacheTTL(for: restrictedByList)
        let flagTTL = await client.detailsCacheTTL(for: restrictedByFlag)
        XCTAssertEqual(openTTL, longWindow)
        XCTAssertEqual(listTTL, shortWindow)
        XCTAssertEqual(flagTTL, shortWindow)
    }

    /// Twitch returns a restricted campaign's approved channels on one fetch and omits them
    /// on the next. The omission is not a claim the restriction was lifted — the allow flag
    /// stays set — so dropping the list leaves nothing to probe and the campaign mineable
    /// only through a directory that does not list these channels. That is how an esports
    /// window is missed while the campaign sits there looking active.
    func testAnApprovedChannelListSurvivesAFetchThatOmitsIt() async {
        let client = TwitchAPIClient(
            authService: TwitchAuthService(clientId: "test", tokenStore: InMemoryTokenStore()),
            clientId: "test",
            persistsCampaignCaches: false
        )
        let channels = [Channel(id: "1", login: "ow_esports", displayName: "OWCS")]

        let withACL = await client.reconcilingCampaign(
            Self.campaign(channels: channels, allowIsEnabled: true)
        )
        XCTAssertEqual(withACL.channels.map(\.login), ["ow_esports"])

        let withoutACL = await client.reconcilingCampaign(
            Self.campaign(channels: [], allowIsEnabled: true)
        )
        XCTAssertEqual(withoutACL.channels.map(\.login), ["ow_esports"])
    }

    /// A campaign Twitch says is open to everyone must not inherit a list from anywhere.
    ///
    /// Narrowed from "not flagged restricted" to "explicitly flagged unrestricted" once the
    /// ALGS campaigns showed what the other case costs: those arrived with `allowIsEnabled`
    /// absent, SwiftMiner read the silence as open, and mined them from the public directory
    /// on channels that could never credit the drop. `false` is an answer and is obeyed;
    /// `nil` is a missing field and no longer overrides what we already knew.
    func testAnUnrestrictedCampaignIsNeverGivenChannels() async {
        let client = TwitchAPIClient(
            authService: TwitchAuthService(clientId: "test", tokenStore: InMemoryTokenStore()),
            clientId: "test",
            persistsCampaignCaches: false
        )

        _ = await client.reconcilingCampaign(
            Self.campaign(channels: [Channel(id: "1", login: "ow_esports", displayName: "OWCS")], allowIsEnabled: true)
        )
        let open = await client.reconcilingCampaign(
            Self.campaign(channels: [], allowIsEnabled: false)
        )

        XCTAssertTrue(open.channels.isEmpty)
    }

    /// The other half of that distinction: an absent flag is not a statement, so a campaign
    /// known to be restricted keeps its ACL rather than falling back to the public directory.
    func testACampaignWhoseRestrictionFlagWentMissingKeepsItsChannels() async {
        let client = TwitchAPIClient(
            authService: TwitchAuthService(clientId: "test", tokenStore: InMemoryTokenStore()),
            clientId: "test",
            persistsCampaignCaches: false
        )

        _ = await client.reconcilingCampaign(
            Self.campaign(channels: [Channel(id: "1", login: "ow_esports", displayName: "OWCS")], allowIsEnabled: true)
        )
        let silent = await client.reconcilingCampaign(
            Self.campaign(channels: [], allowIsEnabled: nil)
        )

        XCTAssertEqual(silent.channels.map(\.login), ["ow_esports"])
        XCTAssertTrue(silent.hasChannelRestrictions)
    }

    func testFreshDashboardWindowWinsOverCachedCampaignDetails() {
        let dashboardStart = Date(timeIntervalSince1970: 1_800_000_000)
        let dashboardEnd = Date(timeIntervalSince1970: 1_800_100_000)
        let dashboard = Campaign(
            id: "campaign",
            name: "Campaign",
            game: Game(id: "1", name: "Overwatch"),
            status: .active,
            startDate: dashboardStart,
            endDate: dashboardEnd,
            drops: [],
            channels: [],
            isAccountConnected: true
        )
        let staleDetails = Campaign(
            id: "campaign",
            name: "Campaign",
            game: Game(id: "1", name: "Overwatch"),
            status: .expired,
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_100_000),
            drops: [drop(id: "drop", claimed: false, minutes: nil)],
            channels: [Channel(id: "1", login: "ow_esports", displayName: "OWCS")],
            isAccountConnected: true,
            allowIsEnabled: true
        )

        let merged = TwitchAPIClient.mergeBasicCampaign(dashboard, withDetails: staleDetails)

        XCTAssertEqual(merged.status, .active)
        XCTAssertEqual(merged.startDate, dashboardStart)
        XCTAssertEqual(merged.endDate, dashboardEnd)
        XCTAssertEqual(merged.drops.map(\.id), ["drop"], "slow detail metadata is still enriched")
        XCTAssertEqual(merged.channels.map(\.login), ["ow_esports"])
    }

    private static func campaign(channels: [Channel], allowIsEnabled: Bool?) -> Campaign {
        Campaign(
            id: "campaign",
            name: "Campaign",
            game: Game(id: "1", name: "Overwatch"),
            status: .active,
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_100_000),
            drops: [],
            channels: channels,
            isAccountConnected: true,
            allowIsEnabled: allowIsEnabled
        )
    }

    /// A shared cache hit that depends on a remembered link result must expire with that
    /// result, rather than silently stretching it for another full details-cache window.
    func testSharedDetailsNeverOutliveRememberedLinkState() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let linkStateExpiration = now.addingTimeInterval(90)

        let expiration = TwitchAPIClient.sharedCampaignDetailsExpiration(
            now: now,
            detailsTTL: 20 * 60,
            basicIsAccountConnected: false,
            knownLinkStateExpiresAt: linkStateExpiration
        )

        XCTAssertEqual(expiration, linkStateExpiration)
    }

    func testDashboardConfirmedLinkageUsesNormalDetailsLifetime() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        let expiration = TwitchAPIClient.sharedCampaignDetailsExpiration(
            now: now,
            detailsTTL: 20 * 60,
            basicIsAccountConnected: true,
            knownLinkStateExpiresAt: now.addingTimeInterval(90)
        )

        XCTAssertEqual(expiration, now.addingTimeInterval(20 * 60))
    }
}
