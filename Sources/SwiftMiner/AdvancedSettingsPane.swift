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
    /// Nothing heard from it yet. Not the same as switched off — a healthy extension is
    /// silent until Twitch is open, so this must never raise a warning on its own.
    case unknown

    var label: String {
        switch self {
        case .active: return "Active"
        case .unknown: return "Not detected yet"
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

/// How one Twitch operation SwiftMiner depends on compares against the live site.
///
/// Twitch keys persisted queries by the hash of the document, so "what SwiftMiner sends"
/// and "what twitch.tv sends" are directly comparable values. That comparison — not a
/// transport result — is what this screen reports.
private struct QueryCompatibility: Identifiable {
    enum State {
        /// Twitch is using the same document SwiftMiner sends.
        case upToDate
        /// Twitch has changed, and the replacement is being tried against a live request.
        case validating
        /// Twitch's own site uses a different document for this operation, and SwiftMiner's
        /// works fine. Normal, not a problem: Twitch serves more than one query under some
        /// operation names, and the Drops inventory is permanently one of them. Flagging it
        /// would put an amber warning on screen forever over nothing.
        case differs
        /// SwiftMiner's own query has stopped working *and* the replacement could not be
        /// adopted. The only case here that is genuinely a warning.
        case unverified
        /// The extension has not seen this query yet. A healthy extension is silent until
        /// Twitch is open, so this must not read as a problem.
        case waiting
    }

    let query: GQLQuery
    let state: State
    let appHash: String
    let siteHash: String?
    let usesDiscoveredHash: Bool

    var id: String { query.rawValue }

    var appLabel: String { usesDiscoveredHash ? "Updated" : "Built-in" }

    var siteLabel: String {
        switch state {
        case .upToDate: return "Matches"
        case .differs: return "Differs"
        case .validating, .unverified: return "Changed"
        case .waiting: return "Not seen yet"
        }
    }
}

/// The single headline state at the top of the card.
///
/// Modelled as a value with an action *case* rather than a closure so it can be derived
/// outside the view builder without capturing view state.
private struct CompatibilityStatus {
    enum Action {
        case safariSettings
        case checkAgain
    }

    var title: String
    var detail: String?
    var symbol: String = "checkmark.circle.fill"
    var tint: Color = .green
    var isWaiting: Bool = false
    var action: Action?
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
            .help("Twitch compatibility updates are new and still being proven. SwiftMiner always keeps the queries it shipped with, so an update that goes wrong cannot stop mining.")
    }
}

// MARK: - Advanced Settings

struct AdvancedSettingsView: View {
    @Bindable var settings: Settings
    @Environment(NavigationModel.self) private var navigation
    @State private var showClientIdAlert = false
    @State private var tempClientId = ""
    @State private var backupMessage: String?
    @State private var queryHashCheckStartedAt: Date?
    @State private var queryHashStateVersion = 0
    @State private var automaticQueryHashDiscovery = false
    @State private var showCompatibilityAdvanced = false

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
            Text("With five miners, 5,000 log entries is roughly 75 minutes of history. Automatic measurements are added to exported diagnostic reports.")
        }
    }

    private var twitchCompatibilitySection: some View {
        let store = TwitchQueryHashStore.standard
        _ = queryHashStateVersion
        let rows = comparedQueries(store: store)
        let status = compatibilityStatus(store: store, rows: rows)

        return Section {
            VStack(alignment: .leading, spacing: 14) {
                Toggle(isOn: $automaticQueryHashDiscovery) {
                    Text("Keep Twitch queries up to date")
                }
                .toggleStyle(.switch)
                .onChange(of: automaticQueryHashDiscovery) { _, enabled in
                    store.automaticDiscoveryEnabled = enabled
                    queryHashStateVersion &+= 1
                }

                compatibilityHeadline(status)

                if automaticQueryHashDiscovery {
                    Divider()
                    compatibilityTable(rows)
                }

                Divider()
                extensionFooter(store: store)

                DisclosureGroup(isExpanded: $showCompatibilityAdvanced) {
                    technicalDetails(store: store, rows: rows)
                        .padding(.top, 8)
                } label: {
                    Text("Technical Details")
                        .font(.callout)
                }
            }
            .padding(.vertical, 2)
        } header: {
            HStack(spacing: 7) {
                Text("Twitch Compatibility")
                BetaBadge()
            }
        }
        .onAppear {
            automaticQueryHashDiscovery = store.automaticDiscoveryEnabled
            settlePendingCandidates()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            queryHashStateVersion &+= 1
        }
        // Ticks for as long as the pane is on screen, not just during a manual check.
        // Everything this card reports happens in the background — the extension observes,
        // a refresh validates, a hash is retired — and the whole sequence can be over in
        // half a second. Bumping only during a manual check left the card frozen on
        // whatever it computed when it appeared, so a state that had already resolved went
        // on showing "validating…" indefinitely. The tick reads a handful of defaults keys.
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            if let startedAt = queryHashCheckStartedAt,
               GQLQuery.allCases.contains(where: {
                   (store.date(for: .observed, query: $0) ?? .distantPast) >= startedAt
               }) {
                // Retire the manual check's marker once the extension has reported back.
                queryHashCheckStartedAt = nil
            }
            queryHashStateVersion &+= 1
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
        HStack(alignment: .top, spacing: 10) {
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

            VStack(alignment: .leading, spacing: 3) {
                Text(status.title)
                    .font(.callout.weight(.medium))

                if let detail = status.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                switch status.action {
                case .none:
                    EmptyView()
                case .safariSettings:
                    Button("Open Safari Settings\u{2026}") {
                        openSafariExtensionSettings()
                    }
                    .buttonStyle(.link)
                    .padding(.top, 1)
                case .checkAgain:
                    Button("Update via Safari") {
                        startSafariUpdate()
                    }
                    .buttonStyle(.link)
                    .padding(.top, 1)
                }
            }

            Spacer(minLength: 0)
        }
    }

    /// Only one state is ever on screen, so the order these are tested in is the order a
    /// user should hear about them: a change SwiftMiner could not adopt first, then work
    /// already under way, then a setup problem that would stop future updates.
    private func compatibilityStatus(
        store: TwitchQueryHashStore,
        rows: [QueryCompatibility]
    ) -> CompatibilityStatus {
        guard automaticQueryHashDiscovery else {
            return CompatibilityStatus(
                title: "Automatic updates are off",
                detail: "SwiftMiner will keep using the Twitch queries it shipped with.",
                symbol: "pause.circle.fill",
                tint: .secondary
            )
        }

        if rows.contains(where: { $0.state == .unverified }) {
            return CompatibilityStatus(
                title: "Update couldn\u{2019}t be verified",
                detail: "One of SwiftMiner\u{2019}s queries has stopped working and the replacement could not be confirmed. Mining continues on the version it shipped with.",
                symbol: "exclamationmark.triangle.fill",
                tint: .orange,
                action: .checkAgain
            )
        }

        let validating = rows.filter { $0.state == .validating }
        if !validating.isEmpty {
            // Only claim to be validating when something is actually in flight. A query the
            // app cannot exercise on demand — a claim mutation, say, which must never be
            // fired just to test a hash — waits for its next real use, and saying so beats
            // a spinner that could run for hours.
            let settleable = validating.contains {
                TwitchCompatibilityRecovery.settleableByRefresh.contains($0.query)
            }
            return CompatibilityStatus(
                title: "Update detected",
                detail: settleable
                    ? "SwiftMiner is validating the new Twitch query\u{2026}"
                    : "SwiftMiner will check the new value the next time it uses this query.",
                symbol: "clock",
                tint: .secondary,
                isWaiting: settleable
            )
        }

        if queryHashCheckStartedAt != nil, !checkFoundNothing(store: store) {
            return CompatibilityStatus(
                title: "Checking Twitch\u{2026}",
                detail: "No action required.",
                isWaiting: true
            )
        }

        if checkFoundNothing(store: store) {
            return CompatibilityStatus(
                title: "Safari extension may be turned off",
                detail: "The update ran but Twitch reported nothing back. Enabling the extension lets SwiftMiner refresh its Twitch queries in Safari.",
                symbol: "exclamationmark.triangle.fill",
                tint: .orange,
                action: .safariSettings
            )
        }

        if rows.allSatisfy({ $0.state == .waiting }) {
            return CompatibilityStatus(
                title: "Waiting for Twitch",
                detail: "Choose Update via Safari and SwiftMiner will step through Twitch in one tab to refresh the queries it uses.",
                symbol: "clock",
                tint: .secondary
            )
        }

        // A recent adoption is worth saying out loud: it is the whole feature working, and
        // it is the one moment the user might otherwise wonder what changed.
        if let updated = lastUpdateDate(store: store),
           Date().timeIntervalSince(updated) < 24 * 60 * 60 {
            return CompatibilityStatus(
                title: "Updated automatically",
                detail: "SwiftMiner adopted a new Twitch query \(compatibilityDateLabel(updated).lowercased())."
            )
        }

        return CompatibilityStatus(
            title: "Up to Date",
            detail: "SwiftMiner automatically keeps its Twitch queries compatible."
        )
    }

    // MARK: Compatibility table

    @ViewBuilder
    private func compatibilityTable(_ rows: [QueryCompatibility]) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow {
                Text("Query")
                Text("SwiftMiner")
                Text("Twitch")
                Color.clear.frame(width: 14, height: 1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            ForEach(rows) { row in
                GridRow {
                    Text(row.query.displayName)

                    Label(row.appLabel, systemImage: "macwindow")
                        .labelStyle(.titleAndIcon)

                    Label(row.siteLabel, systemImage: "safari")
                        .labelStyle(.titleAndIcon)

                    compatibilitySymbol(row.state)
                }
                .font(.callout)
            }
        }
        .imageScale(.small)
    }

    @ViewBuilder
    private func compatibilitySymbol(_ state: QueryCompatibility.State) -> some View {
        switch state {
        case .upToDate:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityLabel("Up to date")
        case .validating:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel("Validating")
        case .differs:
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Twitch uses a different query; SwiftMiner's works")
        case .unverified:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityLabel("Not verified")
        case .waiting:
            Image(systemName: "clock")
                .foregroundStyle(.secondary)
                .accessibilityLabel("Not seen yet")
        }
    }

    /// The operations shown in the table.
    ///
    /// The Drops pages are the only place the extension can observe anything, so those two
    /// are always listed even before they have been seen. Anything else the extension has
    /// actually reported joins them rather than being hidden.
    private func comparedQueries(store: TwitchQueryHashStore) -> [QueryCompatibility] {
        let core: [GQLQuery] = [.viewerDropsDashboard, .inventory]
        let extra = GQLQuery.allCases.filter {
            !core.contains($0) && store.observedHash(for: $0) != nil
        }
        let broken = Set(store.queriesNeedingRecovery())
        return (core + extra).map { compatibility(of: $0, store: store, broken: broken) }
    }

    private func compatibility(
        of query: GQLQuery,
        store: TwitchQueryHashStore,
        broken: Set<GQLQuery>
    ) -> QueryCompatibility {
        let resolution = store.resolution(for: query)
        let observed = store.observedHash(for: query)

        let state: QueryCompatibility.State
        if store.candidate(for: query) != nil {
            state = .validating
        } else if let observed {
            if observed == resolution.hash {
                state = .upToDate
            } else {
                // A difference only matters when SwiftMiner's own query has stopped
                // working. Otherwise Twitch is simply asking a different question under the
                // same name, which it does routinely and which costs nothing.
                state = broken.contains(query) ? .unverified : .differs
            }
        } else {
            state = .waiting
        }

        return QueryCompatibility(
            query: query,
            state: state,
            appHash: resolution.hash,
            siteHash: observed,
            usesDiscoveredHash: resolution.source != .bundled
        )
    }

    // MARK: Extension footer

    @ViewBuilder
    private func extensionFooter(store: TwitchQueryHashStore) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "safari")
                .foregroundStyle(.secondary)

            Text("Safari Extension \u{00B7} \(safariExtensionState(store: store).label)")

            if let verified = lastVerifiedDate(store: store) {
                Text("\u{00B7}")
                    .foregroundStyle(.tertiary)
                Text("Last verified \u{00B7} \(compatibilityDateLabel(verified))")
            }

            Spacer(minLength: 8)

            Button("Update via Safari") {
                startSafariUpdate()
            }
            .controlSize(.small)

            Button("Extension Settings\u{2026}") {
                openSafariExtensionSettings()
            }
            .buttonStyle(.link)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .imageScale(.small)
    }

    // MARK: Technical details

    @ViewBuilder
    private func technicalDetails(
        store: TwitchQueryHashStore,
        rows: [QueryCompatibility]
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.query.displayName)
                        .font(.caption.weight(.medium))
                    hashLine("SwiftMiner", hash: row.appHash)
                    hashLine("Twitch", hash: row.siteHash)
                }
            }

            LabeledContent("Last compatibility check", value: compatibilityDateLabel(lastCheckDate(store: store)))
            LabeledContent("Last successful update", value: compatibilityDateLabel(lastUpdateDate(store: store)))

            Text("An update opens one Twitch tab and steps through the pages SwiftMiner needs, then closes itself out. The extension does nothing at any other time, and a value SwiftMiner cannot confirm is never adopted \u{2014} the version it shipped with stays in use.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func hashLine(_ label: String, hash: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .frame(width: 72, alignment: .leading)
            Text(hash ?? "Not seen yet")
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    // MARK: Compatibility dates

    private func safariExtensionState(store: TwitchQueryHashStore) -> SafariExtensionAvailability {
        lastCheckDate(store: store) == nil ? .unknown : .active
    }

    private func lastCheckDate(store: TwitchQueryHashStore) -> Date? {
        GQLQuery.allCases.compactMap { store.date(for: .observed, query: $0) }.max()
    }

    private func lastUpdateDate(store: TwitchQueryHashStore) -> Date? {
        GQLQuery.allCases.compactMap { store.date(for: .accepted, query: $0) }.max()
    }

    private func lastVerifiedDate(store: TwitchQueryHashStore) -> Date? {
        [lastCheckDate(store: store), lastUpdateDate(store: store)].compactMap { $0 }.max()
    }

    /// True once a manual check has run long enough to conclude nothing is listening.
    private func checkFoundNothing(store: TwitchQueryHashStore) -> Bool {
        guard let startedAt = queryHashCheckStartedAt else { return false }
        guard Date().timeIntervalSince(startedAt) >= 12 else { return false }
        return !GQLQuery.allCases.contains { query in
            (store.date(for: .observed, query: query) ?? .distantPast) >= startedAt
        }
    }

    private func compatibilityDateLabel(_ date: Date?) -> String {
        guard let date else { return "Never" }
        if Calendar.current.isDateInToday(date) {
            return "Today, " + date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private var backupSection: some View {
        Section {
            HStack(spacing: 8) {
                Button("Export Settings\u{2026}") {
                    exportSettingsBackup()
                }
                Button("Import Settings\u{2026}") {
                    importSettingsBackup()
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
            let data = try settings.exportBackupData()
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "SwiftMiner Settings Backup.json"
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            backupMessage = "Settings backup exported."
        } catch {
            backupMessage = "Export failed: \(error.localizedDescription)"
        }
    }

    private func importSettingsBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
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

    private func startSafariUpdate() {
        let store = TwitchQueryHashStore.standard
        store.automaticDiscoveryEnabled = true
        store.clearObservations()
        automaticQueryHashDiscovery = true
        queryHashCheckStartedAt = Date()
        queryHashStateVersion &+= 1

        TwitchCompatibilityRecovery.startUpdate(
            directorySlug: settings.firstPriorityGameCategorySlug
        )
    }

}
