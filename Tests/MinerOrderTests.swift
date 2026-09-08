import XCTest
@testable import SwiftMiner

final class MinerOrderTests: XCTestCase {
    private func sorted(_ ids: [String], order: [String]) -> [String] {
        MinerOrder.sorted(ids, order: order, id: { $0 })
    }

    func testSavedOrderIsApplied() {
        XCTAssertEqual(sorted(["a", "b", "c"], order: ["c", "a", "b"]), ["c", "a", "b"])
    }

    func testAnEmptyOrderLeavesTheFleetAlone() {
        XCTAssertEqual(sorted(["a", "b", "c"], order: []), ["a", "b", "c"])
    }

    func testAnUnplacedMinerGoesLastRatherThanIntoTheMiddleOfAnArrangement() {
        XCTAssertEqual(sorted(["a", "new", "b"], order: ["b", "a"]), ["b", "a", "new"])
    }

    func testUnplacedMinersKeepTheirRelativeOrder() {
        XCTAssertEqual(
            sorted(["x", "a", "y"], order: ["a"]),
            ["a", "x", "y"]
        )
    }

    func testIdsForRemovedAccountsAreSimplyIgnored() {
        XCTAssertEqual(sorted(["a", "b"], order: ["gone", "b", "also-gone", "a"]), ["b", "a"])
    }

    func testDraggingDownwardsLandsAfterTheTarget() {
        XCTAssertEqual(
            MinerOrder.reordered(["a", "b", "c"], moving: "a", onto: "c"),
            ["b", "c", "a"]
        )
    }

    func testDraggingUpwardsLandsBeforeTheTarget() {
        XCTAssertEqual(
            MinerOrder.reordered(["a", "b", "c"], moving: "c", onto: "a"),
            ["c", "a", "b"]
        )
    }

    func testADragThatChangesNothingReportsNoNewOrder() {
        XCTAssertNil(MinerOrder.reordered(["a", "b"], moving: "a", onto: "a"))
        XCTAssertNil(MinerOrder.reordered(["a", "b"], moving: "missing", onto: "b"))
        XCTAssertNil(MinerOrder.reordered(["a", "b"], moving: "a", onto: "missing"))
    }
}
