import Foundation

/// Chooses the default account `TokenStore` for the macOS app based on build configuration.
///
/// - Release: the real macOS Keychain (`KeychainAccountStore`).
/// - DEBUG: the legacy hardware-UUID encrypted file (`KeychainTokenStore`), so development
///   never reads or writes the real login Keychain.
///
/// The legacy store stays compiled in all builds because it is both the DEBUG store and the
/// one-time migration's read source (see `LegacyAccountMigrator`).
public enum TokenStoreFactory {
    public static func makeDefault() -> any TokenStore {
        if SwiftMinerRuntime.isRunningTests {
            return InMemoryTokenStore()
        }
        #if DEBUG
        return KeychainTokenStore()
        #else
        return KeychainAccountStore()
        #endif
    }
}
