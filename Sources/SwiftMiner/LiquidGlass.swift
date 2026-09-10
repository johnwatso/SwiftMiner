import AppKit
import SwiftUI

// MARK: - Semantic Appearance

enum AppearanceSurfaceRole {
    case window
    case sidebar
    case secondary
    case elevated
    case selected
}

/// App-wide semantic appearance values. Views ask for a surface role and never
/// need to know which concrete theme supplied its color.
struct SwiftMinerAppearance {
    /// Resolved by the system, never by the app: SwiftMiner has no light/dark
    /// switch of its own, so both variants of a style come from macOS.
    let colorScheme: ColorScheme
    let style: AppearanceStyle

    var usesTintedSurfaces: Bool { style == .atomicPurple }
    private var isLight: Bool { colorScheme == .light }

    /// Atomic Purple is anchored to a single blue-violet hue (~256°) so every
    /// surface reads as one family. The values below are the theme's own colours
    /// and are painted flat: blending them out of a vibrancy material let the
    /// desktop behind the window pull the hue around from machine to machine.
    var accent: Color {
        guard usesTintedSurfaces else { return .accentColor }
        return isLight
            ? Color(red: 0.518, green: 0.263, blue: 0.969)
            : Color(red: 0.780, green: 0.620, blue: 0.969)
    }

    /// Semantic activity colors follow the theme accent under a tinted style —
    /// a green progress bar fights the purple it sits on. Warning and failure
    /// colors are left alone: those carry meaning the theme must not repaint.
    func activityAccent(_ color: Color) -> Color {
        guard usesTintedSurfaces, color == .green else { return color }
        return accent
    }

    /// The wash a themed surface paints over its blur — and, under Atomic
    /// Purple, that is now every surface: window, sidebar and cards alike.
    ///
    /// This table is the whole translucency control. A wash rather than a fill
    /// is what keeps the hue the theme's own: the blur underneath is already
    /// blurred and muted by the material, so what comes through moves the
    /// surface's brightness far more than its colour. The steps between roles
    /// have to carry the surface hierarchy by themselves now that nothing is
    /// painted solid — each role sits a little heavier than the one it lifts off.
    func tint(for role: AppearanceSurfaceRole) -> Color {
        guard usesTintedSurfaces else { return .clear }
        if isLight {
            switch role {
            case .window:
                return Color(red: 0.80, green: 0.73, blue: 0.94).opacity(0.18)
            case .sidebar:
                return Color(red: 0.70, green: 0.59, blue: 0.90).opacity(0.36)
            case .secondary:
                return Color(red: 0.74, green: 0.65, blue: 0.93).opacity(0.32)
            case .elevated:
                return Color(red: 0.69, green: 0.58, blue: 0.91).opacity(0.38)
            case .selected:
                return Color(red: 0.60, green: 0.44, blue: 0.86).opacity(0.46)
            }
        }
        switch role {
        case .window:
            return Color(red: 0.22, green: 0.13, blue: 0.45).opacity(0.38)
        case .sidebar:
            return Color(red: 0.24, green: 0.15, blue: 0.46).opacity(0.56)
        case .secondary:
            return Color(red: 0.29, green: 0.19, blue: 0.54).opacity(0.50)
        case .elevated:
            return Color(red: 0.34, green: 0.23, blue: 0.60).opacity(0.54)
        case .selected:
            return Color(red: 0.47, green: 0.31, blue: 0.78).opacity(0.62)
        }
    }

    func opaqueColor(for role: AppearanceSurfaceRole) -> Color {
        guard usesTintedSurfaces else {
            switch role {
            case .window: return Color(nsColor: .windowBackgroundColor)
            case .sidebar: return Color(nsColor: .underPageBackgroundColor)
            case .secondary, .elevated, .selected: return Color(nsColor: .controlBackgroundColor)
            }
        }
        if isLight {
            switch role {
            // Near-white with only a breath of lavender: the content plane is
            // where text lives, and the colour belongs to the chrome around it.
            case .window: return Color(red: 0.973, green: 0.961, blue: 0.992)
            case .sidebar: return Color(red: 0.824, green: 0.765, blue: 0.933)
            case .secondary: return Color(red: 0.922, green: 0.894, blue: 0.976)
            case .elevated: return Color(red: 0.894, green: 0.855, blue: 0.965)
            case .selected: return Color(red: 0.718, green: 0.600, blue: 0.910)
            }
        }
        switch role {
        // Dark keeps the steps close together — deep indigo rather than black —
        // so cards lift off the window without turning into separate slabs.
        case .window: return Color(red: 0.173, green: 0.133, blue: 0.322)
        case .sidebar: return Color(red: 0.176, green: 0.149, blue: 0.302)
        case .secondary: return Color(red: 0.192, green: 0.161, blue: 0.337)
        case .elevated: return Color(red: 0.220, green: 0.180, blue: 0.388)
        case .selected: return Color(red: 0.443, green: 0.290, blue: 0.741)
        }
    }

