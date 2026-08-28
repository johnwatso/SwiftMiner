import XCTest
@testable import SwiftMiner

@MainActor
final class ApplicationsFolderInstallerTests: XCTestCase {
    func testDetectsAppLocatedInDownloadsOrSubdirectory() {
        let downloadsURL = URL(fileURLWithPath: "/Users/example/Downloads", isDirectory: true)

        XCTAssertTrue(
            ApplicationsFolderInstaller.isLocatedInDownloads(
                bundleURL: downloadsURL.appendingPathComponent("SwiftMiner.app", isDirectory: true),
                downloadsDirectoryURL: downloadsURL
            )
        )
        XCTAssertTrue(
            ApplicationsFolderInstaller.isLocatedInDownloads(
                bundleURL: downloadsURL
                    .appendingPathComponent("SwiftMiner 1.37.2", isDirectory: true)
                    .appendingPathComponent("SwiftMiner.app", isDirectory: true),
                downloadsDirectoryURL: downloadsURL
            )
        )
    }

    func testDoesNotDetectAppOutsideDownloads() {
        XCTAssertFalse(
            ApplicationsFolderInstaller.isLocatedInDownloads(
                bundleURL: URL(fileURLWithPath: "/Applications/SwiftMiner.app", isDirectory: true),
                downloadsDirectoryURL: URL(fileURLWithPath: "/Users/example/Downloads", isDirectory: true)
            )
        )
    }

    func testTranslocatedBundleUsesTheLaunchServicesLocation() {
        let translocatedBundleURL = URL(
            fileURLWithPath: "/private/var/folders/example/AppTranslocation/SwiftMiner.app",
            isDirectory: true
        )
        let downloadsBundleURL = URL(
            fileURLWithPath: "/Users/example/Downloads/SwiftMiner.app",
            isDirectory: true
        )

        XCTAssertEqual(
            ApplicationsFolderInstaller.sourceBundleURL(
                forRunningBundleURL: translocatedBundleURL,
                registeredBundleURL: downloadsBundleURL
            ),
            downloadsBundleURL
        )
    }

    func testNonTranslocatedBundleDoesNotUseAnUnrelatedRegisteredCopy() {
        let applicationsBundleURL = URL(fileURLWithPath: "/Applications/SwiftMiner.app", isDirectory: true)
        let downloadsBundleURL = URL(
            fileURLWithPath: "/Users/example/Downloads/SwiftMiner.app",
            isDirectory: true
        )

        XCTAssertEqual(
            ApplicationsFolderInstaller.sourceBundleURL(
                forRunningBundleURL: applicationsBundleURL,
                registeredBundleURL: downloadsBundleURL
            ),
            applicationsBundleURL
        )
    }

    func testMoveAppMovesBundleIntoApplicationsDirectory() throws {
        let fileManager = FileManager.default
        let temporaryDirectoryURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryDirectoryURL) }

        let sourceDirectoryURL = temporaryDirectoryURL.appendingPathComponent("Downloads", isDirectory: true)
        let applicationsDirectoryURL = temporaryDirectoryURL.appendingPathComponent("Applications", isDirectory: true)
        let sourceBundleURL = sourceDirectoryURL.appendingPathComponent("SwiftMiner.app", isDirectory: true)
        try fileManager.createDirectory(at: sourceBundleURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: applicationsDirectoryURL, withIntermediateDirectories: true)

        let destinationURL = try ApplicationsFolderInstaller.moveApp(
            from: sourceBundleURL,
            to: applicationsDirectoryURL,
            fileManager: fileManager
        )

        XCTAssertFalse(fileManager.fileExists(atPath: sourceBundleURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: destinationURL.path))
        XCTAssertEqual(destinationURL.lastPathComponent, "SwiftMiner.app")
    }

    func testMoveAppDoesNotReplaceAnExistingApplication() throws {
        let fileManager = FileManager.default
        let temporaryDirectoryURL = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryDirectoryURL) }

        let sourceBundleURL = temporaryDirectoryURL
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("SwiftMiner.app", isDirectory: true)
        let applicationsDirectoryURL = temporaryDirectoryURL.appendingPathComponent("Applications", isDirectory: true)
        let installedBundleURL = applicationsDirectoryURL.appendingPathComponent("SwiftMiner.app", isDirectory: true)
        try fileManager.createDirectory(at: sourceBundleURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: installedBundleURL, withIntermediateDirectories: true)

        XCTAssertThrowsError(
            try ApplicationsFolderInstaller.moveApp(
                from: sourceBundleURL,
                to: applicationsDirectoryURL,
                fileManager: fileManager
            )
        )
        XCTAssertTrue(fileManager.fileExists(atPath: sourceBundleURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: installedBundleURL.path))
    }

    func testRelaunchConfigurationStartsASeparateActivatedInstance() {
        let configuration = ApplicationsFolderInstaller.relaunchConfiguration()

        XCTAssertTrue(configuration.activates)
        XCTAssertTrue(configuration.createsNewApplicationInstance)
    }
}
