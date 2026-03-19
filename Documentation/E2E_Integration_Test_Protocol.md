# SwiftMiner E2E Integration Test Protocol

## Overview
This protocol defines the end-to-end (E2E) validation steps for the SwiftMiner application. The goal is to ensure that the native Swift/SwiftUI implementation correctly handles the full mining lifecycle with functional parity to the reference Python implementation (TwitchDropsMiner).

## Test Prerequisites
- [ ] At least one (ideally two) real Twitch accounts.
- [ ] Active Twitch Drop campaigns for testing (e.g., "Just Chatting" or specific games).
- [ ] macOS environment with Internet access.
- [ ] Debug Trace logging enabled in the application.

---

## 1. Authentication & Identity Lifecycle
**Goal:** Verify secure auth storage and state consistency.

- [ ] **Step 1.1: Initial Login**
    - Trigger Device Code Flow.
    - Authorize on Twitch.
    - **Verification (Backend):** Miner state transitions from `AUTHENTICATING` to `IDLE` (or `FETCHING_CAMPAIGNS`).
    - **Verification (UI):** No brief stale/empty campaign panels appear; the transition is smooth. Multi-account panels maintain the correct identity/username throughout the entire flow.
- [ ] **Step 1.2: Identity Integrity**
    - Observe `getMinerActivitySummary` for the correct `minerId` and `username`.
    - **Verification:** No cross-contamination between account panels in Multi-Account mode.
- [ ] **Step 1.3: Periodic Maintenance**
    - Observe logs for 30+ minutes.
    - **Verification:** `maintenanceTask` fires, token is validated/refreshed, and `apiClient` remains synchronized.
- [ ] **Step 1.4: Token Auto-Refresh**
    - Run a miner with a token near expiry (manually set expiry or wait for 5-min buffer).
    - **Verification:** Engine auto-refreshes via `refreshTokenIfNeeded()` without interrupting the watch session.

## 2. Campaign Discovery & Selection
**Goal:** Ensure the most relevant campaigns are prioritized.

- [ ] **Step 2.1: Enrichment Accuracy**
    - Fetch campaigns.
    - **Verification:** UI shows correct mining eligibility (Account Connected = YES, Within Time Window = YES).
- [ ] **Step 2.2: Strategy Adherence**
    - Set strategy to `prioritiseSelected` with specific games.
    - **Verification:** `selectBestCampaign` correctly picks the priority game even if other campaigns are active.

## 3. Hardened Channel Selection & Watch Session
**Goal:** Verify "safe" mining logic and Spade heartbeat parity.

- [ ] **Step 3.1: Viewer-Count Sorting**
    - Observe `[ChannelSelect]` logs.
    - **Verification:** Engine selects the channel with the **highest** viewer count (matching TDM parity).
- [ ] **Step 3.2: GQL Verification**
    - Observe `[ChannelSelect]` logs for `fetchAvailableDrops` calls.
    - **Verification:** Engine rejects candidates where the specific campaign ID is not active, even if "DropsEnabled" tag is present.
- [ ] **Step 3.3: Heartbeat Loop (Spade Parity)**
    - Observe `[Spade]` logs.
    - **Verification:** Beacons are sent every ~59 seconds with the randomized Android User-Agent and correct `userId` (Integer).
- [ ] **Step 3.4: Selection Coherence**
    - Observe UI during channel selection and start of watch.
    - **Verification (UI):** `currentChannelName` updates exactly when the miner enters `WATCHING`. Switch/Selection reasons are coherent and visible *during* the transition, not just after it settles.
- [ ] **Step 3.5: Special Events Bypass**
    - Test with a "Just Chatting" campaign.
    - **Verification:** Engine correctly falls back to ACL channels when the game directory is empty.

## 4. Progress, Stall, & Recovery
**Goal:** Ensure transition consistency and reliability during stalls.

- [ ] **Step 4.1: Live Progress Updates**
    - Watch for PubSub or GQL poll updates.
    - **Verification:** `MinerActivitySummary.minutesSinceLastProgress` resets to 0 upon server confirmation.
- [ ] **Step 4.2: Stuck Detection**
    - Simulate a progress stall by using a stream that is not crediting drops or by observing `minutesSinceLastProgress` incrementing.
    - Wait 15 minutes.
    - **Verification:** `isStalled` flag becomes `true`.
- [ ] **Step 4.3: Smart Recovery (Phase 3)**
    - Claim a drop via the official Twitch website *while* mining.
    - Wait for stall detection to fire (15 min).
    - **Verification (Backend):** Engine refreshes inventory, detects the external claim, resets the stall counter, and **continues** watching instead of switching channels.
    - **Verification (UI):** Stalled/recovering UI state clears cleanly. No momentarily stale channel/campaign info is shown during the recovery path.
- [ ] **Step 4.4: Network Drop Recovery**
    - Interrupt the network connection mid-watch.
    - Restore connection after 1-2 minutes.
    - **Verification:** Engine resumes heartbeats and watching automatically; session does not hang.

## 5. Auto-Claim & Cleanup
**Goal:** Verify reward delivery and notification management.

- [ ] **Step 5.1: Claim Execution**
    - Complete a drop.
    - **Verification:** `ClaimService` triggers GQL `claimDropBenefit` mutation. Status transitions to `CLAIMING`.
- [ ] **Step 5.2: Notification Cleanup**
    - **Verification:** `NotificationsDelete` GQL call is made after a successful claim (TDM parity).
- [ ] **Step 5.3: UI Finality**
    - **Verification:** Drop status in UI updates to `CLAIMED` and remains stable.

## 6. Multi-Account Concurrent Operations
**Goal:** Verify isolation and resource management.

- [ ] **Step 6.1: Concurrent Heartbeats**
    - Run two miners simultaneously.
    - **Verification:** Both miners send independent heartbeats with their respective `userId` and `integrityToken`.
- [ ] **Step 6.2: Collision Observation**
    - **Verification:** If both miners watch the same channel, both continue to receive progress credit (verified via real account progress). State for one miner does not bleed into the other's panel.
