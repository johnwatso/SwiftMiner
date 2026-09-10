import XCTest
@testable import SwiftMinerCore

/// Twitch's edge answers an outage with a Varnish error page, and the whole body used to be
/// carried into the error message — so one 503 spilled fifteen lines of XHTML into the Activity
/// Log, the useful part being the four words in its `<title>`.
final class ErrorBodyCondensingTests: XCTestCase {

    private let varnish503 = """
    <?xml version="1.0" encoding="utf-8"?>
    <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN"
     "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
    <html>
      <head>
        <title>503 Backend unavailable, connection timeout</title>
      </head>
      <body>
        <h1>Error 503 Backend unavailable, connection timeout</h1>
        <p>Backend unavailable, connection timeout</p>
        <h3>Error 54113</h3>
        <p>Details: cache-akl10321-AKL 1787091341 1517879586</p>
        <hr>
        <p>Varnish cache server</p>
      </body>
    </html>
    """

    func testHTMLErrorPageCollapsesToItsTitle() {
        let condensed = TwitchMinerError.condensedErrorBody(varnish503)

        XCTAssertEqual(condensed, "503 Backend unavailable, connection timeout")
        XCTAssertFalse(condensed.contains("\n"))
    }

    /// The condensed message is what reaches the Activity Log, so it has to survive being
    /// formatted into an error description without dragging the page along.
    func testCondensedBodyKeepsTheErrorDescriptionToOneLine() {
        let error = TwitchMinerError.apiError(
            statusCode: 503,
            message: TwitchMinerError.condensedErrorBody(varnish503)
        )

        XCTAssertEqual(
            error.errorDescription,
            "API error (503): 503 Backend unavailable, connection timeout"
        )
    }

    func testMarkupWithoutATitleReportsItsShape() {
        let condensed = TwitchMinerError.condensedErrorBody("<html><body><h1>502</h1></body></html>")

        XCTAssertTrue(condensed.hasPrefix("HTML error page ("))
    }

    /// JSON error payloads are the useful case and must come through intact.
    func testJSONErrorBodyIsPreserved() {
        let body = #"{"errors":[{"message":"internal server error"}]}"#

        XCTAssertEqual(TwitchMinerError.condensedErrorBody(body), body)
    }

    func testMultiLinePlainTextCollapsesToOneLine() {
        let condensed = TwitchMinerError.condensedErrorBody("first line\n\n  second line\t third")

        XCTAssertEqual(condensed, "first line second line third")
    }

    func testOverlongBodyIsTruncated() {
        let condensed = TwitchMinerError.condensedErrorBody(String(repeating: "x", count: 500))

        XCTAssertEqual(condensed.count, 201)
        XCTAssertTrue(condensed.hasSuffix("…"))
    }

    func testEmptyBodySaysSo() {
        XCTAssertEqual(TwitchMinerError.condensedErrorBody("   \n  "), "no response body")
    }
}
