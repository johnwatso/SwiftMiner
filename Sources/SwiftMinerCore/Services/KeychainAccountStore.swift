import Foundation
import Security

/// `TokenStore` backed by the real macOS Keychain.
///
/// Each account is stored as its own `kSecClassGenericPassword` item:
///   - `kSecAttrService`  = the accounts namespace (`com.swiftminer.accounts`)
///   - `kSecAttrAccount`  = the stable Twitch user ID (`Account.id`)
///   - `kSecValueData`    = the JSON-encoded `Account`
///
/// This is the production store on Release builds. DEBUG builds keep using the legacy
/// `KeychainTokenStore` (hardware-UUID encrypted file) so development never touches the
/// real login Keychain. Mirrors the proven `SecItem` pattern used for the web-dashboard
/// password in `Settings.swift`.
public actor KeychainAccountStore: TokenStore {
    private let service: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// - Parameter service: the `kSecAttrService` namespace. Override only in tests so they
    ///   don't collide with real account items in the login Keychain.
    public init(service: String = "com.swiftminer.accounts") {
        self.service = service
    }

    // MARK: - TokenStore

    public func save(account: Account) async throws {
        try upsert(account)
    }

    public func loadAllAccounts() async throws -> [Account] {
        try readAll()
    }

    public func loadAccount(twitchUserId: String) async throws -> Account? {
        try read(twitchUserId: twitchUserId)
    }

    public func updateTokenMaterial(twitchUserId: String, accessToken: String, refreshToken: String?, expiry: Date) async throws {
        guard let existing = try read(twitchUserId: twitchUserId) else { return }
        try upsert(Account(
            id: existing.id,
            username: existing.username,
            nickname: existing.nickname,
            ownerDiscordId: existing.ownerDiscordId,
            accessToken: accessToken,
            refreshToken: refreshToken ?? existing.refreshToken,
            tokenExpiry: expiry,
            scopes: existing.scopes,
            isOperator: existing.isOperator
        ))
    }

    public func updateNickname(twitchUserId: String, nickname: String?) async throws {
        guard let existing = try read(twitchUserId: twitchUserId) else { return }
        try upsert(Account(
            id: existing.id,
            username: existing.username,
            nickname: nickname,
            ownerDiscordId: existing.ownerDiscordId,
            accessToken: existing.accessToken,
            refreshToken: existing.refreshToken,
            tokenExpiry: existing.tokenExpiry,
            scopes: existing.scopes,
            isOperator: existing.isOperator
        ))
    }

    public func updateOperatorStatus(twitchUserId: String, isOperator: Bool) async throws {
        // Preserve the single-operator-app-wide invariant: clear any other operator first.
        if isOperator {
            for account in try readAll() where account.id != twitchUserId && account.isOperator {
                try upsert(account.withOperator(false))
            }
        }
        guard let existing = try read(twitchUserId: twitchUserId) else { return }
        try upsert(existing.withOperator(isOperator))
    }

    public func deleteAccount(twitchUserId: String) async throws {
        let status = SecItemDelete(itemQuery(twitchUserId: twitchUserId) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status, operation: "delete")
        }
    }

    // MARK: - Synchronous Keychain helpers

    private func upsert(_ account: Account) throws {
        let data = try encoder.encode(account)
        let query = itemQuery(twitchUserId: account.id)

        let updateStatus = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw keychainError(updateStatus, operation: "update")
        }

        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw keychainError(addStatus, operation: "save")
        }
    }

    private func read(twitchUserId: String) throws -> Account? {
        var query = itemQuery(twitchUserId: twitchUserId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw keychainError(status, operation: "load") }
        guard let data = result as? Data else { return nil }
        return try decoder.decode(Account.self, from: data)
    }

    private func readAll() throws -> [Account] {
        // The macOS file keychain rejects a `kSecMatchLimitAll` query that also asks for data
        // (errSecParam). So enumerate attributes only to collect the account IDs, then fetch each
        // item's data with the single-item read that the file keychain does support.
        try allAccountIDs().compactMap { try read(twitchUserId: $0) }
    }

    private func allAccountIDs() throws -> [String] {
        var query = baseQuery()
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnAttributes as String] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw keychainError(status, operation: "load") }
        guard let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
    }

    private func itemQuery(twitchUserId: String) -> [String: Any] {
        var query = baseQuery()
        query[kSecAttrAccount as String] = twitchUserId
        return query
    }

    private func keychainError(_ status: OSStatus, operation: String) -> NSError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return NSError(
            domain: "SwiftMiner.KeychainAccountStore",
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: "Could not \(operation) account in Keychain: \(message)"]
        )
    }
}

private extension Account {
    /// A copy with `isOperator` flipped, preserving all other fields.
    func withOperator(_ value: Bool) -> Account {
        Account(
            id: id,
            username: username,
            nickname: nickname,
            ownerDiscordId: ownerDiscordId,
            accessToken: accessToken,
            refreshToken: refreshToken,
            tokenExpiry: tokenExpiry,
            scopes: scopes,
            isOperator: value
        )
    }
}
