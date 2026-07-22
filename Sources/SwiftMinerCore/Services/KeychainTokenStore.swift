import Foundation
import CryptoKit

/// Implementation of TokenStore using the local encrypted file (legacy "Keychain" storage).
/// Used by the macOS App for backward compatibility.
public actor KeychainTokenStore: TokenStore {
    private let directoryName = "com.swiftminer"
    private let fileName = "accounts.enc"

    public init() {}

    private var storageDir: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent(directoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var storageURL: URL {
        storageDir.appendingPathComponent(fileName)
    }

    private var encryptionKey: SymmetricKey {
        let uuid = hardwareUUID()
        let inputKey = SymmetricKey(data: Data(uuid.utf8))
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: Data("com.swiftminer.accounts".utf8),
            info: Data("aes-256-gcm".utf8),
            outputByteCount: 32
        )
    }

    private func hardwareUUID() -> String {
        // Implementation from original KeychainStorage
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        defer { if service != 0 { IOObjectRelease(service) } }
        if let uuidData = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0),
           let uuid = uuidData.takeRetainedValue() as? String {
            return uuid
        }
        return ProcessInfo.processInfo.hostName
    }

    private func readAll() -> [Account] {
        guard let encrypted = try? Data(contentsOf: storageURL) else { return [] }
        do {
            let box = try AES.GCM.SealedBox(combined: encrypted)
            let plaintext = try AES.GCM.open(box, using: encryptionKey)
            return try JSONDecoder().decode([Account].self, from: plaintext)
        } catch {
            Logger.storage.error("Decryption failed: \(error.localizedDescription)")
            return []
        }
    }

    private func writeAll(_ accounts: [Account]) throws {
        let plaintext = try JSONEncoder().encode(accounts)
        let sealed = try AES.GCM.seal(plaintext, using: encryptionKey)
        guard let combined = sealed.combined else {
            throw NSError(domain: "com.swiftminer.error", code: -1, userInfo: [NSLocalizedDescriptionKey: "Encryption failed"])
        }
        try combined.write(to: storageURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storageURL.path)
    }

    // MARK: - TokenStore Conformance

    public func save(account: Account) async throws {
        var accounts = readAll()
        accounts.removeAll { $0.id == account.id }
        accounts.append(account)
        try writeAll(accounts)
    }

    public func loadAllAccounts() async throws -> [Account] {
        return readAll()
    }

    public func loadAccount(twitchUserId: String) async throws -> Account? {
        return readAll().first { $0.id == twitchUserId }
    }

    public func updateTokenMaterial(twitchUserId: String, accessToken: String, refreshToken: String?, expiry: Date) async throws {
        var accounts = readAll()
        guard let index = accounts.firstIndex(where: { $0.id == twitchUserId }) else { return }
        
        let existing = accounts[index]
        let updated = Account(
            id: existing.id,
            username: existing.username,
            nickname: existing.nickname,
            ownerDiscordId: existing.ownerDiscordId,
            accessToken: accessToken,
            refreshToken: refreshToken ?? existing.refreshToken,
            tokenExpiry: expiry,
            scopes: existing.scopes,
            isOperator: existing.isOperator
        )
        accounts[index] = updated
        try writeAll(accounts)
    }

    public func updateNickname(twitchUserId: String, nickname: String?) async throws {
        var accounts = readAll()
        guard let index = accounts.firstIndex(where: { $0.id == twitchUserId }) else { return }

        let existing = accounts[index]
        accounts[index] = Account(
            id: existing.id,
            username: existing.username,
            nickname: nickname,
            ownerDiscordId: existing.ownerDiscordId,
            accessToken: existing.accessToken,
            refreshToken: existing.refreshToken,
            tokenExpiry: existing.tokenExpiry,
            scopes: existing.scopes,
            isOperator: existing.isOperator
        )
        try writeAll(accounts)
    }

    public func updateOperatorStatus(twitchUserId: String, isOperator: Bool) async throws {
        var accounts = readAll()
        if isOperator {
            for idx in accounts.indices {
                if accounts[idx].id != twitchUserId && accounts[idx].isOperator {
                    let existing = accounts[idx]
                    accounts[idx] = Account(
                        id: existing.id,
                        username: existing.username,
                        nickname: existing.nickname,
                        ownerDiscordId: existing.ownerDiscordId,
                        accessToken: existing.accessToken,
                        refreshToken: existing.refreshToken,
                        tokenExpiry: existing.tokenExpiry,
                        scopes: existing.scopes,
                        isOperator: false
                    )
                }
            }
        }
        guard let index = accounts.firstIndex(where: { $0.id == twitchUserId }) else {
            try writeAll(accounts)
            return
        }
        let existing = accounts[index]
        accounts[index] = Account(
            id: existing.id,
            username: existing.username,
            nickname: existing.nickname,
            ownerDiscordId: existing.ownerDiscordId,
            accessToken: existing.accessToken,
            refreshToken: existing.refreshToken,
            tokenExpiry: existing.tokenExpiry,
            scopes: existing.scopes,
            isOperator: isOperator
        )
        try writeAll(accounts)
    }

    public func deleteAccount(twitchUserId: String) async throws {
        var accounts = readAll()
        accounts.removeAll { $0.id == twitchUserId }
        try writeAll(accounts)
    }
}
