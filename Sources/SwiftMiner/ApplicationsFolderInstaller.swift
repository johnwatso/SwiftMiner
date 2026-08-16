import AppKit
import Foundation

/// Offers to place a manually downloaded copy of the app in `/Applications`.
///
/// Sparkle updates are already installed in place, so this only runs for copies
/// opened from the user's Downloads directory.
@MainActor
enum ApplicationsFolderInstaller {
    private static let applicationsDirectoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)

    static func promptToMoveIfNecessary(bundleURL: URL = Bundle.main.bundleURL) {
        let downloadsDirectoryURL = FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first

        let registeredBundleURL = Bundle.main.bundleIdentifier.flatMap {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        }
        let installableBundleURL = sourceBundleURL(
            forRunningBundleURL: bundleURL,
            registeredBundleURL: registeredBundleURL
        )

        guard let downloadsDirectoryURL,
              isLocatedInDownloads(bundleURL: installableBundleURL, downloadsDirectoryURL: downloadsDirectoryURL)
        else {
            return
        }

        let alert = NSAlert()
        alert.messageText = "Move SwiftMiner to Applications?"
        alert.informativeText = "Keeping SwiftMiner in Applications makes it easier to find and lets macOS manage updates reliably."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        moveAndRelaunch(bundleURL: installableBundleURL)
    }

    static func isLocatedInDownloads(bundleURL: URL, downloadsDirectoryURL: URL) -> Bool {
        let bundlePath = bundleURL.standardizedFileURL.path
        let downloadsPath = downloadsDirectoryURL.standardizedFileURL.path
        return bundlePath.hasPrefix(downloadsPath + "/")
    }

    static func destinationURL(for bundleURL: URL, applicationsDirectoryURL: URL) -> URL {
        applicationsDirectoryURL.appendingPathComponent(bundleURL.lastPathComponent, isDirectory: true)
    }

    /// Gatekeeper can run a downloaded app from a private App Translocation path.
    /// In that case Launch Services retains the original bundle location, which is
    /// the copy we need to move into Applications.
    static func sourceBundleURL(forRunningBundleURL bundleURL: URL, registeredBundleURL: URL?) -> URL {
        guard bundleURL.path.contains("/AppTranslocation/"), let registeredBundleURL else {
            return bundleURL
        }
        return registeredBundleURL
    }

    static func moveApp(
        from bundleURL: URL,
        to applicationsDirectoryURL: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let destinationURL = destinationURL(for: bundleURL, applicationsDirectoryURL: applicationsDirectoryURL)
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw MoveError.destinationAlreadyExists(destinationURL)
        }

        try fileManager.moveItem(at: bundleURL, to: destinationURL)
        return destinationURL
    }

    private static func moveAndRelaunch(bundleURL: URL) {
        do {
            let destinationURL = try moveApp(from: bundleURL, to: applicationsDirectoryURL)
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: destinationURL, configuration: configuration) { _, error in
                Task { @MainActor in
                    if let error {
                        presentMoveError(error)
                    } else {
                        NSApp.terminate(nil)
                    }
                }
            }
        } catch {
            presentMoveError(error)
        }
    }

    private static func presentMoveError(_ error: Error) {
        let alert = NSAlert(error: error)
        alert.messageText = "SwiftMiner couldn't move to Applications"
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }

    private enum MoveError: LocalizedError {
        case destinationAlreadyExists(URL)

        var errorDescription: String? {
            switch self {
            case let .destinationAlreadyExists(destinationURL):
                "A copy of SwiftMiner already exists at \(destinationURL.path). Remove or rename that copy, then try again."
            }
        }
    }
}