    func separator(for contrast: ColorSchemeContrast) -> Color {
        guard usesTintedSurfaces else { return Color(nsColor: .separatorColor) }
        // A white hairline disappears on a near-white light surface, so light
        // draws its edges darker than the fill and dark draws them lighter.
        return isLight
            ? Color(red: 0.36, green: 0.24, blue: 0.60).opacity(contrast == .increased ? 0.38 : 0.16)
            : Color.white.opacity(contrast == .increased ? 0.30 : 0.12)
    }
}

private struct SwiftMinerAppearanceKey: EnvironmentKey {
    static let defaultValue = SwiftMinerAppearance(colorScheme: .dark, style: .standard)
}

extension EnvironmentValues {
    var swiftMinerAppearance: SwiftMinerAppearance {
        get { self[SwiftMinerAppearanceKey.self] }
        set { self[SwiftMinerAppearanceKey.self] = newValue }
    }
}

/// Publishes the chosen style, resolved against whichever appearance macOS is
/// currently in. Deliberately no `preferredColorScheme`: forcing one would
/// override the system setting the whole theme is now keyed to.
private struct SwiftMinerAppearanceModifier: ViewModifier {
    let style: AppearanceStyle
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        let appearance = SwiftMinerAppearance(colorScheme: colorScheme, style: style)
        content
            .environment(\.swiftMinerAppearance, appearance)
            .tint(appearance.accent)
    }
}

extension View {
    func swiftMinerAppearance(style: AppearanceStyle) -> some View {
        modifier(SwiftMinerAppearanceModifier(style: style))
    }
}

struct LiquidGlassBackdrop: View {
    @Environment(\.swiftMinerAppearance) private var appearance
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var isTranslucent: Bool {
        appearance.usesTintedSurfaces && !reduceTransparency
    }

    var body: some View {
        ZStack {
            if isTranslucent {
                // Blur first, theme colour over it. Painting the colour on top —
                // rather than tinting a vibrancy material and letting it blend —
                // is what keeps the hue the theme's own: the desktop underneath
                // shifts how bright the plane reads, not what colour it is.
                VisualEffectMaterialView(
                    material: .fullScreenUI,
                    blendingMode: .behindWindow
                )
                appearance.tint(for: .window)
            } else {
                // Standard stays exactly as it was: a flat window plane, which is
                // also where Reduce Transparency lands.
                appearance.opaqueColor(for: .window)
            }
        }
        .background(WindowTranslucencyConfigurator(isTranslucent: isTranslucent))
        .ignoresSafeArea()
    }
}

/// Lets the desktop reach the window's backing store.
///
/// A behind-window `NSVisualEffectView` blurs whatever the window is sitting on,
/// but an opaque window paints its own background over that first, so the blur
/// never shows. The flags are reverted the moment the style stops asking for
/// translucency, so switching back to Standard restores an ordinary window
/// rather than leaving a see-through one behind.
private struct WindowTranslucencyConfigurator: NSViewRepresentable {
    let isTranslucent: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        // The view has no window during `makeNSView`; apply once it is installed.
        DispatchQueue.main.async { apply(to: view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        apply(to: nsView.window)
    }

    private func apply(to window: NSWindow?) {
        guard let window else { return }
        window.isOpaque = !isTranslucent
        window.backgroundColor = isTranslucent ? .clear : .windowBackgroundColor
    }
}

struct SidebarMaterialBackground: View {
    @Environment(\.swiftMinerAppearance) private var appearance
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        Group {
            if reduceTransparency {
                appearance.opaqueColor(for: .sidebar)
            } else if appearance.usesTintedSurfaces {
                // The sidebar is the most translucent surface in the app: it is
                // chrome, it holds no body text, and it is where the desktop
                // moving behind the window is worth seeing.
                ZStack {
                    VisualEffectMaterialView(material: .sidebar, blendingMode: .behindWindow)
                    appearance.tint(for: .sidebar)
                }
            } else {
                VisualEffectMaterialView(material: .sidebar)
            }
        }
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(appearance.separator(for: colorSchemeContrast))
                    .frame(width: 1)
            }
            .clipShape(Rectangle())
            .ignoresSafeArea()
    }
}

