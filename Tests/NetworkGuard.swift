import XCTest
import Foundation

/// Process-wide fail-fast guard against unexpected, unmocked network traffic in tests.
///
/// Hosted XCTest launches the full SwiftMiner app, and several services
/// (e.g. `TwitchAuthService`, `SteamArtworkService`) use `URLSession.shared`
/// directly rather than an injected session. A test that forgets to install a
/// mock could otherwise reach the real Twitch/Steam endpoints. This guard
/// registers a catch-all `URLProtocol` for the shared/default session, fails any
/// request that reaches it, and records it so the owning test is flagged.
///
/// Suites that install their own `protocolClasses` (the `MockURLProtocol`-based
/// tests) are unaffected: custom `URLSessionConfiguration`s use only their own
/// `protocolClasses` and bypass the global registry.
enum NetworkGuard {
    static let interceptionErrorDomain = "SwiftMinerTestNetworkGuard"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var isArmed = false
    nonisolated(unsafe) private static var unexpected: [URL] = []

    /// When true, interceptions are not recorded as failures. Used only by the
    /// guard's own verification test, which deliberately triggers an interception.
    nonisolated(unsafe) static var expectsInterception = false

    /// Registers the catch-all protocol globally. Idempotent.
    static func arm() {
        lock.lock(); defer { lock.unlock() }
        guard !isArmed else { return }
        isArmed = true
        URLProtocol.registerClass(GuardURLProtocol.self)
    }

    static func note(_ url: URL?) {
        lock.lock(); defer { lock.unlock() }
        guard !expectsInterception, let url else { return }
        unexpected.append(url)
    }

    /// Returns and clears any unexpected requests seen since the last drain.
    static func drainUnexpected() -> [URL] {
        lock.lock(); defer { lock.unlock() }
        let drained = unexpected
        unexpected.removeAll()
        return drained
    }
}

/// Catch-all `URLProtocol` that fails any request reaching it — i.e. requests made
/// through `URLSession.shared` (or the default configuration) that no test mock
/// intercepted first.
final class GuardURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url
        NetworkGuard.note(url)
        let error = NSError(
            domain: NetworkGuard.interceptionErrorDomain,
            code: 1,
            userInfo: [NSLocalizedDescriptionKey:
                "Unmocked network request to \(url?.absoluteString ?? "<nil>"). " +
                "Install MockURLProtocol on the session under test, or inject a stubbed URLSession."]
        )
        client?.urlProtocol(self, didFailWithError: error)
    }

    override func stopLoading() {}
}

/// Arms `NetworkGuard` at test-bundle startup and flunks any test that produced an
/// unexpected network request. Installed as the test bundle's principal class via
/// `INFOPLIST_KEY_NSPrincipalClass` so it applies to every suite, including ones
/// that forget to set up mocking.
@objc(NetworkGuardBootstrap)
final class NetworkGuardBootstrap: NSObject, XCTestObservation {
    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
        NetworkGuard.arm()
    }

    func testBundleWillStart(_ testBundle: Bundle) {
        NetworkGuard.arm()
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        let leaked = NetworkGuard.drainUnexpected()
        for url in leaked {
            testCase.record(
                XCTIssue(
                    type: .assertionFailure,
                    compactDescription: "Unexpected unmocked network request during "
                        + "\(testCase.name): \(url.absoluteString)"
                )
            )
        }
    }
}
