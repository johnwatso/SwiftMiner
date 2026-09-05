import XCTest
@testable import SwiftMinerCore

final class CampaignViewDataCacheTests: XCTestCase {
    func testServiceListFeedAndDetailStayConsistentAndClearTogether() async throws {
        let accountId = "view-cache-\(UUID().uuidString)"
        defer {
            CampaignDiskCache.clear(accountId: accountId)
            InventoryDiskCache.clear(accountId: accountId)
        }
        let now = Date()
        let campaign = makeCampaign(id: "r6", start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(3600))
        let inventory = makeInventory(campaign: campaign, minutes: 63, awardedAt: now)
        CampaignDiskCache.save(campaigns: [campaign], accountId: accountId)
        InventoryDiskCache.save(InventorySnapshot(
            accountId: accountId, benefitIDs: inventory.benefitIDs,
            benefitAwardedAt: inventory.benefitAwardedAt, progress: inventory.progress
        ))
        let auth = TwitchAuthService(clientId: "test-client", tokenStore: TestTokenStore())
        let client = TwitchAPIClient(authService: auth, clientId: "test-client", persistsCampaignCaches: false)
        let inventoryService = InventoryService(apiClient: client)
        await inventoryService.setAccountId(accountId)
        let service = CampaignDataService(apiClient: client, inventoryService: inventoryService, accountId: accountId)

        let all = await service.allCampaigns()
        let feed = await service.currentCampaigns()
        let detail = await service.getCampaign(id: campaign.id)
        XCTAssertEqual(all, feed)
        XCTAssertEqual(detail, all.first)
        XCTAssertEqual(detail?.drops.map(\.isClaimed), [true, false, false])

        await service.clearCache()
        let cleared = await service.allCampaigns()
        XCTAssertTrue(cleared.isEmpty)
    }

    func testRepeatedListFeedAndDetailReadsPreserveUnfinishedRainbowSixTiers() throws {
        let now = Date()
        let campaign = makeCampaign(id: "r6", start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(3600))
        let inventory = makeInventory(campaign: campaign, minutes: 63, awardedAt: now)
        var cache = CampaignViewDataCache()

        let first = cache.snapshot(campaigns: [campaign], inventory: inventory, now: now)
        let detail = try XCTUnwrap(first.byID[campaign.id])
        XCTAssertEqual(detail.dropsClaimed, 1)
        XCTAssertEqual(detail.drops.map(\.isClaimed), [true, false, false])
        XCTAssertEqual(detail.drops.map(\.currentMinutes), [60, 63, 63])
        XCTAssertEqual(first.feed, first.all)

        for _ in 0..<100 {
            let repeated = cache.snapshot(campaigns: [campaign], inventory: inventory, now: now)
            XCTAssertTrue(repeated === first, "Unchanged reads must reuse the reconciled snapshot.")
            XCTAssertEqual(repeated.byID[campaign.id], detail)
        }
    }

    func testChangedProgressInvalidatesButObservationTimestampsDoNot() throws {
        let now = Date()
        let campaign = makeCampaign(id: "r6", start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(3600))
        var cache = CampaignViewDataCache()
        let firstInventory = makeInventory(campaign: campaign, minutes: 63, awardedAt: now, observedAt: now)
        let first = cache.snapshot(campaigns: [campaign], inventory: firstInventory, now: now)

        let unchangedInventory = makeInventory(
            campaign: campaign, minutes: 63, awardedAt: now, observedAt: now.addingTimeInterval(60)
        )
        let unchanged = cache.snapshot(campaigns: [campaign], inventory: unchangedInventory, now: now.addingTimeInterval(60))
        XCTAssertTrue(unchanged === first)

        let progressedInventory = makeInventory(
            campaign: campaign, minutes: 90, awardedAt: now, observedAt: now.addingTimeInterval(120)
        )
        let progressed = cache.snapshot(campaigns: [campaign], inventory: progressedInventory, now: now.addingTimeInterval(120))
        XCTAssertFalse(progressed === first)
        XCTAssertEqual(progressed.byID[campaign.id]?.drops.map(\.currentMinutes), [60, 90, 90])
    }

