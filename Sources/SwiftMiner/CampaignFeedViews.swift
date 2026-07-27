// Campaign feed cards, rails, and ambient artwork used by OverviewView.
import SwiftUI
import SwiftMinerCore
import AppKit

enum CampaignFeedSection: String {
    case prioritised
    case active
    case recent
}

enum CampaignRailLayout {
    case horizontal
    case staggered
}

enum CampaignCardProminence {
    case feature
    case standard
    case compact

    var size: CGSize {
        CGSize(width: 186, height: 286)
    }

    var artworkHeight: CGFloat {
        202
    }

    var spacing: CGFloat {
        switch self {
        case .feature:
            return 18
        case .standard:
            return 18
        case .compact:
            return 16
        }
    }
}

enum CampaignVisualState {
    case watching
    case inProgress
    case claimable
    case claimed
    case idle

    var accent: Color {
        switch self {
        case .watching:
            return .green
        case .inProgress:
            return .blue
        case .claimable:
            return .cyan
        case .claimed:
            return .green
        case .idle:
            return .secondary
        }
    }

    var label: String {
        switch self {
        case .watching:
            return "Watching"
        case .inProgress:
            return "In Progress"
        case .claimable:
            return "Claimable"
        case .claimed:
            return "Claimed"
        case .idle:
            return "Idle — No eligible campaigns"
        }
    }

    var symbol: String {
        switch self {
        case .watching:
            return "play.fill"
        case .inProgress:
            return "chart.line.uptrend.xyaxis"
        case .claimable:
            return "sparkles"
        case .claimed:
            return "checkmark.circle.fill"
        case .idle:
            return "circle.fill"
        }
    }
}

struct CampaignWatcher: Identifiable {
    let id: String
    let username: String
    let initials: String
}


struct CampaignRailItem: Identifiable {
    let id: String
    let section: CampaignFeedSection
    let gameName: String
    let campaignName: String
    let progressText: String
    let progressPercent: Double
    let artworkURL: URL?
    let tint: Color
    let hasOnlyBadgesOrEmotes: Bool
    let visualState: CampaignVisualState
    let watchers: [CampaignWatcher]
    let isDimmed: Bool
    let isPlaceholder: Bool
    let showsLiveMotion: Bool
    var usesCustomArtwork = false
    var game: Game? = nil
}


struct CampaignFeedCard: View {
    let item: CampaignRailItem
    let prominence: CampaignCardProminence
    let onSetSteamId: (String) -> Void
    let onUploadCustomArtwork: (Game) -> Void
    @State private var isHovering = false

    private var settings: Settings {
        Settings.shared
    }

    private var usesStandbyMotionStyle: Bool {
        item.isPlaceholder && item.showsLiveMotion
    }

    private var artworkDimmingStops: [Color] {
        if item.usesCustomArtwork {
            return [
                .clear,
                Color.black.opacity(0),
                Color.black.opacity(0.06),
                Color.black.opacity(item.section == .recent ? 0.24 : 0.30)
            ]
        }

        return [
            .clear,
            Color.black.opacity(0.08),
            Color.black.opacity(0.36),
            Color.black.opacity(item.section == .recent ? 0.56 : 0.66)
        ]
    }

    private var cardOpacity: Double {
        if item.usesCustomArtwork {
            return item.section == .recent ? 0.94 : 1
        }
        return item.section == .recent ? 0.88 : (item.isDimmed ? 0.7 : 1)
    }

    private var cardSaturation: Double {
        item.usesCustomArtwork ? 1 : (item.isDimmed ? 0.82 : 1)
    }

    private var currentPreference: GamePreference? {
        guard let game = item.game else { return nil }
        let matches = settings.gamePreferences.filter { preference in
            let idMatches = !game.id.isEmpty && preference.gameId == game.id
            let nameMatches = preference.gameName.localizedCaseInsensitiveCompare(game.name) == .orderedSame
                || comparableGameName(preference.gameName) == comparableGameName(game.name)
            return idMatches || nameMatches
        }
        return matches.first(where: { $0.customArtworkURL != nil }) ?? matches.first
    }

