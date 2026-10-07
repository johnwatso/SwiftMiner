import XCTest
@testable import SwiftMinerCore

/// Campaign details were cached only in actor memory, so every cold launch re-ran the
/// `DropCampaignDetails` fan-out — roughly one request per active campaign, per account,
/// through the process-wide 5-per-second gate. Persisting the cache removes that from a
/// relaunch, but only if the restored keys match what the client looks up and only if a
/// restart never extends an entry's lifetime.
final class CampaignDetailsPersistenceTests: XCTestCase {
    private let login = "swiftminerpersistencetest"
    private let otherLogin = "swiftminerotherpersistencetest"

    override func tearDown() {
        CampaignDetailsDiskCache.clear(userLogin: login)
        CampaignDetailsDiskCache.clear(userLogin: otherLogin)
        super.tearDown()
    }

    private func makeCampaign(id: String, connected: Bool) -> Campaign {
        Campaign(
            id: id,
            name: "Season 4 Launch",
            game: Game(id: "1", name: "Battlefield 6"),
            startDate: Date(timeIntervalSince1970: 1_700_000_000),
            endDate: Date(timeIntervalSince1970: 1_700_600_000),
            drops: [
                Drop(
                    id: "drop-a",
                    name: "Drop A",
                    requiredMinutes: 60,
                    benefitID: "benefit-a",
                    progress: nil,
                    isClaimed: false
                )
            ],
            channels: [Channel(id: "c1", login: "streamer", displayName: "Streamer")],
            isAccountConnected: connected,
            allowIsEnabled: true,
            isPrioritised: false
        )
    }

    private func detailsKey(_ campaignId: String) -> String {
        TwitchAPIClient.cacheKey("campaign-details", login, campaignId)
    }

    private func makeClient() -> TwitchAPIClient {
        TwitchAPIClient(
            authService: TwitchAuthService(clientId: "test", tokenStore: InMemoryTokenStore()),
            clientId: "test"
        )
    }

    /// The point of the whole change: a fresh client must answer from the restored file
    /// rather than the network. `NetworkGuard` fails the test if any request escapes, so a
    /// broken restore (or a key-format mismatch) shows up here as a network failure.
    func testRestoredDetailsAnswerWithoutNetwork() async throws {
        let campaign = makeCampaign(id: "campaign-1", connected: true)
        let expiry = Date().addingTimeInterval(10 * 60)
        CampaignDetailsDiskCache.save(
            details: [detailsKey("campaign-1"): .init(campaign: campaign, expiresAt: expiry)],
            linkStates: [detailsKey("campaign-1"): .init(isAccountConnected: true, expiresAt: expiry)],
            userLogin: login
        )

        let client = makeClient()
        await client.setUserLogin(login)

        let restored = try await client.fetchCampaignDetails(campaignId: "campaign-1", userLogin: login)

        XCTAssertEqual(restored.id, campaign.id)
        XCTAssertEqual(restored.name, campaign.name)
        XCTAssertEqual(restored.drops.count, 1)
        XCTAssertEqual(restored.channels.count, 1)
        XCTAssertTrue(restored.isAccountConnected)
    }

    /// A restart must not resurrect an entry past the lifetime the in-memory cache gave it,
    /// or a stale link state could keep a campaign in (or out of) mining indefinitely.
    func testExpiredEntriesAreNotRestored() {
        let live = makeCampaign(id: "live", connected: true)
        let stale = makeCampaign(id: "stale", connected: true)
        CampaignDetailsDiskCache.save(
            details: [
                detailsKey("live"): .init(campaign: live, expiresAt: Date().addingTimeInterval(600)),
                detailsKey("stale"): .init(campaign: stale, expiresAt: Date().addingTimeInterval(-1))
            ],
            linkStates: [
                detailsKey("live"): .init(isAccountConnected: true, expiresAt: Date().addingTimeInterval(600)),
                detailsKey("stale"): .init(isAccountConnected: true, expiresAt: Date().addingTimeInterval(-1))
            ],
            userLogin: login
        )

        let contents = CampaignDetailsDiskCache.load(userLogin: login)

        XCTAssertEqual(Set(contents.details.keys), [detailsKey("live")])
        XCTAssertEqual(Set(contents.linkStates.keys), [detailsKey("live")])
    }

