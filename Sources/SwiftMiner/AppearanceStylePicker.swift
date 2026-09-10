import SwiftUI

// MARK: - Appearance Style Picker

/// The theme chooser, drawn the way System Settings draws Appearance: each
/// option is a small picture of what the app becomes, not a word for it.
///
/// A segmented control could only say "Standard" and "Atomic Purple", which
/// tells you nothing until you pick one and look. Each swatch is built from the
/// same `SwiftMinerAppearance` values the app itself paints with — including the
/// translucency — so the preview cannot drift away from the real thing.
struct AppearanceStylePicker: View {
    @Binding var selection: AppearanceStyle

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(AppearanceStyle.allCases) { style in
                AppearanceStyleSwatchButton(
                    style: style,
                    isSelected: selection == style
                ) {
                    selection = style
                }
            }
        }
    }
}

private struct AppearanceStyleSwatchButton: View {
    let style: AppearanceStyle
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(spacing: 6) {
                AppearanceStyleSwatch(style: style)
                    .overlay {
                        // The ring sits outside the swatch rather than on it, so
                        // selection never covers a pixel of the thing being chosen.
                        RoundedRectangle(cornerRadius: AppearanceStyleSwatch.cornerRadius + 3, style: .continuous)
                            // `.tint`, not `Color.accentColor`: the app sets its
                            // tint from the theme, so the ring is purple while
                            // Atomic Purple is the thing selected.
                            .strokeBorder(.tint, lineWidth: 3)
                            .padding(-3.5)
                            .opacity(isSelected ? 1 : 0)
                    }

                Text(style.title)
                    .font(.caption)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
            .padding(4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(style.title)
        .accessibilityLabel(style.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A miniature of the app under one style: sidebar, window plane and a card,
/// over a stand-in desktop that both swatches share — the desktop is the same
/// one either way, so showing it is what makes a translucent style legible next
/// to an opaque one.
private struct AppearanceStyleSwatch: View {
    let style: AppearanceStyle

    static let cornerRadius: CGFloat = 6
    private static let size = CGSize(width: 86, height: 54)

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var appearance: SwiftMinerAppearance {
        SwiftMinerAppearance(colorScheme: colorScheme, style: style)
    }

    /// Stands in for one of the app's surfaces at swatch scale.
    ///
    /// A real `.glassEffect` this small would refract the tile's own edges into
    /// mush, so the preview approximates it: a scrim for the material's body,
    /// the theme's own wash over it, and the desktop showing through both. What
    /// the swatch has to get right is how much comes through, not how the glass
    /// bends it. Reduce Transparency turns the real chrome opaque, so the
    /// preview follows it rather than promising a window the app will not draw.
    @ViewBuilder
    private func surface(_ role: AppearanceSurfaceRole) -> some View {
        if reduceTransparency || !appearance.usesTintedSurfaces {
            appearance.opaqueColor(for: role)
        } else {
            ZStack {
                appearance.opaqueColor(for: role).opacity(0.42)
                appearance.tint(for: role)
            }
        }
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            DesktopStandIn()

            miniWindow
                // Overhangs the bottom-right and is clipped, the way the System
                // Settings swatches do it: enough desktop stays visible for the
                // translucency to have something to show.
                .padding(.leading, 9)
                .padding(.top, 7)
                .offset(x: 4, y: 4)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(Color.black.opacity(0.20), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
    }

    private var miniWindow: some View {
        HStack(spacing: 0) {
            sidebar
            content
        }
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(appearance.separator(for: .standard), lineWidth: 0.5)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 2) {
                trafficLight(.red)
                trafficLight(.yellow)
                trafficLight(.green)
            }

            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(appearance.accent)
                .frame(height: 3.5)
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(Color.primary.opacity(0.22))
                .frame(width: 14, height: 3)

            Spacer(minLength: 0)
        }
        .padding(3)
        .frame(width: 24)
        .background { surface(.sidebar) }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 3) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(Color.primary.opacity(0.45))
                .frame(width: 22, height: 4)

            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(.clear)
                .background { surface(.secondary) }
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .strokeBorder(appearance.separator(for: .standard), lineWidth: 0.5)
                }
                .overlay(alignment: .bottomLeading) {
                    Capsule()
                        .fill(appearance.accent)
                        .frame(width: 18, height: 3)
                        .padding(4)
                }

            Spacer(minLength: 0)
        }
        .padding(4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { surface(.window) }
    }

    private func trafficLight(_ color: Color) -> some View {
        Circle()
            .fill(color)
            .frame(width: 3, height: 3)
    }
}

/// Stands in for the user's desktop. Deliberately generic: the swatch is about
/// what the app does to whatever is behind it, not about the wallpaper.
private struct DesktopStandIn: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.42, green: 0.60, blue: 0.90),
                Color(red: 0.29, green: 0.36, blue: 0.72),
                Color(red: 0.18, green: 0.20, blue: 0.47)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

#Preview {
    @Previewable @State var style: AppearanceStyle = .atomicPurple

    Form {
        LabeledContent("Theme") {
            AppearanceStylePicker(selection: $style)
        }
    }
    .formStyle(.grouped)
    .frame(width: 480)
}