struct VisualEffectMaterialView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .withinWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.state = .active
        view.material = material
        view.blendingMode = blendingMode
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
    }
}

/// A rounded semantic surface shared by selection, card and floating layers.
/// Accessibility fallbacks live here so every themed surface behaves alike.
struct AppearanceRoundedSurface: View {
    let role: AppearanceSurfaceRole
    let cornerRadius: CGFloat
    var material: Material = .thinMaterial
    var usesNativeGlass = false

    @Environment(\.swiftMinerAppearance) private var appearance
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    /// Atomic Purple asks for real glass on every surface it owns, not only the
    /// layers that opted in — the theme is the see-through one, so its cards are
    /// glass for the same reason its window is. Everything else keeps whatever
    /// its caller asked for.
    private var prefersNativeGlass: Bool {
        usesNativeGlass || appearance.usesTintedSurfaces
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            if reduceTransparency {
                shape.fill(appearance.opaqueColor(for: role))
            } else if prefersNativeGlass {
                if #available(macOS 26, *) {
                    // Tinting the glass rather than washing over it: the tint is
                    // part of how the material refracts what is behind it, so the
                    // purple stays lit instead of sitting on top as a flat film.
                    shape
                        .fill(.clear)
                        .glassEffect(.regular.tint(appearance.tint(for: role)), in: shape)
                } else {
                    materialSurface(shape)
                }
            } else {
                materialSurface(shape)
            }
        }
        .overlay {
            shape
                .strokeBorder(appearance.separator(for: colorSchemeContrast), lineWidth: colorSchemeContrast == .increased ? 1.25 : 1)
                .allowsHitTesting(false)
        }
    }

    private func materialSurface(_ shape: RoundedRectangle) -> some View {
        shape
            .fill(material)
            .overlay(shape.fill(appearance.tint(for: role)))
    }
}

// MARK: - Glass Card (SwiftBot-aligned)

private struct GlassCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.swiftMinerAppearance) private var appearance
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    let cornerRadius: CGFloat
    let tint: Color
    let stroke: Color

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                AppearanceRoundedSurface(role: .secondary, cornerRadius: cornerRadius)
            }
            .overlay(
                shape
                    // The white wash belongs to the glass look. On a themed fill it
                    // only bleaches the colour the palette just chose.
                    .fill(appearance.usesTintedSurfaces
                          ? Color.clear
                          : tint.opacity(colorScheme == .dark ? 1.0 : 0.50))
                    .allowsHitTesting(false)
            )
            .overlay(
                shape
                    .strokeBorder(
                        appearance.usesTintedSurfaces
                            ? appearance.separator(for: colorSchemeContrast)
                            : stroke.opacity(colorScheme == .dark ? 1.0 : 0.90),
                        lineWidth: colorSchemeContrast == .increased ? 1.25 : 1
                    )
                    .allowsHitTesting(false)
            )
    }
}

private struct GlassSurfaceModifier: ViewModifier {
    let role: AppearanceSurfaceRole
    let material: Material
    let cornerRadius: CGFloat
    let shadowOpacity: Double
    let shadowRadius: CGFloat
    let shadowY: CGFloat

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .background {
                AppearanceRoundedSurface(
                    role: role,
                    cornerRadius: cornerRadius,
                    material: material,
                    usesNativeGlass: true
                )
                // Shadow on the background shape, not on the clipped view —
                // avoids the rectangular NSVisualEffectView shadow artefact.
                .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius, y: shadowY)
            }
            .overlay {
                if #unavailable(macOS 26) {
                    shape
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.26),
                                    Color.white.opacity(0.08),
                                    Color.clear
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .opacity(0.45)
                        .allowsHitTesting(false)
                }
            }
            .clipShape(shape)
    }
}

enum GlassRadius {
    static let subtle: CGFloat = 4      // Sidebar selection, window-adjacent
    static let small: CGFloat = 6       // Controls, inline panels
    static let medium: CGFloat = 8      // Cards, content sections
    static let large: CGFloat = 10      // Featured content
    static let artwork: CGFloat = 10    // Artwork, images
    static let pill: CGFloat = 999      // Status badges, fully rounded
}

