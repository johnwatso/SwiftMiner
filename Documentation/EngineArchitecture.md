# SwiftTwitchMiner Engine Architecture

## Overview

The SwiftTwitchMiner engine is built using Swift 6's actor-based concurrency model to ensure thread safety and proper isolation of mutable state.

## Core Components

### 1. MinerEngine (Actor)

The main orchestrator that manages the entire mining lifecycle.

**Responsibilities:**
- Lifecycle management (start/stop)
- Authentication coordination
- Campaign selection and prioritization
- Channel selection
- Watch session management
- Drop claiming

**Key Methods:**
- `start()` - Begins the mining loop
- `stop()` - Gracefully stops mining
- `authenticate()` - Initiates device code flow
- `claimAllDrops()` - Claims all ready drops

**Callbacks:**
- `onStatusChange` - Mining status updates
- `onCampaignUpdate` - New campaign data
- `onProgressUpdate` - Overall progress
- `onDropClaimed` - Drop claimed successfully
- `onError` - Error handling
- `onLogMessage` - Log output

### 2. Services (Actors)

Each service is an actor to ensure thread-safe state management.

#### TwitchAuthService
- Device code flow authentication
- Token refresh
- Keychain storage for credentials

#### TwitchAPIClient
- REST API calls (Helix)
- GraphQL queries/mutations
- Rate limiting and retry logic

#### DropsService
- Campaign fetching
- Drop prioritization
- Progress tracking

#### WatchSessionManager
- Stream watching simulation
- Progress polling
- Channel availability monitoring

#### ClaimService
- Drop claiming
- Batch claim operations
- Success/failure tracking

### 3. Models (Sendable)

All models conform to `Sendable` for safe actor-to-actor transfer.

- `Account` - User authentication info
- `Campaign` - Drop campaign data
- `Drop` - Individual drop reward
- `Channel` - Twitch channel/streamer
- `Progress` - Drop progress tracking

## Mining Lifecycle

```
1. Authenticate user
   ↓
2. Fetch active campaigns
   ↓
3. Select best campaign
   ↓
4. Select eligible channel
   ↓
5. Start watch session
   ↓
6. Poll for progress (every minute)
   ↓
7. Claim completed drops
   ↓
8. Repeat from step 2
```

## Concurrency Model

- All services are actors
- Main mining loop runs in a Task
- Callbacks use `@Sendable` closures
- No shared mutable state outside actors

## Platform Requirements

- macOS 26+
- Apple Silicon
- Swift 6
- SwiftUI (for future UI)

## Building

### Swift Package Manager
```bash
swift build
```

### Xcode
```bash
xcodegen generate
open SwiftTwitchMiner.xcodeproj
```

## Usage

### CLI
```bash
export TWITCH_CLIENT_ID=your_client_id
swift run SwiftTwitchMinerCLI
```

### As a Library
```swift
import SwiftTwitchMiner

let engine = MinerEngine(clientId: "your_client_id")

try await engine.authenticate()
try await engine.start()
```
