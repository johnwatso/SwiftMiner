import Foundation
import SwiftMinerCore

/// Hashed lookups over the user's game preferences, priority list, and exclusions.
///
/// Overview derives its feed by asking, for every campaign, whether any preference
/// matches it. Done pairwise that is O(campaigns × preferences) locale-aware string
/// comparisons on every body pass, and the preference list was being re-filtered inside
/// the per-campaign closure on top of that. Hashing each preference under the same keys
/// the pairwise comparison would have matched on turns the question into a dictionary
/// hit, computed once per derivation.
///
/// Matching semantics are deliberately identical to the comparisons this replaces:
/// a non-empty game id equality, a case-insensitive name equality, or equality after
/// reducing both names to their lowercased alphanumerics. Lookups return preferences in
/// their original order, so callers that took "the first match" still take the same one.
struct GameMatchIndex {
    /// One hashed view over a list of preferences.
    private struct Lookup {
        let preferences: [GamePreference]
        private let indicesByKey: [String: [Int]]

        init(_ preferences: [GamePreference], matchesFoldedNames: Bool) {
            self.preferences = preferences
            var indicesByKey: [String: [Int]] = [:]
            for (index, preference) in preferences.enumerated() {
                for key in GameMatchIndex.keys(
                    gameId: preference.gameId,
                    gameName: preference.gameName,
                    matchesFoldedNames: matchesFoldedNames
                ) {
                    indicesByKey[key, default: []].append(index)
                }
            }
            self.indicesByKey = indicesByKey
        }

        func containsMatch(keys: [String]) -> Bool {
            keys.contains { indicesByKey[$0] != nil }
        }

        /// Matching preferences in list order, as the linear `filter` this replaces produced.
        func matches(keys: [String]) -> [GamePreference] {
            var seen = Set<Int>()
            var indices: [Int] = []
            for key in keys {
                for index in indicesByKey[key] ?? [] where seen.insert(index).inserted {
                    indices.append(index)
                }
            }
            return indices.sorted().map { preferences[$0] }
        }
    }

    private let all: Lookup
    private let preferred: Lookup
    private let excludedKeys: Set<String>
    private let priorityRankByKey: [String: Int]
    private let matchesFoldedNames: Bool

    /// Preferences in the `.preferred` state, in list order.
    var preferredPreferences: [GamePreference] { preferred.preferences }

    /// - Parameter matchesFoldedNames: whether two names that differ only in punctuation
    ///   and spacing ("Battlefield 6" and "Battlefield-6") count as the same game. The
    ///   Overview feed matches that way; callers that only ever compared ids and
    ///   case-insensitive names pass `false` to keep exactly that.
    init(
        gamePreferences: [GamePreference],
        priorityGames: [String],
        excludedGames: [String],
        matchesFoldedNames: Bool = true
    ) {
        self.matchesFoldedNames = matchesFoldedNames
        all = Lookup(gamePreferences, matchesFoldedNames: matchesFoldedNames)
        preferred = Lookup(
            gamePreferences.filter { $0.state == .preferred },
            matchesFoldedNames: matchesFoldedNames
        )
        excludedKeys = Set(excludedGames.compactMap { Self.caseInsensitiveKey($0) })

        var priorityRankByKey: [String: Int] = [:]
        for (rank, game) in priorityGames.enumerated() {
            guard let key = Self.caseInsensitiveKey(game) else { continue }
            // The linear scan this replaces took the first index, so keep the first rank.
            if priorityRankByKey[key] == nil {
                priorityRankByKey[key] = rank
            }
        }
        self.priorityRankByKey = priorityRankByKey
    }

    /// Excluded games are listed by name, but some callers also compared the list
    /// against a campaign's game id, so both are checked when an id is supplied.
    func isExcluded(gameName: String, gameId: String? = nil) -> Bool {
        if let key = Self.caseInsensitiveKey(gameName), excludedKeys.contains(key) {
            return true
        }
        guard let gameId, let idKey = Self.caseInsensitiveKey(gameId) else { return false }
        return excludedKeys.contains(idKey)
    }

    /// Keys for one game, honouring this index's matching mode.
    private func keys(gameId: String?, gameName: String) -> [String] {
        Self.keys(gameId: gameId, gameName: gameName, matchesFoldedNames: matchesFoldedNames)
    }

    /// Position in the priority list, or `Int.max` when the game is not pinned.
    func priorityRank(gameName: String) -> Int {
        guard let key = Self.caseInsensitiveKey(gameName) else { return .max }
        return priorityRankByKey[key] ?? .max
    }

    func hasPreferredMatch(gameId: String?, gameName: String) -> Bool {
        preferred.containsMatch(keys: keys(gameId: gameId, gameName: gameName))
    }

    func matchedPreferences(gameId: String?, gameName: String) -> [GamePreference] {
        all.matches(keys: keys(gameId: gameId, gameName: gameName))
    }

    /// The preference a matching game should draw from: one carrying uploaded artwork wins
    /// over one that does not, otherwise the first match in list order.
    func bestPreference(gameId: String?, gameName: String) -> GamePreference? {
        let matches = matchedPreferences(gameId: gameId, gameName: gameName)
        return matches.first(where: { $0.customArtworkURL != nil }) ?? matches.first
    }

    // MARK: - Keys

    static func keys(
        gameId: String?,
        gameName: String,
        matchesFoldedNames: Bool = true
    ) -> [String] {
        var keys: [String] = []
        if let gameId, !gameId.isEmpty {
            keys.append("id:" + gameId)
        }
        if let caseKey = caseInsensitiveKey(gameName) {
            keys.append(caseKey)
        }
        if matchesFoldedNames, let comparableKey = comparableKey(gameName) {
            keys.append(comparableKey)
        }
        return keys
    }

    /// Case folded but not trimmed: the comparison this replaces treated surrounding
    /// whitespace as significant, and exclusions match on this key alone.
    private static func caseInsensitiveKey(_ value: String) -> String? {
        let folded = value.folding(options: .caseInsensitive, locale: .current)
        return folded.isEmpty ? nil : "name:" + folded
    }

    /// Names reduced to lowercased alphanumerics, so "Battlefield 6" and "battlefield-6" meet.
    private static func comparableKey(_ value: String) -> String? {
        let comparable = String(
            value.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        )
        return comparable.isEmpty ? nil : "comparable:" + comparable
    }
}
