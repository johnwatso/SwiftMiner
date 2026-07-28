import Foundation

/// Persists `TwitchAPIClient`'s campaign-details and link-state caches across launches.
///
/// Both caches live only in actor memory, so every cold launch re-fetched
/// `DropCampaignDetails` for every time-active campaign — around a hundred requests per
/// account, metered by the process-wide 5-per-second `TwitchRequestCoordinator` gate, and
/// paid again by each additional account. That fan-out is the bulk of the wait before the
/// first mining cycle can start. Restoring the caches from disk turns a relaunch inside
/// the cache window into a single dashboard request.
///
/// Entries keep the expiry they were given in memory: nothing is resurrected past the
/// lifetime it would otherwise have had, and expired entries are dropped on load. In
/// particular the account link-state window is untouched, so linking or unlinking a game
/// account is still picked up within `campaignLinkStateTTL` — a restart neither extends
/// nor shortens that.
///
/// Files are per account (keyed by Twitch login, which is what the cache keys embed) and
/// contain campaign/drop state plus a boolean link flag, but no credentials or OAuth
/// tokens. This matches the existing `CampaignStoreDiskCache` data boundary.
enum CampaignDetailsDiskCache {
    private static let directoryName = "com.swiftminer"
    private static let folderName = "campaign-details"

    struct DetailsEntry: Codable {
        let campaign: Campaign
        let expiresAt: Date
    }

    struct LinkStateEntry: Codable {
        let isAccountConnected: Bool
        let expiresAt: Date
    }

    struct Contents {
        let details: [String: DetailsEntry]
        let linkStates: [String: LinkStateEntry]

        var isEmpty: Bool { details.isEmpty && linkStates.isEmpty }

        static let empty = Contents(details: [:], linkStates: [:])
    }

    private struct Envelope: Codable {
        let savedAt: Date
        let details: [String: DetailsEntry]
        let linkStates: [String: LinkStateEntry]
    }

    /// Twitch logins are `[a-zA-Z0-9_]`, but the value reaches us from the API, so it is
    /// reduced to a safe basename rather than trusted as one.
    private static func sanitized(_ userLogin: String) -> String? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
        let cleaned = String(
            userLogin.lowercased().unicodeScalars.filter { allowed.contains($0) }
        )
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func directoryURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(folderName, isDirectory: true)
    }

    private static func fileURL(userLogin: String) -> URL? {
        guard let name = sanitized(userLogin) else { return nil }
        let directory = directoryURL()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(name).json")
    }

    static func save(
        details: [String: DetailsEntry],
        linkStates: [String: LinkStateEntry],
        userLogin: String
    ) {
        guard let url = fileURL(userLogin: userLogin) else { return }
        // Expired entries are worthless to a future launch; drop them before writing so
        // the file cannot grow without bound across cycles.
        let now = Date()
        let liveDetails = details.filter { $0.value.expiresAt > now }
        let liveLinkStates = linkStates.filter { $0.value.expiresAt > now }
        guard !liveDetails.isEmpty || !liveLinkStates.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }

        do {
            let envelope = Envelope(savedAt: now, details: liveDetails, linkStates: liveLinkStates)
            let data = try JSONEncoder().encode(envelope)
            try data.write(to: url, options: .atomic)
        } catch {
            Logger.campaigns.error("[CampaignDetailsDiskCache] Save failed: \(error.localizedDescription)")
        }
    }

    static func load(userLogin: String) -> Contents {
        guard let url = fileURL(userLogin: userLogin),
              let data = try? Data(contentsOf: url),
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            return .empty
        }

        let now = Date()
        let details = envelope.details.filter { $0.value.expiresAt > now }
        let linkStates = envelope.linkStates.filter { $0.value.expiresAt > now }
        return Contents(details: details, linkStates: linkStates)
    }

    static func clear(userLogin: String) {
        guard let url = fileURL(userLogin: userLogin) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func clearAll() {
        try? FileManager.default.removeItem(at: directoryURL())
    }
}
