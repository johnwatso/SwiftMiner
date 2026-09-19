import SwiftUI
import SwiftMinerCore
import AppKit

/// Sidebar navigation for the multi-miner dashboard (Phase 6).
///
/// Sections:
///   Overview
///   Miners
///   Drops
///   Activity Log
struct SidebarView: View {
    @Environment(NavigationModel.self) private var navigation
    private var settings: Settings { .shared }

    private var minerAttentionCount: Int {
        MinerAttention.attentionCount(miners: navigation.minerManager.miners, settings: settings)
    }

    // Outline symbol names: the sidebar list picks the symbol variant itself.
    private var sidebarItems: [SidebarItemSpec] {
        [
            SidebarItemSpec(
                id: .overview,
                title: "Overview",
                systemImage: SystemSymbolCompatibility.resolvedName(for: "list.dash.header.rectangle")
            ),
            SidebarItemSpec(id: .miners, title: "Miners", systemImage: "cpu"),
            SidebarItemSpec(id: .drops, title: "Drops", systemImage: "gamecontroller"),
            SidebarItemSpec(
                id: .events,
                title: "Activity Log",
                systemImage: SystemSymbolCompatibility.resolvedName(for: "waveform.path.ecg.text.clipboard")
            ),
        ]
    }

    private func row(for item: SidebarItemSpec) -> some View {
        let attention = item.id == .miners ? minerAttentionCount : 0

        return Label(item.title, systemImage: item.systemImage)
            .badge(attention)
            .accessibilityValue(attention > 0 ? Text("\(attention) miners need attention") : Text(""))
            .background(SidebarClickFocusOptOut())
            .tag(item.id)
    }

    var body: some View {
        @Bindable var navigation = navigation

        // A plain sidebar list: selection, focus ring, type-select and arrow-key
        // navigation and row height all come from AppKit, so the column tracks
        // whatever the running macOS draws for sidebars.
        List(selection: $navigation.selectedItem) {
            ForEach(sidebarItems, content: row(for:))
        }
        .listStyle(.sidebar)
        // The list's own backdrop gives way to `SidebarMaterialBackground`,
        // which is clear under Standard on macOS 26+ (the split view's Liquid
        // Glass shows through) and paints the custom plane otherwise.
        .scrollContentBackground(.hidden)
        .background { SidebarMaterialBackground() }
        .navigationTitle("SwiftMiner")
    }
}

// MARK: - Selection Style

/// Keeps the sidebar's selection the neutral grey pill Apple Music uses.
///
/// macOS draws a sidebar's selection in the accent colour only while its table
/// is first responder, and a click makes it first responder. SwiftUI has no
/// modifier for this: `.tint`, `.focusable(false)` and `.focusEffectDisabled()`
/// all leave the blue highlight in place on macOS 27. Refusing click-to-focus on
/// the backing table does it — a click still selects the row, the system still
/// draws the pill, and keyboard focus stays with the detail content, as in Music.
private struct SidebarClickFocusOptOut: NSViewRepresentable {
    func makeNSView(context: Context) -> ProbeView { ProbeView() }
    func updateNSView(_ nsView: ProbeView, context: Context) {}

    final class ProbeView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            var view = superview
            while let current = view, !(current is NSTableView) {
                view = current.superview
            }
            (view as? NSTableView)?.refusesFirstResponder = true
        }
    }
}

// MARK: - Sidebar Item

private struct SidebarItemSpec: Identifiable {
    let id: NavigationModel.SidebarItem
    let title: String
    let systemImage: String
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
