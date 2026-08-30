import AppKit
import XCTest
@testable import SwiftMiner
@testable import SwiftMinerCore

final class SystemSymbolCompatibilityTests: XCTestCase {
    func testPostSonomaAndInvalidSymbolsHaveSupportedFallbacks() {
        let expectedFallbacks = [
            "arrow.trianglehead.2.clockwise": "arrow.triangle.2.circlepath",
            "checkmark.arrow.trianglehead.counterclockwise": "checkmark.circle",
            "checkmark.circle.trianglebadge.exclamationmark.fill": "exclamationmark.circle.fill",
            "exclamationmark.arrow.trianglehead.counterclockwise.rotate.90": "exclamationmark.arrow.triangle.2.circlepath",
            "gift.slash": "gift.fill",
            "list.bullet.rectangle.stack": "list.bullet.rectangle",
            "list.dash.header.rectangle.fill": "rectangle.grid.2x2.fill",
            "person.badge.shield.check.fill": "person.badge.shield.checkmark.fill",
            "personalhotspot.slash": "personalhotspot",
            "photo.badge.minus": "photo",
            "waveform.path.ecg.text.clipboard.fill": "list.bullet.clipboard.fill",
        ]

        for (preferredName, expectedFallback) in expectedFallbacks {
            let resolvedName = SystemSymbolCompatibility.resolvedName(for: preferredName) { name in
                name != preferredName
            }
            XCTAssertEqual(resolvedName, expectedFallback, "Unexpected fallback for \(preferredName)")
        }
    }

    func testAvailablePreferredSymbolIsPreserved() {
        let resolvedName = SystemSymbolCompatibility.resolvedName(for: "new.symbol") { name in
            name == "new.symbol"
        }

        XCTAssertEqual(resolvedName, "new.symbol")
    }

    func testMacOS14SimulationForcesFallbackEvenWhenPreferredSymbolExists() {
        let resolvedName = SystemSymbolCompatibility.resolvedName(
            for: "list.dash.header.rectangle.fill",
            forceFallback: true
        ) { _ in true }

        XCTAssertEqual(resolvedName, "rectangle.grid.2x2.fill")
    }

    func testUnknownUnavailableSymbolUsesLastResortFallback() {
        let resolvedName = SystemSymbolCompatibility.resolvedName(for: "unknown.symbol") { name in
            name == "questionmark.circle"
        }

        XCTAssertEqual(resolvedName, "questionmark.circle")
    }
}

@MainActor
final class OverviewArtworkTests: XCTestCase {
    private let finalsArtwork = URL(string: "https://static-cdn.jtvnw.net/ttv-boxart/1910103699-600x800.jpg")!
    private let battlefieldArtwork = URL(string: "https://static-cdn.jtvnw.net/ttv-boxart/168648543_IGDB-600x800.jpg")!

