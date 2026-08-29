import SwiftUI
import SwiftMinerCore

/// Dedicated view for managing game preferences (Prioritised and Excluded).
/// Opened as a sheet from Settings.
struct GamePreferenceManagementView: View {
    @Environment(\.dismiss) private var dismiss
    var settings: Settings
    let minerManager: MinerManager

    private var prioritisedGames: [GamePreference] {
        settings.gamePreferences.filter { $0.state == .preferred }
    }

    private var excludedGames: [GamePreference] {
        settings.gamePreferences.filter { $0.state == .excluded }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Native-style header
            HStack {
                Text("Game Rules")
                    .font(.headline)

                Link(destination: URL(string: "https://swiftminer.app/help/game-rules/")!) {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Learn about priorities, exclusions, and failover streamers")
                .accessibilityLabel("Game Rules Help")

                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
            .background(.ultraThinMaterial)

            Divider()

            List {
                Section {
                    GameSearchField(settings: settings, minerManager: minerManager)
                        .padding(.vertical, 4)
                } header: {
                    Text("Add Rule")
                } footer: {
                    Text("Search for games to prioritise or exclude.")
                }

                if !prioritisedGames.isEmpty {
                    Section("Prioritised") {
                        ForEach(prioritisedGames) { preference in
                            PreferenceRow(preference: preference, settings: settings)
                        }
                        .onMove { from, to in
                            settings.moveGamePreferences(fromOffsets: from, toOffset: to, inState: .preferred)
                        }
                    }
                }

                if !excludedGames.isEmpty {
                    Section("Excluded") {
                        ForEach(excludedGames) { preference in
                            PreferenceRow(preference: preference, settings: settings)
                        }
                        .onMove { from, to in
                            settings.moveGamePreferences(fromOffsets: from, toOffset: to, inState: .excluded)
                        }
                    }
                }

                if prioritisedGames.isEmpty && excludedGames.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: SystemSymbolCompatibility.resolvedName(for: "list.bullet.rectangle.stack"))
                            .font(.system(size: 24))
                            .foregroundStyle(.tertiary)
                        Text("No rules configured.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.inset)
        }
        .frame(width: 480, height: 500)
        // `.task(id:)` rather than `.onChange` + `Task {}`: SwiftUI cancels the in-flight push
        // when the rules change again, so a rapid series of edits cannot land out of order.
        .task(id: settings.gameFailoverStreamersData) {
            await minerManager.updateFailoverStreamers(settings.gameFailoverStreamers)
        }
    }
}

private struct PreferenceRow: View {
    let preference: GamePreference
    var settings: Settings
    @State private var resolvedArtworkURL: URL?
    @State private var failoverLogin: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                AsyncImage(url: resolvedArtworkURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(.quaternary)
                }
                .frame(width: 24, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .task(id: artworkRefreshID) {
                    resolvedArtworkURL = preference.customArtworkURL ?? preference.resolvedBoxArtURL
                }

                Text(preference.gameName)
                    .font(.body)

                Spacer()

                Picker("", selection: Binding(
                    get: { preference.state },
                    set: { settings.setPreferenceState($0, for: preference) }
                )) {
                    Text("Prioritise").tag(PreferenceState.preferred)
                    Text("Exclude").tag(PreferenceState.excluded)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)

                Button {
                    settings.removeGamePreference(preference)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Remove rule")
            }

            HStack(spacing: 8) {
                Image(systemName: SystemSymbolCompatibility.resolvedName(for: "arrow.trianglehead.2.clockwise"))
                    .foregroundStyle(.secondary)
                    .frame(width: 24)

                TextField("Failover streamer", text: $failoverLogin)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
                    .onSubmit(commitFailover)

                Button(action: commitFailover) {
                    Image(systemName: "checkmark.circle")
                }
                .buttonStyle(.plain)
                .help("Save failover streamer")

                Button(action: clearFailover) {
                    Image(systemName: "xmark.circle")
                }
                .buttonStyle(.plain)
                .disabled(failoverLogin.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .help("Clear failover streamer")

                Text("Used after stalled progress")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 36)
        }
        .padding(.vertical, 2)
        .onAppear(perform: syncFailover)
        .onChange(of: settings.gameFailoverStreamersData) { _, _ in
            syncFailover()
        }
    }

    private var artworkRefreshID: String {
        preference.customArtworkURL?.absoluteString ?? ""
    }

    private func syncFailover() {
        failoverLogin = settings.failoverStreamer(for: preference).map { "@\($0.streamerLogin)" } ?? ""
    }

    private func commitFailover() {
        settings.setFailoverStreamer(failoverLogin, for: preference)
        syncFailover()
    }

    private func clearFailover() {
        settings.clearFailoverStreamer(for: preference)
        syncFailover()
    }
}
