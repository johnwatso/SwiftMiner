import XCTest
import Sparkle
@testable import SwiftMiner

/// Guards the one property that matters here: the tidied sentence replaces
/// Sparkle's wording only when the user really is on the newest version, and
/// never when an update exists that this Mac cannot install.
final class UpToDateUserDriverTests: XCTestCase {

    private func noUpdateError(reason: SPUNoUpdateFoundReason) -> NSError {
        NSError(
            domain: "SUSparkleErrorDomain",
            code: 1001,
            userInfo: [SPUNoUpdateFoundReasonKey: NSNumber(value: reason.rawValue)]
        )
    }

    func testOnNewerThanLatestVersionIsReducedToOneSentence() throws {
        let suggestion = try XCTUnwrap(
            UpToDateUserDriver.plainRecoverySuggestion(for: noUpdateError(reason: .onNewerThanLatestVersion))
        )
        XCTAssertTrue(suggestion.hasSuffix("is currently the newest version available."))
        XCTAssertFalse(suggestion.contains("("), "Build numbers must not survive: \(suggestion)")
        XCTAssertFalse(suggestion.contains("You are currently running"))
    }

    func testOnLatestVersionIsReducedToOneSentence() throws {
        let suggestion = try XCTUnwrap(
            UpToDateUserDriver.plainRecoverySuggestion(for: noUpdateError(reason: .onLatestVersion))
        )
        XCTAssertFalse(suggestion.contains("("))
    }

    func testSentenceNamesTheAppAndItsMarketingVersion() throws {
        let version = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        let suggestion = try XCTUnwrap(
            UpToDateUserDriver.plainRecoverySuggestion(for: noUpdateError(reason: .onLatestVersion))
        )
        XCTAssertEqual(suggestion, "SwiftMiner \(version) is currently the newest version available.")
    }

    func testCannotInstallReasonsKeepSparkleWording() {
        for reason: SPUNoUpdateFoundReason in [.systemIsTooOld, .systemIsTooNew, .hardwareDoesNotSupportARM64] {
            XCTAssertNil(
                UpToDateUserDriver.plainRecoverySuggestion(for: noUpdateError(reason: reason)),
                "Reason \(reason.rawValue) must keep Sparkle's explanation of why the update cannot be installed"
            )
        }
    }

    func testErrorWithoutAReasonKeepsSparkleWording() {
        let error = NSError(domain: "SUSparkleErrorDomain", code: 1001, userInfo: [:])
        XCTAssertNil(UpToDateUserDriver.plainRecoverySuggestion(for: error))
    }
}
