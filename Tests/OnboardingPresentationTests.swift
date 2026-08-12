import XCTest
@testable import SwiftMinerCore
@testable import SwiftMiner

@MainActor
final class OnboardingPresentationTests: XCTestCase {

    var navigation: NavigationModel!
    var settings: Settings!
    var minerManager: MinerManager!

    override func setUp() {
        super.setUp()
        settings = Settings.shared
        settings.resetToDefaults()
        
        minerManager = MinerManager(clientId: "test")
        navigation = NavigationModel(clientId: "test", minerManager: minerManager)
    }

    // MARK: - Tests

    func test_0Accounts_OnboardingHidden() {
        // Given
        XCTAssertTrue(minerManager.miners.isEmpty)
        XCTAssertFalse(settings.hasDismissedOnboarding)
        
        // When
        navigation.refreshOnboardingPresentation()
        
        // Then
        XCTAssertFalse(navigation.showOnboarding)
        XCTAssertNil(navigation.onboardingPresentation)
    }

    func test_1PlusAccounts_NoPreferences_OnboardingHidden() {
        // Given
        let account = Account(id: "1", username: "test", accessToken: "token", refreshToken: "refresh", tokenExpiry: Date().addingTimeInterval(3600), scopes: [])
        try! minerManager.addAccount(account)
        XCTAssertFalse(minerManager.miners.isEmpty)
        XCTAssertTrue(settings.gamePreferences.isEmpty)
        
        // When
        navigation.refreshOnboardingPresentation()
        
        // Then
        XCTAssertFalse(navigation.showOnboarding)
        XCTAssertNil(navigation.onboardingPresentation)
    }

    func test_1PlusAccounts_Preferences_OnboardingHidden() {
        // Given
        let account = Account(id: "1", username: "test", accessToken: "token", refreshToken: "refresh", tokenExpiry: Date().addingTimeInterval(3600), scopes: [])
        try! minerManager.addAccount(account)
        
        let game = Game(id: "g1", name: "Test Game")
        settings.addGamePreference(game, state: .preferred)
        
        XCTAssertFalse(minerManager.miners.isEmpty)
        XCTAssertFalse(settings.gamePreferences.isEmpty)
        XCTAssertFalse(navigation.isRunningOnboardingSetup)
        
        // When
        navigation.refreshOnboardingPresentation()
        
        // Then
        XCTAssertFalse(navigation.showOnboarding)
        XCTAssertNil(navigation.onboardingPresentation)
    }

    func test_DuplicateAccount_IsRejected() {
        // Given
        let account = Account(id: "1", username: "test", accessToken: "token", refreshToken: "refresh", tokenExpiry: Date().addingTimeInterval(3600), scopes: [])
        try! minerManager.addAccount(account)

        // Then
        XCTAssertThrowsError(try minerManager.addAccount(account)) { error in
            XCTAssertEqual(error as? MinerManager.AccountError, .duplicateAccount(username: "test"))
        }
        XCTAssertEqual(minerManager.miners.count, 1)
    }

    func test_ReauthenticationRejectsADifferentTwitchAccount() async throws {
        let connectedAccount = Account(id: "1", username: "connected", accessToken: "old", refreshToken: "old", tokenExpiry: .distantPast, scopes: [])
        let otherAccount = Account(id: "2", username: "other", accessToken: "new", refreshToken: "new", tokenExpiry: Date().addingTimeInterval(3600), scopes: [])
        let minerId = try minerManager.addAccount(connectedAccount)

        do {
            try await minerManager.replaceAuthentication(for: minerId, with: otherAccount)
            XCTFail("Reauthentication must not replace a miner with a different Twitch account")
        } catch let error as MinerManager.AccountError {
            XCTAssertEqual(
                error,
                .reauthenticationAccountMismatch(expectedUsername: "connected", actualUsername: "other")
            )
        }

        XCTAssertEqual(minerManager.miners.count, 1)
        XCTAssertEqual(minerManager.miners.first?.accountId, connectedAccount.id)
    }

