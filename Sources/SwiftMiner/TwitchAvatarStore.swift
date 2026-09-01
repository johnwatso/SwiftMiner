import Foundation
import SwiftMinerCore

/// Cache of Twitch profile-picture URLs for the accounts SwiftMiner mines with.
///
/// Twitch only hands the URL out through an authenticated lookup, so resolving one
/// costs a request per account. The resolved URL is persisted in `Settings`, which
/// is what lets a picture draw at launch instead of after the first round trip, and
/// re-resolved once a day — Twitch rewrites the URL on every upload, so a stale
/// entry means an out-of-date picture, not a broken one.
@Observable
@MainActor
final class TwitchAvatarStore {
    static let shared = TwitchAvatarStore()

    struct Entry: Codable, Sendable, Equatable {
        let url: URL
        let fetchedAt: Date
    }

    /// How long a resolved URL is trusted before it is looked up again.
    static let refreshInterval: TimeInterval = 24 * 60 * 60

    private(set) var entriesByAccountId: [String: Entry]

    /// Accounts with a lookup in progress, so overlapping refreshes (a re-render,
    /// a settings change) don't each fire their own request.
    @ObservationIgnored private var inFlightAccountIds: Set<String> = []

    private let settings: Settings

    init(settings: Settings = .shared) {
        self.settings = settings
        self.entriesByAccountId = Self.decode(settings.twitchAvatarsData)
    }

    func url(forAccountId accountId: String) -> URL? {
        MinerAvatarURL.usable(entriesByAccountId[accountId]?.url)
    }

    /// Resolves the picture for every given miner whose entry is missing or stale.
    /// Best effort throughout: a miner Twitch has no answer for keeps its old entry
    /// and is simply retried on the next refresh.
    func refreshIfNeeded(
        miners: [MinerManager.ManagedMiner],
        manager: MinerManager,
        now: Date = Date()
    ) async {
        let stale = miners.filter { miner in
            !inFlightAccountIds.contains(miner.accountId)
                && Self.needsRefresh(entriesByAccountId[miner.accountId], now: now)
        }
        guard !stale.isEmpty else { return }

        for miner in stale {
            await refresh(miner: miner, manager: manager)
        }
    }

    /// Re-resolves one account even when its stored URL is still inside the
    /// normal daily cache window. The settings source picker uses this path:
    /// clicking Twitch is an explicit request to show the current Twitch
    /// picture now, not to keep trusting yesterday's URL.
    func refresh(miner: MinerManager.ManagedMiner, manager: MinerManager) async {
        await refresh(accountId: miner.accountId) {
            await manager.fetchTwitchProfileImageURL(minerId: miner.id)
        }
    }

    /// Resolver-injected form keeps the cache update deterministic in tests.
    func refresh(accountId: String, resolver: () async -> URL?) async {
        guard !inFlightAccountIds.contains(accountId) else { return }
        inFlightAccountIds.insert(accountId)
        defer { inFlightAccountIds.remove(accountId) }

        // A transport failure retains the last known picture. A successful
        // lookup that returns Twitch's stock image deliberately clears it so
        // the selected source can fall back to Discord or the account initial.
        guard let url = await resolver() else { return }
        if MinerAvatarURL.usable(url) == nil {
            entriesByAccountId.removeValue(forKey: accountId)
        } else {
            entriesByAccountId[accountId] = Entry(url: url, fetchedAt: Date())
        }
        persist()
    }

    /// Drops entries for accounts that are no longer mined, so removing a miner
    /// doesn't leave its picture behind in the preferences file.
    func pruneEntries(keepingAccountIds accountIds: Set<String>) {
        let removed = entriesByAccountId.keys.filter { !accountIds.contains($0) }
        guard !removed.isEmpty else { return }
        for accountId in removed {
            entriesByAccountId.removeValue(forKey: accountId)
        }
        persist()
    }

    static func needsRefresh(_ entry: Entry?, now: Date = Date()) -> Bool {
        guard let entry else { return true }
        guard MinerAvatarURL.usable(entry.url) != nil else { return true }
        return now.timeIntervalSince(entry.fetchedAt) >= refreshInterval
    }

    /// Twitch returns this stock "404 user" image for accounts without a
    /// profile picture. Treat it as no picture so callers can retain their own
    /// visual fallback (the WebUI uses the Twitch mark).
    static func isGenericTwitchProfileImage(_ url: URL) -> Bool {
        MinerAvatarURL.isGenericTwitchProfileImage(url)
    }

    static func decode(_ json: String) -> [String: Entry] {
        guard let data = json.data(using: .utf8) else { return [:] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([String: Entry].self, from: data)) ?? [:]
    }

    static func encode(_ entries: [String: Entry]) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(entries),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    private func persist() {
        settings.twitchAvatarsData = Self.encode(entriesByAccountId)
    }
}