    private func comparableGameName(_ value: String) -> String {
        value
            .lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    private var hasCustomArtwork: Bool {
        currentPreference?.customArtworkURL != nil
    }

    private var canRemoveFromPrioritised: Bool {
        item.section == .prioritised && currentPreference?.state == .preferred
    }

    private var showsCampaignSubtitle: Bool {
        item.section == .active && !item.campaignName.isEmpty
    }

    private var accessibilityTitle: String {
        item.gameName
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CampaignArtworkBackground(
                url: item.artworkURL,
                title: item.gameName,
                tint: item.tint,
                useGhostArtworkPlaceholder: usesStandbyMotionStyle
            )
            .frame(width: prominence.size.width, height: prominence.size.height)
            .clipped()

            if item.showsLiveMotion {
                if usesStandbyMotionStyle {
                    CampaignStandbyMotionOverlay(tint: item.tint)
                        .opacity(0.68)
                } else {
                    CampaignCardMotionOverlay(tint: item.tint)
                        .opacity(0.5)
                }
            }

            LinearGradient(
                colors: artworkDimmingStops,
                startPoint: .top,
                endPoint: .bottom
            )

            Rectangle()
                .fill(
                    usesStandbyMotionStyle
                        ? AnyShapeStyle(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0),
                                    Color.white.opacity(0.012),
                                    Color.black.opacity(0.08)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        : AnyShapeStyle(
                            LinearGradient(
                                colors: [
                                    item.tint.opacity(0),
                                    item.tint.opacity(item.usesCustomArtwork ? 0 : 0.08),
                                    item.tint.opacity(item.usesCustomArtwork ? 0 : 0.18)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                )
                .mask(alignment: .bottom) {
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.24), .black],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }

            VStack(alignment: .leading, spacing: 4) {
                Text(item.gameName)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(alignment: .bottomLeading) {
                // Material slab treatment for all cards
                if usesStandbyMotionStyle {
                    Rectangle()
                        .fill(.ultraThinMaterial.opacity(0.6))
                        .overlay(alignment: .top) {
                            Color.white.opacity(0.1)
                                .frame(height: 1)
                        }
                } else {
                    Rectangle()
                        .fill(.thinMaterial.opacity(0.35))
                        .overlay(alignment: .top) {
                            Color.white.opacity(0.08)
                                .frame(height: 1)
                        }
                }
            }
            .zIndex(2)
        }
        .frame(width: prominence.size.width, height: prominence.size.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: GlassRadius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: GlassRadius.medium, style: .continuous)
                .strokeBorder(.white.opacity(item.visualState == .watching ? 0.22 : 0.12), lineWidth: 1)
        }
        .opacity(cardOpacity)
        .saturation(cardSaturation)
        .brightness(item.visualState == .watching ? 0.04 : (isHovering ? 0.015 : 0))
        .scaleEffect(isHovering ? 1.03 : 1)
        .shadow(color: .black.opacity(item.visualState == .watching ? 0.16 : (isHovering ? 0.10 : 0.05)), 
                radius: item.visualState == .watching ? 10 : (isHovering ? 8 : 3), 
                y: item.visualState == .watching ? 5 : (isHovering ? 4 : 1))
        .animation(.easeInOut(duration: 0.2), value: isHovering)
        .animation(.easeInOut(duration: 0.7), value: usesStandbyMotionStyle)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(item.campaignName.isEmpty ? item.progressText : item.campaignName)
        .onHover { hovering in
            isHovering = hovering
        }
        .contextMenu {
            if let game = item.game, !item.isPlaceholder {
                Button {
                    Settings.shared.setGamePreference(game, state: .preferred)
                } label: {
                    GameActionMenuLabel(
                        title: "Prioritise Game",
                        systemImage: "star"
                    )
                }

                Button {
                    Settings.shared.setGamePreference(game, state: .excluded)
                } label: {
                    GameActionMenuLabel(
                        title: "Exclude Game",
                        systemImage: "minus.circle"
                    )
                }

                Divider()

                if canRemoveFromPrioritised, let preference = currentPreference {
                    Button(role: .destructive) {
                        Settings.shared.removeGamePreference(preference)
                    } label: {
                        GameActionMenuLabel(
                            title: "Remove Game",
                            subtitle: "Remove this game from the prioritised list.",
                            systemImage: "trash"
                        )
                    }
                }

                Button {
                    onUploadCustomArtwork(game)
                } label: {
                    GameActionMenuLabel(
                        title: "Upload Custom Artwork",
                        subtitle: "Cache a local image in Application Support for this game.",
                        systemImage: "square.and.arrow.up"
                    )
                }

                if hasCustomArtwork {
                    Button(role: .destructive) {
                        Settings.shared.removeCustomArtwork(for: game)
                    } label: {
                        GameActionMenuLabel(
                            title: "Remove Custom Artwork",
                            subtitle: "Return to Steam or Twitch artwork.",
                            systemImage: "photo.badge.minus"
                        )
                    }
                }

                Divider()

                if SteamArtworkService.supportsSteamArtwork(forGameName: game.name, gameId: game.id) {
                    Button {
                        onSetSteamId(game.name)
                    } label: {
                        GameActionMenuLabel(
                            title: "Set Steam ID",
                            subtitle: "Set a Steam ID to enable high-resolution artwork for this game.",
                            systemImage: "photo.artframe"
                        )
                    }
                }
            }
        }
    }
}

struct ReorderableCampaignFeedCard: View {
    let item: CampaignRailItem
    let index: Int
    let itemCount: Int
    let prominence: CampaignCardProminence
    let activeDragIndex: Int?
    let projectedDropIndex: Int?
    let activeDragProgress: CGFloat
    let onSetSteamId: (String) -> Void
    let onUploadCustomArtwork: (Game) -> Void
    let onDragProjectionChanged: (Int, Int, CGFloat) -> Void
    let onDragEnded: () -> Void
    let onMoveItem: ((CampaignRailItem, Int) -> Void)?
    @State private var dragOffset: CGFloat = 0

