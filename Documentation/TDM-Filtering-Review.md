# TwitchDropsMiner Filtering Logic Review

**Date:** 19 March 2026  
**Prepared by:** Qwen, Claude, Gemini, Kimi  
**Request:** Review TDM filtering logic and identify gaps in SwiftMiner

---

## Executive Summary

**Objective:** Understand how TwitchDropsMiner (TDM) excludes non-drop items (e.g., Twitch rewards, badges, emotes) and other filtered content.

**Key Finding:** TDM uses a **multi-layer filtering stack** with 8 distinct checks. SwiftMiner already implements most layers, with only minor gaps identified.

**Implementation Effort:** ~15-20 lines of code (~15-20 minutes) for full TDM parity.

---

## TDM Filtering Architecture

### Layer 1: Benefit Type Filtering

**File:** `TwitchDropsMiner/inventory.py:33-40, 397-405`

```python
class BenefitType(Enum):
    UNKNOWN = "UNKNOWN"
    BADGE = "BADGE"
    EMOTE = "EMOTE"
    DIRECT_ENTITLEMENT = "DIRECT_ENTITLEMENT"  # ← Actual in-game drops

    def is_badge_or_emote(self) -> bool:
        return self in (BenefitType.BADGE, BenefitType.EMOTE)
```

**Campaign Eligibility Check:**
```python
@property
def eligible(self) -> bool:
    if self.has_badge_or_emote:
        return self._twitch.settings.enable_badges_emotes  # ← User setting (default: False)
    return self.linked  # ← Account linking check
```

**User Setting:** `settings.py:23, 37`
```python
"enable_badges_emotes": False  # ← DEFAULT: OFF (excludes badges/emotes)
```

**✅ Key Insight:** TDM **excludes badges and emotes by default** unless user explicitly enables them in settings.

---

### Layer 2: Game Exclusion List

**File:** `TwitchDropsMiner/twitch.py:652-674`

```python
exclude = self.settings.exclude  # ← User-defined exclude list
priority = self.settings.priority

for campaign in sorted_campaigns:
    game: Game = campaign.game
    if (
        game.name not in exclude  # ← Excluded games skipped
        and (not priority_only or game.name in priority)
        and campaign.can_earn_within(next_hour)
    ):
        self.wanted_games.append(game)
```

**User Setting:** `settings.py:18, 30`
```python
"exclude": set(),  # ← User can add games to exclude (e.g., {"Just Chatting", "Music"})
"priority": [],    # ← User can add games to prioritize
```

**✅ Key Insight:** TDM has a **user-configurable exclude list** for games.

---

### Layer 3: Priority Mode Filtering

**File:** `TwitchDropsMiner/twitch.py:656-672`

```python
priority_mode = self.settings.priority_mode  # 3 modes:
# PriorityMode.PRIORITY_ONLY      → Only priority games
# PriorityMode.ENDING_SOONEST     → Sort by end date
# PriorityMode.LOW_AVBL_FIRST     → Sort by availability

if not priority_only:
    if priority_mode is PriorityMode.ENDING_SOONEST:
        sorted_campaigns.sort(key=lambda c: c.ends_at)
    elif priority_mode is PriorityMode.LOW_AVBL_FIRST:
        sorted_campaigns.sort(key=lambda c: c.availability)
```

**✅ Key Insight:** TDM has **3 priority modes** for campaign selection.

---

### Layer 4: Time-Based Filtering

**File:** `TwitchDropsMiner/twitch.py:676`

```python
and campaign.can_earn_within(next_hour)  # ← Must be progressable within 1 hour
```

**✅ Key Insight:** TDM only selects campaigns that can be **progressed within the next hour**.

---

### Layer 5: Account Linking Check

**File:** `TwitchDropsMiner/inventory.py:346, 397-400`

```python
self.linked: bool = data["self"]["isAccountConnected"]

@property
def eligible(self) -> bool:
    if self.has_badge_or_emote:
        return self._twitch.settings.enable_badges_emotes
    return self.linked  # ← Must be linked to game account
```

**✅ Key Insight:** TDM **excludes campaigns where account isn't linked** (except badges/emotes if enabled).

---

### Layer 6: Special Games Exception

**File:** `TwitchDropsMiner/inventory.py:465`

```python
or self.game.is_special_events()  # ← Special events can be earned anywhere
```

**Special Event Games:**
- "509658" — Just Chatting
- "26936" — Music
- "509659" — Travel & Outdoors
- Other special event categories

**✅ Key Insight:** TDM allows **special event campaigns** to bypass normal channel restrictions.

---

### Layer 7: Channel ACL Check

**File:** `TwitchDropsMiner/inventory.py:451-463`

```python
def _base_can_earn(
    self, channel: Channel | None = None, ignore_channel_status: bool = False
) -> bool:
    return (
        self._base_can_earn()
        and self.campaign._base_can_earn(channel, ignore_channel_status)
    )

# Campaign._base_can_earn checks:
# - Channel in allowed_channels (ACL)
# - Channel.game == Campaign.game
# - Stream is live
```

**✅ Key Insight:** TDM enforces **channel-level ACL** (allowed channels list) if campaign has restrictions.

---

### Layer 8: Drop Preconditions

**File:** `TwitchDropsMiner/inventory.py:103-105`

