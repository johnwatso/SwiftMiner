import Foundation
import SwiftMinerCore

/// The order miners are presented in, chosen by the user.
///
/// Purely presentational: the engine schedules every miner independently, and a
/// miner's position here says nothing about what it mines or when. It exists
/// because a fleet arrives in whatever order the accounts were added, which is
/// rarely the order their owner thinks of them in.
///
/// Stored as account ids rather than miner ids: a miner id is rebuilt when a
/// worker is recreated, and an arrangement must survive that.
extension Settings {
    /// Account ids, most-preferred first. Ids for accounts that are no longer
    /// connected are harmless — they simply never match — and are dropped the
    /// next time an order is saved.
    public var minerOrder: [String] {
        get {
            guard let data = minerOrderData.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode([String].self, from: data) else {
                return []
            }
            return decoded
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue),
                  let encoded = String(data: data, encoding: .utf8),
                  minerOrderData != encoded else { return }
            minerOrderData = encoded
        }
    }

    /// Applies the saved arrangement to a fleet.
    public func orderedMiners(_ miners: [MinerManager.ManagedMiner]) -> [MinerManager.ManagedMiner] {
        MinerOrder.sorted(miners, order: minerOrder, id: \.accountId)
    }
}

/// The arrangement itself, kept free of `Settings` and of SwiftUI so the rules
/// that decide where an unplaced miner lands can be tested directly.
public enum MinerOrder {
    /// Items in the saved order, with anything the order does not mention kept in
    /// its original relative position at the end.
    ///
    /// A newly added account therefore appears last rather than jumping into the
    /// middle of an arrangement the user made deliberately.
    public static func sorted<Item>(
        _ items: [Item],
        order: [String],
        id: (Item) -> String
    ) -> [Item] {
        guard !order.isEmpty, items.count > 1 else { return items }

        var rank: [String: Int] = [:]
        for (index, value) in order.enumerated() where rank[value] == nil {
            rank[value] = index
        }

        // Sorting on (rank, original position) rather than sorting in place:
        // `sorted(by:)` is not guaranteed stable, and two unplaced miners must
        // not swap with each other on an unrelated redraw.
        return items
            .enumerated()
            .sorted { lhs, rhs in
                switch (rank[id(lhs.element)], rank[id(rhs.element)]) {
                case let (lhsRank?, rhsRank?):
                    return lhsRank == rhsRank ? lhs.offset < rhs.offset : lhsRank < rhsRank
                case (.some, nil):
                    return true
                case (nil, .some):
                    return false
                case (nil, nil):
                    return lhs.offset < rhs.offset
                }
            }
            .map(\.element)
    }

    /// The order that results from dragging `movingId` onto `targetId`'s place.
    ///
    /// Returns nil when the drag changes nothing, so a caller can skip the write
    /// and the animation entirely — `dropEntered` fires repeatedly while a card
    /// is held over its neighbour.
    public static func reordered(
        _ ids: [String],
        moving movingId: String,
        onto targetId: String
    ) -> [String]? {
        guard movingId != targetId,
              let source = ids.firstIndex(of: movingId),
              let destination = ids.firstIndex(of: targetId) else {
            return nil
        }

        var updated = ids
        updated.move(
            fromOffsets: IndexSet(integer: source),
            // `move(fromOffsets:toOffset:)` takes the position *before* which to
            // insert, which is one past the destination when moving downwards.
            toOffset: destination > source ? destination + 1 : destination
        )
        return updated == ids ? nil : updated
    }
}