    func testFullCampaignContextAndChangedAwardTimeInvalidateAttribution() throws {
        let now = Date()
        let yesterday = makeCampaign(
            id: "yesterday", start: now.addingTimeInterval(-86400), end: now.addingTimeInterval(-43200), tierCount: 1
        )
        let today = makeCampaign(
            id: "today", start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(3600), tierCount: 1
        )
        let oldAward = InventorySnapshot(
            accountId: "account", benefitIDs: ["shared-pack"],
            benefitAwardedAt: ["shared-pack": yesterday.startDate.addingTimeInterval(60)], progress: []
        )
        var cache = CampaignViewDataCache()
        let single = cache.snapshot(campaigns: [today], inventory: oldAward, now: now)
        XCTAssertTrue(try XCTUnwrap(single.byID[today.id]).isClaimed)

        let both = cache.snapshot(campaigns: [yesterday, today], inventory: oldAward, now: now)
        XCTAssertFalse(both === single)
        XCTAssertTrue(try XCTUnwrap(both.byID[yesterday.id]).isClaimed)
        XCTAssertFalse(try XCTUnwrap(both.byID[today.id]).isClaimed)

        // The set of benefit IDs and progress are identical; only the award time changed.
        let newAward = InventorySnapshot(
            accountId: "account", benefitIDs: ["shared-pack"],
            benefitAwardedAt: ["shared-pack": now], progress: [], lastUpdated: oldAward.lastUpdated
        )
        let reassigned = cache.snapshot(campaigns: [yesterday, today], inventory: newAward, now: now)
        XCTAssertFalse(reassigned === both)
        XCTAssertFalse(try XCTUnwrap(reassigned.byID[yesterday.id]).isClaimed)
        XCTAssertTrue(try XCTUnwrap(reassigned.byID[today.id]).isClaimed)
    }

    func testNilInventoryAndAccountChangesDoNotReuseClaimState() throws {
        let now = Date()
        var campaign = makeCampaign(
            id: "single", start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(3600), tierCount: 1
        )
        campaign.drops[0].progress = Progress(
            dropId: campaign.drops[0].id, campaignId: campaign.id,
            currentMinutes: 25, requiredMinutes: 60
        )
        var cache = CampaignViewDataCache()
        let offline = cache.snapshot(campaigns: [campaign], inventory: nil, now: now)
        XCTAssertEqual(offline.all.first?.drops.first?.currentMinutes, 25)

        let claimed = cache.snapshot(
            campaigns: [campaign],
            inventory: InventorySnapshot(accountId: "claimed", benefitIDs: ["shared-pack"], progress: []), now: now
        )
        XCTAssertTrue(try XCTUnwrap(claimed.all.first).isClaimed)

        let empty = cache.snapshot(
            campaigns: [campaign], inventory: .empty(accountId: "unclaimed"), now: now
        )
        XCTAssertFalse(try XCTUnwrap(empty.all.first).isClaimed)
        XCTAssertEqual(empty.all.first?.drops.first?.currentMinutes, 0)
        let otherAccount = cache.snapshot(
            campaigns: [campaign], inventory: .empty(accountId: "another-account"), now: now
        )
        XCTAssertFalse(otherAccount === empty)

        let offlineAgain = cache.snapshot(campaigns: [campaign], inventory: nil, now: now)
        XCTAssertFalse(offlineAgain === empty)
        XCTAssertEqual(offlineAgain.all, offline.all)
    }

    func testCampaignMetadataAndDropOrderChangesRemainVisible() {
        let now = Date()
        let campaign = makeCampaign(id: "r6", start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(3600))
        var cache = CampaignViewDataCache()
        let original = cache.snapshot(campaigns: [campaign], inventory: nil, now: now)

        let renamed = Campaign(
            id: campaign.id, name: "Updated campaign", game: campaign.game,
            startDate: campaign.startDate, endDate: campaign.endDate,
            drops: Array(campaign.drops.reversed()), isAccountConnected: false
        )
        let updated = cache.snapshot(campaigns: [renamed], inventory: nil, now: now)
        XCTAssertFalse(updated === original)
        XCTAssertEqual(updated.all.first?.campaignName, "Updated campaign")
        XCTAssertEqual(updated.all.first?.drops.map(\.id), campaign.drops.reversed().map(\.id))
        XCTAssertEqual(updated.all.first?.isAccountConnected, false)
    }

