import XCTest
@testable import SwiftMinerService

/// The portal's router and its markup are the same string of JavaScript, so a
/// route can quietly point at an element id that nothing ever renders. That is
/// exactly how `#/account/connection` came to resolve to nothing.
final class PortalRouteAnchorTests: XCTestCase {

    private var script: String { WebDashboardAssets.appJS }

    private func matches(_ pattern: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(script.startIndex..., in: script)
        return Set(regex.matches(in: script, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let r = Range(match.range(at: 1), in: script) else { return nil }
            return String(script[r])
        })
    }

    /// Every `$('route-…')` the router asks for must be an id the markup emits.
    func testEveryRouteAnchorLookedUpIsAlsoRendered() {
        let lookedUp = matches(#"\$\('(route-[a-z-]+)'\)"#)
        let rendered = matches(#"id="(route-[a-z-]+)""#)

        XCTAssertFalse(lookedUp.isEmpty, "route anchor lookups should exist")
        XCTAssertTrue(
            lookedUp.isSubset(of: rendered),
            "router looks up ids nothing renders: \(lookedUp.subtracting(rendered).sorted())"
        )
    }

    /// The identity card is the fallback that keeps a deep link from silently
    /// doing nothing, so it must always be rendered on a miner page.
    func testIdentityFallbackAnchorExists() {
        XCTAssertTrue(matches(#"id="(route-[a-z-]+)""#).contains("route-identity"))
    }

    /// Campaign rows carry the id a `#/campaign/<id>` route matches on.
    func testCampaignRowsAreAddressable() {
        XCTAssertTrue(script.contains("data-campaign-id="))
        XCTAssertTrue(script.contains("[data-campaign-id=\""))
    }

    /// Each destination `SwiftMinerPortalLink` can build has to be a route the
    /// script actually parses, or the DM button lands on an unhandled fragment.
    func testEveryBuiltDestinationIsParsedByTheRouter() throws {
        let link = try XCTUnwrap(SwiftMinerPortalLink(base: "https://portal.example.com"))

        for destination in SwiftBotPortalDestination.allCases {
            guard let url = link.url(for: destination, id: "sample") else {
                return XCTFail("\(destination.rawValue) built no URL")
            }
            guard let fragment = url.components(separatedBy: "#/").last, url.contains("#/") else {
                // Only the dashboard root is fragmentless.
                XCTAssertEqual(destination, .dashboard, "\(destination.rawValue) has no fragment")
                continue
            }
            let head = fragment.components(separatedBy: "/")[0]
            XCTAssertTrue(
                script.contains("case '\(head)':"),
                "router has no case for '\(head)' (destination \(destination.rawValue))"
            )
        }
    }
}
