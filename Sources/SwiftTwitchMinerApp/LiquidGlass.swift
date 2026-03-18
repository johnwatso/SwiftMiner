import AppKit
import SwiftUI

struct LiquidGlassBackdrop: View {
    var body: some View {
        ZStack {
            VisualEffectMaterialView(material: .windowBackground, blendingMode: .behindWindow)

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
        .ignoresSafeArea()
    }
}

struct SidebarMaterialBackground: View {
    var body: some View {
        VisualEffectMaterialView(material: .sidebar)
            .overlay {
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.16),
                        Color.clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
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
                shape
                    .fill(material)
            }
            .overlay {
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
            .clipShape(shape)
            .shadow(color: .black.opacity(shadowOpacity), radius: shadowRadius, y: shadowY)
    }
}

extension View {
    func glassContentSurface(cornerRadius: CGFloat = 28) -> some View {
        modifier(
            GlassSurfaceModifier(
                material: AnyShapeStyle(.regularMaterial),
                cornerRadius: cornerRadius,
                shadowOpacity: 0.10,
                shadowRadius: 24,
                shadowY: 10
            )
        )
    }

    func glassPanel(cornerRadius: CGFloat = 22) -> some View {
        modifier(
            GlassSurfaceModifier(
                material: AnyShapeStyle(.thinMaterial),
                cornerRadius: cornerRadius,
                shadowOpacity: 0.09,
                shadowRadius: 18,
                shadowY: 7
            )
        )
    }

    func glassControlSurface(cornerRadius: CGFloat = 16) -> some View {
        modifier(
            GlassSurfaceModifier(
                material: AnyShapeStyle(.ultraThinMaterial),
                cornerRadius: cornerRadius,
                shadowOpacity: 0.06,
                shadowRadius: 10,
                shadowY: 4
            )
        )
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
        .glassContentSurface(cornerRadius: 30)
    }
}

extension MaterialEmptyStatePanel where Actions == EmptyView {
    init(_ title: String, systemImage: String, description: String) {
        self.init(title, systemImage: systemImage, description: description) {
            EmptyView()
        }
    }
}