    private var travelDistance: CGFloat {
        prominence.size.width + prominence.spacing
    }

    private var reorderStep: CGFloat {
        max(travelDistance * 0.62, 1)
    }

    private var dragProgress: CGFloat {
        dragOffset / travelDistance
    }

    private var isActivelyDragged: Bool {
        activeDragIndex == index
    }

    private var neighborOffset: CGFloat {
        guard let activeDragIndex,
              let projectedDropIndex,
              activeDragIndex != index,
              projectedDropIndex != activeDragIndex else {
            return 0
        }

        let progress = activeDragProgress
        if progress > 0,
           index > activeDragIndex {
            let distanceFromActive = CGFloat(index - activeDragIndex)
            let influence = smoothstep(min(max(progress - (distanceFromActive - 1), 0), 1))
            return -travelDistance * influence
        }

        if progress < 0,
           index < activeDragIndex {
            let distanceFromActive = CGFloat(activeDragIndex - index)
            let influence = smoothstep(min(max(abs(progress) - (distanceFromActive - 1), 0), 1))
            return travelDistance * influence
        }

        return 0
    }

    private var liftAmount: CGFloat {
        min(abs(dragProgress), 1)
    }

    private func smoothstep(_ value: CGFloat) -> CGFloat {
        value * value * (3 - (2 * value))
    }

    private var card: some View {
        CampaignFeedCard(
            item: item,
            prominence: prominence,
            onSetSteamId: onSetSteamId,
            onUploadCustomArtwork: onUploadCustomArtwork
        )
    }

