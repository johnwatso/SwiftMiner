import Foundation
import XCTest
@testable import SwiftMiner
@testable import SwiftMinerCore

/// `GameMatchIndex` replaced pairwise locale comparisons in Overview's feed derivation.
/// These tests pin it to the behaviour of the linear code it replaced, reproduced here as
/// the reference implementations, so a faster lookup cannot quietly change which game a
/// campaign is matched to.
final class GameMatchIndexTests: XCTestCase {
    private let preferences: [GamePreference] = [
        GamePreference(gameId: "1", gameName: "Battlefield 6", state: .preferred),
        GamePreference(gameId: "2", gameName: "rust", state: .preferred),
        GamePreference(
            gameId: "",
            gameName: "Battlefield-6",
            customArtworkURL: URL(fileURLWithPath: "/tmp/custom.png"),
            state: .preferred
        ),
        GamePreference(gameId: "3", gameName: "Dead by Daylight", state: .neutral),
        GamePreference(gameId: "4", gameName: "Old Excluded Game", state: .excluded)
    ]

    private var index: GameMatchIndex {
        GameMatchIndex(
            gamePreferences: preferences,
            priorityGames: ["Rust", "battlefield 6", "Rust"],
            excludedGames: ["Old Excluded Game", "dead by daylight"]
        )
    }

    private let probes: [(gameId: String?, gameName: String)] = [
        ("1", "Battlefield 6"),
        (nil, "battlefield 6"),
        (nil, "BATTLEFIELD-6"),
        ("2", "Rust"),
        (nil, "rust"),
        ("3", "Dead by Daylight"),
        ("99", "Unknown Game"),
        (nil, ""),
        ("", "Rust")
    ]

    func testPreferredMatchingAgreesWithThePairwiseScan() {
        let index = index
        let preferred = preferences.filter { $0.state == .preferred }
        for probe in probes {
            let expected = preferred.contains {
                Self.referenceMatches(gameId: probe.gameId, gameName: probe.gameName, preference: $0)
            }
            XCTAssertEqual(
                index.hasPreferredMatch(gameId: probe.gameId, gameName: probe.gameName),
                expected,
                "Mismatch for \(probe.gameId ?? "nil")/\(probe.gameName)"
            )
        }
    }

    func testMatchedPreferencesKeepListOrder() {
        let index = index
        for probe in probes {
            let expected = preferences.filter {
                Self.referenceMatches(gameId: probe.gameId, gameName: probe.gameName, preference: $0)
            }
            XCTAssertEqual(
                index.matchedPreferences(gameId: probe.gameId, gameName: probe.gameName),
                expected,
                "Mismatch for \(probe.gameId ?? "nil")/\(probe.gameName)"
            )
        }
    }

    func testBestPreferenceAgreesWithTheArtworkFirstTiebreak() {
        let index = index
        for probe in probes {
            let matches = preferences.filter {
                Self.referenceMatches(gameId: probe.gameId, gameName: probe.gameName, preference: $0)
            }
            let expected = matches.first(where: { $0.customArtworkURL != nil }) ?? matches.first
            XCTAssertEqual(
                index.bestPreference(gameId: probe.gameId, gameName: probe.gameName),
                expected,
                "Mismatch for \(probe.gameId ?? "nil")/\(probe.gameName)"
            )
        }
    }

    /// A preference matching by id but carrying no uploaded artwork must not win over a
    /// later one that matches by name and does — the tiebreak the linear filter applied.
    func testUploadedArtworkWinsOverAnEarlierIdMatch() {
        let best = index.bestPreference(gameId: "1", gameName: "Battlefield 6")
        XCTAssertEqual(best?.gameName, "Battlefield-6")
        XCTAssertNotNil(best?.customArtworkURL)
    }

    func testExclusionAgreesWithTheCaseInsensitiveScan() {
        let index = index
        let excluded = ["Old Excluded Game", "dead by daylight"]
        for name in ["Old Excluded Game", "OLD EXCLUDED GAME", "Dead by Daylight", "Rust", ""] {
            let expected = excluded.contains {
                $0.localizedCaseInsensitiveCompare(name) == .orderedSame
            }
            XCTAssertEqual(index.isExcluded(gameName: name), expected, "Mismatch for \(name)")
        }
    }

    /// Exclusions compared whole strings, so a name that only differs by surrounding
    /// whitespace was not excluded. The hashed key must not quietly start trimming.
    func testExclusionStillTreatsSurroundingWhitespaceAsSignificant() {
        XCTAssertFalse(index.isExcluded(gameName: " Old Excluded Game "))
    }

    func testPriorityRankAgreesWithTheFirstIndexScan() {
        let index = index
        let priorityGames = ["Rust", "battlefield 6", "Rust"]
        for name in ["Rust", "rust", "Battlefield 6", "Dead by Daylight"] {
            let expected = priorityGames.firstIndex(where: {
                $0.localizedCaseInsensitiveCompare(name) == .orderedSame
            }) ?? Int.max
            XCTAssertEqual(index.priorityRank(gameName: name), expected, "Mismatch for \(name)")
        }
    }

    func testPreferredPreferencesKeepTheirConfiguredOrder() {
        XCTAssertEqual(
            index.preferredPreferences.map(\.gameName),
            ["Battlefield 6", "rust", "Battlefield-6"]
        )
    }

    // MARK: - Strict mode

    /// Drops' artwork lookup only ever compared ids and case-insensitive names. Folded
    /// matching would newly pair "Battlefield-6" with "Battlefield 6" there, so the strict
    /// index must not do it.
    func testStrictModeMatchesIdsAndCaseInsensitiveNamesOnly() {
        let strict = GameMatchIndex(
            gamePreferences: preferences,
            priorityGames: [],
            excludedGames: [],
            matchesFoldedNames: false
        )

        XCTAssertEqual(strict.bestPreference(gameId: "1", gameName: "BATTLEFIELD 6")?.gameId, "1")
        XCTAssertEqual(strict.bestPreference(gameId: "", gameName: "Battlefield-6")?.gameName, "Battlefield-6")
        // Folded-only match: the same game to the feed, a different one here.
        XCTAssertNil(strict.bestPreference(gameId: "", gameName: "battlefield6"))
        XCTAssertNotNil(index.bestPreference(gameId: "", gameName: "battlefield6"))
    }

    func testExclusionCanMatchAGameId() {
        let index = GameMatchIndex(
            gamePreferences: [],
            priorityGames: [],
            excludedGames: ["509660", "IRL"]
        )

        XCTAssertTrue(index.isExcluded(gameName: "Anything", gameId: "509660"))
        XCTAssertTrue(index.isExcluded(gameName: "irl"))
        XCTAssertFalse(index.isExcluded(gameName: "Rust", gameId: "12345"))
        // Without an id supplied, only the name is consulted, as before.
        XCTAssertFalse(index.isExcluded(gameName: "Anything"))
    }

    // MARK: - Reference implementations

    /// The comparison `OverviewArtworkResolver.matches` and `preferenceMatches` performed.
    private static func referenceMatches(
        gameId: String?,
        gameName: String,
        preference: GamePreference
    ) -> Bool {
        let idMatches = gameId.map { !$0.isEmpty && $0 == preference.gameId } ?? false
        let nameMatches = gameName.localizedCaseInsensitiveCompare(preference.gameName) == .orderedSame
            || comparableName(gameName) == comparableName(preference.gameName)
        return idMatches || nameMatches
    }

    private static func comparableName(_ value: String) -> String {
        value
            .lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }
}
