# Mining Engine Changelog

Every change to the mining engine, newest first, against the version reported by
`MinerEngineVersion` (`Sources/SwiftMinerCore/Engine/MinerEngineVersion.swift`).

The engine version is deliberately not the app version. `MARKETING_VERSION` moves
for website, documentation, and UI work; `CURRENT_PROJECT_VERSION` moves for every
build. This number moves only when mining behaviour does, so "is that fix actually
in the copy I'm running?" is answerable from the About panel, Settings → Mining,
the engine's start log line, a diagnostic export, or the web dashboard footer.

**Majors mark structural eras of the engine, minors count changes within one.**
The numbering below `4.0` was reconstructed from the history of
`Sources/SwiftMinerCore/Engine/` after the fact, so entries there describe what
each commit changed in the engine specifically — several of them are app-wide
commits that touched it in passing.

Adding an entry is part of bumping the version, not a separate chore. See the
"Engine versioning" section of `AGENTS.md`.

---

## 4.x — per-responsibility engine files

The current era. `MinerEngine` holds stored state, initialisation, and the public
lifecycle API; the watch loop, channel selection, drop progress, claiming,
campaign warnings, events, callbacks, and UI projections each live in their own
`MinerEngine+*` file.

- **4.14** · 2026-09-05 · `cfbdc51` — Reconcile an account's campaign data once and share it across the Drops list, the curated feed, and campaign detail reads instead of rebuilding it per view. Cuts idle CPU and redundant redraws, and fixes a Drops-page correctness bug found while consolidating.
- **4.13** · 2026-09-03 · `a130401` — Keep the campaign-details cache while the account-link answer is still short-lived. A multi-tier campaign returning one of two drops no longer erases the other, and a `true → false → nil` link sequence no longer resurrects a stale restriction.
- **4.12** · 2026-09-03 · `fad4809` — Stop a claim silently retiring a campaign mid-window. Invalidating details after a claim could leave the campaign with no drops, failing `canAttemptMining` and ending mining with nothing in the log naming what left.
- **4.11** · 2026-09-03 · `e4cf455` — Deduplicate campaigns and drop states, harden Twitch token and followed-channel handling, remove the debug link-bypass code paths, and split performance diagnostics into startup versus steady-state.
- **4.10** · 2026-09-01 · `b46c9aa` — Harden the realtime monitoring lifecycle and refine campaign filtering and status behaviour for 1.39.
- **4.9** · 2026-08-31 · `29c4ff1` — Report approved-channel probe failures as a structured batch result — channel, message, issue category, compatibility flag — instead of a bare log line.
- **4.8** · 2026-08-31 · `649e4ea` — Skip login-less approved channels and carry per-probe verification and compatibility outcomes out of the liveness task group, so a failed batch is distinguishable from an empty one.
- **4.7** · 2026-08-31 · `9bf8289` — Subscribe to stream-up events for the approved channels of restricted campaigns while waiting on them, instead of re-asking every 60 seconds. Twitch pushes these on `video-playback-by-id`; the engine had only ever subscribed to the channel it was already watching.
- **4.6** · 2026-08-31 · `a3abf0d` — Stop losing restricted campaigns when Twitch omits their approved-channel list on a fetch. The same campaign returns its channels on one request and none on the next, leaving it visible and active with nothing to watch.
- **4.5** · 2026-08-31 · `a02fbab` — Replace the "update SwiftMiner" advice on a compatibility incident — no fixed build exists at the moment it appears — with the actions that do work: Override Stream, or watching the stream on Twitch. Fixes the incident reset.
- **4.4** · 2026-08-31 · `cf1506a` — Alert on a failing approved-channel liveness check as a `channelChecksIncompatible` incident, so a missed esports window does not depend on someone happening to look at the app.
- **4.3** · 2026-08-31 · `26224bb` — Surface repeated `VideoPlayerStreamInfoOverlayChannel` failures in Needs attention. 266 failures in one day had left restricted campaigns invisible with no signal beyond a log warning.
- **4.2** · 2026-08-31 · `6bb8f76` — Time the launch path — token acquisition, PubSub handshake, and the campaign work after it — so the serialized per-miner startup cost is visible rather than guessed at.
- **4.1** · 2026-08-30 · `c5adb4f` — Decode each account's campaign file once and keep it in memory, share concurrent refreshes for an account, and index campaigns by id so aggregation stops rescanning lists as accounts multiply.
- **4.0** · 2026-08-30 · `7c8e1a6` — **Era start.** Split the watch loop, claiming, campaign warnings, the ordered event consumer, callback setters, and UI projections out of `MinerEngine.swift`, taking the actor body from 2,324 lines to 904.

