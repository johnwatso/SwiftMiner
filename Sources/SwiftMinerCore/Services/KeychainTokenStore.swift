import Foundation
import CryptoKit

/// Why the legacy encrypted account file could not be read.
///
/// A missing file is *not* an error — it is the empty state. These cases mean the file exists
/// but its contents could not be recovered, which callers must never mistake for "no accounts".
public enum LegacyTokenStoreError: LocalizedError {
    /// The file exists but could not be read from disk (permissions, I/O).
    case unreadable(underlying: Error)
    /// The file was read but could not be decrypted or decoded — typically because the
    /// hardware UUID the key is derived from has changed (restored backup, new machine).
    case undecryptable(underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let underlying):
            return "The saved accounts file could not be read: \(underlying.localizedDescription)"
        case .undecryptable(let underlying):
            return "The saved accounts file could not be decrypted on this Mac: \(underlying.localizedDescription)"
        }
    }
}

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

    /// Reads the store, distinguishing "there is nothing here" from "there is something here
    /// that cannot be read".
    ///
    /// An absent file is the empty state and returns `[]`. Anything else — an unreadable file,
    /// a file this machine's key cannot decrypt, a payload that no longer decodes — throws.
    /// Collapsing those into `[]` is what let a single bad read look like "no accounts", which
    /// in turn let the migration mark itself complete and offer to delete the only copy of the
    /// user's credentials.
    private func readAll() throws -> [Account] {
        let encrypted: Data
        do {
            encrypted = try Data(contentsOf: storageURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return []
        } catch {
            Logger.storage.error("Legacy account file unreadable: \(error.localizedDescription)")
            throw LegacyTokenStoreError.unreadable(underlying: error)
        }

        do {
            let box = try AES.GCM.SealedBox(combined: encrypted)
            let plaintext = try AES.GCM.open(box, using: encryptionKey)
            return try JSONDecoder().decode([Account].self, from: plaintext)
        } catch {
            Logger.storage.error("Decryption failed: \(error.localizedDescription)")
            throw LegacyTokenStoreError.undecryptable(underlying: error)
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
        var accounts = try readAll()
        accounts.removeAll { $0.id == account.id }
        accounts.append(account)
        try writeAll(accounts)
    }

    public func loadAllAccounts() async throws -> [Account] {
        return try readAll()
    }

    public func loadAccount(twitchUserId: String) async throws -> Account? {
        return try readAll().first { $0.id == twitchUserId }
    }

    public func updateTokenMaterial(twitchUserId: String, accessToken: String, refreshToken: String?, expiry: Date) async throws {
        var accounts = try readAll()
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
        var accounts = try readAll()
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
        var accounts = try readAll()
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
        var accounts = try readAll()
        accounts.removeAll { $0.id == twitchUserId }
        try writeAll(accounts)
    }
}
