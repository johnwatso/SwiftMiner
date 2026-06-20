import XCTest
import Security
@testable import SwiftMinerCore

/// Exercises the real-Keychain account store. Each test uses a unique throwaway
/// `kSecAttrService` so it never collides with the user's real account items, and
/// `tearDown` sweeps every item created under that service.
final class KeychainAccountStoreTests: XCTestCase {
    private var service: String = ""

    override func setUp() {
        super.setUp()
        service = "com.swiftminer.tests.accounts.\(UUID().uuidString)"
    }

    override func tearDown() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        SecItemDelete(query as CFDictionary)
        super.tearDown()
    }

    private func makeAccount(id: String, isOperator: Bool = false) -> Account {
        Account(
            id: id,
            username: "user-\(id)",
            accessToken: "access-\(id)",
            refreshToken: "refresh-\(id)",
            tokenExpiry: Date().addingTimeInterval(3600),
            scopes: ["channel:read"],
            isOperator: isOperator
        )
    }

    func testSaveLoadRoundTrip() async throws {
        let store = KeychainAccountStore(service: service)
        try await store.save(account: makeAccount(id: "twitch-1"))

        let loadedOpt = try await store.loadAccount(twitchUserId: "twitch-1")
        let loaded = try XCTUnwrap(loadedOpt)
        XCTAssertEqual(loaded.username, "user-twitch-1")
        XCTAssertEqual(loaded.accessToken, "access-twitch-1")
        XCTAssertEqual(loaded.refreshToken, "refresh-twitch-1")
        XCTAssertEqual(loaded.scopes, ["channel:read"])

        let all = try await store.loadAllAccounts()
        XCTAssertEqual(all.count, 1)
    }

    func testSaveUpsertsByID() async throws {
        let store = KeychainAccountStore(service: service)
        try await store.save(account: makeAccount(id: "twitch-1"))

        let updated = Account(
            id: "twitch-1", username: "renamed",
            accessToken: "a", refreshToken: "r",
            tokenExpiry: Date().addingTimeInterval(3600), scopes: []
        )
        try await store.save(account: updated)

        let all = try await store.loadAllAccounts()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.username, "renamed")
    }

    func testUpdateTokenMaterialPreservesOtherFields() async throws {
        let store = KeychainAccountStore(service: service)
        try await store.save(account: makeAccount(id: "twitch-1"))

        let newExpiry = Date().addingTimeInterval(7200)
        try await store.updateTokenMaterial(twitchUserId: "twitch-1", accessToken: "new-access", refreshToken: nil, expiry: newExpiry)

        let loadedOpt = try await store.loadAccount(twitchUserId: "twitch-1")
        let loaded = try XCTUnwrap(loadedOpt)
        XCTAssertEqual(loaded.accessToken, "new-access")
        XCTAssertEqual(loaded.refreshToken, "refresh-twitch-1") // preserved when nil passed
        XCTAssertEqual(loaded.username, "user-twitch-1")
        XCTAssertEqual(loaded.tokenExpiry.timeIntervalSince1970, newExpiry.timeIntervalSince1970, accuracy: 0.001)
    }

    func testUpdateNickname() async throws {
        let store = KeychainAccountStore(service: service)
        try await store.save(account: makeAccount(id: "twitch-1"))

        try await store.updateNickname(twitchUserId: "twitch-1", nickname: "Boss")
        let loadedOpt = try await store.loadAccount(twitchUserId: "twitch-1")
        let loaded = try XCTUnwrap(loadedOpt)
        XCTAssertEqual(loaded.nickname, "Boss")
    }

    func testOperatorExclusivity() async throws {
        let store = KeychainAccountStore(service: service)
        try await store.save(account: makeAccount(id: "twitch-1"))
        try await store.save(account: makeAccount(id: "twitch-2"))

        try await store.updateOperatorStatus(twitchUserId: "twitch-1", isOperator: true)
        let a1Opt = try await store.loadAccount(twitchUserId: "twitch-1")
        let a2Opt = try await store.loadAccount(twitchUserId: "twitch-2")
        let a1 = try XCTUnwrap(a1Opt)
        let a2 = try XCTUnwrap(a2Opt)
        XCTAssertTrue(a1.isOperator)
        XCTAssertFalse(a2.isOperator)

        // Designating a second operator clears the first.
        try await store.updateOperatorStatus(twitchUserId: "twitch-2", isOperator: true)
        let a1AfterOpt = try await store.loadAccount(twitchUserId: "twitch-1")
        let a2AfterOpt = try await store.loadAccount(twitchUserId: "twitch-2")
        let a1After = try XCTUnwrap(a1AfterOpt)
        let a2After = try XCTUnwrap(a2AfterOpt)
        XCTAssertFalse(a1After.isOperator)
        XCTAssertTrue(a2After.isOperator)
    }

    func testDeleteAccount() async throws {
        let store = KeychainAccountStore(service: service)
        try await store.save(account: makeAccount(id: "twitch-1"))

        try await store.deleteAccount(twitchUserId: "twitch-1")
        let loaded = try await store.loadAccount(twitchUserId: "twitch-1")
        XCTAssertNil(loaded)
        let all = try await store.loadAllAccounts()
        XCTAssertTrue(all.isEmpty)

        // Deleting a missing account is a no-op, not an error.
        try await store.deleteAccount(twitchUserId: "twitch-1")
    }
}
