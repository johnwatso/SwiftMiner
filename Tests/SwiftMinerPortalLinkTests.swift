import XCTest
@testable import SwiftMinerService

/// The routes asserted here are the same ones `WebDashboardAssets.appJS`
/// parses. If a route changes on one side it must change on the other.
final class SwiftMinerPortalLinkTests: XCTestCase {

    private let base = "https://swiftminer.example.com"

    private func link() -> SwiftMinerPortalLink {
        guard let link = SwiftMinerPortalLink(base: base) else {
            preconditionFailure("valid base should build a link")
        }
        return link
    }

    // MARK: - Base validation

    func testRejectsBasesThereIsNothingHonestToLinkTo() {
        XCTAssertNil(SwiftMinerPortalLink(base: nil))
        XCTAssertNil(SwiftMinerPortalLink(base: ""))
        XCTAssertNil(SwiftMinerPortalLink(base: "   "))
        XCTAssertNil(SwiftMinerPortalLink(base: "swiftminer.example.com"), "no scheme")
        XCTAssertNil(SwiftMinerPortalLink(base: "ftp://swiftminer.example.com"), "wrong scheme")
    }

    func testTrailingSlashesAreStrippedSoRoutesNeverDoubleUp() {
        XCTAssertEqual(SwiftMinerPortalLink(base: "\(base)/")?.dashboard, "\(base)/app")
        XCTAssertEqual(SwiftMinerPortalLink(base: "\(base)///")?.dashboard, "\(base)/app")
    }

    func testLocalPortalsAreUsable() {
        XCTAssertEqual(
            SwiftMinerPortalLink(base: "http://localhost:8080")?.dashboard,
            "http://localhost:8080/app"
        )
    }

    // MARK: - Destinations

    func testEveryDestinationMatchesTheRouteTheSPAParses() {
        let link = self.link()

        XCTAssertEqual(link.dashboard, "\(base)/app")
        XCTAssertEqual(link.accountConnection, "\(base)/app#/account/connection")
        XCTAssertEqual(link.campaigns, "\(base)/app#/campaigns")
        XCTAssertEqual(link.drops, "\(base)/app#/drops")
        XCTAssertEqual(link.miner(accountId: "123456"), "\(base)/app#/miner/123456")
        XCTAssertEqual(link.campaign(id: "abc-def"), "\(base)/app#/campaign/abc%2Ddef")
    }

    func testDestinationLookupMatchesTheDirectAccessors() {
        let link = self.link()

        XCTAssertEqual(link.url(for: .dashboard), link.dashboard)
        XCTAssertEqual(link.url(for: .accountConnection), link.accountConnection)
        XCTAssertEqual(link.url(for: .campaigns), link.campaigns)
        XCTAssertEqual(link.url(for: .drops), link.drops)
        XCTAssertEqual(link.url(for: .miner, id: "123456"), link.miner(accountId: "123456"))
        XCTAssertEqual(link.url(for: .campaign, id: "abc-def"), link.campaign(id: "abc-def"))
    }

    /// A missing id must not degrade into a link that means "everything" — the
    /// DM would then point somewhere that does not explain it.
    func testDestinationsNeedingAnIdReturnNilWithoutOne() {
        let link = self.link()

        XCTAssertNil(link.url(for: .campaign, id: nil))
        XCTAssertNil(link.url(for: .miner, id: nil))
        XCTAssertNil(link.url(for: .campaign, id: "   "))
        XCTAssertNil(link.miner(accountId: ""))
    }

    func testIdsWithSeparatorsCannotEscapeTheirRouteSegment() {
        let link = self.link()

        XCTAssertEqual(link.campaign(id: "a/b"), "\(base)/app#/campaign/a%2Fb")
        XCTAssertEqual(link.campaign(id: "a b"), "\(base)/app#/campaign/a%20b")
        XCTAssertEqual(link.campaign(id: "a#b"), "\(base)/app#/campaign/a%23b")
    }

    // MARK: - Labels SwiftBot renders

    func testEveryDestinationOffersAButtonLabel() {
        for destination in SwiftBotPortalDestination.allCases {
            XCTAssertFalse(
                destination.suggestedButtonLabel.isEmpty,
                "\(destination.rawValue) has no button label"
            )
        }
    }

    func testKnownIssueKindsNameTheActualProblem() {
        XCTAssertEqual(SwiftBotIssueKind.subscriptionRequired.suggestedTitle, "Twitch Subscription Required")
        XCTAssertEqual(SwiftBotIssueKind.accountLinkRequired.suggestedTitle, "Account Linking Required")
        XCTAssertEqual(SwiftBotIssueKind.connectionExpired.suggestedTitle, "Twitch Connection Expired")
    }

    func testUnclassifiedIssuesFallBackToActionRequiredNotNeedsALook() {
        XCTAssertEqual(SwiftBotIssueKind.unknown.suggestedTitle, "Action Required")
    }

    // MARK: - Help links

    func testDiagnosableIssuesCarryAHelpArticle() {
        for kind in [SwiftBotIssueKind.connectionExpired, .accountLinkRequired, .subscriptionRequired] {
            XCTAssertNotNil(SwiftMinerHelpLink.url(for: kind), "\(kind.rawValue) has no help article")
        }
        XCTAssertNil(SwiftMinerHelpLink.url(for: .unknown))
    }

    func testHelpLinksPointAtSwiftMinerApp() {
        let urls = SwiftBotIssueKind.allCases.compactMap(SwiftMinerHelpLink.url(for:))
            + [SwiftMinerHelpLink.webDashboard]

        for url in urls {
            XCTAssertTrue(url.hasPrefix("https://swiftminer.app/help/"), "unexpected help URL \(url)")
            XCTAssertTrue(url.hasSuffix("/"), "help URL should be a directory: \(url)")
        }
    }

    // MARK: - Payload wiring

    func testPayloadCarriesTheDeepLinkFieldsSwiftBotReads() throws {
        let link = self.link()
        let request = SwiftBotDMRequest(
            messageType: .accountActionRequired,
            debug: false,
            campaignName: "Phantom Liberty Drops",
            portalURL: link.campaign(id: "camp-1"),
            portalDestination: SwiftBotPortalDestination.campaign.rawValue,
            issueKind: SwiftBotIssueKind.subscriptionRequired.rawValue,
            campaignId: "camp-1",
            helpURL: SwiftMinerHelpLink.url(for: .subscriptionRequired)
        )

        let json = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(request)
        ) as? [String: Any]

        XCTAssertEqual(json?["portal_url"] as? String, "\(base)/app#/campaign/camp%2D1")
        XCTAssertEqual(json?["portal_destination"] as? String, "campaign")
        XCTAssertEqual(json?["issue_kind"] as? String, "subscription_required")
        XCTAssertEqual(json?["campaign_id"] as? String, "camp-1")
        XCTAssertEqual(json?["help_url"] as? String, "https://swiftminer.app/help/subscription-required-drops/")
    }

    /// Existing SwiftBot builds must keep decoding payloads that predate these
    /// fields, and SwiftMiner must keep decoding its own logged payloads.
    func testPayloadsWithoutTheNewFieldsStillDecode() throws {
        let legacy = """
        {"message_type":"welcome","debug":false,"priority_games":[]}
        """
        let request = try JSONDecoder().decode(SwiftBotDMRequest.self, from: Data(legacy.utf8))

        XCTAssertEqual(request.messageType, .welcome)
        XCTAssertNil(request.portalURL)
        XCTAssertNil(request.portalDestination)
        XCTAssertNil(request.issueKind)
        XCTAssertNil(request.helpURL)
    }
}
