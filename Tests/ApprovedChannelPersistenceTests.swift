import XCTest
@testable import SwiftMinerCore

/// Exercises the esports path without an esports campaign.
///
/// The failure being guarded against needs three things to line up: a campaign restricted to
/// specific channels, Twitch omitting that channel list on a fetch, and a relaunch in
/// between. None of that requires a live broadcast — the campaign is a value, the omission is
/// a fetch that returns no channels, and a relaunch is a save followed by a load. What cannot
/// be faked here is Twitch actually behaving this way, and the diagnostics already show it
/// does: two campaigns reported "no usable approved-channel list" sixteen times each, having
/// been probed by channel name earlier in the same session.
final class ApprovedChannelPersistenceTests: XCTestCase {
    private let userLogin = "persistence-tests"

    private func campaign(
        id: String = "campaign-1",
        channels: [Channel],
        endDate: Date = Date().addingTimeInterval(24 * 60 * 60)
    ) -> Campaign {
        Campaign(
            id: id,
            name: "OWCS Stage 3",
            game: Game(id: "515025", name: "Overwatch"),
            status: .active,
            startDate: Date().addingTimeInterval(-3600),
            endDate: endDate,
            drops: [],
            channels: channels,
            isAccountConnected: true,
            allowIsEnabled: true
        )
    }

    private let owcs = [Channel(id: "12345", login: "ow_esports", displayName: "OWCS")]

    override func tearDown() {
        CampaignDetailsDiskCache.clear(userLogin: userLogin)
        super.tearDown()
    }

    /// The case that costs a drop window: the list is learned, the app restarts, and the
    /// first fetch after launch comes back without it.
    func testAnApprovedChannelListSurvivesARelaunch() {
        CampaignDetailsDiskCache.save(
            details: [:],
            linkStates: [:],
            approvedChannels: [
                "campaign-1": CampaignDetailsDiskCache.ApprovedChannelsEntry(
                    channels: owcs,
                    expiresAt: Date().addingTimeInterval(24 * 60 * 60)
                )
            ],
            userLogin: userLogin
        )

        let restored = CampaignDetailsDiskCache.load(userLogin: userLogin)

        XCTAssertEqual(restored.approvedChannels["campaign-1"]?.channels.map(\.login), ["ow_esports"])
    }

    /// Past the campaign's end the list can never be useful again, so it is not carried
    /// forward — otherwise the file accumulates every restricted campaign ever seen.
    func testAListIsDroppedOnceItsCampaignHasEnded() {
        CampaignDetailsDiskCache.save(
            details: [:],
            linkStates: [:],
            approvedChannels: [
                "campaign-1": CampaignDetailsDiskCache.ApprovedChannelsEntry(
                    channels: owcs,
                    expiresAt: Date().addingTimeInterval(-60)
                )
            ],
            userLogin: userLogin
        )

        XCTAssertNil(CampaignDetailsDiskCache.load(userLogin: userLogin).approvedChannels["campaign-1"])
    }

    /// A file written before approved channels were persisted must still load.
    func testAFileWithoutApprovedChannelsStillLoads() {
        CampaignDetailsDiskCache.save(
            details: [
                "details-1": CampaignDetailsDiskCache.DetailsEntry(
                    campaign: campaign(channels: []),
                    expiresAt: Date().addingTimeInterval(3600)
                )
            ],
            linkStates: [:],
            userLogin: userLogin
        )

        let restored = CampaignDetailsDiskCache.load(userLogin: userLogin)

        XCTAssertEqual(restored.details.count, 1)
        XCTAssertTrue(restored.approvedChannels.isEmpty)
    }

    /// End to end through the client: learn a list, restart, and have a fetch that omits it
    /// still produce a campaign with channels to probe.
    func testAClientRestoresAndReinstatesAcrossARestart() async {
        let first = makeClient()
        await first.setUserLogin(userLogin)
        _ = await first.reinstatingKnownApprovedChannels(campaign(channels: owcs))
        await first.persistCampaignCachesIfNeeded()

        // A new client is a new launch: nothing in memory.
        let second = makeClient()
        await second.setUserLogin(userLogin)
        await second.loadPersistedCampaignCachesIfNeeded()
        let omitted = await second.reinstatingKnownApprovedChannels(campaign(channels: []))

        XCTAssertEqual(omitted.channels.map(\.login), ["ow_esports"])
    }

    private func makeClient() -> TwitchAPIClient {
        TwitchAPIClient(
            authService: TwitchAuthService(clientId: "test", tokenStore: InMemoryTokenStore()),
            clientId: "test",
            persistsCampaignCaches: true
        )
    }
}
