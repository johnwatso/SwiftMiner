import AppKit
import Foundation

enum GitHubIssueReporter {
    private static let newIssueURL = "https://github.com/johnwatso/SwiftMiner/issues/new"

    static func openNewIssue(title: String = "[Bug] ", note: String? = nil) {
        var components = URLComponents(string: newIssueURL)!
        components.queryItems = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "body", value: prefilledBody(note: note)),
        ]
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }

    private static func prefilledBody(note: String? = nil) -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        let noteSection = note.map { "\($0)\n\n" } ?? ""
        return """
        \(noteSection)### What happened
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
