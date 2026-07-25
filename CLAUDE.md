# CLAUDE.md

Working notes and task tracker for the Shiritori iOS app. Update the checklists
below as work lands — check the box **and** strike the text (`~~…~~`) when done.

## Project overview

Native SwiftUI word-chain game for iOS (deployment target 17.0). Rebuild of the
desktop Python originals (`shiritori_bot.py` / `shiritori_net.py`) — same rules,
same "cosmic nebula" palette. Three ways to play: Bot Mode, Local pass-and-play,
and LAN multiplayer (Bonjour discovery + fixed TCP port 55731, PC join by IP).

No backend, no accounts, no analytics, no third-party Swift dependencies.

## Architecture / key files

Source is split by concern (all one module `MyApp`, so no imports needed between
these). Both build systems glob `Sources/MyApp/*.swift`, so new files are picked
up automatically — no `project.yml` / `Package.swift` change needed.

- `Sources/MyApp/ShiritoriApp.swift` — `@main` entry + `RootView` (routing).
- `Sources/MyApp/Theme.swift` — `Palette`, `Color` hex helpers, `GameFont`.
- `Sources/MyApp/Models.swift` — `GameState`, `GameEvent`, `NetMessage`, `Route`,
  `WinnerInfo`.
- `Sources/MyApp/DictionaryStore.swift` — off-main dictionary load + validation.
- `Sources/MyApp/BotAI.swift` — `botPickWord`.
- `Sources/MyApp/AudioHaptics.swift` — `ToneEngine` + `Haptics`.
- `Sources/MyApp/Effects.swift` — shake `GeometryEffect` + `View.shake`.
- `Sources/MyApp/Components.swift` — reusable views: glass card, buttons, sliders,
  score card, word chain, timer, dots, confetti, nebula background.
- `Sources/MyApp/GameEngine.swift` — authoritative rules engine (Bot/Local/Host).
- `Sources/MyApp/Networking.swift` — `WireFraming`, `LANHost`, `LANBrowser`, `LANClient`.
- `Sources/MyApp/AppModel.swift` — top-level coordinator (route + live backend).
- `Sources/MyApp/Screens.swift` — all full-screen views (lobby, setup, join, waiting,
  game, winner) + their private helpers.
- `Sources/MyApp/AppSettings.swift` — persisted haptics/audio prefs + Settings screen.
- `Sources/MyApp/PrivacyDisclaimer.swift` — one-time first-launch privacy notice.
- `Sources/MyApp/words_dictionary.json` — ~370k-word English dictionary (looks like
  the public-domain dwyl/english-words list). Loaded off-main at launch.
- `Info.plist` (root) — used by the xtool build. `Sources/MyApp/Info.plist` — used
  by the XcodeGen/Xcode build. **Keep both in sync.**

### How the pieces talk
- `GameEngine` is the single source of truth for Bot, Local, and Host games.
- `LANHost` wraps one `GameEngine` and broadcasts via `engine.onStateChanged` /
  `engine.onGameOver`. Remote clients' moves arrive as `.action` messages.
- `LANClient` runs no rules — it mirrors host state and forwards this player's input.
- Wire format: 4-byte big-endian length prefix + JSON (`WireFraming`). Snake_case
  keys stay byte-compatible with the Python protocol (note `wordlist`, one word).

## Build commands

```sh
# Xcode (via XcodeGen)
brew install xcodegen
xcodegen generate --spec project.yml
open MyApp.xcodeproj      # build/run the MyApp scheme

# xtool (no Xcode project) — see xtool.yml
```

CI: `.github/workflows/ios-build.yml` archives an **unsigned** IPA on push to
`main` (sideload/test only — not an App Store build).

## Conventions

- Swift 5 language mode is pinned intentionally (`Package.swift` `swiftLanguageMode(.v5)`,
  `project.yml` `SWIFT_VERSION 5.0`). The code is pre-concurrency style
  (`DispatchQueue` + `Network` callbacks driving `@Published`). Don't "fix" this to
  Swift 6 strict concurrency without a real migration.