## 3.x — channel selection and drop progress split out

`MinerEngine` gained its first extension files, and `MinerManager` was split by
responsibility. Most of the engine's earning-reliability work happened here.

- **3.26** · 2026-08-30 · `b7b5d53` — Stop recovery reporting success when a PubSub reconnect failed, which left the miner on polling-only progress while looking healthy. Miner registration, watch-session account switches, and fallback-streamer edits now apply in call order instead of racing through detached tasks.
- **3.25** · 2026-08-26 · `62aa95a` — Add debug miner states for exercising the 1.38 status card and Drops filters.
- **3.24** · 2026-08-17 · `8160b95` — Distinguish authentication failures from ordinary fatal request failures. Retrying the same saved credentials cannot repair them, so the miner pauses for a manual reconnect instead, keeping the credentials for the reconnect sheet.
- **3.23** · 2026-08-14 · `ecf8af7` — Track and apply per-miner excluded games, updatable for a single miner at runtime.
- **3.22** · 2026-08-13 · `99345e8` — Revoke the Twitch OAuth grant when an account is removed, best-effort so removal still completes while Twitch is unreachable.
- **3.21** · 2026-08-12 · `eecaf64` — Add `replaceAuthentication(for:with:)` so a re-authorised device flow updates the existing miner instead of creating a duplicate account.
- **3.20** · 2026-08-09 · `9bee244` — Preserve the operator flag when saving tokens, so re-auth stops unlinking nicknames and Discord owners.
- **3.19** · 2026-08-06 · `e3af123` — Bound the channel-verification evidence written into diagnostics to a few campaign IDs per cycle, instead of dumping an unbounded list into every mining-cycle entry.
- **3.18** · 2026-08-05 · `3fb8362` — Report subscription-only campaigns only when they are in the miner's own priority list. Surfacing every sub-gated game Twitch returned made the Activity Log look like the miner was considering work outside the configured priorities.
- **3.17** · 2026-08-02 · `3a9a1ee` — Classify a Twitch persisted-query incompatibility as its own issue category, distinct from a generic API failure.
- **3.16** · 2026-07-30 · `72c1f6a` — Treat a missing game-account link as a delivery warning rather than a scheduling block for a prioritised game, and clean up a residual watch session before starting a newly selected channel.
- **3.15** · 2026-07-29 · `91a2931` — Hold an activity assertion for the length of a real watch session so App Nap cannot deprioritise its heartbeat and recovery timers, and add a single-miner force refresh that does not spend requests for the other accounts.
- **3.14** · 2026-07-29 · `b3939d5` — Serialize mining progress events through one ordered consumer. Each callback previously spawned its own unstructured task, so events raced one another; the stream now reconciles against inventory when Twitch goes quiet while a miner is watching.
- **3.13** · 2026-07-29 · `3122eab` — Add `MinerPresentedState` as the single answer to what a miner is doing. The status label and the activity card resolved it independently, which is how one miner reported "Looking for Streams" and "Drops complete" at the same time.
- **3.12** · 2026-07-29 · `0d320fd` — Record the campaign a miner is waiting on when the channel search comes up empty, and resolve per-game state from `gameChannelAvailability` so it survives watch-session cleanup.
- **3.11** · 2026-07-29 · `5ae7839` — Stop treating an invented token deadline as proof a token is dead. Cookie-imported sessions carry no refresh token and no expiry, so a fabricated 30-day deadline had quietly taken every account's real-time drop connection offline once it passed.
- **3.10** · 2026-07-29 · `01df635` — Stop presenting a subscription-gated campaign as a miner's current state — selection already excluded them, but the highest-priority one was substituted for the real status — and remove the multi-miner launch slowdown.
- **3.9** · 2026-07-28 · `bd06216` — Restore the drop claim and watch-progress paths for 1.35, and make health and campaign state more truthful.
- **3.8** · 2026-07-26 · `d38e1ae` — Hotfix miner startup request starvation, and report a not-yet-running miner honestly as Starting, Paused, or Blocked rather than by its last status.
- **3.7** · 2026-07-26 · `8833a8c` — Bound accepted drop progress against wall-clock time, with slack for clock skew and Twitch crediting in batches, and key unverified channels by campaign and channel so a stale sample cannot move the baseline.
- **3.6** · 2026-07-25 · `4d25293` — Anchor the not-earning check on the last banked progress instead of `statusChangedAt`, which reset every few minutes as mining cycled through watching and refreshing, so the check could never fire. Count earnings per drop from verified progress transitions.
- **3.5** · 2026-07-24 · `646fb1c` — Track `lastDropProgressAt` separately from liveness and flag a miner that has watched 20 minutes without banking progress. Health monitoring had only measured liveness, so a miner could earn nothing for hours with every signal green.
- **3.4** · 2026-07-23 · `6b2c1ff` — Reconnect PubSub from the mining loop, which had only ever connected at start and on auth refresh. A dropped socket left the miner blind to real-time progress for the rest of the session. Skip campaigns that cannot earn.
- **3.3** · 2026-07-22 · `0bfbad7` — Extract failover-rule matching into a pure static helper so it can be tested without building a full engine. No behaviour change.
- **3.2** · 2026-07-22 · `0df09d6` — Make the scheduler drop-aware: defer preemption when the current drop is within roughly ten minutes of completing, since drop minutes are per-campaign and lost on a switch; rank candidates by drop progress as a tiebreaker; fix the watch-loop cadence.
- **3.1** · 2026-07-22 · `a796724` — Split `MinerManager` into `+GameState`, `+EngineWiring`, and `+DebugState`. No logic changes.
- **3.0** · 2026-07-22 · `2adbc7f` — **Era start.** Split `MinerEngine` into `+ChannelSelection` and `+DropProgress` extensions, taking the actor body down from over 2,000 lines.

