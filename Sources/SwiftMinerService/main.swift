import Foundation
import SwiftMinerCore

print("SwiftMinerService v\(SwiftMinerCore.version) starting...")

// Phase 2 implementation: HTTP Server and Projectors will land here.

// Keep the service running
while true {
    try? await Task.sleep(nanoseconds: 1_000_000_000)
}