    var body: some View {
        if let onMoveItem {
            card
                .offset(x: dragOffset + neighborOffset, y: isActivelyDragged ? -6 * liftAmount : 0)
                .scaleEffect(isActivelyDragged ? 1 + (0.018 * liftAmount) : 1)
                .rotationEffect(.degrees(isActivelyDragged ? Double(dragProgress) * 0.35 : 0))
                .shadow(
                    color: .black.opacity(isActivelyDragged ? 0.14 : 0),
                    radius: isActivelyDragged ? 12 : 0,
                    y: isActivelyDragged ? 7 : 0
                )
                .zIndex(isActivelyDragged ? 1000 : Double(itemCount - index))
                .gesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { value in
                            var transaction = Transaction()
                            transaction.disablesAnimations = true
                            withTransaction(transaction) {
                                dragOffset = value.translation.width
                            }

                            let rawProjectedIndex = index + Int((value.translation.width / reorderStep).rounded())
                            let projectedIndex = min(max(rawProjectedIndex, 0), itemCount - 1)
                            let progress = min(
                                max(value.translation.width / travelDistance, CGFloat(-index)),
                                CGFloat(itemCount - index - 1)
                            )
                            onDragProjectionChanged(index, projectedIndex, progress)
                        }
                        .onEnded { value in
                            let translation = abs(value.predictedEndTranslation.width) > abs(value.translation.width)
                                ? value.predictedEndTranslation.width
                                : value.translation.width
                            let rawDelta = translation / reorderStep
                            let delta = Int(rawDelta.rounded())
                            let targetIndex = min(max(index + delta, 0), itemCount - 1)

                            if targetIndex != index {
                                onMoveItem(item, targetIndex)
                            }

                            onDragEnded()
                            withAnimation(.interactiveSpring(response: 0.30, dampingFraction: 0.86, blendDuration: 0.08)) {
                                dragOffset = 0
                            }
                        }
                )
                .help("Drag left or right to reorder priority")
        } else {
            card
        }
    }
}

struct StaggeredCampaignRail: View {
    let items: [CampaignRailItem]
    let prominence: CampaignCardProminence
    let onSetSteamId: (String) -> Void
    let onUploadCustomArtwork: (Game) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: -prominence.size.width * 0.52) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    let clampedDepth = min(index, 4)
                    let scale = max(0.62, 1.0 - (Double(clampedDepth) * 0.12))
                    let opacity = max(0.52, 1.0 - (Double(clampedDepth) * 0.16))
                    let xOffset = CGFloat(clampedDepth) * 16
                    let yOffset = CGFloat(clampedDepth) * 4

                    CampaignFeedCard(
                        item: item,
                        prominence: prominence,
                        onSetSteamId: onSetSteamId,
                        onUploadCustomArtwork: onUploadCustomArtwork
                    )
                    .scaleEffect(scale)
                    .opacity(opacity)
                    .offset(x: xOffset, y: yOffset)
                    .zIndex(Double(120 - index))
                    .animation(.spring(response: 0.34, dampingFraction: 0.82), value: item.id)
                }
            }
            .padding(.horizontal, 2)
            .padding(.vertical, 10)
        }
        .scrollClipDisabled()
    }
}


struct CampaignCardMotionOverlay: View {
    let tint: Color
    // Pause the 24fps timeline whenever the app isn't the active app, so a
    // window left visible in the background stops driving the compositor.
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: controlActiveState == .inactive)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let x = 0.2 + 0.6 * ((sin(t * 0.45) + 1) / 2)
            let y = 0.28 + 0.28 * ((cos(t * 0.32) + 1) / 2)

            ZStack {
                RadialGradient(
                    colors: [tint.opacity(0.28), tint.opacity(0.10), .clear],
                    center: UnitPoint(x: x, y: y),
                    startRadius: 12,
                    endRadius: 180
                )

                LinearGradient(
                    colors: [.clear, tint.opacity(0.12), .clear],
                    startPoint: UnitPoint(x: x - 0.2, y: 0),
                    endPoint: UnitPoint(x: x + 0.2, y: 1)
                )
            }
        }
        .blendMode(.screen)
    }
}

