import SwiftUI
import SwiftMinerCore

/// Sidebar navigation for the multi-miner dashboard (Phase 6).
///
/// Sections:
///   Overview
///   Miners
///   Drops
///   Activity Log
struct SidebarView: View {
    @Environment(NavigationModel.self) private var navigation
    @ObservedObject private var settings = Settings.shared
    @Namespace private var selectionHighlightNamespace
    @State private var rowFrames: [NavigationModel.SidebarItem: CGRect] = [:]
    @State private var isDraggingSelection = false

    private static let dragCoordinateSpace = "sidebarSelectorDrag"

    private var minerAttentionCount: Int {
        MinerAttention.attentionCount(miners: navigation.minerManager.miners, settings: settings)
    }

    fileprivate var sidebarItems: [SidebarItemSpec] {
        var items: [SidebarItemSpec] = [
            SidebarItemSpec(id: .overview, title: "Overview", systemImage: "waveform.path.ecg"),
            SidebarItemSpec(id: .miners, title: "Miners", systemImage: "cpu"),
            SidebarItemSpec(id: .drops, title: "Drops", systemImage: "gamecontroller.fill"),
            SidebarItemSpec(id: .events, title: "Activity Log", systemImage: "list.bullet.rectangle.fill"),
        ]
        if settings.swiftBotEnabled {
            items.append(SidebarItemSpec(id: .admin, title: "Discord", systemImage: "checkmark.message.fill"))
        }
        return items
    }

    private var currentSelection: NavigationModel.SidebarItem {
        navigation.selectedItem ?? .overview
    }

    @ViewBuilder
    private func rowView(for item: SidebarItemSpec) -> some View {
        let attention = item.id == .miners ? minerAttentionCount : 0
        SidebarRow(
            item: item,
            isSelected: currentSelection == item.id,
            selectionHighlightNamespace: selectionHighlightNamespace,
            attentionCount: attention
        ) {
            withAnimation(.easeInOut(duration: 0.18)) {
                navigation.selectedItem = item.id
            }
        }
    }

    var body: some View {
        ZStack {
            SidebarMaterialBackground()

            VStack(alignment: .leading, spacing: 2) {
                ForEach(sidebarItems) { item in
                    rowView(for: item)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .coordinateSpace(name: Self.dragCoordinateSpace)
            .onPreferenceChange(SidebarRowFramesKey.self) { rowFrames = $0 }
            .gesture(selectionDragGesture)
        }
        .navigationTitle("SwiftMiner")
        .onChange(of: settings.swiftBotEnabled) { _, enabled in
            if !enabled && navigation.selectedItem == .admin {
                navigation.selectedItem = .overview
            }
        }
    }

    private var selectionDragGesture: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.dragCoordinateSpace))
            .onChanged { value in
                isDraggingSelection = true
                updateSelection(forDragLocation: value.location)
            }
            .onEnded { _ in
                isDraggingSelection = false
            }
    }

    private func updateSelection(forDragLocation point: CGPoint) {
        guard let target = sidebarItems.first(where: { rowFrames[$0.id]?.contains(point) ?? false }) else {
            return
        }
        guard navigation.selectedItem != target.id else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            navigation.selectedItem = target.id
        }
    }
}

// MARK: - Drag tracking

private struct SidebarRowFramesKey: PreferenceKey {
    static var defaultValue: [NavigationModel.SidebarItem: CGRect] { [:] }
    static func reduce(value: inout [NavigationModel.SidebarItem: CGRect], nextValue: () -> [NavigationModel.SidebarItem: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

// MARK: - Sidebar Row & Selection Highlight (ported from SwiftBot)

fileprivate struct SidebarItemSpec: Identifiable {
    let id: NavigationModel.SidebarItem
    let title: String
    let systemImage: String
}

private struct SidebarRow: View {
    let item: SidebarItemSpec
    let isSelected: Bool
    let selectionHighlightNamespace: Namespace.ID
    let attentionCount: Int
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.systemImage)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 18)

            Text(item.title)
                .font(.system(size: 14, weight: isSelected ? .semibold : .medium))
                .lineLimit(1)

            Spacer(minLength: 0)

            if attentionCount > 0 {
                Text("\(attentionCount)")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange, in: Capsule())
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background {
            if isSelected {
                SidebarSelectionHighlight()
                    .matchedGeometryEffect(id: "sidebarSelectionHighlight", in: selectionHighlightNamespace)
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: SidebarRowFramesKey.self,
                    value: [item.id: geo.frame(in: .named("sidebarSelectorDrag"))]
                )
            }
        )
        .contentShape(Rectangle())
        .onTapGesture { action() }
    }
}

private struct SidebarSelectionHighlight: View {
    @Environment(\.controlActiveState) private var controlActiveState

    private var highlightMaterial: Material {
        controlActiveState == .active ? .ultraThinMaterial : .bar
    }

    private var strokeOpacity: Double {
        controlActiveState == .active ? 0.16 : 0.10
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(highlightMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(.white.opacity(strokeOpacity), lineWidth: 1)
            )
    }
}

// MARK: - Preview

#Preview {
    NavigationSplitView {
        SidebarView()
    } content: {
        Text("Content")
    } detail: {
        Text("Detail")
    }
    .environment(NavigationModel(clientId: "preview"))
}
