import XCTest
@testable import SwiftMiner
import SwiftMinerCore
import SwiftMinerService

@MainActor
final class MinerAvatarTests: XCTestCase {
    private let discord = URL(string: "https://cdn.discordapp.com/avatars/1/abc.png")!
    private let twitch = URL(string: "https://static-cdn.jtvnw.net/jtv_user_pictures/xyz-300x300.png")!

    // MARK: - Source resolution

    func testAccountSourcePrefersItsServiceAndFallsBackToTheOther() {
        XCTAssertEqual(AccountAvatarSource.discord.resolve(discord: discord, twitch: twitch), discord)
        XCTAssertEqual(AccountAvatarSource.twitch.resolve(discord: discord, twitch: twitch), twitch)
        XCTAssertEqual(AccountAvatarSource.discord.resolve(discord: nil, twitch: twitch), twitch)
        // Twitch accounts on the stock 404-user image still show a linked
        // Discord picture rather than dropping to the initial.
        XCTAssertEqual(AccountAvatarSource.twitch.resolve(discord: discord, twitch: nil), discord)
        XCTAssertNil(AccountAvatarSource.twitch.resolve(discord: nil, twitch: nil))
    }

    func testAccountAvatarSourcesDefaultToTwitchAndPersistIndependently() throws {
        let settings = Settings.shared
        let previousData = settings.accountAvatarSourcesData
        let previousLegacy = settings.minerAvatarSource
        defer {
            settings.accountAvatarSourcesData = previousData
            settings.minerAvatarSource = previousLegacy
        }
        settings.accountAvatarSourcesData = "{}"
        settings.minerAvatarSource = .automatic

        XCTAssertEqual(settings.avatarSource(forAccountId: "john"), .twitch)
        XCTAssertEqual(settings.avatarSource(forAccountId: "ryan"), .twitch)

        settings.setAvatarSource(.discord, forAccountId: "john")
        settings.setAvatarSource(.twitch, forAccountId: "ryan")

        let stored = try XCTUnwrap(Settings.appStorageStore.string(forKey: "accountAvatarSourcesData"))
        let persisted = try JSONDecoder().decode(
            [String: AccountAvatarSource].self,
            from: Data(stored.utf8)
        )
        XCTAssertEqual(persisted["john"], .discord)
        XCTAssertEqual(persisted["ryan"], .twitch)

        settings.removeAvatarSource(forAccountId: "john")
        XCTAssertEqual(settings.avatarSource(forAccountId: "john"), .twitch)
    }

    /// A setup that had picked Discord under the old global preference must not
    /// silently revert to Twitch pictures when the choice became per-account.
    func testUnsetAccountsInheritTheRetiredGlobalPreference() {
        let settings = Settings.shared
        let previousData = settings.accountAvatarSourcesData
        let previousLegacy = settings.minerAvatarSource
        defer {
            settings.accountAvatarSourcesData = previousData
            settings.minerAvatarSource = previousLegacy
        }
        settings.accountAvatarSourcesData = "{}"

        settings.minerAvatarSource = .discord
        XCTAssertEqual(settings.avatarSource(forAccountId: "john"), .discord)

        settings.minerAvatarSource = .twitch
        XCTAssertEqual(settings.avatarSource(forAccountId: "john"), .twitch)

        // An explicit per-account choice always wins over the legacy default.
        settings.minerAvatarSource = .discord
        settings.setAvatarSource(.twitch, forAccountId: "john")
        XCTAssertEqual(settings.avatarSource(forAccountId: "john"), .twitch)
    }

    /// The settings row and the miner header redraw off observation of the
    /// stored selection, so a change has to reach observers that only read
    /// through `avatarSource(forAccountId:)`.
    func testChangingAnAccountSourceNotifiesObservers() {
        final class Box: @unchecked Sendable { var fired = false }
        let box = Box()

        let settings = Settings.shared
        let previousData = settings.accountAvatarSourcesData
        defer { settings.accountAvatarSourcesData = previousData }
        settings.accountAvatarSourcesData = "{}"

        withObservationTracking {
            _ = settings.avatarSource(forAccountId: "john")
        } onChange: {
            box.fired = true
        }

        settings.setAvatarSource(.discord, forAccountId: "john")
        XCTAssertTrue(box.fired)
    }

