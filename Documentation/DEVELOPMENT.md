# Developing SwiftMiner

SwiftMiner is a native macOS application built as an Xcode project. [XcodeGen](https://github.com/yonaskolb/XcodeGen) generates `SwiftMiner.xcodeproj` from `project.yml`; the project is not a Swift Package.

## Requirements

- macOS with Xcode
- XcodeGen
- macOS 14.0 or later as the deployment target

Xcode resolves the project's Sparkle and Swift Async Algorithms dependencies when the generated project is opened or built.

## Generate the Project

Run XcodeGen after changing `project.yml`:

```sh
xcodegen
```

Keep `project.yml` and the generated `SwiftMiner.xcodeproj` aligned. Avoid unrelated generated-project drift.

## Build and Test

Build the Debug configuration with Xcode's build system:

```sh
xcodebuild -project SwiftMiner.xcodeproj -scheme SwiftMiner -configuration Debug build
```

Run the existing Xcode test target with:

```sh
xcodebuild -project SwiftMiner.xcodeproj -scheme SwiftMiner -configuration Debug test
```

## Project Layout

```text
Sources/
  SwiftMiner/          macOS app, SwiftUI views, settings, and resources
  SwiftMinerCore/      mining engine, Twitch services, models, and persistence
  SwiftMinerService/   Discord integration and embedded Web UI server
Tests/                 Xcode unit and integration tests
Tools/
  SparklePublisher/    release packaging and Sparkle publishing tool
Website/               public website source and generated assets
Documentation/         architecture, implementation notes, and release material
SwiftMiner.icon/       source assets for the macOS application icon
SwiftMiner.xcodeproj/  generated Xcode project
project.yml            XcodeGen source configuration
scripts/               build, validation, and release automation
```

## Further Reading

- [Architecture Overview](ARCHITECTURE.md)
- [Engine Architecture](EngineArchitecture.md)
- [Release Process](RELEASING.md)
