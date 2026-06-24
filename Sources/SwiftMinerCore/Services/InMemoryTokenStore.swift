import Foundation

/// Ephemeral account storage used by the hosted XCTest process.
///
/// Each instance starts empty and never reads the developer or production
/// account stores.
public actor InMemoryTokenStore: TokenStore {
    private var accountsByID: [String: Account]

    public init(accounts: [Account] = []) {
        self.accountsByID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
    }

    public func save(account: Account) {
        if account.isOperator {
            clearOtherOperators(except: account.id)
        }
        accountsByID[account.id] = account
    }

    public func loadAllAccounts() -> [Account] {
        accountsByID.values.sorted { $0.id < $1.id }
    }

    public func loadAccount(twitchUserId: String) -> Account? {
        accountsByID[twitchUserId]
    }

    public func updateTokenMaterial(
        twitchUserId: String,
        accessToken: String,
        refreshToken: String?,
        expiry: Date
    ) {
        guard let existing = accountsByID[twitchUserId] else { return }
        accountsByID[twitchUserId] = copy(
            existing,
            accessToken: accessToken,
            refreshToken: refreshToken ?? existing.refreshToken,
            tokenExpiry: expiry
        )
    }

    public func updateNickname(twitchUserId: String, nickname: String?) {
        guard let existing = accountsByID[twitchUserId] else { return }
        accountsByID[twitchUserId] = Account(
            id: existing.id,
            username: existing.username,
            nickname: Account.normalizedNickname(nickname),
            ownerDiscordId: existing.ownerDiscordId,
            accessToken: existing.accessToken,
            refreshToken: existing.refreshToken,
            tokenExpiry: existing.tokenExpiry,
            scopes: existing.scopes,
            isOperator: existing.isOperator
        )
    }

    public func updateOperatorStatus(twitchUserId: String, isOperator: Bool) {
        guard let existing = accountsByID[twitchUserId] else { return }
        if isOperator {
            clearOtherOperators(except: twitchUserId)
        }
        accountsByID[twitchUserId] = copy(existing, isOperator: isOperator)
    }

    public func deleteAccount(twitchUserId: String) {
        accountsByID.removeValue(forKey: twitchUserId)
    }

    private func clearOtherOperators(except accountID: String) {
        for account in accountsByID.values where account.id != accountID && account.isOperator {
            accountsByID[account.id] = copy(account, isOperator: false)
        }
    }

    private func copy(
        _ account: Account,
        nickname: String? = nil,
        accessToken: String? = nil,
        refreshToken: String? = nil,
        tokenExpiry: Date? = nil,
        isOperator: Bool? = nil
    ) -> Account {
        Account(
            id: account.id,
            username: account.username,
            nickname: nickname ?? account.nickname,
            ownerDiscordId: account.ownerDiscordId,
            accessToken: accessToken ?? account.accessToken,
            refreshToken: refreshToken ?? account.refreshToken,
            tokenExpiry: tokenExpiry ?? account.tokenExpiry,
            scopes: account.scopes,
            isOperator: isOperator ?? account.isOperator
        )
    }
}
