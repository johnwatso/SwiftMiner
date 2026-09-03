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
    static let maxApprovedChannelEntries = 600
    static let maxRememberedCampaignEntries = 600

    struct DetailsEntry: Codable {
        let campaign: Campaign
        let expiresAt: Date
    }

    struct LinkStateEntry: Codable {
        let isAccountConnected: Bool
        let expiresAt: Date
    }

    /// A restricted campaign's approved channels, kept until the campaign itself ends.
    ///
    /// Deliberately outlives the details entry it came from. Twitch omits this list on some
    /// fetches, and a launch that lands on one of those omissions has nothing to probe and
    /// nothing to subscribe to — the campaign is visible and unmineable. Remembering the
    /// list across launches is what makes it recoverable at all: within a session there may
    /// simply never have been a fetch that carried it.
    struct ApprovedChannelsEntry: Codable {
        let channels: [Channel]
        /// The campaign's own end date: past it the list can never be useful again.
        let expiresAt: Date
    }

    /// Campaign-global fields that must survive longer than a details-cache entry. A claim
    /// deliberately invalidates account-specific details, but it must not erase the last
    /// complete drop definition or the last explicit restriction answer needed to repair
    /// the response that follows.
    struct RememberedCampaignEntry: Codable {
        let drops: [Drop]
        let allowIsEnabled: Bool?
        let expiresAt: Date
    }

    struct Contents {
        let details: [String: DetailsEntry]
        let linkStates: [String: LinkStateEntry]
        let approvedChannels: [String: ApprovedChannelsEntry]
        let rememberedCampaigns: [String: RememberedCampaignEntry]

        var isEmpty: Bool {
            details.isEmpty
                && linkStates.isEmpty
                && approvedChannels.isEmpty
                && rememberedCampaigns.isEmpty
        }

        static let empty = Contents(
            details: [:],
            linkStates: [:],
            approvedChannels: [:],
            rememberedCampaigns: [:]
        )
    }

    private struct Envelope: Codable {
        let savedAt: Date
        let details: [String: DetailsEntry]
        let linkStates: [String: LinkStateEntry]
        /// Absent in files written before approved channels were persisted.
        let approvedChannels: [String: ApprovedChannelsEntry]?
        /// Absent in files written before refresh reconciliation was persisted.
        let rememberedCampaigns: [String: RememberedCampaignEntry]?
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
        approvedChannels: [String: ApprovedChannelsEntry] = [:],
        rememberedCampaigns: [String: RememberedCampaignEntry] = [:],
        userLogin: String
    ) {
        guard let url = fileURL(userLogin: userLogin) else { return }
        // Expired entries are worthless to a future launch; drop them before writing so
        // the file cannot grow without bound across cycles.
        let now = Date()
        let liveDetails = details.filter { $0.value.expiresAt > now }
        let liveLinkStates = linkStates.filter { $0.value.expiresAt > now }
        // Approved channels expire with the campaign rather than with its details window:
        // the whole point is to still have them on a launch where Twitch omits them.
        let liveApprovedChannels = Dictionary(
            uniqueKeysWithValues: approvedChannels
                .filter { $0.value.expiresAt > now }
                .sorted { $0.value.expiresAt > $1.value.expiresAt }
                .prefix(maxApprovedChannelEntries)
                .map { ($0.key, $0.value) }
        )
        let liveRememberedCampaigns = Dictionary(
            uniqueKeysWithValues: rememberedCampaigns
                .filter { $0.value.expiresAt > now }
                .sorted { $0.value.expiresAt > $1.value.expiresAt }
                .prefix(maxRememberedCampaignEntries)
                .map { ($0.key, $0.value) }
        )
        guard !liveDetails.isEmpty
                || !liveLinkStates.isEmpty
                || !liveApprovedChannels.isEmpty
                || !liveRememberedCampaigns.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }

        do {
            let envelope = Envelope(
                savedAt: now,
                details: liveDetails,
                linkStates: liveLinkStates,
                approvedChannels: liveApprovedChannels,
                rememberedCampaigns: liveRememberedCampaigns
            )
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
        // A file from before refresh reconciliation has no remembered baseline. Its details
        // entry may itself be the degraded four-hour answer this fix is intended to stop, so
        // force one fresh lookup on upgrade instead of carrying that risk forward. The
        // shorter-lived link observations and independently persisted ACLs remain useful.
        let details = envelope.rememberedCampaigns == nil
            ? [:]
            : envelope.details.filter { $0.value.expiresAt > now }
        let linkStates = envelope.linkStates.filter { $0.value.expiresAt > now }
        let approvedChannels = (envelope.approvedChannels ?? [:]).filter { $0.value.expiresAt > now }
        let rememberedCampaigns = (envelope.rememberedCampaigns ?? [:]).filter { $0.value.expiresAt > now }
        return Contents(
            details: details,
            linkStates: linkStates,
            approvedChannels: approvedChannels,
            rememberedCampaigns: rememberedCampaigns
        )
    }

    static func clear(userLogin: String) {
        guard let url = fileURL(userLogin: userLogin) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    static func clearAll() {
        try? FileManager.default.removeItem(at: directoryURL())
    }
}
