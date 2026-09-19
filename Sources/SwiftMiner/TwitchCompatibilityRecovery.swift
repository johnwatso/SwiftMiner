// Steps the Safari extension through Twitch to read the query hashes its own site uses.
// Only ever on an explicit request from the user — SwiftMiner never opens Safari or
// replaces a hash on its own.
import Foundation
import AppKit
import SwiftMinerCore

/// The mechanics of one Twitch query update.
///
/// When Twitch retires a persisted query, every miner built against it stops working and
/// stays broken until its developer ships a new hash — days, typically. Twitch's own site
/// has already moved to the successor document by then, and the Safari extension can read
/// it, so SwiftMiner can close that gap itself.
///
/// What it must never do is close that gap quietly. An update opens the user's browser and
/// changes which document SwiftMiner sends to Twitch, so it happens when — and only when —
/// someone chooses "Update via Safari…" in Settings → Advanced. `TwitchQueryUpdateController`
/// owns that run; this type is the pages, the queue, and the validation it needs.
///
/// A value Safari brings back is still only a candidate. A query that still works is left
/// alone however different the website's hash is, because a difference on a healthy query
/// means Twitch's page is using a sibling document — a different question with the same
/// operation name — and copying one of those is how a working Drops inventory query got
/// replaced with one that reported every claimed drop as unclaimed.
@MainActor
enum TwitchCompatibilityRecovery {
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

// MARK: - The explicit update

/// The one Twitch query update SwiftMiner ever performs: the one the user asked for.
///
/// Owns the whole span of an "Update via Safari…" — opening the session, waiting for the
/// extension to report back, settling whatever it brought home, and writing each step into
/// the Activity Log. It lives outside the Settings pane on purpose: the run can take a
/// couple of minutes, and closing the window must not abandon it or lose its result.
///
/// Nothing here starts on a timer, on launch, or on a broken query. `reportBrokenQueries`
/// is the only thing SwiftMiner does unprompted, and all it does is say so.
@MainActor
@Observable
final class TwitchQueryUpdateController {
    static let shared = TwitchQueryUpdateController()

    /// How far the current update has got. Both live cases are worth showing a spinner for.
    enum Phase: Equatable {
        case idle
        /// Safari is stepping through Twitch, reading the hashes its pages issue.
        case collecting
        /// A replacement is being tried against a real Twitch request.
        case validating
    }

    /// Why an update could not run at all.
    enum Failure: Equatable {
        /// Safari reported nothing whatsoever: the extension is missing, off, or blocked.
        case extensionUnavailable
        /// There was no session to open — no pages could be queued, or Safari refused.
        case couldNotStart
    }

    /// What one update ended up doing. Everything said about a finished run — in Settings
    /// and in the Activity Log — is read from this value rather than re-derived from dates.
    struct Result: Equatable {
        /// Replacements Twitch accepted, and SwiftMiner now sends.
        var adopted: [GQLQuery] = []
        /// Replacements that did not work. The query in use before the run stays in use.
        var rejected: [GQLQuery] = []
        /// Replacements found but not yet exercised; they wait for a real request.
        var pending: [GQLQuery] = []
        /// Queries Twitch never issued during the run, so there was nothing to compare.
        var unseen: [GQLQuery] = []
        /// Queries the run could not even ask for, because SwiftMiner had no page to open
        /// for them. Not a fault, and not the same as unseen: nothing was missed, nothing
        /// was checked, and saying which is which is the difference between a blank row
        /// and an answer.
        var skipped: [GQLQuery] = []
        /// Queries confirmed to be the ones SwiftMiner already sends.
        var confirmed: [GQLQuery] = []
        /// Queries whose own hash had stopped working and still has no replacement.
        var unresolved: [GQLQuery] = []
        var failure: Failure?
    }

    private(set) var phase: Phase = .idle
    private(set) var startedAt: Date?
    private(set) var result: Result?
    private(set) var finishedAt: Date?

    /// Broken queries already announced, so a five-minute review cannot repeat itself.
    private var reportedBreaks: Set<GQLQuery> = []
    private var run: Task<Void, Never>?

    var isRunning: Bool { phase != .idle }

    /// Long enough for Safari to launch and Twitch to boot on a cold connection. Past this
    /// with nothing at all reported, the extension is not running.
    private static let firstSignTimeout: TimeInterval = 40
    /// A full pass is five pages, each waiting up to 20s for its operation, plus loads.
    private static let sessionTimeout: TimeInterval = 240
    /// How long a replacement gets to be exercised before the run stops waiting on it.
    private static let validationTimeout: TimeInterval = 120

