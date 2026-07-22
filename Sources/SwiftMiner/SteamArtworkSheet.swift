// Manual Steam App ID entry sheet and its glass button styles.
import SwiftUI
import SwiftMinerCore
import AppKit

struct SteamIdSheetPresentation: Identifiable {
    let id = UUID()
    let gameName: String
}

struct SetSteamIdSheet: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isInputFocused: Bool
    @State private var steamId = ""
    let onSet: (String) -> Void
    private let modalCornerRadius: CGFloat = 20

    private var normalizedSteamId: String {
        steamId.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isValidSteamId: Bool {
        !normalizedSteamId.isEmpty && normalizedSteamId.allSatisfy(\.isNumber)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Set Steam ID")
                .font(.title3.weight(.semibold))

            Text("""
            SwiftMiner uses Steam IDs to fetch high-resolution artwork for games.
            Without this, some games may appear with low-quality or missing images.
            """)
            .font(.body)
            .foregroundStyle(Color.secondary.opacity(0.82))
            .lineLimit(nil)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 10)

            TextField("e.g. 2073850", text: $steamId)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .frame(maxWidth: .infinity)
                .focused($isInputFocused)
                .onSubmit {
                    submitIfValid()
                }
                .opacity(0.82)
                .padding(.top, 16)

            Text("You can find this on SteamDB or the game's store page.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .opacity(0.76)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)

            HStack(spacing: 14) {
                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(SteamSecondaryGlassButtonStyle())
                .keyboardShortcut(.cancelAction)

                Button("Set") {
                    submitIfValid()
                }
                .buttonStyle(SteamPrimaryGlassButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!isValidSteamId)
            }
            .padding(.top, 18)
        }
        .frame(maxWidth: 420, alignment: .leading)
        .padding(24)
        .background {
            RoundedRectangle(cornerRadius: modalCornerRadius, style: .continuous)
                .fill(.thinMaterial.opacity(0.50))
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.12),
                            Color.white.opacity(0.03),
                            .clear
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(height: 1)
                .padding(.horizontal, 16)
                .blendMode(.screen)
        }
        .shadow(color: .black.opacity(0.055), radius: 46, y: 14)
        .scaleEffect(1.001)
        .padding(20)
        .onAppear {
            isInputFocused = true
        }
    }

    private func submitIfValid() {
        guard isValidSteamId else { return }
        onSet(normalizedSteamId)
        dismiss()
    }
}

struct SteamPrimaryGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryBody(configuration: configuration)
    }

    private struct PrimaryBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(isEnabled ? 0.96 : 0.72))
                .padding(.horizontal, 15)
                .padding(.vertical, 8)
                .background {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(.ultraThinMaterial.opacity(0.58))
                        .overlay {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(Color.accentColor.opacity(isHovering ? 0.34 : 0.30))
                        }
                        .overlay(alignment: .top) {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color.white.opacity(0.20),
                                            .clear
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .padding(0.5)
                                .blendMode(.screen)
                        }
                }
                .brightness(isHovering ? 0.028 : 0)
                .brightness(configuration.isPressed ? -0.06 : 0)
                .opacity(isEnabled ? 1 : 0.65)
                .onHover { hovering in
                    isHovering = hovering
                }
                .animation(.easeInOut(duration: 0.16), value: isHovering)
                .animation(.easeInOut(duration: 0.10), value: configuration.isPressed)
        }
    }
}

struct SteamSecondaryGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        SecondaryBody(configuration: configuration)
    }

    private struct SecondaryBody: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.white.opacity(isHovering ? 0.08 : 0.01))
                }
                .opacity(configuration.isPressed ? 0.78 : (isEnabled ? 0.58 : 0.42))
                .onHover { hovering in
                    isHovering = hovering
                }
                .animation(.easeInOut(duration: 0.16), value: isHovering)
                .animation(.easeInOut(duration: 0.10), value: configuration.isPressed)
        }
    }
}
