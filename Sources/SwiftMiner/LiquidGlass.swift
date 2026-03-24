import AppKit
import SwiftUI

struct LiquidGlassBackdrop: View {
    @State private var animationPhase = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            VisualEffectMaterialView(material: .windowBackground, blendingMode: .behindWindow)

            if #available(macOS 15, *) {
                MeshGradient(
                    width: 3,
                    height: 3,
                    points: [
                        [0.0, 0.0], [0.5, 0.0], [1.0, 0.0],
                        [0.0, 0.5], animationPhase ? [0.6, 0.4] : [0.4, 0.6], [1.0, 0.5],
                        [0.0, 1.0], [0.5, 1.0], [1.0, 1.0]
                    ],
                    colors: [
                        .white.opacity(0.05), .clear,              .white.opacity(0.03),
                        .clear, animationPhase ? Color.blue.opacity(0.10) : Color.cyan.opacity(0.07), .blue.opacity(0.03),
                        .clear,              .purple.opacity(0.04), .clear
                    ]
                )
                .ignoresSafeArea()
                .onAppear {
                    if !reduceMotion {
                        withAnimation(.easeInOut(duration: 8).repeatForever(autoreverses: true)) {
                            animationPhase.toggle()
                        }
                    }
                }
            } else {
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.08),
                        Color.white.opacity(0.02),
                        Color.blue.opacity(0.04)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )

                Circle()
                    .fill(Color.white.opacity(0.16))
                    .frame(width: 360, height: 360)
                    .blur(radius: 90)
                    .offset(x: -220, y: -180)

                Circle()
                    .fill(Color.cyan.opacity(0.10))
                    .frame(width: 420, height: 420)
                    .blur(radius: 120)
                    .offset(x: 260, y: 220)
            }
        }
        .ignoresSafeArea()
    }
}

struct SidebarMaterialBackground: View {
    var body: some View {
        VisualEffectMaterialView(material: .sidebar)
            .overlay {
                // Keep sidebar treatment flat and column-like (Apple Music style),
                // instead of a rounded floating glass slab.
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.10),
                        Color.clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(Color.black.opacity(0.10))
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

private struct GlassSurfaceModifier: ViewModifier {
    let material: AnyShapeStyle
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
                if #available(macOS 26, *) {
                    shape
                        .fill(.clear)
                        .glassEffect(.regular.interactive())
                } else {
                    shape
                        .fill(material)
                }
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
            .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius, y: shadowY)
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
                material: AnyShapeStyle(.regularMaterial),
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
                material: AnyShapeStyle(.thinMaterial),
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
                material: AnyShapeStyle(.ultraThinMaterial),
                cornerRadius: cornerRadius,
                shadowOpacity: 0,
                shadowRadius: 0,
                shadowY: 0
            )
        )
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
        .glassContentSurface(cornerRadius: GlassRadius.large)
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
                    .frame(maxWidth: fillsAvailableSpace ? .infinity : nil, alignment: .leading)
                    .padding(contentInsets)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: selectedCornerRadius, style: .continuous)
                                .fill(.ultraThinMaterial)
                                .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
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