    // MARK: Starting

    /// Begin the update the user just asked for. A second request while one is running is
    /// ignored rather than queued: there is one Safari tab and one session.
    func startUpdate(
        directorySlug: String?,
        navigation: NavigationModel,
        store: TwitchQueryHashStore = .standard
    ) {
        guard !isRunning else { return }

        let begun = Date()
        phase = .collecting
        startedAt = begun
        result = nil
        finishedAt = nil

        // An explicit update means "try again", so a value refused last time gets another
        // go. What Twitch was last seen using is deliberately kept: a run that delivers
        // nothing must not leave the screen knowing less than before it was asked. Each
        // observation is dated, so this run's findings are told apart by time, not by
        // having wiped the previous ones.
        store.clearRejections()
        store.clearSessionResult()

        navigation.logEvent(
            message: "Twitch query update started",
            level: .info,
            rawMessage: "[compatibility] update started · requested by: Settings → Advanced"
                + " · the queries this run covers are listed when Safari opens"
        )

        run = Task { [weak self] in
            await self?.perform(
                directorySlug: directorySlug,
                navigation: navigation,
                store: store,
                begun: begun
            )
        }
    }

    private func perform(
        directorySlug: String?,
        navigation: NavigationModel,
        store: TwitchQueryHashStore,
        begun: Date
    ) async {
        let channelLogin = await navigation.minerManager.compatibilityRecoveryChannelLogin()
        // Neither page is about the game the user cares about — the directory and channel
        // queries are read from whatever category and channel page happen to be open. So a
        // priority list that yields no slug is no reason to leave that query unchecked.
        let category = directorySlug ?? navigation.minerManager.compatibilityRecoveryDirectorySlug()
        let queued = await TwitchCompatibilityRecovery.startUpdate(
            directorySlug: category,
            channelLogin: channelLogin
        )
        guard !queued.isEmpty else {
            finish(Result(failure: .couldNotStart), navigation: navigation)
            return
        }
        let requested = queued.map(\.operation)
        // Two queries share the campaigns page; list each page once.
        var pages: [String] = []
        for item in queued where !pages.contains(item.page) {
            pages.append(item.page)
        }
        navigation.logEvent(
            message: "Opened Twitch in Safari to check \(requested.count) "
                + (requested.count == 1 ? "query" : "queries"),
            level: .info,
            rawMessage: "[compatibility] safari opened · queries: \(Self.names(requested))"
                + " · pages: \(pages.joined(separator: ", "))"
                + " · TDM fallback values carried: \(queued.filter { $0.fallbackHash != nil }.count)"
        )
        // `Available drops` is only ever issued by a live channel page, and the directory
        // page needs a category. When nothing with a running campaign is live at all there
        // is no such page to open, so those operations are absent from the queue rather
        // than failed by it — a distinction the Activity Log and the table both keep.
        let skipped = GQLQuery.frequentlyRotated.filter { !requested.contains($0) }
        let before = requested.reduce(into: [GQLQuery: String]()) { snapshot, query in
            snapshot[query] = store.resolution(for: query).hash
        }

        guard await waitForFirstSign(store: store, since: begun) else {
            finish(
                Result(unseen: requested, skipped: skipped, failure: .extensionUnavailable),
                navigation: navigation
            )
            return
        }

        let session = await waitForSession(store: store, since: begun)
        let seen = session?.succeeded ?? requested.filter {
            (store.date(for: .observed, query: $0) ?? .distantPast) >= begun
        }
        let unseen = session?.failed ?? requested.filter { !seen.contains($0) }
        navigation.logEvent(
            message: unseen.isEmpty
                ? "Checked \(seen.count) Twitch " + (seen.count == 1 ? "query" : "queries")
                : "Checked \(seen.count) of \(requested.count) Twitch queries",
            level: .info,
            rawMessage: "[compatibility] queries checked · read: \(Self.names(seen))"
                + (unseen.isEmpty ? "" : " · not issued by Twitch: \(Self.names(unseen))")
                + (skipped.isEmpty ? "" : " · no page to read them from: \(Self.names(skipped))")
        )

        let changed = requested.filter { store.candidate(for: $0) != nil }
        for query in changed {
            guard let candidate = store.candidate(for: query) else { continue }
            navigation.logEvent(
                message: "Twitch changed the \(query.displayName.lowercased()) query",
                level: .info,
                rawMessage: "[compatibility] query changed · \(query.displayName)"
                    + " · SwiftMiner: \(before[query] ?? "unknown")"
                    + " · Twitch: \(candidate)"
            )
        }

        guard !changed.isEmpty else {
            finish(
                Result(
                    unseen: unseen,
                    skipped: skipped,
                    confirmed: requested.filter { !unseen.contains($0) },
                    unresolved: store.queriesNeedingRecovery()
                ),
                navigation: navigation
            )
            return
        }

        phase = .validating
        await validate(changed, navigation: navigation, store: store)

        var outcome = Result(
            unseen: unseen,
            skipped: skipped,
            confirmed: requested.filter { !unseen.contains($0) && !changed.contains($0) }
        )
        for query in changed {
            if store.candidate(for: query) != nil {
                // Still queued: nothing has had cause to send this query yet.
                outcome.pending.append(query)
            } else if let override = store.override(for: query), override != before[query] {
                outcome.adopted.append(query)
                navigation.logEvent(
                    message: "Updated the \(query.displayName.lowercased()) query",
                    level: .info,
                    rawMessage: "[compatibility] query updated · \(query.displayName)"
                        + " · previous: \(before[query] ?? "unknown")"
                        + " · now in use: \(override)"
                        + " · confirmed by a live Twitch request"
                )
            } else {
                // The candidate slot emptied without becoming an override, which only
                // happens when the request path judged the value and refused it.
                outcome.rejected.append(query)
            }
        }
        outcome.unresolved = store.queriesNeedingRecovery()
        finish(outcome, navigation: navigation)
    }

