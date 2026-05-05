import XCTest

/// Regression guard for Sparkle updater configuration.
/// Sparkle reads SUFeedURL and SUPublicEDKey from the host app's Info.plist at runtime.
/// If these are missing (e.g. stripped by xcodegen because they aren't in project.yml
/// info.properties), auto-updates silently break.
final class SparkleConfigTests: XCTestCase {

    func testBuiltAppInfoPlistContainsSparkleKeys() {
        let info = Bundle.main.infoDictionary ?? [:]

        let feedURL = info["SUFeedURL"] as? String
        let publicKey = info["SUPublicEDKey"] as? String

        XCTAssertNotNil(feedURL, "SUFeedURL must be present in built app Info.plist")
        XCTAssertNotNil(publicKey, "SUPublicEDKey must be present in built app Info.plist")

        XCTAssertFalse(feedURL?.isEmpty ?? true, "SUFeedURL must not be empty")
        XCTAssertFalse(publicKey?.isEmpty ?? true, "SUPublicEDKey must not be empty")
    }

    func testProjectYmlPreservesSparkleInfoPlistProperties() throws {
        // Resolve project root from this test file: Tests/ → project root
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
        let projectYML = projectRoot.appendingPathComponent("project.yml")

        let yaml = try String(contentsOf: projectYML, encoding: .utf8)

        // These strings must appear in project.yml info.properties so xcodegen
        // rewrites them into Sources/SwiftMiner/Info.plist on every generate.
        XCTAssertTrue(yaml.contains("SUFeedURL"), "project.yml must reference SUFeedURL in info.properties")
        XCTAssertTrue(yaml.contains("SUPublicEDKey"), "project.yml must reference SUPublicEDKey in info.properties")
    }

    func testSourceInfoPlistContainsSparkleKeys() throws {
        let testFile = URL(fileURLWithPath: #filePath)
        let projectRoot = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let plist = projectRoot
            .appendingPathComponent("Sources/SwiftMiner/Info.plist")

        let data = try Data(contentsOf: plist)
        let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] ?? [:]

        XCTAssertNotNil(info["SUFeedURL"] as? String, "Sources/SwiftMiner/Info.plist must contain SUFeedURL")
        XCTAssertNotNil(info["SUPublicEDKey"] as? String, "Sources/SwiftMiner/Info.plist must contain SUPublicEDKey")
    }
}
