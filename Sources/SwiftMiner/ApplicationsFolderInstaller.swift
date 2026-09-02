import AppKit
import CoreServices
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
        guard let downloadsDirectoryURL else { return }

        let registeredBundleURLs = Bundle.main.bundleIdentifier.map(registeredApplicationURLs) ?? []
        let installableBundleURL = sourceBundleURL(
            forRunningBundleURL: bundleURL,
            registeredBundleURLs: registeredBundleURLs,
            downloadsDirectoryURL: downloadsDirectoryURL
        )

        guard isLocatedInDownloads(
            bundleURL: installableBundleURL,
            downloadsDirectoryURL: downloadsDirectoryURL
        ) else {
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
    /// Launch Services may know about both that Downloads copy and an older installed
    /// copy. Prefer the Downloads candidate instead of whichever one happens to be
    /// returned first for the shared bundle identifier.
    static func sourceBundleURL(
        forRunningBundleURL bundleURL: URL,
        registeredBundleURLs: [URL],
        downloadsDirectoryURL: URL
    ) -> URL {
        guard bundleURL.path.contains("/AppTranslocation/") else {
            return bundleURL
        }
        let downloadsCandidates = registeredBundleURLs.filter {
            isLocatedInDownloads(bundleURL: $0, downloadsDirectoryURL: downloadsDirectoryURL)
        }
        return downloadsCandidates.first {
            $0.lastPathComponent == bundleURL.lastPathComponent
        } ?? downloadsCandidates.first ?? bundleURL
    }

    private static func registeredApplicationURLs(bundleIdentifier: String) -> [URL] {
        guard let urls = LSCopyApplicationURLsForBundleIdentifier(bundleIdentifier as CFString, nil)?
            .takeRetainedValue() as? [URL] else {
            return []
        }
        return urls
    }

    static func moveApp(
        from bundleURL: URL,
        to applicationsDirectoryURL: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let destinationURL = destinationURL(for: bundleURL, applicationsDirectoryURL: applicationsDirectoryURL)
        if fileManager.fileExists(atPath: destinationURL.path) {
            // Manual downloads are commonly launched while an older SwiftMiner is
            // already installed. Replace it atomically after the user accepts the
            // move prompt instead of requiring a trip to Finder first.
            return try fileManager.replaceItemAt(
                destinationURL,
                withItemAt: bundleURL,
                backupItemName: nil,
                options: [.usingNewMetadataOnly]
            ) ?? destinationURL
        }

        try fileManager.moveItem(at: bundleURL, to: destinationURL)
        return destinationURL
    }

    static func relaunchConfiguration() -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // The Downloads copy is still running when this request is made. Without
        // a new instance, Launch Services can simply activate that process; the
        // subsequent termination then leaves no copy of SwiftMiner open.
        configuration.createsNewApplicationInstance = true
        return configuration
    }

    private static func moveAndRelaunch(bundleURL: URL) {
        do {
            let destinationURL = try moveApp(from: bundleURL, to: applicationsDirectoryURL)
            let configuration = relaunchConfiguration()
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
}
