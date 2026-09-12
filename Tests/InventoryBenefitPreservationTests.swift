import XCTest
@testable import SwiftMinerCore

/// A completed campaign must stay completed across a relaunch.
///
/// Claimed state is derived from the inventory benefit set alone, so a response that comes
/// back without one marks every earned drop unclaimed and returns finished campaigns to
/// mining. That is what sent the fleet hunting THE FINALS streams for a reward both
/// accounts had already claimed.
final class InventoryBenefitPreservationTests: XCTestCase {
    private func benefit(_ id: String, awardedAt: Date = Date(timeIntervalSince1970: 1_000)) -> TwitchAPIClient.ClaimedBenefit {
        TwitchAPIClient.ClaimedBenefit(id: id, name: id, lastAwardedAt: awardedAt)
    }

    private func snapshot(benefitIDs: Set<String>, awardedAt: [String: Date] = [:]) -> InventorySnapshot {
        InventorySnapshot(
            accountId: "account",
            benefitIDs: benefitIDs,
            benefitAwardedAt: awardedAt,
            progress: []
        )
    }

    func testEmptyResponseKeepsBenefitsAlreadyKnown() {
        let awarded = Date(timeIntervalSince1970: 2_000)
        let previous = snapshot(benefitIDs: ["blaze-hover-pad"], awardedAt: ["blaze-hover-pad": awarded])

        let result = InventoryService.preservingKnownBenefits(fresh: [:], previous: previous)

        XCTAssertEqual(result.benefitIDs, ["blaze-hover-pad"])
        XCTAssertEqual(result.awardedAt["blaze-hover-pad"], awarded)
    }

    func testFreshBenefitsAlwaysWinWhenPresent() {
        let previous = snapshot(benefitIDs: ["old-benefit"])

        let result = InventoryService.preservingKnownBenefits(
            fresh: ["new-benefit": benefit("new-benefit")],
            previous: previous
        )

        // Never a union: a non-empty response is Twitch's own answer and is trusted whole,
        // so this can't resurrect a benefit Twitch has genuinely stopped listing.
        XCTAssertEqual(result.benefitIDs, ["new-benefit"])
    }

    func testEmptyResponseWithNothingKnownStaysEmpty() {
        XCTAssertTrue(InventoryService.preservingKnownBenefits(fresh: [:], previous: nil).benefitIDs.isEmpty)
        XCTAssertTrue(
            InventoryService.preservingKnownBenefits(
                fresh: [:],
                previous: snapshot(benefitIDs: [])
            ).benefitIDs.isEmpty
        )
    }
}