struct CampaignStandbyMotionOverlay: View {
    let tint: Color
    // Pause the 24fps timeline whenever the app isn't the active app, so a
    // window left visible in the background stops driving the compositor.
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24, paused: controlActiveState == .inactive)) { context in
            let t = context.date.timeIntervalSinceReferenceDate

            // Hue cycling (full cycle every 30s)
            let hueBase = (t * 0.033).truncatingRemainder(dividingBy: 1.0)
            
            // Noticeable but smooth multi-sinusoidal drift
            let driftX = 70 * sin(t * 0.12) + 30 * cos(t * 0.18)
            let driftY = 30 * cos(t * 0.08) + 15 * sin(t * 0.15)
            
            // Dynamic colors cycling through hues - boosted saturation and brightness for "fun" look
            let color1 = Color(hue: hueBase, saturation: 0.85, brightness: 0.95)
            let color2 = Color(hue: (hueBase + 0.33).truncatingRemainder(dividingBy: 1.0), saturation: 0.80, brightness: 0.90)
            let color3 = Color(hue: (hueBase + 0.66).truncatingRemainder(dividingBy: 1.0), saturation: 0.75, brightness: 0.85)
            let highlight = Color(hue: (hueBase + 0.15).truncatingRemainder(dividingBy: 1.0), saturation: 0.50, brightness: 1.0)

            ZStack {
                // Background base - deeper version of the primary cycling color
                Color(hue: hueBase, saturation: 0.90, brightness: 0.30)

                // 3 Overlapping vibrant soft shapes cycling colors
                GhostArtworkShape(color: color1.opacity(0.7), size: CGSize(width: 280, height: 240))
                    .offset(
                        x: -80 + driftX * 0.7,
                        y: -40 + driftY * 0.9
                    )
                    .scaleEffect(1.0 + 0.06 * sin(t * 0.14))

                GhostArtworkShape(color: color2.opacity(0.6), size: CGSize(width: 220, height: 260))
                    .offset(
                        x: 20 + driftX,
                        y: 30 + driftY * 1.1
                    )
                    .scaleEffect(1.0 - 0.04 * cos(t * 0.11))

                GhostArtworkShape(color: color3.opacity(0.55), size: CGSize(width: 240, height: 200))
                    .offset(
                        x: 90 + driftX * 1.3,
                        y: 70 + driftY * 1.4
                    )
                    .scaleEffect(1.0 + 0.03 * sin(t * 0.09))
                
                // Extra warm "light leak" highlight
                GhostArtworkShape(color: highlight.opacity(0.22), size: CGSize(width: 200, height: 160))
                    .offset(
                        x: 40 + 50 * sin(t * 0.08),
                        y: -60 + 40 * cos(t * 0.06)
                    )
                    .blur(radius: 60)

                // Depth & Polish
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.18), // Glass top highlight
                        .clear,
                        Color.black.opacity(0.25)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .blendMode(.overlay)

                // Subtle vignette
                RadialGradient(
                    colors: [.clear, Color.black.opacity(0.15)],
                    center: .center,
                    startRadius: 90,
                    endRadius: 320
                )
                .blendMode(.multiply)
            }
        }
        .mask {
            RoundedRectangle(cornerRadius: GlassRadius.artwork, style: .continuous)
        }
        .blendMode(.screen)
    }
}

struct GhostArtworkShape: View {
    let color: Color
    let size: CGSize

    var body: some View {
        UnevenRoundedRectangle(
            topLeadingRadius: size.width * 0.34,
            bottomLeadingRadius: size.width * 0.18,
            bottomTrailingRadius: size.width * 0.32,
            topTrailingRadius: size.width * 0.12,
            style: .continuous
        )
        .fill(color)
        .frame(width: size.width, height: size.height)
        .rotationEffect(.degrees(-18))
        .blur(radius: 42)
        .blendMode(.screen)
    }
}

struct GameActionMenuLabel: View {
    let title: String
    var subtitle: String? = nil
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 14, alignment: .center)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)

                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

