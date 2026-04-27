import Foundation
import SwiftMinerCore
import SwiftMinerService

// MARK: - Configuration

let port = UInt16(ProcessInfo.processInfo.environment["SWIFTMINER_API_PORT"] ?? "8080") ?? 8080
let apiKey = ProcessInfo.processInfo.environment["SWIFTMINER_API_KEY"] ?? "dev-key-change-in-production"

// MARK: - Database Setup

let fileManager = FileManager.default
let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
let dbDir = appSupport.appendingPathComponent("SwiftMiner", isDirectory: true)
try? fileManager.createDirectory(at: dbDir, withIntermediateDirectories: true)
let dbURL = dbDir.appendingPathComponent("swiftminer.db")

let manager = SQLiteManager(databaseURL: dbURL)
do {
    try await manager.open()
    print("[SwiftMinerService] Database opened at \(dbURL.path)")
} catch {
    print("[SwiftMinerService] Failed to open database: \(error)")
    exit(1)
}

// MARK: - Services

let projectionBuilder = DiscordProjectionBuilder(manager: manager)
let apiRoutes = DiscordAPIRoutes(manager: manager, projectionBuilder: projectionBuilder, apiKey: apiKey)
let router = HTTPRouter()

// MARK: - Server Startup

let server = HTTPAPIServer(port: port, apiKey: apiKey, router: router)

Task {
    await apiRoutes.configure(router)
    do {
        try await server.start()
    } catch {
        print("[SwiftMinerService] Failed to start server: \(error)")
        exit(1)
    }
}

print("SwiftMinerService v\(SwiftMinerCore.version) starting...")
print("[SwiftMinerService] API key: \(apiKey.prefix(4))...")
print("[SwiftMinerService] Press Ctrl+C to stop.")

// Keep the service running
while true {
    try? await Task.sleep(nanoseconds: 1_000_000_000)
}
