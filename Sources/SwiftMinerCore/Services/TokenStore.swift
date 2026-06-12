import Foundation

/// Protocol for persisting Twitch account tokens (v1.1).
/// Decouples the mining engine core from specific storage implementations (Keychain vs SQLite).
public protocol TokenStore: Sendable {
    /// Persist or update an account. Implementation MUST perform an upsert based on Twitch User ID.
    func save(account: Account) async throws
    
    /// Retrieve all accounts managed by this store.
    func loadAllAccounts() async throws -> [Account]
    
    /// Retrieve a specific account by its stable Twitch User ID.
    func loadAccount(twitchUserId: String) async throws -> Account?
    
    /// Explicitly update token material during refresh cycles.
    func updateTokenMaterial(twitchUserId: String, accessToken: String, refreshToken: String?, expiry: Date) async throws

    /// Update an account's local display nickname without changing token material.
    func updateNickname(twitchUserId: String, nickname: String?) async throws

    /// Update whether an account is designated as operator (limit one operator app-wide).
    func updateOperatorStatus(twitchUserId: String, isOperator: Bool) async throws
    
    /// Remove an account and its tokens from the store.
    func deleteAccount(twitchUserId: String) async throws
}