    func testStartEndAndClockRollbackReevaluateUnchangedData() {
        let now = Date()
        let start = now.addingTimeInterval(100)
        let end = now.addingTimeInterval(200)
        let campaign = makeCampaign(id: "scheduled", start: start, end: end)
        var cache = CampaignViewDataCache()
        let beforeStart = cache.snapshot(campaigns: [campaign], inventory: nil, now: now)
        XCTAssertTrue(cache.snapshot(campaigns: [campaign], inventory: nil, now: start.addingTimeInterval(-1)) === beforeStart)

        let atStart = cache.snapshot(campaigns: [campaign], inventory: nil, now: start)
        XCTAssertFalse(atStart === beforeStart)
        let afterStart = cache.snapshot(campaigns: [campaign], inventory: nil, now: start.addingTimeInterval(1))
        XCTAssertFalse(afterStart === atStart, "Exact boundaries must also reevaluate strict date comparisons on the following read.")
        XCTAssertTrue(cache.snapshot(campaigns: [campaign], inventory: nil, now: end.addingTimeInterval(-1)) === afterStart)

        let atEnd = cache.snapshot(campaigns: [campaign], inventory: nil, now: end)
        XCTAssertFalse(atEnd === afterStart)
        let afterEnd = cache.snapshot(campaigns: [campaign], inventory: nil, now: end.addingTimeInterval(1))
        XCTAssertFalse(afterEnd === atEnd)
        XCTAssertTrue(cache.snapshot(campaigns: [campaign], inventory: nil, now: end.addingTimeInterval(100)) === afterEnd)
        XCTAssertFalse(cache.snapshot(campaigns: [campaign], inventory: nil, now: now) === afterEnd)
    }

    func testRepeatedHistoryReadBenchmark() {
        let now = Date()
        let campaigns = (0..<425).map {
            makeCampaign(id: "history-\($0)", start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(3600))
        }
        let inventory = InventorySnapshot(accountId: "account", benefitIDs: ["shared-pack"], progress: [])
        let reads = 25
        var uncached: [CampaignViewData] = []
        let uncachedDuration = ContinuousClock().measure {
            for _ in 0..<reads {
                uncached = CampaignMapper.map(campaigns: campaigns, inventory: inventory)
            }
        }

        var cache = CampaignViewDataCache()
        let initial = cache.snapshot(campaigns: campaigns, inventory: inventory, now: now)
        var cached = initial
        let cachedDuration = ContinuousClock().measure {
            for _ in 0..<reads {
                cached = cache.snapshot(campaigns: campaigns, inventory: inventory, now: now)
            }
        }
        XCTAssertTrue(cached === initial)
        XCTAssertEqual(cached.all, uncached)
        // Diagnostic benchmark, with no timing threshold that would fail on a busy CI host.
        print("Campaign history benchmark (425 campaigns, 25 reads): uncached=\(uncachedDuration), cached=\(cachedDuration)")
    }

    private func makeCampaign(id: String, start: Date, end: Date, tierCount: Int = 3) -> Campaign {
        let tiers = Array([60, 180, 360].prefix(tierCount))
        return Campaign(
            id: id, name: "Rainbow Six \(id)", game: Game(id: "r6-game", name: "Rainbow Six Siege"),
            startDate: start, endDate: end,
            drops: tiers.map { Drop(id: "\(id)-\($0)", name: "Esports Pack", requiredMinutes: $0, benefitID: "shared-pack") },
            isAccountConnected: true
        )
    }

    private func makeInventory(
        campaign: Campaign, minutes: Int, awardedAt: Date, observedAt: Date = Date()
    ) -> InventorySnapshot {
        InventorySnapshot(
            accountId: "account", benefitIDs: ["shared-pack"], benefitAwardedAt: ["shared-pack": awardedAt],
            progress: campaign.drops.dropFirst().map { drop in
                Progress(
                    id: drop.id, dropId: drop.id, dropName: drop.name, campaignId: campaign.id,
                    currentMinutes: minutes, requiredMinutes: drop.requiredMinutes, lastUpdated: observedAt
                )
            },
            lastUpdated: observedAt
        )
    }
}