    func test_ReauthenticationClearsTheAuthBlockForTheSameAccount() async throws {
        let expiredAccount = Account(id: "1", username: "connected", accessToken: "old", refreshToken: "old", tokenExpiry: .distantPast, scopes: [])
        let refreshedAccount = Account(id: "1", username: "connected", accessToken: "new", refreshToken: "new", tokenExpiry: Date().addingTimeInterval(3600), scopes: [])
        let minerId = try minerManager.addAccount(expiredAccount)
        minerManager.miners[0].needsAuth = true
        minerManager.miners[0].status = .error

        try await minerManager.replaceAuthentication(for: minerId, with: refreshedAccount)

        XCTAssertFalse(minerManager.miners[0].needsAuth)
        XCTAssertFalse(minerManager.miners[0].isRunning)
        XCTAssertEqual(minerManager.miners[0].status, .idle)
    }

    func test_Dismissed_PanelHidden() {
        // Given
        settings.hasDismissedOnboarding = true
        
        // When
        navigation.refreshOnboardingPresentation()
        
        // Then
        XCTAssertFalse(navigation.showOnboarding)
        XCTAssertNil(navigation.onboardingPresentation)
    }

    func test_SettingsUseIsolatedDefaultsStoreDuringTests() {
        XCTAssertTrue(SwiftMinerRuntime.isRunningTests)
        XCTAssertFalse(
            Settings.appStorageStore === UserDefaults.standard,
            "App-hosted tests must not write Settings changes into the production app defaults domain"
        )
    }

    func test_DefaultTokenStoreStartsEmptyDuringTests() async throws {
        let store = TokenStoreFactory.makeDefault()
        let accounts = try await store.loadAllAccounts()
        XCTAssertTrue(accounts.isEmpty)
        XCTAssertTrue(store is InMemoryTokenStore)
    }

    func test_DefaultTokenStoresDoNotShareAccountsDuringTests() async throws {
        let first = TokenStoreFactory.makeDefault()
        let second = TokenStoreFactory.makeDefault()
        let account = Account(
            id: "isolated",
            username: "isolated",
            accessToken: "token",
            refreshToken: "refresh",
            tokenExpiry: Date().addingTimeInterval(3600),
            scopes: []
        )

        try await first.save(account: account)

        let firstAccounts = try await first.loadAllAccounts()
        let secondAccounts = try await second.loadAllAccounts()
        XCTAssertEqual(firstAccounts.count, 1)
        XCTAssertTrue(secondAccounts.isEmpty)
    }

    func test_SyncInProgress_OnboardingHidden() {
        // Given
        let account = Account(id: "1", username: "test", accessToken: "token", refreshToken: "refresh", tokenExpiry: Date().addingTimeInterval(3600), scopes: [])
        try! minerManager.addAccount(account)
        
        // When
        navigation.isRunningOnboardingSetup = true
        navigation.updateOnboardingSetupStage(.campaigns)
        
        // Then
        XCTAssertFalse(navigation.showOnboarding)
        XCTAssertNil(navigation.onboardingPresentation)
    }

    func test_InitialAccountHydration_DoesNotResetDismissedOnboarding() {
        // Given
        settings.hasDismissedOnboarding = true
        let account1 = Account(id: "1", username: "one", accessToken: "token", refreshToken: "refresh", tokenExpiry: Date().addingTimeInterval(3600), scopes: [])
        let account2 = Account(id: "2", username: "two", accessToken: "token", refreshToken: "refresh", tokenExpiry: Date().addingTimeInterval(3600), scopes: [])

        // Simulate startup account restoration (before configureOnboardingPresentation is called)
        try! minerManager.addAccount(account1)
        navigation.handleAccountCountChange()
        try! minerManager.addAccount(account2)
        navigation.handleAccountCountChange()

        // When
        navigation.configureOnboardingPresentation()

        // Then
        XCTAssertTrue(settings.hasDismissedOnboarding)
        XCTAssertFalse(navigation.showOnboarding)
        XCTAssertNil(navigation.onboardingPresentation)
    }
}
