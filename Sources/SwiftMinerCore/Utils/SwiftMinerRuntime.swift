import Foundation

/// Process-wide runtime facts shared by the app and core targets.
///
/// Hosted XCTest bundles launch the full SwiftMiner application. Keep that
/// process distinguishable from an ordinary Debug run so tests cannot load the
/// developer's saved accounts or start background integrations.
public enum SwiftMinerRuntime {
    public static let isRunningTests =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    public static let testSupportDirectory: URL = {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftMinerTests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    }()
}
