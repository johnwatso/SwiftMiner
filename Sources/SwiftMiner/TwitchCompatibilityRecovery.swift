// Sends the Safari extension looking for a replacement Twitch query hash when — and only
// when — a Twitch rotation has actually broken SwiftMiner.
import Foundation
import AppKit
import SwiftMinerCore

/// The interim self-heal.
///
/// When Twitch retires a persisted query, every miner built against it stops working and
/// stays broken until its developer ships a new hash — days, typically. Twitch's own site
/// has already moved to the successor document by then, and the Safari extension can read
/// it, so SwiftMiner can close that gap itself.
///
/// The trigger is deliberately narrow: only a query whose *bundled* hash has stopped
/// working is worth chasing. A query that still works is left alone however different the
/// website's hash is, because a difference on a healthy query means Twitch's page is using
/// a sibling document — a different question with the same operation name — and copying
/// one of those is how a working Drops inventory query got replaced with one that reported
/// every claimed drop as unclaimed.
@MainActor
enum TwitchCompatibilityRecovery {
    /// Long enough that a permanently unfixable query cannot reopen Safari on a loop,
    /// short enough that a rotation is picked up well inside the window a release takes.
    static let retryInterval: TimeInterval = 30 * 60

    /// Opens an update session in Safari when — and only when — a Twitch rotation has
    /// actually broken a query. Returns the broken queries it went looking for, or empty
    /// when nothing is due.
    @discardableResult
    static func runIfNeeded(
        store: TwitchQueryHashStore = .standard,
        directorySlug: String? = nil,
        channelLogin: String? = nil,
        now: Date = Date()
    ) async -> [GQLQuery] {
        guard store.automaticDiscoveryEnabled else { return [] }

        let broken = store.queriesNeedingRecovery()
        guard !broken.isEmpty else { return [] }

        if let last = store.lastRecoveryAttempt, now.timeIntervalSince(last) < retryInterval {
            return []
        }

        let queued = await startUpdate(
            directorySlug: directorySlug,
            channelLogin: channelLogin,
            requestedQueries: Set(broken),
            store: store
        )
        guard !queued.isEmpty else { return [] }

        store.recordRecoveryAttempt(at: now)
        return queued.map(\.operation)
    }

    /// Twitch category slugs are the game name lowercased with runs of anything else
    /// collapsed to a single hyphen — "Rainbow Six Siege" becomes "rainbow-six-siege".
    static func categorySlug(from gameName: String) -> String? {
        let allowed = CharacterSet.alphanumerics
        let pieces = gameName.lowercased().unicodeScalars
            .split { !allowed.contains($0) }
            .map(String.init)
        let slug = pieces.joined(separator: "-")
        return slug.isEmpty ? nil : slug
    }

    /// One step of an update session: a Twitch page to visit, and the operation whose hash
    /// SwiftMiner is waiting to see while that page loads.
    struct QueueItem {
        let operation: GQLQuery
        let page: String
        let fallbackHash: String?
    }

    /// The pages associated with the operations SwiftMiner can refresh, in the order the
    /// session visits them. A page observation is preferred where Twitch issues the client
    /// document; otherwise the exact TDM catalog pair carried in the queue is used.
    ///
    /// A side-effecting operation can never be here. Claiming a drop, for one, fires only
    /// when someone presses Claim, and driving that from a compatibility check would claim
    /// a reward as a side effect.
    static func queue(
        directorySlug: String?,
        channelLogin: String?,
        requestedQueries: Set<GQLQuery> = Set(GQLQuery.frequentlyRotated),
        fallbackHashes: [GQLQuery: String] = [:]
    ) -> [QueueItem] {
        var items: [QueueItem] = []

        func append(_ operation: GQLQuery, page: String) {
            guard requestedQueries.contains(operation) else { return }
            items.append(QueueItem(
                operation: operation,
                page: page,
                fallbackHash: fallbackHashes[operation]
            ))
        }

        // The campaigns page issues the dashboard request. Campaign details is associated
        // with the same route but needs a user click, so its TDM fallback is normally used.
        // Any requests Twitch does dispatch together are buffered until their queue turn.
        append(.viewerDropsDashboard, page: "/drops/campaigns")
        append(.dropCampaignDetails, page: "/drops/campaigns")
        append(.inventory, page: "/drops/inventory")

        if let directorySlug = normalizedPathComponent(directorySlug) {
            append(.directoryPageGame, page: "/directory/category/\(directorySlug)")
        }
        if let channelLogin = normalizedPathComponent(channelLogin) {
            append(.dropsHighlightServiceAvailableDrops, page: "/\(channelLogin)")
        }
        return items
    }