extension View {
    func glassContentSurface(cornerRadius: CGFloat = GlassRadius.medium) -> some View {
        modifier(
            GlassSurfaceModifier(
                role: .secondary,
                material: .regularMaterial,
                cornerRadius: cornerRadius,
                shadowOpacity: 0.08,
                shadowRadius: 6,
                shadowY: 2
            )
        )
    }

    func glassPanel(cornerRadius: CGFloat = GlassRadius.small) -> some View {
        modifier(
            GlassSurfaceModifier(
                role: .elevated,
                material: .thinMaterial,
                cornerRadius: cornerRadius,
                shadowOpacity: 0.06,
                shadowRadius: 4,
                shadowY: 1
            )
        )
    }

    func glassControlSurface(cornerRadius: CGFloat = GlassRadius.subtle) -> some View {
        modifier(
            GlassSurfaceModifier(
                role: .selected,
                material: .ultraThinMaterial,
                cornerRadius: cornerRadius,
                shadowOpacity: 0,
                shadowRadius: 0,
                shadowY: 0
            )
        )
    }

    /// SwiftBot-aligned card surface: thinMaterial + white tint overlay + white stroke border.
    func glassCard(
        cornerRadius: CGFloat = 18,
        tint: Color = .white.opacity(0.10),
        stroke: Color = .white.opacity(0.18)
    ) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius, tint: tint, stroke: stroke))
    }

    func metricPanelSurface(cornerRadius: CGFloat = GlassRadius.medium) -> some View {
        self
            .background(
                .thinMaterial.opacity(0.58),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.04), radius: 3, y: 1)
    }
}

// MARK: - Tahoe Content Surfaces

/// Metrics tuned to the macOS Tahoe look: larger corner radii and more air than
/// the tighter pre-Tahoe `GlassRadius` scale.
///
/// Nested radii follow the concentric rule — an inset child's radius is its
/// parent's radius minus the inset — so corners stay parallel instead of
/// pinching at the edges.
enum TahoeMetrics {
    static let card: CGFloat = 16       // Top-level grouped section
    static let nested: CGFloat = 10     // Content inset inside a card
    static let row: CGFloat = 8         // List rows and selection
    static let sectionSpacing: CGFloat = 20
    static let headerGap: CGFloat = 7
}

private struct TahoeCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?
    @Environment(\.swiftMinerAppearance) private var appearance
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private var borderOpacity: Double {
        // Tahoe's grouped boxes sit on a lighter fill and carry a fainter edge
        // than the heavier hairline earlier releases needed for separation.
        if #available(macOS 26, *) { return 0.20 }
        return 0.32
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                if appearance.usesTintedSurfaces {
                    AppearanceRoundedSurface(
                        role: .secondary,
                        cornerRadius: cornerRadius,
                        material: .thinMaterial
                    )
                } else {
                    shape.fill(.background.secondary)
                }
                if let tint {
                    shape.fill(tint)
                }
            }
            .overlay {
                shape
                    .strokeBorder(
                        appearance.usesTintedSurfaces
                            ? appearance.separator(for: colorSchemeContrast)
                            : Color(nsColor: .separatorColor).opacity(borderOpacity),
                        lineWidth: colorSchemeContrast == .increased ? 1.25 : 1
                    )
                    .allowsHitTesting(false)
            }
    }
}

