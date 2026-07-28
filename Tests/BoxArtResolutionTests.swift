import XCTest
@testable import SwiftMinerCore

/// Box art is requested at a fixed size, but campaigns and game preferences are persisted and
/// restored verbatim. An install that cached artwork URLs before sizing existed kept rendering
/// Twitch's small default indefinitely — clearing the image cache only re-downloaded the same
/// low-resolution asset — while a fresh install looked correct. These tests cover the upgrade
/// happening on read, so no migration is needed.
final class BoxArtResolutionTests: XCTestCase {

    private let lowResolution = "https://static-cdn.jtvnw.net/ttv-boxart/12345_IGDB-120x160.jpg"
    private let expectedSuffix = "-\(TwitchBoxArt.preferredWidth)x\(TwitchBoxArt.preferredHeight).jpg"

    // MARK: - TwitchBoxArt

    func testRewritesBakedInSize() {
        let sized = TwitchBoxArt.sized(lowResolution)
        XCTAssertTrue(sized.hasSuffix(expectedSuffix), "Expected a resized URL, got \(sized)")
    }

    func testRewritesHelixTemplate() {
        let sized = TwitchBoxArt.sized("https://static-cdn.jtvnw.net/ttv-boxart/12345-{width}x{height}.jpg")
        XCTAssertTrue(sized.hasSuffix(expectedSuffix))
        XCTAssertFalse(sized.contains("{width}"))
    }

    func testLeavesUnrecognisedURLsAlone() {
        let custom = "https://example.com/my-own-artwork.png"
        XCTAssertEqual(TwitchBoxArt.sized(custom), custom)
    }

    func testStaysUnderTwitchDimensionCeiling() {
        // Twitch stops preserving aspect ratio past 2560 and returns a squashed image.
        let sized = TwitchBoxArt.sized(lowResolution, width: 4000, height: 6000)
        XCTAssertTrue(sized.hasSuffix("-2560x2560.jpg"), "Got \(sized)")
    }

    // MARK: - Game (persisted inside the campaign disk caches)

    func testGameNormalisesBoxArtOnConstruction() {
        let game = Game(id: "1", name: "Test Game", boxArtURL: URL(string: lowResolution))
        XCTAssertTrue(game.boxArtURL?.absoluteString.hasSuffix(expectedSuffix) == true)
    }

    func testGameUpgradesLowResolutionArtworkOnDecode() throws {
        // Simulates a campaigns-cache.json written before box-art sizing existed.
        let json = """
        {"id":"1","name":"Test Game","boxArtURL":"\(lowResolution)"}
        """.data(using: .utf8)!

        let game = try JSONDecoder().decode(Game.self, from: json)

        XCTAssertTrue(
            game.boxArtURL?.absoluteString.hasSuffix(expectedSuffix) == true,
            "A campaign restored from a stale disk cache must render at full resolution, got \(game.boxArtURL?.absoluteString ?? "nil")"
        )
    }

    func testGameSurvivesRoundTripWithoutArtwork() throws {
        let encoded = try JSONEncoder().encode(Game(id: "1", name: "Test Game"))
        let decoded = try JSONDecoder().decode(Game.self, from: encoded)
        XCTAssertNil(decoded.boxArtURL)
        XCTAssertEqual(decoded.name, "Test Game")
    }

    // MARK: - GamePreference (persisted in @AppStorage, drives the prioritised tiles)

    func testGamePreferenceUpgradesLowResolutionArtworkOnDecode() throws {
        let json = """
        {"gameId":"1","gameName":"Test Game","boxArtURL":"\(lowResolution)","state":"preferred"}
        """.data(using: .utf8)!

        let preference = try JSONDecoder().decode(GamePreference.self, from: json)

        XCTAssertTrue(
            preference.resolvedBoxArtURL?.absoluteString.hasSuffix(expectedSuffix) == true,
            "A preference stored before sizing existed must render at full resolution, got \(preference.resolvedBoxArtURL?.absoluteString ?? "nil")"
        )
    }

    func testGamePreferenceStillRejectsCachePaths() throws {
        // Purgeable cache paths must keep being dropped; sizing must not resurrect them.
        let json = """
        {"gameId":"1","gameName":"Test Game","boxArtURL":"file:///Users/test/Library/Caches/art.png","state":"preferred"}
        """.data(using: .utf8)!

        let preference = try JSONDecoder().decode(GamePreference.self, from: json)
        XCTAssertNil(preference.boxArtURL)
    }

    func testGamePreferenceLeavesCustomArtworkUntouched() throws {
        let custom = "file:///Users/test/Library/Application%20Support/custom.png"
        let json = """
        {"gameId":"1","gameName":"Test Game","customArtworkURL":"\(custom)","state":"preferred"}
        """.data(using: .utf8)!

        let preference = try JSONDecoder().decode(GamePreference.self, from: json)
        XCTAssertEqual(preference.customArtworkURL?.absoluteString, custom)
    }
}