    /// Exercise the replacements this run found, rather than leaving them queued until some
    /// unrelated piece of work happens to need that query. A claim mutation is never in
    /// this set — firing one to test a hash would claim a reward as a side effect.
    private func validate(
        _ changed: [GQLQuery],
        navigation: NavigationModel,
        store: TwitchQueryHashStore
    ) async {
        store.recordSettleAttempt()
        await navigation.minerManager.forceRefreshAllMiners()
        _ = navigation.refreshDropsInBackground(force: true)

        let deadline = Date().addingTimeInterval(Self.validationTimeout)
        while Date() < deadline {
            guard changed.contains(where: { store.candidate(for: $0) != nil }) else { return }
            guard await sleepOneSecond() else { return }
        }
    }

    private func finish(_ result: Result, navigation: NavigationModel) {
        phase = .idle
        startedAt = nil
        self.result = result
        finishedAt = Date()
        run = nil

        // A run that just adopted a replacement has already answered the alarm, and one
        // that failed should be reported again the next time it is worth saying.
        reportedBreaks = []

        let entry = Self.completionEntry(for: result)
        navigation.logEvent(message: entry.message, level: entry.level, rawMessage: entry.raw)
    }

    // MARK: Waiting

    /// True once anything at all has come back from the extension.
    private func waitForFirstSign(store: TwitchQueryHashStore, since: Date) async -> Bool {
        let deadline = since.addingTimeInterval(Self.firstSignTimeout)
        while Date() < deadline {
            if (store.latestSessionResult?.finishedAt ?? .distantPast) >= since { return true }
            if GQLQuery.allCases.contains(where: {
                (store.date(for: .observed, query: $0) ?? .distantPast) >= since
            }) {
                return true
            }
            guard await sleepOneSecond() else { return true }
        }
        return false
    }

    /// The extension's own summary of the run, once it has finished stepping the queue.
    private func waitForSession(
        store: TwitchQueryHashStore,
        since: Date
    ) async -> TwitchQueryHashSessionResult? {
        let deadline = since.addingTimeInterval(Self.sessionTimeout)
        while Date() < deadline {
            if let session = store.latestSessionResult, session.finishedAt >= since {
                return session
            }
            guard await sleepOneSecond() else { return store.latestSessionResult }
        }
        return nil
    }

    /// False when the run was cancelled, which is the caller's cue to stop waiting.
    private func sleepOneSecond() async -> Bool {
        do {
            try await Task.sleep(for: .seconds(1))
            return true
        } catch {
            return false
        }
    }

    // MARK: What is broken

    /// Queries Twitch has stopped accepting, as every surface should report them — the
    /// Overview status bar, the Settings pane, and the Activity Log alike.
    ///
    /// Read from the store each time rather than cached: the break is recorded in Core by
    /// the request that failed, which has no way to tell the UI, and the reads are a
    /// dozen in-process defaults lookups.
    func brokenQueries(store: TwitchQueryHashStore = .standard) -> [GQLQuery] {
        #if DEBUG
        if let preview = previewBrokenQueries { return preview }
        #endif
        return store.queriesNeedingRecovery()
    }

