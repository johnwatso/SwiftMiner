import XCTest
@testable import SwiftMinerCore
@testable import SwiftMiner

final class AboutMetadataTests: XCTestCase {

    func testVersionLineSeparatesVersionAndBuild() {
        let metadata = AboutMetadata(
            shortVersion: "1.40.6",
            build: "2026090618",
            engineVersion: "4.14",
            engineUpdated: "2026-09-05"
        )
        XCTAssertEqual(metadata.versionLine, "Version 1.40.6 · Build 2026090618")
    }

    func testEngineLineUsesHumanReadableDate() {
        let metadata = AboutMetadata(
            shortVersion: "1.40.6",
            build: "2026090618",
            engineVersion: "4.14",
            engineUpdated: "2026-09-05"
        )
        XCTAssertEqual(metadata.engineLine, "Engine 4.14 · Updated 5 Sep 2026")
    }

    func testUnparseableEngineDatePassesThrough() {
        XCTAssertEqual(AboutMetadata.displayDate(from: "not-a-date"), "not-a-date")
    }

    func testMissingBuildLeavesNoTrailingSeparator() {
        let metadata = AboutMetadata(
            shortVersion: "1.40.6",
            build: nil,
            engineVersion: "4.14",
            engineUpdated: "2026-09-05"
        )
        XCTAssertEqual(metadata.versionLine, "Version 1.40.6")
    }

    func testReadsRunningBundleVersions() {
        let metadata = AboutMetadata()
        XCTAssertTrue(metadata.versionLine.hasPrefix("Version "))
        XCTAssertEqual(metadata.engineLine, "Engine \(MinerEngineVersion.current) · Updated \(AboutMetadata.displayDate(from: MinerEngineVersion.updated))")
    }
}
