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
