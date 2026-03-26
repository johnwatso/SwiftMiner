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

    func test_0Accounts_NotDismissed_PanelVisible() {
        // Given
        XCTAssertTrue(minerManager.miners.isEmpty)
        XCTAssertFalse(settings.hasDismissedOnboarding)
        
        // When
        navigation.refreshOnboardingPresentation()
        
        // Then
        XCTAssertTrue(navigation.showOnboarding)
        XCTAssertEqual(navigation.onboardingPresentation?.accountState, .noAccounts)
        XCTAssertEqual(navigation.onboardingPresentation?.title, "Connect an account when you're ready")
    }

    func test_1PlusAccounts_NoPreferences_PanelVisible_GamePrompt() {
        // Given
        let account = Account(id: "1", username: "test", accessToken: "token", refreshToken: "refresh", tokenExpiry: Date().addingTimeInterval(3600), scopes: [])
        minerManager.addAccount(account)
        XCTAssertFalse(minerManager.miners.isEmpty)
        XCTAssertTrue(settings.gamePreferences.isEmpty)
        
        // When
        navigation.refreshOnboardingPresentation()
        
        // Then
        XCTAssertTrue(navigation.showOnboarding)
        XCTAssertTrue(navigation.onboardingPresentation?.showsGamePreferences ?? false)
        XCTAssertEqual(navigation.onboardingPresentation?.title, "Refine what SwiftMiner should prioritize")
    }

    func test_1PlusAccounts_Preferences_NotSyncing_PanelHidden() {
        // Given
        let account = Account(id: "1", username: "test", accessToken: "token", refreshToken: "refresh", tokenExpiry: Date().addingTimeInterval(3600), scopes: [])
        minerManager.addAccount(account)
        
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

    func test_Dismissed_PanelHidden() {
        // Given
        settings.hasDismissedOnboarding = true
        
        // When
        navigation.refreshOnboardingPresentation()
        
        // Then
        XCTAssertFalse(navigation.showOnboarding)
        XCTAssertNil(navigation.onboardingPresentation)
    }

    func test_SyncInProgress_SetupStatusVisible() {
        // Given
        let account = Account(id: "1", username: "test", accessToken: "token", refreshToken: "refresh", tokenExpiry: Date().addingTimeInterval(3600), scopes: [])
        minerManager.addAccount(account)
        
        // When
        navigation.isRunningOnboardingSetup = true
        navigation.updateOnboardingSetupStage(.campaigns)
        
        // Then
        XCTAssertTrue(navigation.showOnboarding)
        XCTAssertNotNil(navigation.onboardingPresentation?.setupStage)
        XCTAssertEqual(navigation.onboardingPresentation?.setupStage, .campaigns)
        XCTAssertEqual(navigation.onboardingPresentation?.title, "Syncing your account")
    }

    func test_InitialAccountHydration_DoesNotResetDismissedOnboarding() {
        // Given
        settings.hasDismissedOnboarding = true
        let account1 = Account(id: "1", username: "one", accessToken: "token", refreshToken: "refresh", tokenExpiry: Date().addingTimeInterval(3600), scopes: [])
        let account2 = Account(id: "2", username: "two", accessToken: "token", refreshToken: "refresh", tokenExpiry: Date().addingTimeInterval(3600), scopes: [])

        // Simulate startup account restoration (before configureOnboardingPresentation is called)
        minerManager.addAccount(account1)
        navigation.handleAccountCountChange()
        minerManager.addAccount(account2)
        navigation.handleAccountCountChange()

        // When
        navigation.configureOnboardingPresentation()

        // Then
        XCTAssertTrue(settings.hasDismissedOnboarding)
        XCTAssertFalse(navigation.showOnboarding)
        XCTAssertNil(navigation.onboardingPresentation)
    }
}
