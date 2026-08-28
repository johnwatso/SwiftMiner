import AppKit
import SwiftUI

/// Keeps SF Symbols visible when a newer symbol name is used on an older macOS release.
/// Call this at the point where a symbol name is selected so every downstream renderer,
/// including `Label`, receives a name that exists on the current system.
enum SystemSymbolCompatibility {
    static let macOS14SimulationEnvironmentKey = "SWIFTMINER_SIMULATE_MACOS14_SYMBOLS"

    private static let fallbackNames: [String: String] = [
        "arrow.trianglehead.2.clockwise": "arrow.triangle.2.circlepath",
        "checkmark.arrow.trianglehead.counterclockwise": "checkmark.circle",
        "checkmark.circle.trianglebadge.exclamationmark.fill": "exclamationmark.circle.fill",
        "exclamationmark.arrow.trianglehead.counterclockwise.rotate.90": "exclamationmark.arrow.triangle.2.circlepath",
        "gift.slash": "gift.fill",
        "list.bullet.rectangle.stack": "list.bullet.rectangle",
        "list.dash.header.rectangle.fill": "rectangle.grid.2x2.fill",
        "person.badge.shield.check.fill": "person.badge.shield.checkmark.fill",
        "personalhotspot.slash": "personalhotspot",
        "photo.badge.minus": "photo",
        "waveform.path.ecg.text.clipboard.fill": "list.bullet.clipboard.fill",
    ]

    static func resolvedName(for preferredName: String) -> String {
        #if DEBUG
        let forceFallback = ProcessInfo.processInfo.environment[macOS14SimulationEnvironmentKey] == "1"
        #else
        let forceFallback = false
        #endif

        return resolvedName(for: preferredName, forceFallback: forceFallback) { name in
            NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
        }
    }

    static func resolvedName(
        for preferredName: String,
        forceFallback: Bool = false,
        symbolExists: (String) -> Bool
    ) -> String {
        if forceFallback, let fallbackName = fallbackNames[preferredName] {
            return symbolExists(fallbackName) ? fallbackName : "questionmark.circle"
        }

        guard !symbolExists(preferredName) else { return preferredName }

        let fallbackName = fallbackNames[preferredName] ?? "questionmark.circle"
        return symbolExists(fallbackName) ? fallbackName : "questionmark.circle"
    }
}

// MARK: - AnimatedStatusIcon

/// A centralized, HIG-aligned SF Symbol component that applies modern symbol animations.
/// Continuous looping animation only runs for active/live states ("Looking for Streams", "Mining Active", "Reconnecting").
/// Completed or static transitions ("Up to Date", "Claiming Rewards") animate once on transition and then remain static.
/// Automatically respects the system Reduced Motion setting.
struct AnimatedStatusIcon: View {
    let symbol: String
    var color: Color = .primary
    var size: CGFloat = 11
    var weight: Font.Weight = .semibold

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var triggerBounce = false

    var body: some View {
        let isAnimated = !reduceMotion
        
        Group {
            if symbol == "checkmark.circle.fill" {
                if isAnimated {
                    AnimatedCheckmarkCircleView(color: color, size: size)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: size, weight: weight))
                        .foregroundStyle(color)
                }
            } else if symbol == "calendar.badge.checkmark" {
                AnimatedCalendarCheckmarkIcon(
                    calendarColor: .red,
                    checkmarkColor: .green,
                    size: size,
                    weight: weight,
                    isAnimated: isAnimated
                )
            } else if symbol == "checkmark.circle.badge.questionmark.fill" {
                Image(systemName: symbol)
                    .font(.system(size: size, weight: weight))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.orange, .green)
            } else if symbol == "clock.badge.exclamationmark" {
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
            } else if symbol == "checkmark.seal.fill" {
                let base = Image(systemName: symbol)
                    .font(.system(size: size, weight: weight))
                    .foregroundStyle(color)
                
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
                    .foregroundStyle(color)
                
                if isAnimated {
                    // Mirror the macOS "searching for Wi-Fi" feel: the radio bands fill
                    // outward and reset (cumulative, not a bouncing single highlight), at a
                    // slow, deliberate pace rather than the default fast cycle.
                    base.symbolEffect(.variableColor.cumulative, options: .repeating.speed(0.4))
                } else {
                    base
                }
            } else if symbol == "dot.radiowaves.left.and.right" {
                let base = Image(systemName: symbol)
                    .font(.system(size: size, weight: weight))
                    .foregroundStyle(color)
                
                if isAnimated {
                    base.symbolEffect(.pulse, options: .repeating)
                } else {
                    base
                }
            } else if symbol == "bolt.fill" || symbol == "bolt.circle.fill" {
                let base = Image(systemName: symbol)
                    .font(.system(size: size, weight: weight))
                    .foregroundStyle(color)

                if isAnimated {
                    base.symbolEffect(.pulse, options: .repeating.speed(0.7))
                } else {
                    base
                }
            } else if symbol == "gift.fill" {
                let base = Image(systemName: symbol)
                    .font(.system(size: size, weight: weight))
                    .foregroundStyle(color)
                
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
                    ReconnectingSpinnerView(symbol: symbol, size: size, weight: weight, color: color)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: size, weight: weight))
                        .foregroundStyle(color)
                }
            } else {
                Image(systemName: symbol)
                    .font(.system(size: size, weight: weight))
                    .foregroundStyle(color)
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

    /// SF Symbols sit on a text baseline, so an `Image`'s layout frame is a line box,
    /// not a tight glyph box. The default `.center` anchor therefore spins the glyph
    /// about a point that is not its visual centre, and the whole icon orbits instead
    /// of turning in place. `arrow.clockwise` is the worst offender — its ink centre
    /// of mass sits low and left of the frame centre, giving ~2.9pt of orbit at size 44.
    ///
    /// These anchors are the alpha-weighted ink centroid of the rendered glyph, which
    /// is the point the eye reads as "the middle". Chosen to minimise worst-case orbit
    /// across the sizes and weights used in the app (9–48pt): both stay under 0.4pt.
    private var rotationAnchor: UnitPoint {
        symbol == "arrow.clockwise"
            ? UnitPoint(x: 0.464, y: 0.546)
            : UnitPoint(x: 0.488, y: 0.510)
    }

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(color)
            .rotationEffect(.degrees(angle), anchor: rotationAnchor)
            .onAppear {
                withAnimation(.linear(duration: 4.0).repeatForever(autoreverses: false)) {
                    angle = 360
                }
            }
    }
}
