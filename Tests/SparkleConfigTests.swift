import XCTest

/// Regression guard for Sparkle updater configuration.
/// Sparkle reads SUFeedURL and SUPublicEDKey from the host app's Info.plist at runtime.
/// If these are missing (e.g. stripped by xcodegen because they aren't in project.yml
/// info.properties), auto-updates silently break.
final class SparkleConfigTests: XCTestCase {
    private let expectedFeedURL = "https://johnwatso.github.io/SwiftMiner/appcast.xml"
    private let expectedPublicKey = "rxaJsfCpTKtpqRubSfkJwKnztT5S8RHsdAueuT+jKck="
    private let previousPublicKey = "4Aht0ilQOmLxGQMnSwGNJvtZ0VKH7lZoV4Raag6eEN8="
    private var testBundle: Bundle { Bundle(for: Self.self) }

    func testBuiltAppInfoPlistContainsSparkleKeys() {
        let info = Bundle.main.infoDictionary ?? [:]

        let feedURL = info["SUFeedURL"] as? String
        let publicKey = info["SUPublicEDKey"] as? String

        XCTAssertNotNil(feedURL, "SUFeedURL must be present in built app Info.plist")
        XCTAssertNotNil(publicKey, "SUPublicEDKey must be present in built app Info.plist")

        XCTAssertFalse(feedURL?.isEmpty ?? true, "SUFeedURL must not be empty")
        XCTAssertFalse(publicKey?.isEmpty ?? true, "SUPublicEDKey must not be empty")
        XCTAssertEqual(feedURL, expectedFeedURL, "SUFeedURL must keep using the stable SwiftMiner appcast")
        XCTAssertEqual(publicKey, expectedPublicKey, "SUPublicEDKey must match the current Sparkle EdDSA public key")
        XCTAssertNotEqual(publicKey, previousPublicKey, "SUPublicEDKey must not regress to the retired Sparkle public key")
        XCTAssertNil(
            info["SUEnableAutomaticChecks"],
            "SUEnableAutomaticChecks must remain absent so Sparkle can ask for update-check permission"
        )
        XCTAssertEqual(
            info["SUAutomaticallyUpdate"] as? Bool,
            true,
            "Sparkle's permission prompt should initially select unattended updates"
        )
    }

    func testProjectYmlPreservesSparkleInfoPlistProperties() throws {
        let projectYML = try XCTUnwrap(testBundle.url(forResource: "project", withExtension: "yml"))
        let yaml = try String(contentsOf: projectYML, encoding: .utf8)

        // These strings must appear in project.yml info.properties so xcodegen
        // rewrites them into Sources/SwiftMiner/Info.plist on every generate.
        XCTAssertTrue(yaml.contains("SUFeedURL"), "project.yml must reference SUFeedURL in info.properties")
        XCTAssertTrue(yaml.contains("SUPublicEDKey"), "project.yml must reference SUPublicEDKey in info.properties")
        XCTAssertFalse(yaml.contains("SUEnableAutomaticChecks"), "project.yml must allow Sparkle to show its permission prompt")
        XCTAssertTrue(yaml.contains("SUAutomaticallyUpdate: true"), "project.yml must offer unattended updates in Sparkle's permission prompt")
        XCTAssertTrue(yaml.contains("SPARKLE_PUBLIC_ED_KEY: \"\(expectedPublicKey)\""), "project.yml must preserve the current Sparkle public key")
        XCTAssertFalse(yaml.contains(previousPublicKey), "project.yml must not contain the retired Sparkle public key")
    }

}