    func testAccountAvatarSourcesSurviveABackupRoundTrip() throws {
        let settings = Settings.shared
        let previousData = settings.accountAvatarSourcesData
        defer { settings.accountAvatarSourcesData = previousData }

        settings.accountAvatarSourcesData = "{}"
        settings.setAvatarSource(.discord, forAccountId: "john")

        let backup = try settings.exportBackupData()
        settings.accountAvatarSourcesData = "{}"
        try settings.importBackupData(backup)

        XCTAssertEqual(settings.avatarSource(forAccountId: "john"), .discord)
    }

    // MARK: - Twitch avatar cache

    func testMissingEntryNeedsRefresh() {
        XCTAssertTrue(TwitchAvatarStore.needsRefresh(nil))
    }

    func testFreshEntryIsNotRefetched() {
        let now = Date()
        let entry = TwitchAvatarStore.Entry(url: twitch, fetchedAt: now.addingTimeInterval(-60 * 60))
        XCTAssertFalse(TwitchAvatarStore.needsRefresh(entry, now: now))
    }

    func testEntryOlderThanRefreshIntervalIsRefetched() {
        let now = Date()
        let entry = TwitchAvatarStore.Entry(
            url: twitch,
            fetchedAt: now.addingTimeInterval(-TwitchAvatarStore.refreshInterval - 1)
        )
        XCTAssertTrue(TwitchAvatarStore.needsRefresh(entry, now: now))
    }

    func testExplicitRefreshReplacesAFreshCachedTwitchAvatar() async {
        let settings = Settings.shared
        let previousData = settings.twitchAvatarsData
        defer { settings.twitchAvatarsData = previousData }

        settings.twitchAvatarsData = TwitchAvatarStore.encode([
            "42": TwitchAvatarStore.Entry(url: twitch, fetchedAt: Date())
        ])
        let store = TwitchAvatarStore(settings: settings)
        let replacement = URL(string: "https://static-cdn.jtvnw.net/jtv_user_pictures/new-300x300.png")!
        var resolutions = 0

        await store.refresh(accountId: "42") {
            resolutions += 1
            return replacement
        }

        XCTAssertEqual(resolutions, 1, "An explicit picker action must bypass the daily URL cache")
        XCTAssertEqual(store.url(forAccountId: "42"), replacement)
    }

    func testExplicitRefreshRetainsCachedAvatarAfterTransportFailure() async {
        let settings = Settings.shared
        let previousData = settings.twitchAvatarsData
        defer { settings.twitchAvatarsData = previousData }

        settings.twitchAvatarsData = TwitchAvatarStore.encode([
            "42": TwitchAvatarStore.Entry(url: twitch, fetchedAt: Date())
        ])
        let store = TwitchAvatarStore(settings: settings)

        await store.refresh(accountId: "42") { nil }

        XCTAssertEqual(store.url(forAccountId: "42"), twitch)
    }