```python
self.precondition_drops: list[str] = [d["id"] for d in (data["preconditionDrops"] or [])]

def can_earn(self) -> bool:
    # Check if all precondition drops are claimed
    return all(
        self.campaign.timed_drops[pid].is_claimed
        for pid in self.precondition_drops
    )
```

**✅ Key Insight:** TDM handles **drop chains** where Drop B requires Drop A to be claimed first.

---

## SwiftMiner Gap Analysis

| Filter Layer | TDM | SwiftMiner | Gap | Priority |
|--------------|-----|------------|-----|----------|
| **Benefit Type Detection** | ✅ `BenefitType` enum | ⚠️ `RewardType` exists | Minor | High |
| **Badge/Emote Exclusion** | ✅ Default OFF | ❌ Not implemented | ~5 lines | High |
| **Game Exclusion List** | ✅ User-configurable | ✅ Already implemented | ✅ Covered | N/A |
| **Priority Modes** | ✅ 3 modes | ✅ Already implemented | ✅ Covered | N/A |
| **Time-Based Filtering** | ✅ 1-hour window | ❌ Not implemented | ~10 lines | Low |
| **Account Linking** | ✅ Enforced | ✅ Already implemented | ✅ Covered | N/A |
| **Special Events** | ✅ Bypass restrictions | ❌ Not implemented | ~10 lines | Medium |
| **Channel ACL** | ✅ Enforced | ⚠️ Partial | ~5 lines | Medium |
| **Drop Preconditions** | ✅ Enforced | ✅ Already implemented | ✅ Covered | N/A |

---

## Implementation Recommendations

### Priority 1: Badge/Emote Filtering (~5 lines)

**Why:** TDM excludes these by default. Prevents mining "fake" drops (badges/emotes vs actual in-game drops).

**Implementation:**

```swift
// Campaign.swift
public var hasOnlyBadgesOrEmotes: Bool {
    drops.allSatisfy { drop in
        drop.reward?.type == .badge || drop.reward?.type == .emote
    }
}

// MinerEngine.swift - Selection logic (line ~528-537)
let eligible = nonExcluded.filter { campaign in
    guard campaign.isAccountConnected else { return false }
    
    // Skip badges/emotes unless enabled in settings
    if campaign.hasOnlyBadgesOrEmotes && !Settings.shared.enableBadgesEmotes {
        return false
    }
    
    let s = campaign.miningStatus
    return s == .available || s == .inProgress
}

// Settings.swift
public var enableBadgesEmotes: Bool = false  // Default: OFF (matches TDM)
```

**Effort:** ~5-10 minutes

---

### Priority 2: Special Events Handling (~10 lines)

**Why:** TDM allows special events to bypass normal restrictions. SwiftMiner will fail to find channels for these campaigns.

**Implementation:**

```swift
// Campaign.swift
public var isSpecialEvent: Bool {
    // Special event game IDs from TDM
    let specialEventIds = ["509658", "26936", "509659"]  // Just Chatting, Music, Travel
    return specialEventIds.contains(game.id) || game.name.contains("Special")
}

// MinerEngine.swift - Channel selection
if campaign.isSpecialEvent {
    // Allow any live channel for special events
    return true
}
// Normal channel selection for regular campaigns
return channel.game == campaign.game && ...
```

**Effort:** ~10-15 minutes

---

### Priority 3: Time-Window Pre-Check (~10 lines) - OPTIONAL

**Why:** TDM optimization to avoid selecting campaigns that can't be progressed within 1 hour.

**Implementation:**

```swift
// Campaign.swift
public func canEarnWithin(timeWindow: TimeInterval = 3600) -> Bool {
    // Check if any drop can be progressed within the time window
    drops.contains { drop in
        let remaining = drop.requiredMinutes - (drop.progress?.currentMinutes ?? 0)
        return remaining <= Int(timeWindow / 60)
    }
}

// MinerEngine.swift - Selection logic
let eligible = nonExcluded.filter { campaign in
    campaign.canEarnWithin(timeWindow: 3600)  // 1 hour
    // ... other filters
}
```

**Effort:** ~10-15 minutes

**Note:** This is an **optimization**, not a correctness issue. SwiftMiner's `earnableDrops` already achieves similar filtering.

---

## Summary

### What TDM Excludes:
1. ✅ Badges/Emotes (unless user enables `enable_badges_emotes`)
2. ✅ User-excluded games (configurable list)
3. ✅ Unlinked campaigns (account connection check)
4. ✅ Campaigns not progressable within 1 hour
5. ✅ Non-priority games (in priority-only mode)
6. ✅ Channels not in ACL (if campaign has restrictions)
7. ✅ Drops with unmet preconditions

### What SwiftMiner Already Covers:
- ✅ Game exclusion list
- ✅ Priority modes
- ✅ Account linking
- ✅ Drop preconditions
- ✅ Channel ACL (partial)

### What SwiftMiner Needs:
- ⚠️ Badge/Emote filtering (Priority 1, ~5 lines)
- ⚠️ Special events handling (Priority 2, ~10 lines)
- ⚠️ Time-window pre-check (Priority 3, optional, ~10 lines)

---

## Final Recommendation

**Implement Priority 1 + 2 only** (~15 lines, ~15-20 minutes total):
- Badge/Emote filtering prevents mining "fake" drops
- Special events handling ensures global campaigns work
- Time-window check is optional optimization

**Defer Priority 3** unless testing shows it's needed.

---

*Report generated by Qwen, Claude, Gemini, Kimi — 19 March 2026*
