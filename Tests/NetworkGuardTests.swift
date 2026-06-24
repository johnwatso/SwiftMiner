import XCTest

/// Verifies the fail-fast network guard actually intercepts the escape routes it
/// claims to — primarily `URLSession.shared`, which several services use directly.
final class NetworkGuardTests: XCTestCase {

    func testSharedSessionUnmockedRequestIsBlocked() async {
        // This test deliberately triggers an interception, so don't let the
        // bundle observer record it as an unexpected request.
        NetworkGuard.expectsInterception = true
        defer { NetworkGuard.expectsInterception = false }

        // `.invalid` is reserved (RFC 6761) and never resolves, so even if the
        // guard somehow failed to intercept, this cannot reach a real host.
        let url = URL(string: "https://network-guard.invalid/should-never-be-reached")!

        do {
            _ = try await URLSession.shared.data(from: url)
            XCTFail("Expected the network guard to block this request")
        } catch {
            let nsError = error as NSError
            XCTAssertEqual(
                nsError.domain,
                NetworkGuard.interceptionErrorDomain,
                "Expected guard interception of URLSession.shared, but got "
                    + "\(nsError.domain) (\(nsError.localizedDescription)). "
                    + "If this is NSURLErrorDomain, registerClass did not cover the shared session."
            )
        }
    }
}
