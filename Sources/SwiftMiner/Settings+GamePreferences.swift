import Foundation
import SwiftMinerCore

// Per-game preferences: priority and exclusion lists, per-account overrides, custom artwork,
// and failover streamers.
//
// Split out of Settings.swift, which had grown past the point where one file could be read.
// The memoisation storage these read through stays in the class body — an extension cannot
// declare stored properties.

extension Settings {
    // MARK: - Backing Stores

    
    /// JSON-encoded array of GamePreference for selected games
    public var gamePreferencesData: String {
        get {
            access(keyPath: \.gamePreferencesData)
            return Self.read("gamePreferencesData", default: "[]")
        }
        set {
            withMutation(keyPath: \.gamePreferencesData) {
                Self.write("gamePreferencesData", newValue)
            }
        }
    }

    /// JSON-encoded array of game-scoped failover streamer rules.
    public var gameFailoverStreamersData: String {
        get {
            access(keyPath: \.gameFailoverStreamersData)
            return Self.read("gameFailoverStreamersData", default: "[]")
        }
        set {
            withMutation(keyPath: \.gameFailoverStreamersData) {
                Self.write("gameFailoverStreamersData", newValue)
            }
        }
    }

    /// Legacy storage (kept for migration only)
    var priorityGamesString: String {
        get {
            access(keyPath: \.priorityGamesString)
            return Self.read("priorityGamesString", default: "")
        }
        set {
            withMutation(keyPath: \.priorityGamesString) {
                Self.write("priorityGamesString", newValue)
            }
        }
    }

    /// Legacy storage (kept for migration only)
    var excludedGamesString: String {
        get {
            access(keyPath: \.excludedGamesString)
            return Self.read("excludedGamesString", default: "")
        }
        set {
            withMutation(keyPath: \.excludedGamesString) {
                Self.write("excludedGamesString", newValue)
            }
        }
    }

    /// JSON-encoded map of Twitch account ID -> ordered priority game names.
    public var accountPriorityGamesData: String {
        get {
            access(keyPath: \.accountPriorityGamesData)
            return Self.read("accountPriorityGamesData", default: "{}")
        }
        set {
            withMutation(keyPath: \.accountPriorityGamesData) {
                Self.write("accountPriorityGamesData", newValue)
            }
        }
    }

    /// JSON-encoded map of Twitch account ID -> whether global priority games
    /// should be appended after the miner's own list. Missing means true for
    /// backward compatibility.
    public var accountIncludesGlobalPriorityGamesData: String {
        get {
            access(keyPath: \.accountIncludesGlobalPriorityGamesData)
            return Self.read("accountIncludesGlobalPriorityGamesData", default: "{}")
        }
        set {
            withMutation(keyPath: \.accountIncludesGlobalPriorityGamesData) {
                Self.write("accountIncludesGlobalPriorityGamesData", newValue)
            }
        }
    }

    /// JSON-backed per-account source selection for priority games.
    public var accountPrioritySourcesData: String {
        get {
            access(keyPath: \.accountPrioritySourcesData)
            return Self.read("accountPrioritySourcesData", default: "{}")
        }
        set {
            withMutation(keyPath: \.accountPrioritySourcesData) {
                Self.write("accountPrioritySourcesData", newValue)
            }
        }
    }

    /// JSON-encoded map of Twitch account ID -> games excluded only for that
    /// miner. Global exclusions still apply to every miner.
    public var accountExcludedGamesData: String {
        get {
            access(keyPath: \.accountExcludedGamesData)
            return Self.read("accountExcludedGamesData", default: "{}")
        }
        set {
            withMutation(keyPath: \.accountExcludedGamesData) {
                Self.write("accountExcludedGamesData", newValue)
            }
        }
    }

    /// Mining strategy selection
    public var miningStrategy: MiningStrategy {
        get {
            access(keyPath: \.miningStrategy)
            return Self.read("miningStrategy", default: .mineAll)
        }
        set {
            withMutation(keyPath: \.miningStrategy) {
                Self.write("miningStrategy", newValue)
            }
        }
    }

    // MARK: - Game Preferences

    /// Memoized decode of `gamePreferencesData`. Decoding + normalization is
    /// expensive and `gamePreferences` is read many times per SwiftUI render
    /// (directly, and via `excludedGames`/`gameNames(for:)`), so we cache the
    /// result and only re-decode when the backing JSON string actually changes.
    /// `@ObservationIgnored` storage on this `@MainActor` class: mutating it
    /// from the getter is safe and never triggers a view-update cycle.

