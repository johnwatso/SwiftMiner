// Advanced pane of the Settings window.
import SwiftUI
import SwiftMinerCore
import SwiftMinerService
import AppKit
import Combine
import SafariServices
import UniformTypeIdentifiers

/// What SwiftMiner can honestly say about its Safari query-hash extension.
///
/// Derived from observations the extension has actually delivered, never from
/// `SFSafariExtensionManager.getStateOfSafariExtension`. SafariServices declares that
/// completion handler `@MainActor` but invokes it on its own XPC reply queue, so Debug's
/// actor data-race checks insert a main-queue assertion the callback cannot satisfy and
/// the app traps in `_dispatch_assert_queue_fail` before it can answer. It also reports
/// only `SFErrorDomain 1` for this extension, so it never had an answer worth the trap.
enum SafariExtensionAvailability {
    /// The extension has reported a hash, which is proof it is installed and running.
    case active
    /// Nothing heard from it yet. Not the same as switched off — the extension is inert
    /// until an update asks it for something, so this must never raise a warning on its own.
    case unknown
    /// An update ran and nothing came back at all, which does mean something is wrong.
    case unavailable

    var label: String {
        switch self {
        case .active: return "Active"
        case .unknown: return "Not detected yet"
        case .unavailable: return "Not responding"
        }
    }

    /// Green is reserved for the one state that is genuinely healthy.
    var tint: Color {
        switch self {
        case .active: return .green
        case .unknown: return .secondary
        case .unavailable: return .orange
        }
    }
}

private enum SafariQueryHashExtensionBridge {
    static let identifier = "com.swiftminer.app.SafariQueryHash"

    nonisolated static func showPreferences() {
        SFSafariApplication.showPreferencesForExtension(
            withIdentifier: identifier
        ) { @Sendable _ in }
    }
}

/// Whether one Twitch query SwiftMiner depends on is healthy.
///
/// Worked out by comparing what SwiftMiner sends with what Twitch's own site was last seen
/// using, but that comparison is the mechanism, not the message. A row only ever says
/// "fine" (a quiet tick) or names the one thing the user might need to know.
private struct QueryCompatibility: Identifiable {
    enum State {
        /// Twitch is using the same query SwiftMiner sends.
        case upToDate
        /// Twitch's site uses a different query under this name and SwiftMiner's still
        /// works. Normal — Twitch serves more than one query under some names, and the
        /// Drops inventory is permanently one of them — so it reads exactly like `upToDate`.
        case differs
        /// A replacement from the user's update is being tried against a live request.
        case validating
        /// SwiftMiner's own query has stopped working and nothing has replaced it. The one
        /// state that needs the user.
        case unverified
        /// Never checked. Checks only happen when the user asks, so this is not a problem.
        case waiting
        /// The last check could not reach this query: Twitch only issues `Available drops`
        /// on a live Drops channel, and nothing with a running campaign was live.
        case notChecked
    }

    let query: GQLQuery
    let state: State

    var id: String { query.rawValue }

    var isHealthy: Bool { state == .upToDate || state == .differs }

    /// Replaces the tick when there is something to say. Deliberately short.
    var statusLabel: String? {
        switch state {
        case .upToDate, .differs: return nil
        case .validating: return "Updating"
        case .unverified: return "Needs Update"
        case .waiting: return "Not Checked"
        case .notChecked: return "Unavailable"
        }
    }

    /// Hover detail for the rows that are not simply fine.
    var explanation: String? {
        switch state {
        case .upToDate, .differs:
            return nil
        case .validating:
            return "SwiftMiner is finishing the update you started."
        case .unverified:
            return "Twitch has changed this query. Choose Update via Safari to update it."
        case .waiting:
            return "Choose Update via Safari to check this query."
        case .notChecked:
            return "Twitch only provides this query while a Drops stream is live. Try again when one is."
        }
    }
}

