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

                LazyVGrid(columns: minerActivityColumns, spacing: 14) {
                    ForEach(miners) { miner in
                        minerCard(for: miner, orderedIds: orderedIds)
                    }
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
        // stay in the grid, or every other card shuffles as the drag starts.
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

    /// Wide enough that the drop line — reward name, watched and required minutes —
    /// stays on one line rather than wrapping mid-phrase, narrow enough that four
    /// miners still sit on one row at a typical Overview width. The grid wraps
    /// beyond that rather than scrolling, in the order the user arranged.
    ///
    /// 268 was low enough that a 1920pt window laid out *six* columns of 269pt —
    /// the floor of the range. A five-miner fleet then filled five and left the
    /// sixth as trailing whitespace, so the row stopped short of the right edge
    /// while the Priority Queue below it did not. 300 gives that window five
    /// columns of ~325pt: wider cards, and the two sections line up.
    private var minerActivityColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 300), spacing: 14, alignment: .top)]
    }
}