    /// Decoded game preferences from JSON storage
    public var gamePreferences: [GamePreference] {
        get {
            let raw = gamePreferencesData
            if cachedGamePreferencesKey == raw {
                return cachedGamePreferences
            }
            let decoded: [GamePreference]
            if let data = raw.data(using: .utf8),
               let prefs = try? JSONDecoder().decode([GamePreference].self, from: data) {
                decoded = normalizedPreferences(prefs)
            } else {
                decoded = []
            }
            cachedGamePreferencesKey = raw
            cachedGamePreferences = decoded
            return decoded
        }
        set {
            let normalized = normalizedPreferences(newValue)
            if let data = try? JSONEncoder().encode(normalized),
               let string = String(data: data, encoding: .utf8) {
                guard gamePreferencesData != string else { return }
                gamePreferencesData = string
                // Keep the cache hot for the value we just persisted.
                cachedGamePreferencesKey = string
                cachedGamePreferences = normalized
            }
        }
    }

    public var gameFailoverStreamers: [GameFailoverStreamer] {
        get {
            guard let data = gameFailoverStreamersData.data(using: .utf8),
                  let rules = try? JSONDecoder().decode([GameFailoverStreamer].self, from: data) else {
                return []
            }
            return normalizedFailoverStreamers(rules)
        }
        set {
            let normalized = normalizedFailoverStreamers(newValue)
            if let data = try? JSONEncoder().encode(normalized),
               let string = String(data: data, encoding: .utf8) {
                guard gameFailoverStreamersData != string else { return }
                gameFailoverStreamersData = string
            }
        }
    }

    /// Priority game names derived from preferences (backward compat for MinerEngine)
    public var priorityGames: [String] {
        gameNames(for: .preferred)
    }