    /// How long a break must last before it reaches outside the app — the Dock badge and a
    /// notification. The one transient cause of a recorded break is a single edge node
    /// answering from a stale cache, and the next good reply clears it; ten minutes of
    /// sustained failure is long past that. Inside the app (Overview, Settings, the log)
    /// a break shows at once: seeing it costs nothing, being interrupted by it does.
    static let alertGracePeriod: TimeInterval = 10 * 60

    /// Broken queries that have lasted long enough to badge the Dock. Includes a Developer
    /// preview, which stands in for a break already past the grace period — the badge is
    /// display, so previewing it is safe. The notification is not; see `takeAlertChange`.
    func queriesWorthAlerting(
        store: TwitchQueryHashStore = .standard,
        now: Date = Date()
    ) -> [GQLQuery] {
        #if DEBUG
        if let preview = previewBrokenQueries { return preview }
        #endif
        return sustainedBreaks(store: store, now: now)
    }

    /// What the notification incident should now say, or nil when nothing has changed since
    /// it was last synced. Real breaks only: a preview must never write the health store or
    /// send a notification, so it is deliberately invisible here.
    ///
    /// Nil-at-launch means the first review always syncs, which is what resolves an incident
    /// left open by a previous run whose break has since cleared.
    func takeAlertChange(
        store: TwitchQueryHashStore = .standard,
        now: Date = Date()
    ) -> [GQLQuery]? {
        let current = sustainedBreaks(store: store, now: now)
        guard current != syncedAlert else { return nil }
        syncedAlert = current
        return current
    }

    private var syncedAlert: [GQLQuery]?

    private func sustainedBreaks(store: TwitchQueryHashStore, now: Date) -> [GQLQuery] {
        store.queriesNeedingRecovery().filter { query in
            guard let since = store.recoveryNeededSince(for: query) else { return false }
            return now.timeIntervalSince(since) >= Self.alertGracePeriod
        }
    }

    /// The incident that carries the badge and the notification. System-scoped, like the
    /// web dashboard's: a query belongs to the app, not to any one miner.
    static let incidentID = "system:twitch-queries"

    /// Wording for the notification and the unattended-health history. The notification
    /// service formats it as "<displayName>: <summary>. <action>."
    nonisolated static func incidentSummary(for queries: [GQLQuery]) -> String {
        queries.count == 1
            ? "Twitch changed the \(listed(queries)) query, so Drops can\u{2019}t be read until it\u{2019}s updated"
            : "Twitch changed the queries for \(listed(queries)), so Drops can\u{2019}t be read until they\u{2019}re updated"
    }

    nonisolated static let incidentAction = "In Settings \u{2192} Advanced, choose Update via Safari"

    #if DEBUG
    /// Developer-menu stand-in for a real break, so the prompt can be seen without waiting
    /// for Twitch to rotate something. Display only: it changes what the UI reports and
    /// nothing else — no Activity Log entry, no store write, nothing a miner acts on.
    private(set) var previewBrokenQueries: [GQLQuery]?

    func previewBreak(of queries: [GQLQuery]?) {
        previewBrokenQueries = queries
    }
    #endif

    // MARK: Reporting a break

    /// Say once that a query SwiftMiner depends on has stopped working.
    ///
    /// This is the whole of SwiftMiner's unprompted behaviour here. It does not open Safari
    /// and it does not change a hash; it records what is already known and names the button
    /// that fixes it, because a user who is never told cannot choose to press it.
    func reportBrokenQueries(
        navigation: NavigationModel,
        store: TwitchQueryHashStore = .standard
    ) {
        let broken = Set(store.queriesNeedingRecovery())
        // Forget queries that have recovered, so a later rotation is announced again.
        reportedBreaks.formIntersection(broken)
        let unreported = broken.subtracting(reportedBreaks)
        guard !unreported.isEmpty, !isRunning else { return }
        reportedBreaks.formUnion(unreported)

        let names = Self.names(GQLQuery.allCases.filter { unreported.contains($0) })
        navigation.logEvent(
            message: "Twitch changed a query SwiftMiner depends on (\(names)). "
                + "In Settings → Advanced, choose Update via Safari to look for the replacement.",
            level: .warning,
            rawMessage: "[compatibility] query no longer accepted by Twitch · \(names)"
                + " · SwiftMiner is still using the query it shipped with"
                + " · action: Settings → Advanced → Update via Safari"
        )
    }

    // MARK: Wording