struct CampaignAmbientRailCard: View {
    let title: String
    let subtitle: String
    let prominence: CampaignCardProminence
    let tint: Color

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [tint.opacity(0.5), tint.opacity(0.14), Color.white.opacity(0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(tint.opacity(0.22))
                .frame(width: prominence.size.width * 0.55)
                .blur(radius: 24)
                .offset(x: prominence.size.width * 0.22, y: -prominence.size.height * 0.18)

            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(prominence == .feature ? .title3.weight(.semibold) : .headline.weight(.semibold))

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            .padding(prominence == .compact ? 16 : 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial.opacity(0.5), in: RoundedRectangle(cornerRadius: GlassRadius.medium, style: .continuous))
            .padding(14)
        }
        .frame(width: prominence.size.width, height: prominence.size.height)
        .background(.thinMaterial.opacity(0.5), in: RoundedRectangle(cornerRadius: GlassRadius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: GlassRadius.medium, style: .continuous)
                .strokeBorder(.white.opacity(0.14), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.06), radius: 4, y: 1)
    }
}

struct CampaignWatcherStack: View {
    let watchers: [CampaignWatcher]
    let size: CGFloat
    private var avatarDiameter: CGFloat { size * 0.88 }

    var body: some View {
        HStack(spacing: -avatarDiameter * 0.24) {
            ForEach(Array(watchers.prefix(3).enumerated()), id: \.element.id) { index, watcher in
                let swatch = AvatarColorPalette.swatch(for: watcher.id, username: watcher.username)

                Text(watcher.initials)
                    .font(.system(size: avatarDiameter * 0.34, weight: .semibold, design: .rounded))
                    .tracking(0.16)
                    .foregroundStyle(swatch.text)
                    .frame(width: avatarDiameter, height: avatarDiameter)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay {
                        Circle()
                            .fill(swatch.gradient)
                            .opacity(0.9)
                    }
                    .overlay {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.24), .clear],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .opacity(0.72)
                    }
                    .overlay {
                        Circle()
                            .strokeBorder(.white.opacity(0.68), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.045), radius: 2, y: 1)
                    .zIndex(Double(watchers.count - index))
            }

            if watchers.count > 3 {
                Text("+\(watchers.count - 3)")
                    .font(.system(size: avatarDiameter * 0.32, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary.opacity(0.75))
                    .frame(height: avatarDiameter)
                    .padding(.horizontal, avatarDiameter * 0.3)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay {
                        Capsule()
                            .strokeBorder(.white.opacity(0.56), lineWidth: 1)
                    }
                    .padding(.leading, 4)
            }
        }
    }
}

struct CampaignStateBadge: View {
    let state: CampaignVisualState
    var titleOverride: String? = nil
    var useDarkForeground = true

    var body: some View {
        Label(titleOverride ?? state.label, systemImage: state.symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(useDarkForeground ? state.accent : .white.opacity(0.95))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                useDarkForeground
                    ? AnyShapeStyle(.thinMaterial)
                    : AnyShapeStyle(.ultraThinMaterial),
                in: Capsule()
            )
    }
}

@MainActor
private final class CampaignArtworkImageCache {
    static let shared = CampaignArtworkImageCache()

    private let images = NSCache<NSURL, NSImage>()

    func image(for url: URL) -> NSImage? {
        images.object(forKey: url as NSURL)
    }

    func insert(_ image: NSImage, for url: URL) {
        images.setObject(image, forKey: url as NSURL)
    }
}

private struct LoadedCampaignArtwork {
    let url: URL
    let image: NSImage
}

struct CampaignArtworkBackground: View {
    let url: URL?
    let title: String
    let tint: Color
    var useGhostArtworkPlaceholder = false

    @State private var loadedArtwork: LoadedCampaignArtwork?
    @State private var failedArtworkURL: URL?

    private var resolvedArtworkURL: URL? {
        url?.overviewHighResolutionArtworkURL
    }

    private var displayedImage: NSImage? {
        guard let resolvedArtworkURL else { return nil }
        if loadedArtwork?.url == resolvedArtworkURL {
            return loadedArtwork?.image
        }
        return CampaignArtworkImageCache.shared.image(for: resolvedArtworkURL)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                placeholder

                if let displayedImage {
                    Image(nsImage: displayedImage)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
                } else if resolvedArtworkURL == nil || failedArtworkURL == resolvedArtworkURL {
                    initialsOverlay
                } else {
                    Color.clear
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .clipped()
        }
        .task(id: resolvedArtworkURL) {
            await loadArtwork(from: resolvedArtworkURL)
        }
    }

