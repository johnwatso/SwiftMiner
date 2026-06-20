// swift-tools-version:6.0
//
// ─────────────────────────────────────────────────────────────────────────────
//  This Package.swift is METADATA ONLY — it is not used to build SwiftMiner.
//
//  SwiftMiner is an Xcode app, generated from `project.yml` via XcodeGen and
//  built with Xcode. Swift Package Manager does NOT build this project: this
//  manifest declares no targets, so `swift build` produces nothing.
//
//  Its sole purpose is to surface the project's dependencies in GitHub's
//  dependency graph (Insights → Dependency graph). Keep the versions below in
//  sync with the `packages:` section of `project.yml`.
// ─────────────────────────────────────────────────────────────────────────────
import PackageDescription

let package = Package(
    name: "SwiftMiner",
    platforms: [
        .macOS("26.0")
    ],
    dependencies: [
        // Sparkle — software auto-update framework for macOS apps.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.8.0"),
        // swift-async-algorithms — async/await sequence algorithms.
        .package(url: "https://github.com/apple/swift-async-algorithms", from: "1.0.0"),
    ]
)