/// Raised surface for headers and action bars sitting above content.
///
/// Under Standard this is deliberately *not* `.glassEffect`: a real Liquid Glass
/// backdrop inside a scroll view resamples what's behind it every frame, which
/// reads as scroll jank, so it takes the near-opaque `.thinMaterial` treatment
/// the Drops feed cards use, which scrolls smoothly. Atomic Purple opts into the
/// glass anyway — being see-through is the whole point of that style — and pays
/// the resampling cost for it. If a list ever scrolls badly under the theme,
/// `AppearanceRoundedSurface.prefersNativeGlass` is the one switch to reach for.
private struct TahoeRaisedSurfaceModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.swiftMinerAppearance) private var appearance
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                AppearanceRoundedSurface(
                    role: .elevated,
                    cornerRadius: cornerRadius,
                    material: .thinMaterial
                )
            }
            .overlay {
                shape
                    .strokeBorder(
                        appearance.usesTintedSurfaces
                            ? appearance.separator(for: colorSchemeContrast)
                            : Color(nsColor: .separatorColor).opacity(0.22),
                        lineWidth: colorSchemeContrast == .increased ? 1.25 : 1
                    )
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    /// Grouped content surface. Content sits on an opaque grouped fill rather
    /// than glass — under Tahoe, Liquid Glass belongs to the control layer, and
    /// stacking it behind scrolling content muddies both.
    func tahoeCard(cornerRadius: CGFloat = TahoeMetrics.card, tint: Color? = nil) -> some View {
        modifier(TahoeCardModifier(cornerRadius: cornerRadius, tint: tint))
    }

    /// Raised surface for headers and action bars that sit above content.
    func tahoeRaisedSurface(cornerRadius: CGFloat = TahoeMetrics.card) -> some View {
        modifier(TahoeRaisedSurfaceModifier(cornerRadius: cornerRadius))
    }

    /// Tahoe's glass button treatment where available, bordered elsewhere.
    ///
    /// The tint is cleared deliberately. SwiftUI fills a `.glass` button with
    /// whatever tint is in the environment, and SwiftMiner sets one app-wide for
    /// the theme — which turned every ordinary action into a solid accent capsule
    /// indistinguishable from `.glassProminent`. A Pending row carries three of
    /// them side by side, so the row read as three default buttons competing.
    /// Tahoe's own buttons are clear glass with a plain label; a filled one means
    /// "this is the default action", which none of these are.
    @ViewBuilder
    func tahoeButtonStyle() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glass).tint(nil)
        } else {
            buttonStyle(.bordered).tint(nil)
        }
    }
}

/// A titled content group: sentence-case header above a rounded grouped box,
/// matching Tahoe's System Settings idiom. Replaces the older pattern of an
/// all-caps micro-label living inside the box above a divider.
struct TahoeSection<Accessory: View, Content: View>: View {
    private let title: String
    private let count: Int?
    private let cornerRadius: CGFloat
    private let tint: Color?
    private let accessory: Accessory
    private let content: Content

    init(
        _ title: String,
        count: Int? = nil,
        cornerRadius: CGFloat = TahoeMetrics.card,
        tint: Color? = nil,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.count = count
        self.cornerRadius = cornerRadius
        self.tint = tint
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: TahoeMetrics.headerGap) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.subheadline.weight(.semibold))

                if let count {
                    Text(count.formatted())
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                accessory
            }
            .padding(.horizontal, 2)

            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .tahoeCard(cornerRadius: cornerRadius, tint: tint)
        }
    }
}

extension TahoeSection where Accessory == EmptyView {
    init(
        _ title: String,
        count: Int? = nil,
        cornerRadius: CGFloat = TahoeMetrics.card,
        tint: Color? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            title,
            count: count,
            cornerRadius: cornerRadius,
            tint: tint,
            accessory: { EmptyView() },
            content: content
        )
    }
}

/// Hairline between rows inside a `tahoeCard`, inset so it never collides with
/// the card's rounded corners.
struct TahoeRowDivider: View {
    var leadingInset: CGFloat = 12

    var body: some View {
        Divider()
            .padding(.leading, leadingInset)
            .padding(.trailing, 12)
    }
}

struct MaterialEmptyStatePanel<Actions: View>: View {
    let title: String
    let systemImage: String
    let description: String
    let actions: Actions

    init(
        _ title: String,
        systemImage: String,
        description: String,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 42, weight: .medium))
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                Text(title)
                    .font(.headline)

                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            actions
        }
        .frame(maxWidth: 420)
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .glassCard()
    }
}

extension MaterialEmptyStatePanel where Actions == EmptyView {
    init(_ title: String, systemImage: String, description: String) {
        self.init(title, systemImage: systemImage, description: description) {
            EmptyView()
        }
    }
}

struct GlassSelectionItem<ID: Hashable>: Identifiable {
    let id: ID
    let title: String
    let systemImage: String
}

private struct GlassSelectionFramePreferenceKey: PreferenceKey {
    nonisolated(unsafe) static let defaultValue: [AnyHashable: CGRect] = [:]

