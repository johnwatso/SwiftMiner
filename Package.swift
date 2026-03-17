// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SwiftTwitchMiner",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(
            name: "SwiftTwitchMiner",
            targets: ["SwiftTwitchMiner"]
        ),
        .executable(
            name: "SwiftTwitchMinerCLI",
            targets: ["SwiftTwitchMinerCLI"]
        ),
        .executable(
            name: "SwiftTwitchMinerApp",
            targets: ["SwiftTwitchMinerApp"]
        )
    ],
    dependencies: [],
    targets: [
        .target(
            name: "SwiftTwitchMiner",
            dependencies: [],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "SwiftTwitchMinerCLI",
            dependencies: ["SwiftTwitchMiner"]
        ),
        .executableTarget(
            name: "SwiftTwitchMinerApp",
            dependencies: ["SwiftTwitchMiner"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "SwiftTwitchMinerTests",
            dependencies: ["SwiftTwitchMiner"]
        )
    ]
)