    private func loadArtwork(from url: URL?) async {
        guard let url else {
            loadedArtwork = nil
            failedArtworkURL = nil
            return
        }

        if let cached = CampaignArtworkImageCache.shared.image(for: url) {
            loadedArtwork = LoadedCampaignArtwork(url: url, image: cached)
            failedArtworkURL = nil
            return
        }

        let image: NSImage?
        if url.isFileURL {
            image = NSImage(contentsOf: url)
        } else {
            image = await fetchRemoteArtwork(from: url)
        }

        guard !Task.isCancelled else { return }
        guard let image else {
            failedArtworkURL = url
            return
        }

        CampaignArtworkImageCache.shared.insert(image, for: url)
        loadedArtwork = LoadedCampaignArtwork(url: url, image: image)
        failedArtworkURL = nil
    }

    private func fetchRemoteArtwork(from url: URL) async -> NSImage? {
        var request = URLRequest(url: url)
        request.cachePolicy = .returnCacheDataElseLoad

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            return nil
        }
        return NSImage(data: data)
    }

    private var initialsOverlay: some View {
        Text(initials(from: title))
            .font(.system(size: 44, weight: .bold, design: .rounded))
            .foregroundStyle(.white.opacity(0.18))
            .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
    }

    private func initials(from name: String) -> String {
        let parts = name.split(separator: " ")
        if parts.count >= 2 {
            return String(parts[0].prefix(1) + parts[1].prefix(1)).uppercased()
        }
        return String(name.prefix(2)).uppercased()
    }

    private var placeholder: some View {
        Group {
            if useGhostArtworkPlaceholder {
                ZStack {
                    // Match the deeper base
                    Color(red: 0.12, green: 0.11, blue: 0.28)

                    GhostArtworkShape(color: Color(hue: 0.0, saturation: 0.85, brightness: 0.95).opacity(0.5), size: CGSize(width: 250, height: 210))
                        .offset(x: -70, y: 8)

                    GhostArtworkShape(color: Color(hue: 0.33, saturation: 0.80, brightness: 0.90).opacity(0.45), size: CGSize(width: 184, height: 244))
                        .offset(x: 8, y: 48)

                    GhostArtworkShape(color: Color(hue: 0.66, saturation: 0.75, brightness: 0.85).opacity(0.4), size: CGSize(width: 208, height: 154))
                        .offset(x: 102, y: 94)

                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.15),
                            Color.clear,
                            Color.black.opacity(0.18)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .blendMode(.overlay)

                    RadialGradient(
                        colors: [.clear, Color.black.opacity(0.12)],
                        center: .center,
                        startRadius: 60,
                        endRadius: 280
                    )
                    .blendMode(.multiply)
                }
            } else {
                LinearGradient(
                    colors: [tint.opacity(0.85), tint.opacity(0.45), Color.black.opacity(0.45)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
    }
}

struct CampaignThumbnail: View {
    let url: URL?
    let tint: Color

    var body: some View {
        ZStack {
            if let url {
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                } placeholder: {
                    placeholder
                }
            } else {
                placeholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: GlassRadius.artwork, style: .continuous))
    }

    private var placeholder: some View {
        LinearGradient(
            colors: [tint.opacity(0.65), tint.opacity(0.35), Color.white.opacity(0.14)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private extension URL {
    var overviewHighResolutionArtworkURL: URL {
        let replacements: [(String, String)] = [
            ("{width}", "600"),
            ("{height}", "800"),
            ("%7Bwidth%7D", "600"),
            ("%7Bheight%7D", "800")
        ]

        let resolved = replacements.reduce(absoluteString) { partial, pair in
            partial.replacingOccurrences(of: pair.0, with: pair.1)
        }

        return URL(string: resolved) ?? self
    }
}