/// The single headline state at the top of the section.
///
/// Modelled as a value so it can be derived outside the view builder, and so the one
/// primary action on the page ("Update via Safari…") never has to move with the state.
private struct CompatibilityStatus {
    var title: String
    var detail: String?
    var symbol: String = "checkmark.circle.fill"
    var tint: Color = .green
    var isWaiting: Bool = false
}

/// Marks a shipped-but-unproven feature.
///
/// Filled capsule rather than an outlined one, matching the badges elsewhere in the app.
/// The detail sits in `.help()` rather than on screen: the badge only needs to set an
/// expectation, and the section beneath it is already carrying a lot of explanation.
private struct BetaBadge: View {
    var body: some View {
        Text("BETA")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(Color.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange.opacity(0.16), in: Capsule())
            .accessibilityLabel("Beta feature")
            .help("Refreshing Twitch queries from Safari is new and still being proven. SwiftMiner keeps the queries it shipped with unless a replacement is confirmed to work, so an update that goes wrong cannot stop mining.")
    }
}

// MARK: - Advanced Settings

struct AdvancedSettingsView: View {
    @Bindable var settings: Settings
    @Environment(NavigationModel.self) private var navigation
    @State private var showClientIdAlert = false
    @State private var tempClientId = ""
    @State private var backupMessage: String?
    @State private var settingsBackupExport: SettingsBackupFile?
    @State private var isExportingSettingsBackup = false
    @State private var isImportingSettingsBackup = false
    @State private var queryHashStateVersion = 0

    /// The live update, if one is running. Shared rather than owned by this view: a run
    /// takes a minute or two and must survive the Settings window being closed.
    private var updates: TwitchQueryUpdateController { .shared }

    var body: some View {
        Form {
            apiConfigurationSection
            twitchCompatibilitySection
            backupSection
            diagnosticsSection
        }
        .formStyle(.grouped)
        .padding(.horizontal, 24)
        .padding(.bottom, 20)
        .padding(.top, 10)
        .alert("Custom Twitch Client ID", isPresented: $showClientIdAlert) {
            TextField("Client ID", text: $tempClientId)
            Button("Save") {
                settings.twitchClientId = tempClientId.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Enter a custom Twitch Client ID to use for API requests. Leave blank to reset to default.")
        }
    }

    // MARK: Sections

    private var apiConfigurationSection: some View {
        Section {
            LabeledContent("Twitch Client ID") {
                if settings.twitchClientId.isEmpty {
                    Button("Set Custom\u{2026}") {
                        tempClientId = ""
                        showClientIdAlert = true
                    }
                    .buttonStyle(.link)
                } else {
                    HStack(spacing: 8) {
                        Text(settings.twitchClientId)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)

                        Button("Edit\u{2026}") {
                            tempClientId = settings.twitchClientId
                            showClientIdAlert = true
                        }
                        .buttonStyle(.link)

                        Button("Reset", role: .destructive) {
                            settings.twitchClientId = ""
                        }
                        .buttonStyle(.link)
                    }
                }
            }

            SettingsSecondaryText("By default, SwiftMiner uses a built-in Twitch client. Only change this if you know what you are doing.")
        } header: {
            Text("API Configuration")
        }
    }

