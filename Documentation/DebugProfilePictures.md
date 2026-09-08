# Debug profile pictures

The square PNGs in `Sources/SwiftMiner/DebugAvatars/` are generated profile
pictures for screenshot fixtures: one miner avatar and a similar Discord variant
per account. Views crop them into circles at display time.
Release builds exclude these assets.

The set is currently nine files — `DebugAvatarAnimeGirlDiscord.png` has not been
drawn, so quietcomet's Discord row reuses its miner portrait. Any portrait whose
Discord counterpart is missing falls back the same way.

Adding or renaming a file here needs a `xcodegen` run before it reaches the app:
the PNGs are loose bundle resources listed individually in the generated project,
so a file that XcodeGen has not seen is simply absent at runtime and every lookup
for it returns `nil`.

## Preview the artwork

Open `Sources/SwiftMiner/OverviewView+SystemState.swift` in Xcode and select the
**Debug Profile Pictures** canvas preview. It shows each miner portrait above its Discord variant, with
username labels. This gallery needs no accounts or
network connection.

## Capture the app

In the SwiftMiner scheme's Run settings, select Debug and enable the environment
variable `SWIFTMINER_MARKETING_SCREENSHOTS=1`. Launch the app with at least one
account and cached campaigns containing drops; the existing screenshot fixture
uses that campaign data to populate five sample miners.

The portraits appear wherever the app already draws an account picture: the
Miners list and the miner detail header, plus the Discord row. Overview miner
cards do not show one, because Release does not draw one there either.
Assignments follow sample account IDs, so the same miner keeps the same portrait
across screens. Images load directly from the app bundle without network requests.
Each Discord section uses its own synthetic identity and matching `*.drops`
username. The `DebugAvatar*Discord.png` files are used only for Discord; the main
miner pictures remain unchanged.

## The rule this fixture follows

Screenshot mode substitutes **data** — miners, campaigns, portraits, Discord
identities and DM history — into the views the app already has. It must never
add, remove or restyle UI, because every capture it produces is published as a
picture of the shipping app. A screenshot showing a control that Release cannot
draw is a promise the download does not keep.

Forcing a real, reachable state is fine and is not a divergence: the fixture
opens the Discord disclosure, reports the connection as `.connected`, and turns
the Discord section on regardless of `swiftBotEnabled`. An operator can reach
each of those, so the captured screen is one a user really can see. Suppressing
a side effect is fine too — `resendLast()` returns early so a capture session
never actually sends a DM.

Disable the environment variable to return to the usual account presentation.

Listed in fleet order — `usernames` and `avatarNames` are index-aligned, so
reordering the fleet means reordering both arrays together.

| Sample miner | Portrait |
| --- | --- |
| quietcomet | Anime girl |
| Pixelpanda | Pixel-art panda |
| nightowl | Ghibli-style corgi |
| emberfox | Anime cat with a little bow |
| saltmarsh | Minimalist yellow duck |

Every row has a matching `*Discord.png` except quietcomet.

## Generation

Created with the built-in image generation tool from the user's five requested
subjects. These are new illustrations, not crops of the original reference sheet.
The exact prompt set is recorded in `DebugProfilePicturePrompts.json`.
