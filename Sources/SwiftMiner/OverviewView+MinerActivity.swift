import SwiftUI
import SwiftMinerCore
import AppKit

/// The miner activity section of Overview.
extension OverviewView {
    // MARK: - Miner Activity

    var minerActivitySection: some View {
        let miners = displayedMiners

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                sectionHeading("Miner Activity")

                Button {
                    isMinerStatusLegendPresented.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Explain miner card statuses")
                .accessibilityLabel("Explain miner statuses")
                .popover(isPresented: $isMinerStatusLegendPresented, arrowEdge: .top) {
                    MinerStatusLegendPopover()
                }

                Spacer()

                minerActivityControls(canReorder: miners.count > 1)
            }

            Text("Current status and progress for each miner.")
                .font(.callout)
                .foregroundStyle(.secondary)

            if miners.isEmpty {
                MaterialEmptyStatePanel(
                    "No Twitch accounts connected",
                    systemImage: "person.badge.plus",
                    description: "Add an account to see what each miner is mining now."
                ) {
                    Button {
                        navigation.showAddAccountSheet = true
                    } label: {
                        Label("Add Account", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                let orderedIds = miners.map(\.accountId)

                // Fit the whole fleet across the available width when readable.
                // Larger fleets scroll sideways instead of adding another row.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(miners) { miner in
                            minerCard(for: miner, orderedIds: orderedIds)
                                .frame(minWidth: 268, idealWidth: 268, maxWidth: .infinity)
                        }
                    }
                    .padding(6)

                    MinerActivityScrollRow {
                        HStack(alignment: .top, spacing: 14) {
                            ForEach(miners) { miner in
                                minerCard(for: miner, orderedIds: orderedIds)
                                    .frame(width: 300)
                            }
                        }
                        .padding(6)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 9)
                .padding(.bottom, 12)
                .background {
                    RoundedRectangle(cornerRadius: GlassRadius.large, style: .continuous)
                        .fill(Color.primary.opacity(0.03))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: GlassRadius.large, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
            }
        }
    }

    @ViewBuilder
    private func minerCard(
        for miner: MinerManager.ManagedMiner,
        orderedIds: [String]
    ) -> some View {
        MinerActivityCard(
            miner: miner,
            prominence: .compact,
            // While an arrangement is being made, a card is something to move
            // rather than something to open.
            onSelect: isReorderingMiners ? nil : {
                navigation.selectedMinerId = miner.id
                navigation.selectedItem = .miners
            }
        )
        .overlay(alignment: .topTrailing) {
            if isReorderingMiners {
                MinerReorderGrip()
                    .padding(10)
            }
        }
        // The card being carried is dimmed rather than removed: its slot has to
        // stay in the row, or every other card shuffles as the drag starts.
        .opacity(draggingMinerId == miner.accountId ? 0.4 : 1)
        .minerReorderable(
            id: miner.accountId,
            ids: orderedIds,
            isEnabled: isReorderingMiners,
            draggingId: $draggingMinerId,
            onReorder: applyMinerOrder
        )
    }

    @ViewBuilder
    private func minerActivityControls(canReorder: Bool) -> some View {
        HStack(spacing: 8) {
            Button {
                navigation.showAddAccountSheet = true
            } label: {
                Label("Add", systemImage: "plus")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isReorderingMiners)
            .help("Add a Twitch account")

            if isReorderingMiners {
                Button {
                    setMinerReordering(false)
                } label: {
                    Label("Done", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Finish reordering")
            } else {
                Button {
                    setMinerReordering(true)
                } label: {
                    Label("Reorder", systemImage: "arrow.left.arrow.right")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canReorder)
                .help("Drag the cards to change the order miners appear in")
            }
        }
    }

    private func setMinerReordering(_ isReordering: Bool) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.18)) {
            isReorderingMiners = isReordering
        }
        if !isReordering {
            draggingMinerId = nil
        }
    }

    /// Saves the arrangement as the whole displayed fleet, which also drops the
    /// account ids of miners that have since been removed.
    private func applyMinerOrder(_ ids: [String]) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.24)) {
            settings.minerOrder = ids
        }
    }
}

/// Fade only the edges with more miners offscreen, leaving the first and last
/// cards fully visible when the row reaches either end.
private struct MinerActivityScrollRow<Content: View>: View {
    @ViewBuilder var content: Content
    @State private var contentFrame: CGRect = .zero
    @State private var viewportWidth: CGFloat = 0

    var body: some View {
        ScrollView(.horizontal) {
            content
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .named("minerActivityScroll"))
                } action: { contentFrame = $0 }
        }
        .coordinateSpace(name: "minerActivityScroll")
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { viewportWidth = $0 }
        .mask {
            HStack(spacing: 0) {
                if contentFrame.minX < -1 {
                    LinearGradient(
                        colors: [.clear, .black],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: 32)
                }
                Rectangle()
                if contentFrame.maxX > viewportWidth + 1 {
                    LinearGradient(
                        colors: [.black, .clear],
                        startPoint: .leading, endPoint: .trailing
                    )
                    .frame(width: 32)
                }
            }
        }
    }
}