    private var diagnosticsSection: some View {
        Section {
            Picker(selection: $settings.maxLogEntries) {
                ForEach(Settings.logEntryChoices, id: \.self) { count in
                    Text(count.formatted(.number.grouping(.automatic)) + " entries").tag(count)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Activity Log history")
                    Text("Stored separately for each activity category")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: settings.maxLogEntries) { _, newValue in
                navigation.setActivityLogRetention(newValue)
            }

            LabeledContent {
                Text("Always included")
                    .foregroundStyle(.secondary)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Performance and earnings")
                    Text("CPU, memory and seven-day earning history")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("The Activity Log keeps a bounded working set for the app. Diagnostics are also written to one file per day, with seven days included in an export. Automatic measurements are added to exported reports.")
        }
    }

    /// Three sections rather than one: status, the queries, and the extension. Section
    /// spacing does the separating that used to take a divider between every block.
    @ViewBuilder
    private var twitchCompatibilitySection: some View {
        let store = TwitchQueryHashStore.standard
        let _ = queryHashStateVersion
        let rows = comparedQueries(store: store)
        let status = compatibilityStatus(store: store, rows: rows)
        let availability = safariExtensionState(store: store)

        Section {
            compatibilityHeadline(status)
        } header: {
            HStack(spacing: 7) {
                Text("Twitch Query Compatibility")
                BetaBadge()
            }
        }
        // Attached to one section only: modifiers on the enclosing group would be applied
        // to all three, running the settle and the tick three times over.
        .onAppear {
            settlePendingCandidates()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            queryHashStateVersion &+= 1
        }
        // The store is plain defaults, so nothing here publishes. A tick keeps the rows
        // honest while the user's update is in flight — the whole sequence can be over in
        // half a second — and stops as soon as there is nothing moving to report.
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            guard updates.isRunning || rows.contains(where: { $0.state == .validating }) else {
                return
            }
            queryHashStateVersion &+= 1
        }

        Section {
            queryList(rows)
        } header: {
            Text("Queries")
        } footer: {
            Text("SwiftMiner uses these queries to access Twitch Drops.")
        }

        Section {
            extensionRow(availability)
        } footer: {
            if availability == .unavailable {
                Text("Turn on SwiftMiner in Safari \u{2192} Settings \u{2192} Extensions, then choose Update via Safari again.")
            }
        }
    }

    /// Exercise a pending candidate now rather than waiting for the mining loop to want it.
    /// Opening this pane is the moment the user is actually watching the spinner.
    private func settlePendingCandidates() {
        guard TwitchCompatibilityRecovery.shouldForceRefreshToSettle() else { return }
        Task {
            await navigation.minerManager.forceRefreshAllMiners()
            _ = navigation.refreshDropsInBackground(force: true)
            queryHashStateVersion &+= 1
        }
    }

    // MARK: Compatibility headline

    @ViewBuilder
    private func compatibilityHeadline(_ status: CompatibilityStatus) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Group {
                if status.isWaiting {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: status.symbol)
                        .foregroundStyle(status.tint)
                }
            }
            .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(status.title)
                    .font(.callout.weight(.medium))