    /// The Activity Log entry for a finished run. Pure, so what the log says about an
    /// outcome can be checked without driving Safari.
    nonisolated static func completionEntry(
        for result: Result
    ) -> (message: String, level: EventLevel, raw: String) {
        switch result.failure {
        case .extensionUnavailable:
            return (
                "No response from the Safari extension — Twitch queries were not updated",
                .warning,
                "[compatibility] safari extension unavailable"
                    + " · nothing was reported back during the update"
                    + " · the extension is switched off, or its results could not be handed back"
                    + " · action: check SwiftMiner in Safari → Settings → Extensions, then update again"
            )
        case .couldNotStart:
            return (
                "Twitch query update couldn't start",
                .warning,
                "[compatibility] update failed · no Safari session could be opened"
            )
        case nil:
            break
        }

        var diagnostics: [String] = []
        if !result.adopted.isEmpty { diagnostics.append("adopted: \(names(result.adopted))") }
        if !result.rejected.isEmpty { diagnostics.append("rejected: \(names(result.rejected))") }
        if !result.pending.isEmpty {
            diagnostics.append("awaiting first use: \(names(result.pending))")
        }
        if !result.unseen.isEmpty {
            diagnostics.append("not issued by Twitch: \(names(result.unseen))")
        }
        if !result.skipped.isEmpty {
            diagnostics.append(
                "not checked, no page to read them from: \(names(result.skipped))"
                    + " · Available drops is only issued by a live channel page, and nothing"
                    + " with a running campaign was live to open"
            )
        }
        if !result.confirmed.isEmpty { diagnostics.append("unchanged: \(names(result.confirmed))") }
        if !result.unresolved.isEmpty {
            diagnostics.append("still unresolved: \(names(result.unresolved))")
        }

        func entry(_ message: String, _ level: EventLevel, _ headline: String) -> (String, EventLevel, String) {
            (message, level, (["[compatibility] " + headline] + diagnostics).joined(separator: " · "))
        }

        if !result.adopted.isEmpty {
            let queries = listed(result.adopted)
            return entry(
                result.adopted.count == 1
                    ? "Twitch query update completed — SwiftMiner now uses Twitch's current \(queries) query"
                    : "Twitch query update completed — SwiftMiner now uses Twitch's current queries for \(queries)",
                .info,
                "update completed"
            )
        }

        if !result.rejected.isEmpty {
            let queries = listed(result.rejected)
            return entry(
                result.rejected.count == 1
                    ? "Twitch query update failed — the replacement \(queries) query didn't work, so SwiftMiner kept the one it had"
                    : "Twitch query update failed — the replacement queries for \(queries) didn't work, so SwiftMiner kept the ones it had",
                .warning,
                "update failed"
            )
        }

        if !result.pending.isEmpty {
            let queries = listed(result.pending)
            return entry(
                result.pending.count == 1
                    ? "Twitch query update completed — the new \(queries) query will be tried the next time SwiftMiner uses it"
                    : "Twitch query update completed — the new queries for \(queries) will be tried the next time SwiftMiner uses them",
                .info,
                "update completed"
            )
        }

        if !result.unresolved.isEmpty {
            return entry(
                "Twitch query update found no replacement for the \(listed(result.unresolved)) query",
                .warning,
                "update completed without a replacement"
            )
        }

        if !result.unseen.isEmpty {
            return entry(
                "Twitch query update completed — Twitch didn't use its \(listed(result.unseen)) query during the check",
                .info,
                "update completed with gaps"
            )
        }

        if !result.skipped.isEmpty {
            return entry(
                "No changes required — though the \(listed(result.skipped)) query couldn't be checked, "
                    + "because nothing with a running campaign was live to read it from",
                .info,
                "no changes required"
            )
        }

        return entry(
            "No changes required — Twitch is using the queries SwiftMiner already has",
            .info,
            "no changes required"
        )
    }

    /// "drops dashboard", or "drops dashboard and drops inventory" — the form that reads
    /// as a sentence rather than as a list.
    nonisolated static func listed(_ queries: [GQLQuery]) -> String {
        let labels = queries.map { $0.displayName.lowercased() }
        guard let last = labels.last else { return "no queries" }
        guard labels.count > 1 else { return last }
        return labels.dropLast().joined(separator: ", ") + " and " + last
    }

    nonisolated static func names(_ queries: [GQLQuery], lowercased: Bool = false) -> String {
        let labels = queries.map { lowercased ? $0.displayName.lowercased() : $0.displayName }
        return labels.isEmpty ? "none" : labels.joined(separator: ", ")
    }
}
