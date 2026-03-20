// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "SwiftTwitchMiner",
    platforms: [
        .macOS("26.0")
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
            name: "SwiftMiner",
            targets: ["SwiftMiner"]
        ),
        .executable(
            name: "SparklePublisher",
            targets: ["SparklePublisher"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.8.0")
    ],
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
            name: "SwiftMiner",
            dependencies: [
                "SwiftTwitchMiner",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/SwiftTwitchMinerApp",
            exclude: ["Info.plist"],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .executableTarget(
            name: "SparklePublisher",
            path: "Tools/SparklePublisher"
        ),
        .testTarget(
            name: "SwiftTwitchMinerTests",
            dependencies: ["SwiftTwitchMiner"]
        )
    ]
)
