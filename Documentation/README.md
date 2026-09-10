# SwiftMiner Documentation

The main [README](../README.md) is a concise project overview. End-user installation, configuration, and troubleshooting guides live on the [SwiftMiner website](https://swiftminer.app/help/). This directory contains the deeper technical and developer documentation for the repository.

## Development and Architecture

- [Development Guide](DEVELOPMENT.md) — project structure, generation, builds, and tests
- [Architecture Overview](ARCHITECTURE.md) — app, core, service, persistence, and data flow
- [Engine Architecture](EngineArchitecture.md) — mining loop, account isolation, watch sessions, and campaign selection
- [Engine Changelog](EngineChangelog.md) — behavioural history of the mining engine

## Integrations and Implementation Notes

- [SwiftBot DM Contract](SwiftBotDMContract.md) — messages exchanged with the Discord integration
- [Native Share Invitations](NativeShareInvitations.md) — macOS sharing and Mail integration details
- [Debug Profile Pictures](DebugProfilePictures.md) — debug avatar generation and project integration
- [Security](../SECURITY.md) — Web UI threat model and security guidance

## Releases

- [Release Process](RELEASING.md) — versioning, ShipHook, Sparkle, signing, and verification
- [Curated Release Notes](ReleaseNotes/) — source release notes used by the website build
