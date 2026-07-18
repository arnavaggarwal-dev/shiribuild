# ✦ Shiritori

A native SwiftUI word-chain game for iOS — a rebuild of the desktop Shiritori
games (`shiritori_bot.py` / `shiritori_net.py`), same rules and "cosmic nebula"
look, with a bot opponent, local pass-and-play, and LAN multiplayer over
Bonjour.

## Gameplay

Shiritori is a word-chain game:

- Each word must **start with the last letter** of the previous word.
- **No repeats** — a word already used in the chain is rejected.
- Don't end a word on the **forbidden letter** (randomized each game) — doing so
  eliminates you.
- You score points equal to the **length of the word** you play.
- Last player standing wins.

You have **30 seconds** per turn. Running out of time triggers a skip.

### Commands

Type these into the word box instead of a word:

| Command | Effect |
|---|---|
| `/skip` | Skip your turn — random outcome: −10 pts, no penalty, or elimination |
| `/donate <pts> <player>` | Give points to another active player and skip your turn |
| `/wordlist` | Show every word used so far |
| `/rules` | Quick rules reminder |
| `/help` | List the commands |

## Modes

- **Bot Mode** — 1–7 human players on one device plus an AI opponent with
  adjustable difficulty (1–100).
- **Local Play** — 2–8 players passing a single device around.
- **Host a Game (LAN)** — advertise a game over Bonjour that nearby players join
  automatically; PC players can join by IP on port `55731`.
- **Join a Game (LAN)** — discover nearby hosted games, or enter a host's IP
  directly.

Everyone must be on the **same Wi-Fi network** (including a shared personal
hotspot) for LAN play to work.

## Privacy

There is no server, no account system, and no backend. Multiplayer connects
devices **directly** over the local network; nothing leaves your Wi-Fi. No
analytics, no tracking, no ads, no data collection.

## Project layout

```
Sources/MyApp/
  ShiritoriApp.swift        App entry, models, game engine, networking, all views
  AppSettings.swift         Persisted haptics/audio prefs + Settings screen
  PrivacyDisclaimer.swift   One-time first-launch privacy notice
  words_dictionary.json     ~370k-word English dictionary for validation
  Assets.xcassets/          App icon
  Info.plist                App target Info.plist
```

Config files at the repo root:

- `Package.swift` — SwiftPM manifest (used by the xtool build).
- `project.yml` — [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec that
  generates `MyApp.xcodeproj`.
- `xtool.yml` — [xtool](https://github.com/xtool-org/xtool) config for building
  and sideloading without Xcode.
- `Info.plist` (root) — Info.plist used by the xtool build.

## Requirements

- iOS 17.0 or later (deployment target).
- Swift 5 language mode (the code is pre-concurrency style; the manifests pin
  language mode to 5 while using a Swift 6 toolchain).
- No third-party Swift dependencies.

## Building

### With Xcode (via XcodeGen)

```sh
brew install xcodegen
xcodegen generate --spec project.yml
open MyApp.xcodeproj
```

Then build and run the `MyApp` scheme on a simulator or device.

### With xtool (no Xcode project)

See [xtool](https://github.com/xtool-org/xtool) for setup, then build and
sideload using `xtool.yml`.

### CI

`.github/workflows/ios-build.yml` generates the Xcode project and archives an
**unsigned** IPA on every push to `main` (uploaded as a build artifact). This is
for testing/sideloading — it is not a signed App Store build.

## Local network permissions

LAN hosting and joining require the local-network permission and a Bonjour
service declaration, both already set in the Info.plists:

- `NSLocalNetworkUsageDescription`
- `NSBonjourServices` → `_shiritori._tcp`

Without these, iOS silently blocks Bonjour discovery on a real device.
