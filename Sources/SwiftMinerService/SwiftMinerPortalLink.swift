import Foundation

/// Builds deep links into the operator's web portal for Discord DMs.
///
/// A DM that tells someone to do something should hand them the place to do it.
/// The portal is a single-page app, so every destination is a fragment route
/// under `/app` — see `WebDashboardAssets.appJS`, which parses the same routes.
///
/// The whole builder is optional by design: when the portal has no reachable
/// public URL there is nothing honest to link to, and every method returns nil
/// so SwiftBot renders a DM with no button rather than a dead one.
public struct SwiftMinerPortalLink: Sendable, Equatable {
    /// Portal origin, already validated and stripped of any trailing slash.
    public let base: String

    /// Fails when `base` is not an absolute http(s) URL with a host — the same
    /// bar `Settings.normalizedWebDashboardURL` applies before storing it.
    public init?(base rawBase: String?) {
        guard let rawBase else { return nil }
        let trimmed = rawBase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host,
              !host.isEmpty else {
            return nil
        }
        var absolute = url.absoluteString
        while absolute.hasSuffix("/") { absolute.removeLast() }
        guard !absolute.isEmpty else { return nil }
        self.base = absolute
    }

    // MARK: - Destinations

    public func url(for destination: SwiftBotPortalDestination, id: String? = nil) -> String? {
        switch destination {
        case .dashboard:
            return dashboard
        case .miner:
            return id.flatMap(miner(accountId:))
        case .accountConnection:
            return accountConnection
        case .campaign:
            return id.flatMap(campaign(id:))
        case .campaigns:
            return campaigns
        case .drops:
            return drops
        }
    }

    public var dashboard: String { "\(base)/app" }

    public var accountConnection: String { route("account/connection") }

    public var campaigns: String { route("campaigns") }

    public var drops: String { route("drops") }

    /// A specific miner's detail page. Only meaningful for an operator session
    /// that can see more than one miner; a single-miner session lands on its
    /// own page regardless.
    public func miner(accountId: String) -> String? {
        guard let slug = slug(accountId) else { return nil }
        return route("miner/\(slug)")
    }

    public func campaign(id: String) -> String? {
        guard let slug = slug(id) else { return nil }
        return route("campaign/\(slug)")
    }

    // MARK: - Helpers

    private func route(_ path: String) -> String {
        "\(base)/app#/\(path)"
    }

    /// Percent-encodes one path segment, rejecting blanks so a nil id can never
    /// silently produce a route that means "everything".
    private func slug(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? trimmed
    }
}

/// Public help articles on swiftminer.app, paired with the issue they explain.
///
/// These are the "why did this happen / how do I fix it" companion to a portal
/// link. Only articles that actually exist belong here.
public enum SwiftMinerHelpLink {
    public static let base = "https://swiftminer.app/help"

    public static func url(for kind: SwiftBotIssueKind) -> String? {
        switch kind {
        case .connectionExpired:
            return "\(base)/troubleshooting/"
        case .accountLinkRequired:
            return "\(base)/twitch-drops-not-progressing/"
        case .subscriptionRequired:
            return "\(base)/subscription-required-drops/"
        case .unknown:
            return nil
        }
    }

    public static let webDashboard = "\(base)/web-dashboard/"
}
