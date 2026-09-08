import SwiftUI
import UniformTypeIdentifiers

/// Drag-to-reorder for miners, shared by the Overview grid and the Accounts
/// pane so both arrange the same fleet the same way.
///
/// The order is applied live as a card is dragged across its neighbours rather
/// than on release: the arrangement being built is the thing the user is
/// looking at, and a card that only jumps into place on drop gives them nothing
/// to aim with.
struct MinerReorderDropDelegate: DropDelegate {
    /// The account id of the row or card being dragged over.
    let targetId: String
    /// The fleet's current arrangement, in displayed order.
    let ids: [String]
    @Binding var draggingId: String?
    let onReorder: ([String]) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggingId,
              let updated = MinerOrder.reordered(ids, moving: draggingId, onto: targetId) else {
            return
        }
        onReorder(updated)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingId = nil
        return true
    }
}

extension View {
    /// Makes a miner card or row draggable within `ids`, and a drop target for
    /// its neighbours. `isEnabled` covers the Overview grid, where reordering is
    /// a mode rather than something always live under the pointer.
    @ViewBuilder
    func minerReorderable(
        id: String,
        ids: [String],
        isEnabled: Bool = true,
        draggingId: Binding<String?>,
        onReorder: @escaping ([String]) -> Void
    ) -> some View {
        if isEnabled {
            self
                .onDrag {
                    draggingId.wrappedValue = id
                    return NSItemProvider(object: id as NSString)
                }
                .onDrop(
                    of: [UTType.text],
                    delegate: MinerReorderDropDelegate(
                        targetId: id,
                        ids: ids,
                        draggingId: draggingId,
                        onReorder: onReorder
                    )
                )
        } else {
            self
        }
    }
}

/// The grip that says a thing can be dragged. Drawn only while an arrangement is
/// actually being made, so a card that is merely being read carries no chrome.
struct MinerReorderGrip: View {
    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(5)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: GlassRadius.small, style: .continuous))
            .accessibilityHidden(true)
    }
}