    public var accountPriorityGames: [String: [String]] {
        get {
            guard let data = accountPriorityGamesData.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) else {
                return [:]
            }
            return decoded.mapValues(Self.normalizedPriorityGameNames)
        }
        set {
            let normalized = newValue.reduce(into: [String: [String]]()) { result, entry in
                let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
                let values = Self.normalizedPriorityGameNames(entry.value)
                if !key.isEmpty, !values.isEmpty {
                    result[key] = values
                }
            }
            if let data = try? JSONEncoder().encode(normalized),
               let string = String(data: data, encoding: .utf8) {
                accountPriorityGamesData = string
            }
        }
    }

    public func priorityGames(forAccountId accountId: String) -> [String] {
        let key = accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return priorityGames }
        switch prioritySource(forAccountId: key) {
        case .global:
            return priorityGames
        case .globalAndPersonal:
            return Self.normalizedPriorityGameNames(personalPriorityGames(forAccountId: key) + priorityGames)
        case .personal:
            return personalPriorityGames(forAccountId: key)
        }
    }

    public var accountIncludesGlobalPriorityGames: [String: Bool] {
        get {
            guard let data = accountIncludesGlobalPriorityGamesData.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String: Bool].self, from: data) else {
                return [:]
            }
            return decoded.reduce(into: [String: Bool]()) { result, entry in
                let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty {
                    result[key] = entry.value
                }
            }
        }
        set {
            let normalized = newValue.reduce(into: [String: Bool]()) { result, entry in
                let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty {
                    result[key] = entry.value
                }
            }
            if let data = try? JSONEncoder().encode(normalized),
               let string = String(data: data, encoding: .utf8) {
                accountIncludesGlobalPriorityGamesData = string
            }
        }
    }

    public func includesGlobalPriorityGames(forAccountId accountId: String) -> Bool {
        switch prioritySource(forAccountId: accountId) {
        case .global, .globalAndPersonal: return true
        case .personal: return false
        }
    }

    public var accountPrioritySources: [String: AccountPrioritySource] {
        get {
            guard let data = accountPrioritySourcesData.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String: AccountPrioritySource].self, from: data) else {
                return [:]
            }
            return decoded.reduce(into: [String: AccountPrioritySource]()) { result, entry in
                let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty { result[key] = entry.value }
            }
        }
        set {
            let normalized = newValue.reduce(into: [String: AccountPrioritySource]()) { result, entry in
                let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
                if !key.isEmpty { result[key] = entry.value }
            }
            if let data = try? JSONEncoder().encode(normalized),
               let string = String(data: data, encoding: .utf8) {
                accountPrioritySourcesData = string
            }
        }
    }

    public func prioritySource(forAccountId accountId: String) -> AccountPrioritySource {
        let key = accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .global }
        if let source = accountPrioritySources[key] { return source }
        if accountIncludesGlobalPriorityGames[key] == false { return .personal }
        return accountPriorityGames[key, default: []].isEmpty ? .global : .globalAndPersonal
    }

    public func setPrioritySource(_ source: AccountPrioritySource, forAccountId accountId: String) {
        let key = accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        var sources = accountPrioritySources
        sources[key] = source
        accountPrioritySources = sources

        // Keep the legacy value aligned for callers that have not yet migrated.
        var includeGlobals = accountIncludesGlobalPriorityGames
        includeGlobals[key] = source != .personal
        accountIncludesGlobalPriorityGames = includeGlobals
    }

    public func setIncludesGlobalPriorityGames(_ include: Bool, forAccountId accountId: String) {
        let key = accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        if include {
            let hasPersonalPriorities = !accountPriorityGames[key, default: []].isEmpty
            setPrioritySource(hasPersonalPriorities ? .globalAndPersonal : .global, forAccountId: key)
        } else {
            setPrioritySource(.personal, forAccountId: key)
        }
    }

    /// Whether this account has an explicitly configured, per-account priority
    /// list. The native UI uses this to expose only the reset action; creating
    /// and editing the list belongs in the Web UI.
    public func hasCustomPriorityGames(forAccountId accountId: String) -> Bool {
        let key = accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        return !key.isEmpty && !accountPriorityGames[key, default: []].isEmpty
    }

    /// Removes an account's custom priority list and restores the shared global
    /// priority order.
    @discardableResult
    public func resetPriorityGamesToGlobal(forAccountId accountId: String) -> [String] {
        let key = accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return priorityGames }

        var priorities = accountPriorityGames
        priorities.removeValue(forKey: key)
        accountPriorityGames = priorities
        setPrioritySource(.global, forAccountId: key)
        return priorityGames(forAccountId: key)
    }

    @discardableResult
    public func prioritiseGameForAccount(accountId: String, gameName: String) -> [String] {
        let key = accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        let game = gameName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !game.isEmpty else { return priorityGames(forAccountId: accountId) }

        if prioritySource(forAccountId: key) == .global {
            setPrioritySource(.globalAndPersonal, forAccountId: key)
        }
        var map = accountPriorityGames
        let existing = priorityGames(forAccountId: key)
        let remaining = existing.filter { $0.localizedCaseInsensitiveCompare(game) != .orderedSame }
        let updated = Self.normalizedPriorityGameNames([game] + remaining)
        map[key] = updated
        accountPriorityGames = map
        return priorityGames(forAccountId: key)
    }

    /// Remove a game from a miner's personal priority override, returning the
    /// miner's resulting effective list. Seeds the override from the global list
    /// first (so removing a personal game doesn't accidentally re-inherit it).
    @discardableResult
    public func deprioritiseGameForAccount(accountId: String, gameName: String) -> [String] {
        let key = accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        let game = gameName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !game.isEmpty else { return priorityGames(forAccountId: accountId) }

        var map = accountPriorityGames
        let existing = priorityGames(forAccountId: key)
        let updated = Self.normalizedPriorityGameNames(
            existing.filter { $0.localizedCaseInsensitiveCompare(game) != .orderedSame }
        )
        map[key] = updated
        accountPriorityGames = map
        return priorityGames(forAccountId: key)
    }

    /// Replace a miner's personal priority games with `games`, returning the miner's
    /// resulting effective list. The stored override keeps the personal games ahead of
    /// the global list (global still applies, at lower priority). Used by the Discord
    /// "edit games" modal, which submits the whole personal list at once.
    @discardableResult
    public func setPersonalPriorityGames(accountId: String, games: [String]) -> [String] {
        let key = accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return priorityGames(forAccountId: accountId) }

        let combined = Self.normalizedPriorityGameNames(games)
        var map = accountPriorityGames
        map[key] = combined
        accountPriorityGames = map
        if !combined.isEmpty, prioritySource(forAccountId: key) == .global {
            setPrioritySource(.globalAndPersonal, forAccountId: key)
        }
        return priorityGames(forAccountId: key)
    }

    /// The games prioritised specifically for one miner. When global priorities
    /// also apply, games that duplicate the global list are omitted from the
    /// returned list. Stored personal priorities remain available while the
    /// global-only source is selected, so changing sources never discards them.
    public func personalPriorityGames(forAccountId accountId: String) -> [String] {
        let key = accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, let override = accountPriorityGames[key] else { return [] }
        // Hide global duplicates only while the global list still applies to
        // this miner — there they'd be redundant. When the miner opts out of
        // global priorities, a personally-added game must stand on its own even
        // if it also appears globally; filtering it here made adding such a
        // game silently do nothing.
        guard prioritySource(forAccountId: key) == .globalAndPersonal else { return override }
        let globalKeys = Set(priorityGames.map { $0.lowercased() })
        return override.filter { !globalKeys.contains($0.lowercased()) }
    }

    public var accountExcludedGames: [String: [String]] {
        get {
            guard let data = accountExcludedGamesData.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) else { return [:] }
            return decoded.reduce(into: [String: [String]]()) { result, entry in
                let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
                let games = Self.normalizedPriorityGameNames(entry.value)
                if !key.isEmpty, !games.isEmpty { result[key] = games }
            }
        }
        set {
            let normalized = newValue.reduce(into: [String: [String]]()) { result, entry in
                let key = entry.key.trimmingCharacters(in: .whitespacesAndNewlines)
                let games = Self.normalizedPriorityGameNames(entry.value)
                if !key.isEmpty, !games.isEmpty { result[key] = games }
            }
            if let data = try? JSONEncoder().encode(normalized),
               let string = String(data: data, encoding: .utf8) {
                accountExcludedGamesData = string
            }
        }
    }

    public func excludedGames(forAccountId accountId: String) -> [String] {
        Self.normalizedPriorityGameNames(excludedGames + accountExcludedGames[accountId, default: []])
    }

    @discardableResult
    public func setExcludedGames(accountId: String, games: [String]) -> [String] {
        let key = accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return excludedGames }
        var values = accountExcludedGames
        values[key] = Self.normalizedPriorityGameNames(games)
        accountExcludedGames = values
        return excludedGames(forAccountId: key)
    }

    public func removeExcludedGames(forAccountId accountId: String) {
        let key = accountId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        var values = accountExcludedGames
        values.removeValue(forKey: key)
        accountExcludedGames = values
    }

    /// Excluded game names and category IDs derived from preferences (backward
    /// compat for MinerEngine). Special Events is treated as IRL-adjacent for
    /// the mining safety option because it can host real-world event campaigns.
    public var excludedGames: [String] {
        var games = gameNames(for: .excluded)
        if !mineIRLCampaigns {
            games.append(contentsOf: [
                Game.specialIRLCategoryId,
                Game.specialEventsCategoryId
            ])
        }
        return games
    }

    /// Add or update a game preference
    public func addGamePreference(_ game: Game, state: PreferenceState) {
        setGamePreference(game, state: state)
    }

    /// Add or update a game preference with the provided state.
    public func setGamePreference(_ game: Game, state: PreferenceState) {
        var prefs = gamePreferences
        if let index = prefs.firstIndex(where: { preferenceMatches($0, gameId: game.id, gameName: game.name) }) {
            let old = prefs[index]
            prefs[index] = GamePreference(
                gameId: game.id,
                gameName: game.name,
                boxArtURL: game.boxArtURL ?? old.boxArtURL,
                customArtworkURL: old.customArtworkURL,
                state: state
            )
        } else {
            prefs.append(GamePreference(gameId: game.id, gameName: game.name, boxArtURL: game.boxArtURL, state: state))
        }
        gamePreferences = prefs
    }

    /// Remove a game preference by game ID
    public func removeGamePreference(gameId: String) {
        var prefs = gamePreferences
        let removed = prefs.filter { $0.gameId == gameId }
        prefs.removeAll { $0.gameId == gameId }
        gamePreferences = prefs
        removeCachedArtworkFiles(for: removed)
    }

    /// Remove a specific game preference.
    public func removeGamePreference(_ preference: GamePreference) {
        var prefs = gamePreferences
        let removed = prefs.filter { preferenceMatches($0, gameId: preference.gameId, gameName: preference.gameName) }
        prefs.removeAll { preferenceMatches($0, gameId: preference.gameId, gameName: preference.gameName) }
        gamePreferences = prefs
        clearFailoverStreamer(for: preference)
        removeCachedArtworkFiles(for: removed)
    }

    public func failoverStreamer(for preference: GamePreference) -> GameFailoverStreamer? {
        gameFailoverStreamers.first { failoverMatches($0, gameId: preference.gameId, gameName: preference.gameName) }
    }

    public func setFailoverStreamer(_ login: String, for preference: GamePreference) {
        guard let normalizedLogin = GameFailoverStreamer.normalizedStreamerLogin(login) else {
            clearFailoverStreamer(for: preference)
            return
        }

        var rules = gameFailoverStreamers
        let updated = GameFailoverStreamer(
            gameId: preference.gameId,
            gameName: preference.gameName,
            streamerLogin: normalizedLogin,
            enabled: true
        )

        if let index = rules.firstIndex(where: { failoverMatches($0, gameId: preference.gameId, gameName: preference.gameName) }) {
            rules[index] = updated
        } else {
            rules.append(updated)
        }
        gameFailoverStreamers = rules
    }

    public func clearFailoverStreamer(for preference: GamePreference) {
        var rules = gameFailoverStreamers
        rules.removeAll { failoverMatches($0, gameId: preference.gameId, gameName: preference.gameName) }
        gameFailoverStreamers = rules
    }

    /// Set a stored preference to a specific state.
    public func setPreferenceState(_ state: PreferenceState, for preference: GamePreference) {
        var prefs = gamePreferences
        if let idx = prefs.firstIndex(where: { preferenceMatches($0, gameId: preference.gameId, gameName: preference.gameName) }) {
            let old = prefs[idx]
            prefs[idx] = GamePreference(
                gameId: old.gameId,
                gameName: old.gameName,
                boxArtURL: old.boxArtURL,
                customArtworkURL: old.customArtworkURL,
                state: state
            )
        }
        gamePreferences = prefs
    }

    public func setCustomArtwork(from sourceURL: URL, for game: Game) throws {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let directory = try customArtworkDirectory()
        let fileExtension = preferredArtworkExtension(for: sourceURL)
        let destination = directory
            .appendingPathComponent(customArtworkFileStem(gameId: game.id, gameName: game.name))
            .appendingPathExtension(fileExtension)

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destination)

        var prefs = gamePreferences
        if let index = prefs.firstIndex(where: { preferenceMatches($0, gameId: game.id, gameName: game.name) }) {
            let old = prefs[index]
            removeCachedArtworkFile(at: old.customArtworkURL)
            prefs[index] = GamePreference(
                gameId: old.gameId.isEmpty ? game.id : old.gameId,
                gameName: game.name,
                boxArtURL: game.boxArtURL ?? old.boxArtURL,
                customArtworkURL: destination,
                state: old.state
            )
        } else {
            prefs.append(GamePreference(
                gameId: game.id,
                gameName: game.name,
                boxArtURL: game.boxArtURL,
                customArtworkURL: destination,
                state: .preferred
            ))
        }
        gamePreferences = prefs
    }

    /// Drops persisted artwork links so the next render falls back to live artwork.
    ///
    /// Rewriting each preference through `GamePreference.init` is what does the work:
    /// it rejects `file://` URLs outright, so any cache path stored by an older build
    /// is discarded here. Uploaded artwork is passed through untouched — it lives in
    /// Application Support and is the user's own file, not a cache.
    public func clearCachedArtworkLinks() {
        gamePreferences = gamePreferences.map { preference in
            GamePreference(
                gameId: preference.gameId,
                gameName: preference.gameName,
                boxArtURL: preference.resolvedBoxArtURL,
                customArtworkURL: preference.customArtworkURL,
                state: preference.state
            )
        }
    }

    public func removeCustomArtwork(for game: Game) {
        var prefs = gamePreferences
        guard let index = prefs.firstIndex(where: { preferenceMatches($0, gameId: game.id, gameName: game.name) }) else {
            return
        }

        let old = prefs[index]
        removeCachedArtworkFile(at: old.customArtworkURL)
        prefs[index] = GamePreference(
            gameId: old.gameId,
            gameName: old.gameName,
            boxArtURL: old.boxArtURL,
            customArtworkURL: nil,
            state: old.state
        )
        gamePreferences = prefs
    }

    /// Toggle a stored preference through preferred -> excluded -> neutral.
    public func togglePreferenceState(for preference: GamePreference) {
        setPreferenceState(nextPreferenceState(after: preference.state), for: preference)
    }

    /// Reorder game preferences within a state group (drag-to-reorder support).
    /// Moves only items that share `state`; items in other states are unaffected.
    public func moveGamePreferences(fromOffsets: IndexSet, toOffset: Int, inState state: PreferenceState) {
        var prefs = gamePreferences
        let stateIndices = prefs.indices.filter { prefs[$0].state == state }
        var stateItems = stateIndices.map { prefs[$0] }
        stateItems.move(fromOffsets: fromOffsets, toOffset: toOffset)
        for (position, originalIndex) in stateIndices.enumerated() {
            prefs[originalIndex] = stateItems[position]
        }
        gamePreferences = prefs
    }
}