    /// Link state is what lets a second account reuse shared metadata instead of repeating
    /// the fan-out, so it has to survive the round trip alongside the details.
    func testLinkStateSurvivesRoundTrip() {
        let expiry = Date().addingTimeInterval(600)
        CampaignDetailsDiskCache.save(
            details: [:],
            linkStates: [
                detailsKey("linked"): .init(isAccountConnected: true, expiresAt: expiry),
                detailsKey("unlinked"): .init(isAccountConnected: false, expiresAt: expiry)
            ],
            userLogin: login
        )

        let contents = CampaignDetailsDiskCache.load(userLogin: login)

        XCTAssertEqual(contents.linkStates[detailsKey("linked")]?.isAccountConnected, true)
        XCTAssertEqual(contents.linkStates[detailsKey("unlinked")]?.isAccountConnected, false)
    }

    func testPreReconciliationDetailsAreInvalidatedOnUpgrade() throws {
        struct LegacyEnvelope: Encodable {
            let savedAt: Date
            let details: [String: CampaignDetailsDiskCache.DetailsEntry]
            let linkStates: [String: CampaignDetailsDiskCache.LinkStateEntry]
            let approvedChannels: [String: CampaignDetailsDiskCache.ApprovedChannelsEntry]
        }

        let expiry = Date().addingTimeInterval(600)
        let legacy = LegacyEnvelope(
            savedAt: Date(),
            details: [
                detailsKey("campaign-1"): .init(
                    campaign: makeCampaign(id: "campaign-1", connected: true),
                    expiresAt: expiry
                )
            ],
            linkStates: [
                detailsKey("campaign-1"): .init(isAccountConnected: true, expiresAt: expiry)
            ],
            approvedChannels: [:]
        )
        let directory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
            .appendingPathComponent("com.swiftminer", isDirectory: true)
            .appendingPathComponent("campaign-details", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(login).json")
        try JSONEncoder().encode(legacy).write(to: url, options: .atomic)

        let restored = CampaignDetailsDiskCache.load(userLogin: login)

        XCTAssertTrue(restored.details.isEmpty, "legacy details need one fresh post-upgrade fetch")
        XCTAssertEqual(restored.linkStates[detailsKey("campaign-1")]?.isAccountConnected, true)
    }

    func testChangingLoginDropsPreviousAccountsInMemoryCaches() async throws {
        let campaign = makeCampaign(id: "campaign-1", connected: true)
        let expiry = Date().addingTimeInterval(600)
        CampaignDetailsDiskCache.save(
            details: [detailsKey(campaign.id): .init(campaign: campaign, expiresAt: expiry)],
            linkStates: [detailsKey(campaign.id): .init(isAccountConnected: true, expiresAt: expiry)],
            userLogin: login
        )

        let client = makeClient()
        await client.setUserLogin(login)
        _ = try await client.fetchCampaignDetails(campaignId: campaign.id, userLogin: login)

        await client.setUserLogin(otherLogin)

        let detailKeys = await client.campaignDetailsByKey.keys
        let linkStateKeys = await client.campaignLinkStateByKey.keys
        XCTAssertTrue(detailKeys.isEmpty)
        XCTAssertTrue(linkStateKeys.isEmpty)
    }

    func testSuccessfulClaimInvalidationRemovesPersistedDetails() async throws {
        let campaign = makeCampaign(id: "campaign-1", connected: true)
        let expiry = Date().addingTimeInterval(600)
        CampaignDetailsDiskCache.save(
            details: [detailsKey(campaign.id): .init(campaign: campaign, expiresAt: expiry)],
            linkStates: [detailsKey(campaign.id): .init(isAccountConnected: true, expiresAt: expiry)],
            userLogin: login
        )

        let client = makeClient()
        await client.setUserLogin(login)
        _ = try await client.fetchCampaignDetails(campaignId: campaign.id, userLogin: login)

        await client.invalidateCampaignDetailsAfterClaim()

        let contents = CampaignDetailsDiskCache.load(userLogin: login)
        XCTAssertTrue(contents.details.isEmpty)
        XCTAssertEqual(contents.linkStates[detailsKey(campaign.id)]?.isAccountConnected, true)
    }

    /// A claim changes only the claimed campaign's account-specific state. Clearing every
    /// entry sent all of an account's active campaigns back to Twitch after each claim.
    func testClaimInvalidationIsScopedToTheClaimedCampaign() async throws {
        let claimed = makeCampaign(id: "campaign-1", connected: true)
        let untouched = makeCampaign(id: "campaign-2", connected: true)
        let expiry = Date().addingTimeInterval(600)
        CampaignDetailsDiskCache.save(
            details: [
                detailsKey(claimed.id): .init(campaign: claimed, expiresAt: expiry),
                detailsKey(untouched.id): .init(campaign: untouched, expiresAt: expiry)
            ],
            linkStates: [:],
            userLogin: login
        )

        let client = makeClient()
        await client.setUserLogin(login)
        _ = try await client.fetchCampaignDetails(campaignId: claimed.id, userLogin: login)

        await client.invalidateCampaignDetailsAfterClaim(campaignId: claimed.id, dropId: "drop-a")

        let memoryKeys = await Set(client.campaignDetailsByKey.keys)
        XCTAssertEqual(memoryKeys, [detailsKey(untouched.id)])
        let contents = CampaignDetailsDiskCache.load(userLogin: login)
        XCTAssertEqual(Set(contents.details.keys), [detailsKey(untouched.id)])
    }

    func testClaimInvalidationFindsTheCampaignByDropAndFallsBackToClearingAll() {
        let entry = { (id: String, dropId: String) in
            TwitchAPIClient.CampaignDetailsCacheEntry(
                campaign: Campaign(
                    id: id,
                    name: id,
                    game: Game(id: "1", name: "Game"),
                    startDate: Date().addingTimeInterval(-3600),
                    endDate: Date().addingTimeInterval(3600),
                    drops: [Drop(id: dropId, name: dropId, requiredMinutes: 60)]
                ),
                expiresAt: Date().addingTimeInterval(600)
            )
        }
        let entries = ["key-a": entry("a", "drop-a"), "key-b": entry("b", "drop-b")]

        XCTAssertEqual(
            TwitchAPIClient.campaignDetailsKeysToInvalidate(in: entries, campaignKey: "key-a", dropId: "drop-b"),
            ["key-a"],
            "a matching campaign id wins"
        )
        XCTAssertEqual(
            TwitchAPIClient.campaignDetailsKeysToInvalidate(in: entries, campaignKey: nil, dropId: "drop-b"),
            ["key-b"]
        )
        XCTAssertEqual(
            TwitchAPIClient.campaignDetailsKeysToInvalidate(in: entries, campaignKey: "key-gone", dropId: nil),
            [],
            "a known campaign with no cached entry has nothing stale"
        )
        XCTAssertNil(
            TwitchAPIClient.campaignDetailsKeysToInvalidate(in: entries, campaignKey: nil, dropId: "drop-unknown")
        )
        XCTAssertNil(TwitchAPIClient.campaignDetailsKeysToInvalidate(in: entries, campaignKey: nil, dropId: nil))
    }

    /// The login comes from the Twitch API, so it is reduced to a safe basename rather than
    /// trusted as one — a traversal attempt must not write outside the cache directory.
    func testLoginIsReducedToASafeFilename() {
        let hostile = "../../../etc/swiftminerpersistencetest"
        defer { CampaignDetailsDiskCache.clear(userLogin: hostile) }

        CampaignDetailsDiskCache.save(
            details: [:],
            linkStates: ["k": .init(isAccountConnected: true, expiresAt: Date().addingTimeInterval(600))],
            userLogin: hostile
        )

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let expected = appSupport
            .appendingPathComponent("com.swiftminer", isDirectory: true)
            .appendingPathComponent("campaign-details", isDirectory: true)
            .appendingPathComponent("etcswiftminerpersistencetest.json")

        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: "/etc/swiftminerpersistencetest.json"))
    }
}