                if let detail = status.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 16)

            Button("Update via Safari\u{2026}") {
                startSafariUpdate()
            }
            .buttonStyle(.borderedProminent)
            .disabled(updates.isRunning)
            .help("Checks Twitch in Safari and updates the queries if they have changed. SwiftMiner only does this when you ask.")
        }
        .padding(.vertical, 1)
    }

    /// Only one state is ever on screen, so the order these are tested in is the order a
    /// user should hear about them: work in flight first, then an update that could not
    /// run, then a query that needs updating, then the ordinary answer.
    private func compatibilityStatus(
        store: TwitchQueryHashStore,
        rows: [QueryCompatibility]
    ) -> CompatibilityStatus {
        let lastChecked = lastCheckedDate(store: store).map(lastCheckedDescription)

        switch updates.phase {
        case .collecting:
            return CompatibilityStatus(
                title: "Checking Twitch\u{2026}",
                detail: "This takes about a minute in Safari.",
                isWaiting: true
            )
        case .validating:
            return CompatibilityStatus(
                title: "Updating\u{2026}",
                detail: "Trying Twitch\u{2019}s latest version.",
                isWaiting: true
            )
        case .idle:
            break
        }

        switch updates.result?.failure {
        case .extensionUnavailable:
            return CompatibilityStatus(
                title: "Update Didn\u{2019}t Finish",
                detail: "Safari didn\u{2019}t respond, so nothing was changed.",
                symbol: "exclamationmark.triangle.fill",
                tint: .orange
            )
        case .couldNotStart:
            return CompatibilityStatus(
                title: "Update Couldn\u{2019}t Start",
                detail: "Safari couldn\u{2019}t be opened.",
                symbol: "exclamationmark.triangle.fill",
                tint: .orange
            )
        case nil:
            break
        }

        if rows.contains(where: { $0.state == .unverified }) {
            return CompatibilityStatus(
                title: "Needs Update",
                detail: lastChecked,
                symbol: "exclamationmark.triangle.fill",
                tint: .orange
            )
        }

        if rows.contains(where: { $0.state == .validating }) {
            return CompatibilityStatus(
                title: "Update Pending",
                detail: "Finishes the next time SwiftMiner uses the query.",
                symbol: "clock",
                tint: .secondary
            )
        }

        guard let lastChecked else {
            return CompatibilityStatus(
                title: "Not Checked Yet",
                symbol: "circle.dashed",
                tint: .secondary
            )
        }

        return CompatibilityStatus(title: "Up to Date", detail: lastChecked)
    }

    // MARK: Queries

    /// One form row holding every query, so the list reads as a list rather than five
    /// separately ruled-off rows. Healthy rows are a quiet trailing tick; anything else
    /// swaps the tick for a word, and only a query that needs the user gets colour.
    private func queryList(_ rows: [QueryCompatibility]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows) { row in
                LabeledContent(row.query.displayName) {
                    queryStatus(row)
                }
                .help(row.explanation ?? "")
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func queryStatus(_ row: QueryCompatibility) -> some View {
        if row.isHealthy {
            Image(systemName: "checkmark")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.green)
                .accessibilityLabel("Healthy")
        } else if row.state == .validating {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                Text(row.statusLabel ?? "")
                    .foregroundStyle(.secondary)
            }
        } else if row.state == .unverified {
            Label(row.statusLabel ?? "", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        } else {
            Text(row.statusLabel ?? "")
                .foregroundStyle(.secondary)
        }
    }

    /// The queries listed: the ones an update can actually refresh, in the order they
    /// matter to Drops. Anything else the extension has reported joins them rather than
    /// being hidden.
    private func comparedQueries(store: TwitchQueryHashStore) -> [QueryCompatibility] {
        let core: [GQLQuery] = [
            .viewerDropsDashboard,
            .inventory,
            .dropCampaignDetails,
            .directoryPageGame,
            .dropsHighlightServiceAvailableDrops
        ]
        let extra = GQLQuery.allCases.filter {
            !core.contains($0) && store.observedHash(for: $0) != nil
        }
        let broken = Set(updates.brokenQueries(store: store))
        // Queries the last update had no page to open for. Nothing durable records this —
        // it is a property of the moment the update ran, not of the query.
        let skipped = Set(updates.result?.skipped ?? [])
        return (core + extra).map {
            compatibility(of: $0, store: store, broken: broken, skipped: skipped)
        }
    }

    private func compatibility(
        of query: GQLQuery,
        store: TwitchQueryHashStore,
        broken: Set<GQLQuery>,
        skipped: Set<GQLQuery>
    ) -> QueryCompatibility {
        let observed = store.observedHash(for: query)

        let state: QueryCompatibility.State
        if store.candidate(for: query) != nil {
            state = .validating
        } else if broken.contains(query) {
            // Before the observation, not after: the last check may well have matched,
            // and Twitch retired the query since. A tick from an older check must never
            // outrank a failure recorded by a live request.
            state = .unverified
        } else if let observed {
            if observed == store.resolution(for: query).hash {
                state = .upToDate
            } else {
                // A difference only matters when SwiftMiner's own query has stopped
                // working. Otherwise Twitch is simply asking a different question under the
                // same name, which it does routinely and which costs nothing.
                state = .differs
            }
        } else {
            state = skipped.contains(query) ? .notChecked : .waiting
        }

        return QueryCompatibility(query: query, state: state)
    }

    // MARK: Safari extension

    private func extensionRow(_ availability: SafariExtensionAvailability) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                Circle()
                    .fill(availability.tint)
                    .frame(width: 7, height: 7)

                Text(availability.label)
                    .foregroundStyle(availability == .active ? .primary : .secondary)

                Spacer(minLength: 12)

                // A link is right for a place to look; when the extension is the thing
                // standing in the way, it is the action to take.
                if availability == .unavailable {
                    Button("Extension Settings\u{2026}") {
                        openSafariExtensionSettings()
                    }
                    .controlSize(.small)
                } else {
                    Button("Extension Settings\u{2026}") {
                        openSafariExtensionSettings()
                    }
                    .buttonStyle(.link)
                }
            }
        } label: {
            Text("Safari Extension")
        }
    }

    // MARK: Compatibility dates

    /// Honest about what it is derived from: the extension has been heard from, or it has
    /// not. `SFSafariExtensionManager` cannot be asked — see `SafariExtensionAvailability`.
    private func safariExtensionState(store: TwitchQueryHashStore) -> SafariExtensionAvailability {
        if updates.result?.failure == .extensionUnavailable { return .unavailable }
        if lastCheckedDate(store: store) != nil { return .active }
        return .unknown
    }

    /// When the user last ran a check. Only an explicit update writes either of these —
    /// the extension's end-of-run summary, or a query it read — so this is never the time
    /// of some background verification, because there is none.
    private func lastCheckedDate(store: TwitchQueryHashStore) -> Date? {
        let observed = GQLQuery.allCases.compactMap { store.date(for: .observed, query: $0) }
        return (observed + [store.latestSessionResult?.finishedAt].compactMap { $0 }).max()
    }

    private func lastCheckedDescription(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) {
            return "Last checked today at \(time)"
        }
        if Calendar.current.isDateInYesterday(date) {
            return "Last checked yesterday at \(time)"
        }
        return "Last checked \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private var backupSection: some View {
        Section {
            HStack(spacing: 8) {
                // Each dialog hangs off its own button: two file dialogs on one view can
                // leave only the last one working.
                Button("Export Settings\u{2026}") {
                    exportSettingsBackup()
                }
                .fileExporter(
                    isPresented: $isExportingSettingsBackup,
                    item: settingsBackupExport,
                    contentTypes: [.json],
                    defaultFilename: "SwiftMiner Settings Backup.json"
                ) { result in
                    settingsBackupExport = nil
                    switch result {
                    case .success:
                        backupMessage = "Settings backup exported."
                    case .failure(let error):
                        backupMessage = "Export failed: \(error.localizedDescription)"
                    }
                } onCancellation: {
                    settingsBackupExport = nil
                }
                Button("Import Settings\u{2026}") {
                    isImportingSettingsBackup = true
                }
                .fileImporter(
                    isPresented: $isImportingSettingsBackup,
                    allowedContentTypes: [.json]
                ) { result in
                    importSettingsBackup(result)
                }
            }

            if let backupMessage {
                SettingsSecondaryText(backupMessage)
            } else {
                SettingsSecondaryText("Exports preferences, game rules, filters, quiet hours and integration endpoints. Account login tokens are never included.")
            }
        } header: {
            Text("Backup")
        }
    }

    private func exportSettingsBackup() {
        do {
            settingsBackupExport = SettingsBackupFile(data: try settings.exportBackupData())
            isExportingSettingsBackup = true
        } catch {
            backupMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func importSettingsBackup(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let data = try Data(contentsOf: url)
            try settings.importBackupData(data)
            Task {
                await navigation.minerManager.updateAntiStallRecovery(enabled: settings.antiStallRecoveryEnabled)
                await navigation.minerManager.updateFollowedStreamerPriority(enabled: settings.prioritiseFollowedStreamers)
            }
            backupMessage = "Settings backup imported."
        } catch {
            backupMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    private func openSafariExtensionSettings() {
        SafariQueryHashExtensionBridge.showPreferences()
    }

    /// The only path that ever refreshes a Twitch query hash: the user pressed the button.
    private func startSafariUpdate() {
        updates.startUpdate(
            directorySlug: settings.firstPriorityGameCategorySlug,
            navigation: navigation
        )
        queryHashStateVersion &+= 1
    }

}

/// A settings backup as the save dialog writes it.
private struct SettingsBackupFile: Transferable {
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .json) { $0.data }
    }
}
