import AppKit
import Foundation

enum GitHubIssueReporter {
    private static let newIssueURL = "https://github.com/johnwatso/SwiftMiner/issues/new"

    static func openNewIssue() {
        var components = URLComponents(string: newIssueURL)!
        components.queryItems = [
            URLQueryItem(name: "title", value: "[Bug] "),
            URLQueryItem(name: "body", value: prefilledBody()),
        ]
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }

    private static func prefilledBody() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        return """
        ### What happened
        <!-- Briefly describe the issue. -->

        ### Steps to reproduce
        1.
        2.
        3.

        ### Expected behavior


        ### Environment
        - SwiftMiner: \(version) (build \(build))
        - macOS: \(os)
        """
    }
}