## 2.x — supervised workers

`MinerSupervisor` took ownership of the worker lifecycle and stall recovery.
Stream overrides, failover streamers, subscription gating, and live-aware
campaign ranking all arrived in this era.

- **2.34** · 2026-07-22 · `2c84162` — Route diagnostics through `os.log` so Release-build failures survive in the unified log, and stop logging raw token response bodies.
- **2.33** · 2026-07-21 · `1574239` — Rotate the offsets of bounded directory and approved-channel probes so lower-ranked streams stop being permanently starved, and stable-partition results so known approved channels are always considered.
- **2.32** · 2026-07-20 · `f3d234c` — Refresh the `DirectoryPage_Game` persisted-query hash, make direct Spade beacons the primary watch heartbeat with GQL as fallback, and distinguish desired PubSub topics from those submitted on the current socket.
- **2.31** · 2026-07-03 · `8122e86` — Present a missing game-account link as blocked only when the game is one this miner has prioritised; unrelated unlinked campaigns are ordinary "no eligible work".
- **2.30** · 2026-07-02 · `448abe4` — Add bounded shared caches for static campaign metadata, available drops, live directory results, and game-slug candidates, reused across accounts without sharing progress or claim state.
- **2.29** · 2026-07-02 · `084f6ba` — Add mining-cycle performance timing, plus campaign-selection and channel-verification summaries, to the log.
- **2.28** · 2026-07-01 · `ccf9133` — Resolve renamed and branded Twitch categories by carrying campaign game slugs and expanding through category search, and verify directory and per-stream game IDs before accepting a live channel so a bad slug match cannot switch the miner into an unrelated category.
- **2.27** · 2026-07-01 · `cc42019` — Make campaign ranking live-aware via `rankCandidates`, backed by a 15-minute per-game live-channel probe cache: a short-window campaign with no live stream can no longer out-rank a game that actually has streams. Fixes the five-minute re-evaluation tearing down a working session.
- **2.26** · 2026-06-29 · `8a18911` — Treat Twitch's IRL category as an earn-anywhere campaign category, with a setting to skip IRL campaigns without a manual game exclusion.
- **2.25** · 2026-06-24 · `e67cb68` — Raise a `recoveryExhausted` incident when automatic recovery cannot restore mining, instead of silently re-recording current health.
- **2.24** · 2026-06-24 · `9263bd8` — Record health state and recovery stages into the persistent unattended-health store.
- **2.23** · 2026-06-24 · `05869e5` — Gate miner auto-start and coordinator auto-refresh behind the hosted-test runtime check, so a test run cannot start real mining.
- **2.22** · 2026-06-22 · `b821cae` — Add per-game failover streamers: on a stall the engine selects a verified failover channel, with cooldowns and pending-target handling to avoid rapid retries.
- **2.21** · 2026-06-21 · `02cd61d` — Handle subscription-required rewards: consider same-game verification candidates, log diagnostics for same-game subscription-only campaigns, and suppress up-next suggestions that a paywall blocks.
- **2.20** · 2026-06-20 · `92bd736` — Re-probe ACL-restricted campaigns roughly every 60 seconds while idle and probe approved channels concurrently in a task group, waking the engine early when one goes live, so a brief esports window is not missed.
- **2.19** · 2026-06-20 · `1814ba9` — Continue channel selection for ACL-restricted campaigns even when the directory returns no results.
- **2.18** · 2026-06-20 · `6a0001b` — Add `PrimaryState.overriding(login:progress:)` so an active stream override is what the UI reports.
- **2.17** · 2026-06-20 · `5f52395` — Delegate stream-login normalization to the shared parser, accepting plain usernames, `@handles`, and twitch.tv URLs.
- **2.16** · 2026-06-20 · `60326d8` — Add watch-only stream override: watch a streamer even when no eligible campaign is active, with live-check, polling, and stall logic adjusted not to switch away mid-session.
- **2.15** · 2026-06-20 · `7f4225d` — Add stream override end-to-end — override state, a set API, live and offline checks, auto-clear, and override-aware campaign and channel selection.
- **2.14** · 2026-06-18 · `8564da6` — Skip campaigns with no remaining earnable drops, so a miner is never pinned to a stream that cannot pay.
- **2.13** · 2026-06-15 · `b8974bd` — Simplify the drop claim path for reliability.
- **2.12** · 2026-06-12 · `c5c0266` — Auto-claim drops from PubSub claim events, and log maintenance-task token validation and refreshes.
- **2.11** · 2026-06-06 · `0e97474` — Add `updatePriorityGames(resolving:)` so a global reorder or a re-auth stops flattening every miner to the global list and wiping personal overrides.
- **2.10** · 2026-06-06 · `d49635e` — Restore the account-link gate narrowly: an unlinked campaign is attemptable only when its game is prioritised for that miner. Dropping it entirely leaked one miner's prioritised game into another.
- **2.9** · 2026-06-06 · `d6d44bb` — Allow prioritised unlinked campaigns to mine.
- **2.8** · 2026-06-06 · `01fcd82` — Add per-miner priority-game updates that leave the other miners untouched.
- **2.7** · 2026-05-29 · `7968173` — Add `MinerManager.DebugState` and per-miner debug state setting for exercising card presentations.
- **2.6** · 2026-05-29 · `de35fe4` — Add `revertToLiveData(for:)` and `revertAllToLiveData()` to restore miner state from the engine and supervisor after debug overrides.
- **2.5** · 2026-05-29 · `61ef57c` — Refine campaign matching for the Ended filter: start and end dates, completion, and whether any obtainable reward remains.
- **2.4** · 2026-05-24 · `6902112` — Gate notification preferences and DM event emission behind quiet hours.
- **2.3** · 2026-05-11 · `ba68d00` — Raise the supervisor stall timeout from 6 to 15 minutes so the engine's normal five-minute wait between rescans stops tripping recovery, and add an `IssueCategory` taxonomy folded into the recovery reason, so the log says what actually went wrong.
- **2.2** · 2026-05-10 · `ad2785e` — Track initialised campaign snapshots and fire `onCampaignDetected` for newly seen active campaigns; expose account-action-required events.
- **2.1** · 2026-05-09 · `1e26bf0` — Add `onLinkWarning` and the DM event callbacks: drop claimed, auth required, campaign completed, welcome back.
- **2.0** · 2026-05-08 · `189bff5` — **Era start.** Add `MinerSupervisor` to own worker lifecycle, stall detection, and recovery.

