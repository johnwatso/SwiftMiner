import SwiftUI
import SwiftTwitchMiner

/// Dedicated view for managing game preferences (Prioritised and Excluded).
/// Opened as a sheet from Settings.
struct GamePreferenceManagementView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var settings: Settings
    let minerManager: MinerManager

    private var prioritisedGames: [GamePreference] {
        settings.gamePreferences.filter { $0.state == .preferred }
            .sorted { $0.gameName.localizedCaseInsensitiveCompare($1.gameName) == .orderedAscending }
    }

    private var excludedGames: [GamePreference] {
        settings.gamePreferences.filter { $0.state == .excluded }
            .sorted { $0.gameName.localizedCaseInsensitiveCompare($1.gameName) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Native-style header
            HStack {
                Text("Game Rules")
                    .font(.headline)
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
                    }
                }

                if !excludedGames.isEmpty {
                    Section("Excluded") {
                        ForEach(excludedGames) { preference in
                            PreferenceRow(preference: preference, settings: settings)
                        }
                    }
                }

                if prioritisedGames.isEmpty && excludedGames.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "list.bullet.rectangle.stack")
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
    }
}

private struct PreferenceRow: View {
    let preference: GamePreference
    @ObservedObject var settings: Settings

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: preference.boxArtURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.quaternary)
            }
            .frame(width: 24, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))

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
        }
        .padding(.vertical, 2)
    }
}
