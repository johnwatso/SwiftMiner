import XCTest
@testable import SwiftMiner
import SwiftMinerService

/// The DEBUG preview section in Settings → Integrations is how DM rendering is
/// actually looked at, so its payload has to match what production sends. It
/// previously omitted the portal fields entirely, which made every preview
/// render as though no portal were configured.
@MainActor
final class DMPreviewPayloadTests: XCTestCase {

    func testEveryMessageTypeHasAPreviewDestination() {
        for type in SwiftBotDMMessageType.allCases {
            let destination = IntegrationsSettingsView.debugPortalDestination(for: type)
            XCTAssertFalse(
                destination.suggestedButtonLabel.isEmpty,
                "\(type.rawValue) has no usable preview destination"
            )
        }
    }

    /// Each preview must land where the matching production send site lands,
    /// or the preview is showing a DM that does not exist.
    func testPreviewDestinationsMatchTheProductionSendSites() {
        let expected: [SwiftBotDMMessageType: SwiftBotPortalDestination] = [
            .reauth: .accountConnection,
            .prioritisedGameNeedsLinking: .campaigns,
            .accountActionRequired: .campaign,
            .campaignDetected: .campaign,
            .campaignCompleted: .drops,
            .welcomeBack: .miner,
            .welcome: .dashboard,
            .linked: .dashboard,
            .webDashboardAvailable: .dashboard
        ]

        for (type, destination) in expected {
            XCTAssertEqual(
                IntegrationsSettingsView.debugPortalDestination(for: type),
                destination,
                type.rawValue
            )
        }
    }

    func testActionableTypesPreviewTheirClassifiedCause() {
        XCTAssertEqual(IntegrationsSettingsView.debugIssueKind(for: .reauth), .connectionExpired)
        XCTAssertEqual(
            IntegrationsSettingsView.debugIssueKind(for: .prioritisedGameNeedsLinking),
            .accountLinkRequired
        )
        XCTAssertEqual(
            IntegrationsSettingsView.debugIssueKind(for: .accountActionRequired),
            .subscriptionRequired
        )
    }

    /// Informational DMs have no problem to name, so they must not claim one.
    func testInformationalTypesCarryNoIssueKind() {
        for type in [SwiftBotDMMessageType.welcome, .linked, .campaignCompleted, .campaignDetected, .welcomeBack] {
            XCTAssertNil(IntegrationsSettingsView.debugIssueKind(for: type), type.rawValue)
        }
    }

    /// Every issue kind a preview can produce must have a help article behind it.
    func testPreviewIssueKindsAllResolveToHelpArticles() {
        for type in SwiftBotDMMessageType.allCases {
            guard let kind = IntegrationsSettingsView.debugIssueKind(for: type) else { continue }
            XCTAssertNotNil(SwiftMinerHelpLink.url(for: kind), "\(type.rawValue) → \(kind.rawValue)")
        }
    }
}