## 1.x — the original engine

`MinerEngine`, `MinerManager`, and `MiningDataCoordinator`, with
`PrimaryStateResolver` added early on. Account-scoped mining, channel
verification, and the first stall recovery took shape here.

- **1.22** · 2026-05-07 · `3575021` — Add `attachActivatedAccount(_:)` for the bot-driven device flow and `setOwnerDiscordId(forAccountId:to:)`, persisted so the link survives restarts.
- **1.21** · 2026-05-06 · `d949545` — Actually wire sticky per-account Twitch User-Agent allocation into the API client, auth service, and spade beacon. Every caller had been taking an independent random pick, so two miners could collide and one miner's traffic looked like three clients.
- **1.20** · 2026-05-05 · `9575559` — Detect subscription-required drops and exclude them from candidates, so miners stop hanging on a reward watching alone cannot earn. Re-adds stall recovery with a one-hour cooldown for false-positive account connections.
- **1.19** · 2026-05-05 · `fd8a365` — Revert 1.18.
- **1.18** · 2026-05-05 · `9ffb012` — Add a campaign cooldown and fast-fail when `fetchCurrentDrop` never produces an active drop session, and sync inventory before checking newly claimed drops in the stall handler so stale local claim state cannot mask a genuine stall.
- **1.17** · 2026-05-04 · `e3cc536` — Route miner nicknames through a `displayName(forAccountId:fallback:)` resolver, so a nickname set anywhere is the name shown everywhere.
- **1.16** · 2026-05-01 · `37e2121` — Add anti-stall recovery: a background monitor that conservatively restarts miners wedged after network or progress stalls, with a setting to turn it off.
- **1.15** · 2026-05-01 · `58d08b9` — Add `clearCachedDropHistory()` so stale completed-drop snapshots can be discarded and repopulated from whatever Twitch still exposes.
- **1.14** · 2026-05-01 · `865e528` — Rescan immediately when claiming or an inventory sync removes the current campaign from the mineable set.
- **1.13** · 2026-04-30 · `52eec5f` — Add followed-streamer channel ranking that applies without an engine restart, and stream spreading that avoids channels already occupied by another miner while bypassing it when too few channels are viable.
- **1.12** · 2026-04-30 · `9f83ec0` — Record every matching candidate for a channel and choose by campaign priority after the directory scan, so a restricted side campaign stops preempting a broader same-game campaign purely by appearing earlier in the directory.
- **1.11** · 2026-04-29 · `19147ac` — Separate watch-session error and heartbeat handling, add explicit session cleanup, and count only changed server state as verified progress.
- **1.10** · 2026-04-28 · `3ff14f9` — Engine reliability fixes shipped in 1.10: ACL-restricted channel selection, and account-scoped campaign selection.
- **1.9** · 2026-04-23 · `f974e41` — Wire the manager into the SwiftBot admin linking service.
- **1.8** · 2026-04-22 · `35beab8` — Restructure eligibility into explicit stages — active, account-linked, eligible drops, then user preferences — with a debug bypass for testing the watch pipeline without link gating.
- **1.7** · 2026-04-18 · `6f7477b` — Group candidates by game and match each live channel's active-drops list against every candidate for that game, so the miner pivots to whichever campaign is actually running instead of giving up.
- **1.6** · 2026-04-18 · `7e81096` — Rework claim discovery and add `[ChannelSelect]` verification logging, including a live approved-channel fallback when no directory candidate matches the campaign ACL.
- **1.5** · 2026-04-17 · `0873523` — Make campaign selection account-scoped: count account-eligible candidates, warn about expired campaigns still marked eligible, and search channels per candidate.
- **1.4** · 2026-04-16 · `22b394f` — Add `GameAggregate` grouping with deterministic state precedence — action required, in progress, ready, completed, unavailable — and deterministic sorting at both levels.
- **1.3** · 2026-04-14 · `a6f8956` — Add `PrimaryStateResolver` to unify the engine's internal states into one user-facing model with documented precedence.
- **1.2** · 2026-04-14 · `402bb30` — Miners run at all times; the paused state is presented as Standby.
- **1.1** · 2026-03-28 · `f4ee760` — Warn when a prioritised game is blocked because the account is not linked, with per-miner suppression of the warning.
- **1.0** · 2026-03-26 · `63e305f` — **Era start.** `MinerEngine`, `MinerManager`, and `MiningDataCoordinator` as SwiftMinerCore.
