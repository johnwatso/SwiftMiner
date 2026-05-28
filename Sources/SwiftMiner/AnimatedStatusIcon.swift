import SwiftUI

// MARK: - AnimatedStatusIcon

/// A centralized, HIG-aligned SF Symbol component that applies modern symbol animations.
/// Continuous looping animation only runs for active/live states ("Looking for Streams", "Mining Active", "Reconnecting").
/// Completed or static transitions ("Up to Date", "Claiming Rewards") animate once on transition and then remain static.
/// Automatically respects system reduced motion and the user's "Animated Status Icons" setting.
struct AnimatedStatusIcon: View {
    let symbol: String
    var color: Color = .primary
    var size: CGFloat = 11
    var weight: Font.Weight = .semibold

    @ObservedObject private var settings = Settings.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var triggerBounce = false

    var body: some View {
        Group {
            if !settings.animatedStatusIcons || reduceMotion {
                Image(systemName: symbol)
                    .font(.system(size: size, weight: weight))
                    .foregroundStyle(color)
            } else {
                animatedIcon
            }
        }
    }

    @ViewBuilder
    private var animatedIcon: some View {
        if symbol == "checkmark.circle.fill" {
            AnimatedCheckmarkCircleView(color: color, size: size)
        } else if symbol == "checkmark.circle.trianglebadge.exclamationmark.fill" {
            Image(systemName: symbol)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(color)
                .symbolEffect(.bounce.down, value: triggerBounce)
                .onAppear {
                    triggerBounce.toggle()
                }
                .onChange(of: symbol) { _, _ in
                    triggerBounce.toggle()
                }
        } else if symbol == "checkmark.seal.fill" {
            Image(systemName: symbol)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(color)
                .symbolEffect(.bounce.down, value: triggerBounce)
                .onAppear {
                    triggerBounce.toggle()
                }
                .onChange(of: symbol) { _, _ in
                    triggerBounce.toggle()
                }
        } else if symbol == "antenna.radiowaves.left.and.right" {
            // Animate only the waves iteratively (variableColor)
            Image(systemName: symbol)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(color)
                .symbolEffect(.variableColor.iterative.reversing, options: .repeating)
        } else if symbol == "dot.radiowaves.left.and.right" {
            // Gentle ambient pulse effect only
            Image(systemName: symbol)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(color)
                .symbolEffect(.pulse, options: .repeating)
        } else if symbol == "gift.fill" {
            // Gift icon with single bounce transition
            Image(systemName: symbol)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(color)
                .symbolEffect(.bounce.up, value: triggerBounce)
                .onAppear {
                    triggerBounce.toggle()
                }
                .onChange(of: symbol) { _, _ in
                    triggerBounce.toggle()
                }
        } else if symbol == "arrow.triangle.2.circlepath" || symbol == "arrow.clockwise" {
            // Slow, subtle rotational animation
            ReconnectingSpinnerView(symbol: symbol, size: size, weight: weight, color: color)
        } else {
            Image(systemName: symbol)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(color)
        }
    }
}

// MARK: - AnimatedCheckmarkCircleView

/// Draws a filled circle and animates the white tick path drawing in from left to right once per session, then stays fully drawn.
private struct AnimatedCheckmarkCircleView: View {
    let color: Color
    let size: CGFloat

    /// Tracks whether the draw-in has already played this session.
    /// `static` so it survives view re-creation (tab switches, navigation changes).
    private static var hasAnimated = false

    @State private var progress: CGFloat = Self.hasAnimated ? 1.0 : 0.0

    var body: some View {
        // SF Symbols include ~18% optical padding around the glyph, so a symbol rendered
        // at font size N appears smaller than an N×N frame. Scale down to match visually.
        let glyphSize = size * 0.82

        ZStack {
            // Static filled circle background
            Circle()
                .fill(color)
                .frame(width: glyphSize, height: glyphSize)

            // White tick layer — immediately full if already animated this session
            CheckmarkShape()
                .trim(from: 0, to: progress)
                .stroke(
                    Color.white,
                    style: StrokeStyle(lineWidth: glyphSize * 0.14, lineCap: .round, lineJoin: .round)
                )
                .frame(width: glyphSize * 0.55, height: glyphSize * 0.45)
                .offset(y: glyphSize * 0.03)
        }
        .frame(width: size, height: size)
        .onAppear {
            guard !Self.hasAnimated else { return }
            Self.hasAnimated = true
            withAnimation(.easeOut(duration: 0.5)) {
                progress = 1.0
            }
        }
    }
}

// MARK: - CheckmarkShape

/// A tick-mark path that fits inside a normalised [0,1]×[0,1] rect.
/// The path goes: left mid-bottom → centre bottom → top-right,
/// matching the proportions of a standard Apple checkmark.
private struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Start at the bottom-left of the tick
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        // Vertex at centre-bottom
        path.addLine(to: CGPoint(x: rect.width * 0.38, y: rect.maxY))
        // Up to the top-right
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

// MARK: - ReconnectingSpinnerView

private struct ReconnectingSpinnerView: View {
    let symbol: String
    let size: CGFloat
    let weight: Font.Weight
    let color: Color
    @State private var angle: Double = 0

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(color)
            .rotationEffect(.degrees(angle))
            .onAppear {
                withAnimation(.linear(duration: 4.0).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            }
    }
}