    static func reduce(value: inout [AnyHashable: CGRect], nextValue: () -> [AnyHashable: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct GlassSelectionControl<ID: Hashable, ItemContent: View>: View {
    let items: [GlassSelectionItem<ID>]
    @Binding var selection: ID
    var axis: Axis
    var itemSpacing: CGFloat
    var padding: CGFloat
    var contentInsets: EdgeInsets
    var selectedCornerRadius: CGFloat
    var fillsAvailableSpace: Bool
    var showsContainer: Bool
    var contentAlignment: Alignment
    @ViewBuilder var itemContent: (GlassSelectionItem<ID>, Bool) -> ItemContent

    @Namespace private var selectionNamespace
    @State private var itemFrames: [AnyHashable: CGRect] = [:]
    @ScaledMetric private var accessibilityScale: CGFloat = 1

    private let coordinateSpaceName = "GlassSelectionControlSpace"

    init(
        items: [GlassSelectionItem<ID>],
        selection: Binding<ID>,
        axis: Axis = .horizontal,
        itemSpacing: CGFloat = 10,
        padding: CGFloat = 6,
        contentInsets: EdgeInsets = EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14),
        selectedCornerRadius: CGFloat = GlassRadius.subtle,
        fillsAvailableSpace: Bool = true,
        showsContainer: Bool = true,
        contentAlignment: Alignment = .leading,
        @ViewBuilder itemContent: @escaping (GlassSelectionItem<ID>, Bool) -> ItemContent
    ) {
        self.items = items
        self._selection = selection
        self.axis = axis
        self.itemSpacing = itemSpacing
        self.padding = padding
        self.contentInsets = contentInsets
        self.selectedCornerRadius = selectedCornerRadius
        self.fillsAvailableSpace = fillsAvailableSpace
        self.showsContainer = showsContainer
        self.contentAlignment = contentAlignment
        self.itemContent = itemContent
    }

    var body: some View {
        selectionBody
            .coordinateSpace(name: coordinateSpaceName)
            .onPreferenceChange(GlassSelectionFramePreferenceKey.self) { frames in
                itemFrames = frames
            }
            .contentShape(Rectangle())
            .simultaneousGesture(dragSelectionGesture)
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: selection)
    }

    @ViewBuilder
    private var stack: some View {
        switch axis {
        case .horizontal:
            HStack(spacing: itemSpacing) {
                itemButtons
            }
        case .vertical:
            VStack(spacing: itemSpacing) {
                itemButtons
            }
        }
    }

    @ViewBuilder
    private var selectionBody: some View {
        if showsContainer {
            stack
                .padding(padding)
                .glassControlSurface(cornerRadius: axis == .horizontal ? GlassRadius.small : GlassRadius.medium)
        } else {
            stack
                .padding(padding)
        }
    }

    private var itemButtons: some View {
        ForEach(items) { item in
            let isSelected = selection == item.id
            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                    selection = item.id
                }
            } label: {
                itemContent(item, isSelected)
                    .frame(maxWidth: fillsAvailableSpace ? .infinity : nil, alignment: contentAlignment)
                    .padding(contentInsets)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: selectedCornerRadius, style: .continuous)
                                .fill(.ultraThinMaterial)
                                .matchedGeometryEffect(id: "selection", in: selectionNamespace)
                        }
                    }
            }
            .buttonStyle(.plain)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: GlassSelectionFramePreferenceKey.self,
                        value: [AnyHashable(item.id): proxy.frame(in: .named(coordinateSpaceName))]
                    )
                }
            }
        }
    }

    private var dragSelectionGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named(coordinateSpaceName))
            .onChanged { value in
                guard let target = nearestItem(to: value.location) else { return }
                guard target != selection else { return }
                withAnimation(.spring(response: 0.28, dampingFraction: 0.84)) {
                    selection = target
                }
            }
    }

    private func nearestItem(to location: CGPoint) -> ID? {
        if let containing = items.first(where: { item in
            itemFrames[AnyHashable(item.id)]?.contains(location) == true
        }) {
            return containing.id
        }

        return items.min(by: { lhs, rhs in
            guard let lhsFrame = itemFrames[AnyHashable(lhs.id)],
                  let rhsFrame = itemFrames[AnyHashable(rhs.id)] else {
                return false
            }

            let lhsCenter = CGPoint(x: lhsFrame.midX, y: lhsFrame.midY)
            let rhsCenter = CGPoint(x: rhsFrame.midX, y: rhsFrame.midY)
            let lhsDistance = hypot(lhsCenter.x - location.x, lhsCenter.y - location.y)
            let rhsDistance = hypot(rhsCenter.x - location.x, rhsCenter.y - location.y)
            return lhsDistance < rhsDistance
        })?.id
    }
}
