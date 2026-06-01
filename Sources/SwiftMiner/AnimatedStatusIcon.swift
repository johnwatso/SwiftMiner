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

    /// Resolves to `.secondary` when the user has turned off coloured icons,
    /// stripping all accent tints so everything renders in a neutral grey/black.
    private var effectiveColor: Color {
        settings.coloredStatusIcons ? color : .secondary
    }

    var body: some View {
        let isAnimated = settings.animatedStatusIcons && !reduceMotion
        
        Group {
            if symbol == "checkmark.circle.fill" {
                if isAnimated {
                    AnimatedCheckmarkCircleView(color: effectiveColor, size: size)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: size, weight: weight))
                        .foregroundStyle(effectiveColor)
                }
            } else if symbol == "calendar.badge.checkmark" {
                AnimatedCalendarCheckmarkIcon(
                    calendarColor: settings.coloredStatusIcons ? .red : effectiveColor,
                    checkmarkColor: settings.coloredStatusIcons ? .green : effectiveColor,
                    size: size,
                    weight: weight,
                    isAnimated: isAnimated
                )
            } else if symbol == "clock.badge.exclamationmark" {
                if settings.coloredStatusIcons {
                    let base = Image(systemName: symbol)
                        .font(.system(size: size, weight: weight))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.red, Color(nsColor: .labelColor))
                    
                    if isAnimated {
                        base
                            .symbolEffect(.bounce.down, value: triggerBounce)
                            .onAppear { triggerBounce.toggle() }
                            .onChange(of: symbol) { _, _ in triggerBounce.toggle() }
                    } else {
                        base
                    }
                } else {
                    let base = Image(systemName: symbol)
                        .font(.system(size: size, weight: weight))
                        .foregroundStyle(effectiveColor)
                    
                    if isAnimated {
                        base
                            .symbolEffect(.bounce.down, value: triggerBounce)
                            .onAppear { triggerBounce.toggle() }
                            .onChange(of: symbol) { _, _ in triggerBounce.toggle() }
                    } else {
                        base
                    }
                }
            } else if symbol == "checkmark.seal.fill" {
                let base = Image(systemName: symbol)
                    .font(.system(size: size, weight: weight))
                    .foregroundStyle(effectiveColor)
                
                if isAnimated {
                    base
                        .symbolEffect(.bounce.down, value: triggerBounce)
                        .onAppear { triggerBounce.toggle() }
                        .onChange(of: symbol) { _, _ in triggerBounce.toggle() }
                } else {
                    base
                }
            } else if symbol == "antenna.radiowaves.left.and.right" {
                let base = Image(systemName: symbol)
                    .font(.system(size: size, weight: weight))
                    .foregroundStyle(effectiveColor)
                
                if isAnimated {
                    base.symbolEffect(.variableColor.iterative.reversing, options: .repeating)
                } else {
                    base
                }
            } else if symbol == "dot.radiowaves.left.and.right" {
                let base = Image(systemName: symbol)
                    .font(.system(size: size, weight: weight))
                    .foregroundStyle(effectiveColor)
                
                if isAnimated {
                    base.symbolEffect(.pulse, options: .repeating)
                } else {
                    base
                }
            } else if symbol == "gift.fill" {
                let base = Image(systemName: symbol)
                    .font(.system(size: size, weight: weight))
                    .foregroundStyle(effectiveColor)
                
                if isAnimated {
                    base
                        .symbolEffect(.bounce.up, value: triggerBounce)
                        .onAppear { triggerBounce.toggle() }
                        .onChange(of: symbol) { _, _ in triggerBounce.toggle() }
                } else {
                    base
                }
            } else if symbol == "arrow.triangle.2.circlepath" || symbol == "arrow.clockwise" {
                if isAnimated {
                    ReconnectingSpinnerView(symbol: symbol, size: size, weight: weight, color: effectiveColor)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: size, weight: weight))
                        .foregroundStyle(effectiveColor)
                }
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size, weight: weight))
                    .foregroundStyle(effectiveColor)
            }
        }
    }
}

// MARK: - AnimatedCalendarCheckmarkIcon

private struct AnimatedCalendarCheckmarkIcon: View {
    let calendarColor: Color
    let checkmarkColor: Color
    let size: CGFloat
    let weight: Font.Weight
    let isAnimated: Bool

    @State private var badgeScale: CGFloat
    @State private var checkmarkProgress: CGFloat
    @State private var didAnimate = false

    init(calendarColor: Color, checkmarkColor: Color, size: CGFloat, weight: Font.Weight, isAnimated: Bool) {
        self.calendarColor = calendarColor
        self.checkmarkColor = checkmarkColor
        self.size = size
        self.weight = weight
        self.isAnimated = isAnimated
        _badgeScale = State(initialValue: isAnimated ? 0 : 1)
        _checkmarkProgress = State(initialValue: isAnimated ? 0 : 1)
    }

    var body: some View {
        let badgeSize = size * 0.42
        let checkSize = badgeSize * 0.52

        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "calendar")
                .font(.system(size: size, weight: weight))
                .foregroundStyle(calendarColor)

            ZStack {
                Circle()
                    .fill(checkmarkColor)

                CheckmarkShape()
                    .trim(from: 0, to: checkmarkProgress)
                    .stroke(
                        Color.white,
                        style: StrokeStyle(lineWidth: max(badgeSize * 0.12, 1.1), lineCap: .round, lineJoin: .round)
                    )
                    .frame(width: checkSize, height: checkSize * 0.78)
                    .offset(y: badgeSize * 0.03)
            }
            .frame(width: badgeSize, height: badgeSize)
            .scaleEffect(badgeScale)
            .offset(x: size * 0.06, y: size * 0.02)
        }
        .frame(width: size, height: size)
        .onAppear {
            guard isAnimated, !didAnimate else {
                badgeScale = 1
                checkmarkProgress = 1
                return
            }

            didAnimate = true
            withAnimation(.spring(response: 0.24, dampingFraction: 0.78).delay(0.06)) {
                badgeScale = 1
            }
            withAnimation(.easeOut(duration: 0.28).delay(0.16)) {
                checkmarkProgress = 1
            }
        }
        .onChange(of: isAnimated) { _, newValue in
            if !newValue {
                badgeScale = 1
                checkmarkProgress = 1
            }
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