- All colors come from `Palette`; all fonts from `GameFont` (SF Rounded). Reuse them.
- Haptics/audio degrade gracefully and are gated by `AppSettings` — keep that.
- Bundle ID: `com.arnavaggarwal.myapp`. Bump `MARKETING_VERSION` / `CFBundleShortVersionString`
  and `CURRENT_PROJECT_VERSION` / `CFBundleVersion` together for releases.

---

## Task tracker

### 🔴 Functional bugs — LAN multiplayer
Both stemmed from the host only broadcasting on turn-advancing changes. Fixed in
branch `fix/lan-feedback-and-timer` via new `GameEngine.onReject` / `onTick`
hooks that `LANHost` relays.

- [x] ~~**Rejection feedback never reaches clients.** `GameEngine.reject()` only
  called `setMessage()`, not a broadcast, so a remote player's invalid word was
  silently dropped (and shown on the *host's* screen instead). Fixed: `reject()`
  fires `onReject`, `LANHost` sends a targeted `.msg` to just that player; a new
  `localPlayerNum` stops the host surfacing remote players' rejections.~~
- [x] ~~**Client timer frozen at 30.** `LANHost` never sent `.tick`; the host's
  per-second `tick()` only mutated local `engine.timeLeft`. Fixed: `tick()` (and
  turn start) fire `onTick`, `LANHost` broadcasts `.tick`, client applies it.~~

### 🟠 App Store readiness (blockers)
- [x] ~~Add `ITSAppUsesNonExemptEncryption = false` to **both** Info.plists (standard
  TCP only, no custom crypto) — clears the per-build export-compliance prompt in
  App Store Connect.~~
- [ ] Build a real **signed** App Store archive path (distribution cert + profile,
  `xcodebuild -exportArchive` with App Store export plist, upload via
  Transporter/Xcode). Current CI is unsigned.
- [ ] App Store Connect: privacy nutrition label → **Data Not Collected**.
- [ ] App Store Connect: host a short **privacy policy URL** (reuse the
  `PrivacyDisclaimer` text) — required even when nothing is collected.
- [ ] Add **App Review note**: "Multiplayer needs 2 devices on the same Wi-Fi; Bot
  Mode and Local Play are fully testable on one device."
- [ ] Pick a **distinguishing App Store name** (plain "Shiritori" is likely taken;
  App Store names must be unique). e.g. "Shiritori: Nebula".

### 🟢 Peripheral / IP — cleared or to verify
- [x] ~~LAN multiplayer allowed on iOS — yes, Apple-supported (Network.framework +
  Bonjour).~~
- [x] ~~Local Network permission + Bonjour keys present in both Info.plists.~~
- [x] ~~App is reviewable on a single device (Bot + Local modes).~~
- [x] ~~App icon is 1024×1024 with no alpha channel.~~
- [x] ~~Local IP shown in host mode is a private/LAN address, host-only, not a
  privacy concern.~~
- [x] ~~"Shiritori" is a generic/traditional game name — low trademark risk.~~
- [ ] Verify `words_dictionary.json` source & license (confirm dwyl/english-words /
  public domain) and keep an attribution note.
- [ ] Confirm `AppIcon-1024.png` is original art and contains **no SF Symbol**
  (Apple forbids SF Symbols in app icons).
- [ ] Confirm authorship of the Python originals this is derived from (own work).

### 🟡 Code quality (non-blocking)
- [x] ~~Split the 2,970-line `ShiritoriApp.swift` into per-concern files (Theme,
  Models, DictionaryStore, BotAI, AudioHaptics, Effects, Components, GameEngine,
  Networking, AppModel, Screens). Pure move, no behavior change.~~
- [ ] Stop overloading `lastEvent` as a generic "something changed" signal
  (`applyStateDiff` emits a fake `.donated`).
- [ ] Clarify the bot-turn staleness guard in `scheduleBotTurn`
  (`timerGen == gen || botPlayerNum != nil` is effectively always-true for bots).
- [ ] Randomize the opening word (every game currently starts with "apple").
- [ ] Manual IP field: use `.numbersAndPunctuation` instead of `.decimalPad`.

### ✅ Done
- [x] ~~Add `README.md` (merged to `main`, PR #1).~~
- [x] ~~Add an in-game **Leave** button (was no way to quit/pause once a game
  started). `QuitButton` with a confirm dialog on every game screen →
  `model.backToLobby()`. Rule polish intentionally skipped.~~
