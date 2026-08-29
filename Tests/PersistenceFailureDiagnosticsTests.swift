import XCTest
@testable import SwiftMinerCore

/// Covers the storage paths that used to fail silently.
///
/// Each of these once collapsed several very different outcomes — a first launch, a truncated
/// file, a keychain that refused a write — into the same quiet "nothing here". That is the worst
/// shape for an unattended miner: the state an operator reads back after an overnight failure is
/// exactly the state that was being discarded.
final class PersistenceFailureDiagnosticsTests: XCTestCase {

    // MARK: - Unattended health history

    func testFirstLaunchStartsFromAnEmptyHistoryWithoutQuarantining() async throws {
        let fileURL = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let store = UnattendedHealthStore(fileURL: fileURL)

        let snapshots = await store.allSnapshots()
        XCTAssertTrue(snapshots.isEmpty)
        XCTAssertTrue(
            quarantinedFiles(besideStoreAt: fileURL).isEmpty,
            "An absent history is normal on a first launch and must not leave a quarantine file behind."
        )
    }

    func testCorruptHistoryIsMovedAsideInsteadOfBeingOverwritten() async throws {
        let fileURL = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{ \"snapshots\": { truncated".utf8).write(to: fileURL)

        let store = UnattendedHealthStore(fileURL: fileURL)
        let snapshots = await store.allSnapshots()
        XCTAssertTrue(snapshots.isEmpty)

        let quarantined = quarantinedFiles(besideStoreAt: fileURL)
        XCTAssertEqual(
            quarantined.count, 1,
            "A history we could not decode is the only copy of what went wrong overnight; it has to survive the next write."
        )
        XCTAssertEqual(quarantined.first?.pathExtension, "json")

        // The store still works from here, and recording does not resurrect the bad file.
        let observedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.record(.minerObserved(minerID: "miner-1", displayName: "Primary", at: observedAt))
        let reloaded = UnattendedHealthStore(fileURL: fileURL)
        let reloadedSnapshot = await reloaded.snapshot(for: "miner-1")
        XCTAssertEqual(reloadedSnapshot?.displayName, "Primary")
        XCTAssertEqual(quarantinedFiles(besideStoreAt: fileURL).count, 1)
    }

    func testHistoryFromAnUnknownSchemaIsMovedAsideRatherThanDiscarded() async throws {
        let fileURL = temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let future = #"{"schemaVersion":999,"snapshots":{},"incidentHistory":[],"recoveryHistory":{}}"#
        try Data(future.utf8).write(to: fileURL)

        let store = UnattendedHealthStore(fileURL: fileURL)

        let snapshots = await store.allSnapshots()
        XCTAssertTrue(snapshots.isEmpty)
        XCTAssertEqual(
            quarantinedFiles(besideStoreAt: fileURL).count, 1,
            "A downgrade must not silently destroy the history the newer build wrote."
        )
    }

    /// Every caller now reports a failed health write instead of discarding it, which only means
    /// anything while `record` still surfaces one. If this ever goes back to swallowing errors,
    /// all of that error handling becomes dead code and the incident history can stop
    /// accumulating in silence again.
    func testRecordingHealthSurfacesAPersistenceFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftMinerHealthUnwritable-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // A regular file where the store expects its containing directory: `persist()` cannot
        // create the directory, so the write fails the way a full or read-only disk would.
        try Data("not a directory".utf8).write(to: directory)
        let store = UnattendedHealthStore(fileURL: directory.appendingPathComponent("health.json"))

        do {
            try await store.record(.minerObserved(
                minerID: "miner-1",
                displayName: "Primary",
                at: Date(timeIntervalSince1970: 1_800_000_000)
            ))
            XCTFail("Recording into an unwritable location must not report success")
        } catch {
            // Expected.
        }
    }

    // MARK: - Token re-arm

    /// Re-arming pushes the local expiry out so an account with no refresh grant stops re-entering
    /// the refresh path on every request. If the store refuses the write, the token itself is
    /// still perfectly good — dropping the account over a storage fault would take a working miner
    /// offline — so the caller must still get it back.
    func testReArmedTokenWindowKeepsTheAccountUsableWhenTheStoreRefusesTheWrite() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            let body = #"{"client_id":"test_client_id","login":"testuser","scopes":[],"user_id":"user123","expires_in":0}"#
            return (response, Data(body.utf8))
        }
        defer {
            MockURLProtocol.requestHandler = nil
            MockURLProtocol.stubResponseData = nil
            MockURLProtocol.stubError = nil
            MockURLProtocol.lastRequest = nil
        }

        let store = TestTokenStore()
        await store.failSaves(with: NSError(
            domain: "TestTokenStore",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "keychain unavailable"]
        ))
        let service = TwitchAuthService(
            clientId: "test_client_id",
            tokenStore: store,
            urlSession: session
        )

        // No refresh grant and an expiry already in the past: the account can only be revalidated.
        await service.setCurrentAccount(Account(
            id: "user123",
            username: "testuser",
            accessToken: "live_token",
            refreshToken: "",
            tokenExpiry: Date().addingTimeInterval(-60),
            scopes: []
        ))

        let token = try await service.refreshTokenIfNeeded()

        XCTAssertEqual(token, "live_token", "A storage fault must not cost the caller a working token.")
        let authenticated = await service.isAuthenticated
        XCTAssertTrue(
            authenticated,
            "The in-memory window still has to be re-armed, or every request re-enters the refresh path."
        )
        let persisted = try await store.loadAccount(twitchUserId: "user123")
        XCTAssertNil(persisted, "Precondition: the store really did refuse the write.")
    }

    // MARK: - Helpers

    private func temporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftMinerHealthDiagnostics-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("health.json")
    }

    private func quarantinedFiles(besideStoreAt fileURL: URL) -> [URL] {
        let directory = fileURL.deletingLastPathComponent()
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )) ?? []
        return contents.filter { $0.lastPathComponent.contains("corrupt-") }
    }
}
