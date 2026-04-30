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
        XCTAssertFalse(
            Settings.appStorageStore === UserDefaults.standard,
            "App-hosted tests must not write Settings changes into the production app defaults domain"
        )
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
