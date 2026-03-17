import Foundation
import SwiftTwitchMiner

@main
struct SwiftTwitchMinerCLI {
    static func main() async {
        print("SwiftTwitchMiner CLI")
        print("====================")
        
        // Configuration
        let clientId = ProcessInfo.processInfo.environment["TWITCH_CLIENT_ID"] ?? ""
        
        guard !clientId.isEmpty else {
            print("Error: TWITCH_CLIENT_ID environment variable not set")
            print("Please set your Twitch Client ID:")
            print("  export TWITCH_CLIENT_ID=your_client_id_here")
            exit(1)
        }
        
        // Create engine
        let engine = MinerEngine(clientId: clientId)
        
        // Set up logging using setter methods
        await engine.setLogMessageHandler { message in
            print(message)
        }

        await engine.setStatusChangeHandler { status in
            print("[Status] \(status.rawValue)")
        }

        await engine.setCampaignUpdateHandler { campaigns in
            print("[Campaigns] Found \(campaigns.count) active campaigns")
            for campaign in campaigns {
                print("  - \(campaign.name) (\(campaign.gameName)) - \(campaign.drops.count) drops")
            }
        }

        await engine.setDropClaimedHandler { drop in
            print("[Claimed] \(drop.name)")
        }

        await engine.setErrorHandler { error in
            print("[Error] \(error.localizedDescription)")
        }
        
        // Check for existing auth
        do {
            let authService = TwitchAuthService(clientId: clientId)
            if let account = try await authService.loadSavedAccount() {
                print("Found saved account: \(account.username)")
                print("Token valid: \(account.isTokenValid)")
            } else {
                print("No saved account found. Starting authentication...")
                let authInfo = try await engine.authenticate()
                print(authInfo.displayMessage)
                
                // Wait for authentication
                print("Waiting for authentication...")
                while !(await authService.isAuthenticated) {
                    try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
                }
            }
            
            // Start mining
            print("\nStarting miner...")
            try await engine.start()
            
            // Keep running until interrupted
            print("\nMiner is running. Press Ctrl+C to stop.")
            while await engine.isActive {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            
        } catch {
            print("Fatal error: \(error)")
            exit(1)
        }
    }
}
