import XCTest
@testable import SwiftMiner
import SwiftMinerCore

@MainActor
final class MinerAvatarTests: XCTestCase {
    private let discord = URL(string: "https://cdn.discordapp.com/avatars/1/abc.png")!
    private let twitch = URL(string: "https://static-cdn.jtvnw.net/jtv_user_pictures/xyz-300x300.png")!

    // MARK: - Source resolution

    func testDiscordSourcePrefersDiscordPicture() {
        XCTAssertEqual(MinerAvatarSource.discord.resolve(discord: discord, twitch: twitch), discord)
    }

    func testAutomaticSourcePrefersTwitchPicture() {
        XCTAssertEqual(MinerAvatarSource.automatic.resolve(discord: discord, twitch: twitch), twitch)
    }

    func testTwitchSourcePrefersTwitchPicture() {
        XCTAssertEqual(MinerAvatarSource.twitch.resolve(discord: discord, twitch: twitch), twitch)
    }

    func testEachSourceFallsBackToTheOther() {
        XCTAssertEqual(MinerAvatarSource.discord.resolve(discord: nil, twitch: twitch), twitch)
        XCTAssertEqual(MinerAvatarSource.twitch.resolve(discord: discord, twitch: nil), discord)
    }

    func testResolvesToNilWhenNeitherServiceHasAPicture() {
        XCTAssertNil(MinerAvatarSource.discord.resolve(discord: nil, twitch: nil))
        XCTAssertNil(MinerAvatarSource.twitch.resolve(discord: nil, twitch: nil))
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

    func testGenericDiscordProfileImageIsNotUsedAsAnAvatar() {
        let generic = URL(string: "https://cdn.discordapp.com/embed/avatars/3.png")!

        XCTAssertTrue(MinerAvatarURL.isGenericDiscordProfileImage(generic))
        XCTAssertNil(MinerAvatarSource.automatic.resolve(discord: generic, twitch: nil))
        XCTAssertEqual(MinerAvatarSource.automatic.resolve(discord: generic, twitch: twitch), twitch)
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