    override func tearDown() {
        MockURLProtocol.stubResponseData = nil
        MockURLProtocol.stubError = nil
        MockURLProtocol.lastRequest = nil
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testResolverSkipsMatchingCampaignWithoutArtwork() {
        let preference = GamePreference(
            gameId: "1910103699",
            gameName: "THE FINALS",
            state: .preferred
        )
        let campaigns = [
            campaignViewData(id: "old", gameId: "1910103699", name: "THE FINALS", artworkURL: nil),
            campaignViewData(id: "current", gameId: "1910103699", name: "THE FINALS", artworkURL: finalsArtwork)
        ]

        XCTAssertEqual(
            OverviewArtworkResolver.artworkURL(for: preference, campaigns: campaigns),
            finalsArtwork
        )
    }

    func testResolverMatchesDiskSeedByNameWhenPreferenceHasSyntheticId() {
        let preference = GamePreference(
            gameId: "battlefield 6",
            gameName: "Battlefield 6",
            state: .preferred
        )
        let campaign = Campaign(
            id: "season-4",
            name: "Season 4 Launch",
            game: Game(id: "168648543", name: "Battlefield 6", boxArtURL: battlefieldArtwork),
            startDate: Date().addingTimeInterval(-3600),
            endDate: Date().addingTimeInterval(3600),
            drops: []
        )

        XCTAssertEqual(
            OverviewArtworkResolver.artworkURL(for: preference, campaigns: [campaign]),
            battlefieldArtwork
        )
    }

    func testCampaignArtworkSurvivesASecondCacheInstanceWithoutNetwork() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftMinerCampaignArtworkTests-(UUID().uuidString)", isDirectory: true)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let counter = RequestCounter()
        let url = URL(string: "https://example.com/campaign.png")!
        let png = try XCTUnwrap(Self.testPNGData())

        MockURLProtocol.requestHandler = { request in
            counter.increment()
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "image/png"]
            )!
            return (response, png)
        }

        let firstCache = CampaignArtworkCache(cacheDirectory: directory, session: session)
        let downloadedImage = await firstCache.image(for: url)
        XCTAssertNotNil(downloadedImage)
        XCTAssertEqual(counter.value, 1)

        MockURLProtocol.requestHandler = { _ in
            XCTFail("The second cache instance should load campaign artwork from disk")
            throw URLError(.notConnectedToInternet)
        }

        let secondCache = CampaignArtworkCache(cacheDirectory: directory, session: session)
        let diskImage = await secondCache.image(for: url)
        XCTAssertNotNil(diskImage)
        XCTAssertEqual(counter.value, 1)

        await secondCache.clearCache()
        session.invalidateAndCancel()
    }

    func testCampaignArtworkCacheKeepsItsFolderInsideTheDiskBudget() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftMinerArtworkBudgetTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let png = try XCTUnwrap(Self.testPNGData())
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "image/png"]
            )!
            return (response, png)
        }
        defer { MockURLProtocol.requestHandler = nil }

        // Every second download crosses the sweep interval, so the folder is pruned
        // during the run rather than only at the next launch.
        let cache = CampaignArtworkCache(
            cacheDirectory: directory,
            session: session,
            diskByteLimit: Int64(png.count) * 2,
            diskFileLimit: 2,
            budgetCheckWriteInterval: 2
        )
        for index in 0..<6 {
            let url = try XCTUnwrap(URL(string: "https://example.com/artwork-\(index).png"))
            let image = await cache.image(for: url)
            XCTAssertNotNil(image)
        }

        let cachedFiles = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        XCTAssertLessThanOrEqual(cachedFiles.count, 2)
    }

    func testCampaignArtworkCachePrunesAnOversizedFolderOnFirstUse() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftMinerArtworkBudgetTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Stand in for a folder left oversized by an earlier launch.
        for index in 0..<5 {
            let url = directory.appendingPathComponent("stale-\(index)")
            try Data(repeating: 0x41, count: 32).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-Double(index) * 60)],
                ofItemAtPath: url.path
            )
        }

        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        MockURLProtocol.requestHandler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        defer { MockURLProtocol.requestHandler = nil }

        let cache = CampaignArtworkCache(
            cacheDirectory: directory,
            session: session,
            diskByteLimit: 64,
            diskFileLimit: 2
        )
        let missing = await cache.image(for: try XCTUnwrap(URL(string: "https://example.com/missing.png")))
        XCTAssertNil(missing)

        let remaining = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        XCTAssertEqual(remaining.count, 2)
        // The newest files survive: eviction is oldest-first.
        XCTAssertEqual(Set(remaining.map { $0.lastPathComponent }), ["stale-0", "stale-1"])
    }

    private func campaignViewData(
        id: String,
        gameId: String,
        name: String,
        artworkURL: URL?
    ) -> CampaignViewData {
        CampaignViewData(
            id: id,
            gameId: gameId,
            gameName: name,
            campaignName: "Campaign \(id)",
            artworkURL: artworkURL,
            progress: 0,
            isClaimed: false,
            dropsClaimed: 0,
            totalDrops: 1,
            startDate: Date().addingTimeInterval(-3600),
            endDate: Date().addingTimeInterval(3600)
        )
    }

    private static func testPNGData() -> Data? {
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 2,
            pixelsHigh: 2,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        let purple = NSColor(deviceRed: 0.55, green: 0.25, blue: 0.85, alpha: 1)
        let blue = NSColor(deviceRed: 0.20, green: 0.55, blue: 0.95, alpha: 1)
        bitmap.setColor(purple, atX: 0, y: 0)
        bitmap.setColor(blue, atX: 1, y: 0)
        bitmap.setColor(blue, atX: 0, y: 1)
        bitmap.setColor(purple, atX: 1, y: 1)
        return bitmap.representation(using: .png, properties: [:])
    }
}

private final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

final class LegacySteamArtworkCleanupTests: XCTestCase {
    /// The Steam artwork feature was removed; an install that used it still holds a cache
    /// directory and defaults keys nothing will read again. Custom uploaded artwork lives
    /// elsewhere and must survive untouched.
    func testLegacySteamArtworkCleanupClearsItsDefaultsOnceAndLeavesOthersAlone() throws {
        let suiteName = "LegacySteamArtworkCleanupTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: "preferSteamArtwork")
        defaults.set(["THE FINALS": "2073850"], forKey: "steamArtworkAppIdCache")
        defaults.set(["Halo": "976730"], forKey: "steamArtworkManualOverrides")
        defaults.set("{}", forKey: "gamePreferences")

        LegacySteamArtworkCleanup.runIfNeeded(defaults: defaults)

        XCTAssertNil(defaults.object(forKey: "preferSteamArtwork"))
        XCTAssertNil(defaults.object(forKey: "steamArtworkAppIdCache"))
        XCTAssertNil(defaults.object(forKey: "steamArtworkManualOverrides"))
        XCTAssertEqual(
            defaults.string(forKey: "gamePreferences"), "{}",
            "Game preferences carry customArtworkURL; the cleanup must not touch them."
        )
        XCTAssertNotNil(
            defaults.object(forKey: LegacySteamArtworkCleanup.completedKey),
            "A clean install should not pay for this on every launch."
        )

        // A second run is a no-op rather than re-clearing keys the user has since set.
        defaults.set(true, forKey: "preferSteamArtwork")
        LegacySteamArtworkCleanup.runIfNeeded(defaults: defaults)
        XCTAssertTrue(defaults.bool(forKey: "preferSteamArtwork"))
    }
}