    func testEntriesRoundTripThroughStorage() {
        let entry = TwitchAvatarStore.Entry(url: twitch, fetchedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let decoded = TwitchAvatarStore.decode(TwitchAvatarStore.encode(["42": entry]))
        XCTAssertEqual(decoded, ["42": entry])
    }

    func testMalformedStorageDecodesAsEmpty() {
        XCTAssertTrue(TwitchAvatarStore.decode("not json").isEmpty)
        XCTAssertTrue(TwitchAvatarStore.decode("{}").isEmpty)
    }

    func testGenericTwitchProfileImageIsNotUsedAsAnAvatar() {
        let generic = URL(string: "https://static-cdn.jtvnw.net/jtv_user_pictures/xarth/404_user_300x300.png")!
        XCTAssertTrue(TwitchAvatarStore.isGenericTwitchProfileImage(generic))

        let settings = Settings.shared
        settings.twitchAvatarsData = TwitchAvatarStore.encode([
            "generic": TwitchAvatarStore.Entry(url: generic, fetchedAt: Date())
        ])
        let store = TwitchAvatarStore(settings: settings)
        XCTAssertNil(store.url(forAccountId: "generic"))
        settings.twitchAvatarsData = "{}"
    }

    func testGenericDiscordProfileImageIsUsedOnlyForAnExplicitDiscordChoice() {
        let generic = URL(string: "https://cdn.discordapp.com/embed/avatars/3.png")!

        XCTAssertTrue(MinerAvatarURL.isGenericDiscordProfileImage(generic))
        XCTAssertEqual(AccountAvatarSource.discord.resolve(discord: generic, twitch: twitch), generic)
        XCTAssertEqual(AccountAvatarSource.twitch.resolve(discord: generic, twitch: twitch), twitch)
        XCTAssertNil(AccountAvatarSource.twitch.resolve(discord: generic, twitch: nil))
    }

    func testSwiftBotRetainsDiscordDefaultAvatarForAnExplicitDiscordChoice() throws {
        let generic = URL(string: "https://cdn.discordapp.com/embed/avatars/3.png")!
        let data = Data(#"{"discord_id":"123","display_name":"Gabe","avatar_url":"https://cdn.discordapp.com/embed/avatars/3.png"}"#.utf8)

        let user = try JSONDecoder().decode(SwiftBotDiscordUser.self, from: data)

        XCTAssertEqual(user.avatarURL, generic)
        XCTAssertEqual(AccountAvatarSource.discord.resolve(discord: user.avatarURL, twitch: twitch), generic)
    }

    func testSwiftBotUserLookupCanRecoverAfterStartupFailure() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let endpoint = "http://127.0.0.1:38888"
        let expectedAvatar = "https://cdn.discordapp.com/avatars/123/avatar.png?size=96"
        var attempts = 0

        MockURLProtocol.requestHandler = { request in
            attempts += 1
            let statusCode = attempts == 1 ? 503 : 200
            let data = attempts == 1
                ? Data()
                : Data(#"{"users":[{"discord_id":"123","display_name":"Gabe","username":"gabe","avatar_url":"https://cdn.discordapp.com/avatars/123/avatar.png?size=96"}]}"#.utf8)
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                data
            )
        }
        defer {
            MockURLProtocol.requestHandler = nil
            MockURLProtocol.stubResponseData = nil
            MockURLProtocol.stubError = nil
            MockURLProtocol.lastRequest = nil
        }

        let service = RestSwiftBotConnectionService(
            endpoint: endpoint,
            urlSession: session,
            outboxProvider: { nil }
        )

        let startupUsers = await service.fetchDiscordUsers()
        XCTAssertTrue(startupUsers.isEmpty)
        let recovered = await service.fetchDiscordUsers()

        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(MockURLProtocol.lastRequest?.url?.path, "/v1/users")
        XCTAssertEqual(recovered.count, 1)
        XCTAssertEqual(recovered.first?.id, "123")
        XCTAssertEqual(recovered.first?.avatarURL?.absoluteString, expectedAvatar)
    }

    func testPruningDropsAccountsThatAreNoLongerMined() {
        let settings = Settings.shared
        settings.twitchAvatarsData = TwitchAvatarStore.encode([
            "keep": TwitchAvatarStore.Entry(url: twitch, fetchedAt: Date()),
            "drop": TwitchAvatarStore.Entry(url: discord, fetchedAt: Date())
        ])

        let store = TwitchAvatarStore(settings: settings)
        store.pruneEntries(keepingAccountIds: ["keep"])

        XCTAssertEqual(Set(store.entriesByAccountId.keys), ["keep"])
        XCTAssertEqual(Set(TwitchAvatarStore.decode(settings.twitchAvatarsData).keys), ["keep"])

        settings.twitchAvatarsData = "{}"
    }
}