    /// Twitch category slugs and channel logins are ASCII path components. Rejecting
    /// anything else keeps the fragment-carried queue from becoming a general redirect.
    private static func normalizedPathComponent(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !value.isEmpty,
              value.count <= 100,
              value.utf8.allSatisfy({
                  ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57) || $0 == 45 || $0 == 95
              }) else {
            return nil
        }
        return value
    }

    /// The single URL that starts a session.
    ///
    /// The queue travels in the fragment rather than through shared storage, which keeps
    /// the trigger explicit and self-contained: the extension does nothing until a page is
    /// opened carrying one, and it works identically in a local build that has no App
    /// Group. The content script strips the fragment as it starts, so a reload or a
    /// bookmarked URL cannot restart a session.
    static func sessionURL(queue: [QueueItem]) -> URL? {
        guard !queue.isEmpty else { return nil }
        let payload = queue.map { item -> [String: String] in
            var value = ["operation": item.operation.rawValue, "page": item.page]
            if let fallbackHash = item.fallbackHash,
               TwitchQueryHashStore.isValidHash(fallbackHash) {
                value["fallbackHash"] = fallbackHash
            }
            return value
        }
        guard let json = try? JSONSerialization.data(withJSONObject: payload),
              let encoded = json.base64EncodedString()
                .addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
            return nil
        }
        let first = queue[0].page
        return URL(string: "https://www.twitch.tv\(first)#swiftminer-update=\(encoded)")
    }

    /// Starts an update session in a single Safari tab.
    @discardableResult
    static func startUpdate(
        directorySlug: String?,
        channelLogin: String?,
        requestedQueries: Set<GQLQuery> = Set(GQLQuery.frequentlyRotated),
        store: TwitchQueryHashStore = .standard
    ) async -> [QueueItem] {
        // The public TDM catalog is a fallback for documents Twitch's website cannot
        // reproduce on demand. Every changed value is still untrusted until the normal
        // SwiftMiner request path proves Twitch accepts it and its response has the fields
        // SwiftMiner reads.
        let fallbackHashes = (try? await TwitchDropsMinerQueryCatalog.fetch(
            for: requestedQueries
        )) ?? [:]
        let items = queue(
            directorySlug: directorySlug,
            channelLogin: channelLogin,
            requestedQueries: requestedQueries,
            fallbackHashes: fallbackHashes
        )
        guard let url = sessionURL(queue: items) else { return [] }
        store.clearSessionResult()
        open([url])
        return items
    }

    /// Queries that can be exercised on demand purely to settle a pending candidate.
    ///
    /// A candidate is otherwise only tried when the mining loop happens to need that
    /// operation. For a read the app runs every cycle that is seconds away; for a claim
    /// mutation it could be hours, and firing one speculatively would claim a drop as a
    /// side effect of a compatibility check. So only side-effect-free reads that a routine
    /// refresh already issues are listed here — everything else waits, honestly, for its
    /// next real use.
    static let settleableByRefresh: Set<GQLQuery> = [.viewerDropsDashboard, .inventory]

    /// Don't re-force a refresh more often than this while a candidate stays unsettled.
    static let settleInterval: TimeInterval = 120

    /// Whether a routine refresh should be forced now to settle a queued candidate.
    ///
    /// Without this, "SwiftMiner is validating the new Twitch query…" is not a description
    /// of anything happening: the candidate sits queued until some unrelated piece of work
    /// happens to need that query, and the spinner runs for as long as that takes.
    static func shouldForceRefreshToSettle(
        store: TwitchQueryHashStore = .standard,
        now: Date = Date()
    ) -> Bool {
        let pending = settleableByRefresh.filter { store.candidate(for: $0) != nil }
        guard !pending.isEmpty else { return false }

        if let last = store.lastSettleAttempt, now.timeIntervalSince(last) < settleInterval {
            return false
        }

        store.recordSettleAttempt(at: now)
        return true
    }

    /// Opens in Safari specifically. The extension lives in Safari, so the user's default
    /// browser being something else would make the session silently useless.
    ///
    /// Always one URL: the session navigates that same tab through the rest of the queue,
    /// so Twitch is never open in more than one place at a time.
    private static func open(_ urls: [URL]) {
        guard let first = urls.first else { return }
        guard let safari = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.Safari"
        ) else {
            NSWorkspace.shared.open(first)
            return
        }
        NSWorkspace.shared.open(
            [first],
            withApplicationAt: safari,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }
}
