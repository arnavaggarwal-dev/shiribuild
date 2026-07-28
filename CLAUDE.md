# CLAUDE.md

Working notes and task tracker for the Shiritori iOS app. Update the checklists
below as work lands — check the box **and** strike the text (`~~…~~`) when done.

## Project overview

Native SwiftUI word-chain game for iOS (deployment target 17.0). Rebuild of the
desktop Python originals (`shiritori_bot.py` / `shiritori_net.py`) — same rules,
same "cosmic nebula" palette. Two ways to play: **Local Game** (pass-and-play,
with 0-7 AI opponents mixed in — this merges what used to be separate "Bot
Mode" and "Local Play" screens) and **LAN multiplayer** (Bonjour discovery +
fixed TCP port 55731, PC join by IP).

No backend, no accounts, no analytics, no third-party Swift dependencies.

**One caveat on "offline":** looking up a starred word's definition sends that
single word to a free third-party dictionary service over HTTPS. It's the only
outbound internet call in the app, it's user-initiated, and it can be switched
off in Settings. Everything else — games, scores, starred words — stays on the
device.

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
- `Sources/MyApp/GameEngine.swift` — authoritative rules engine (Local/Host).
  `botPlayerNums: Set<Int>` supports any number of simultaneous bot seats —
  strictly turn-based, so multiple bots need no concurrent bookkeeping, each
  just triggers `scheduleBotTurn()` on its own turn.
- `Sources/MyApp/Networking.swift` — `WireFraming`, `LANHost`, `LANBrowser`, `LANClient`.
- `Sources/MyApp/AppModel.swift` — top-level coordinator (route + live backend).
- `Sources/MyApp/Screens.swift` — all full-screen views (lobby, setup, join,
  waiting, game, winner) + their private helpers.
- `Sources/MyApp/Stores.swift` — `GameLogEntry`, `StarredWord`, `WordFolder` and
  their JSON-file-backed `GameLogStore` / `StarredStore`.
- `Sources/MyApp/LogScreens.swift` — game history list + detail, and the shared
  `StarToggleButton`.
- `Sources/MyApp/StarredScreens.swift` — starred words, folder assignment, definition sheet.
- `Sources/MyApp/DictionaryAPI.swift` — `CachedDefinition` + the 4-provider lookup chain.
- `Sources/MyApp/ColorEditor.swift` — RGB/HSV picker for the two themeable colours.
- `Sources/MyApp/AppSettings.swift` — persisted prefs + Settings screen.
- `Sources/MyApp/PrivacyDisclaimer.swift` — one-time first-launch privacy notice.
- `Sources/MyApp/words_dictionary.json` — ~370k-word English dictionary (looks like
  the public-domain dwyl/english-words list). Loaded off-main at launch.
- `Info.plist` (root) — used by the xtool build. `Sources/MyApp/Info.plist` — used
  by the XcodeGen/Xcode build. **Keep both in sync.**

### How the pieces talk
- `GameEngine` is the single source of truth for Bot, Local, and Host games.
- `AppModel.showWinner(...)` is the one funnel every finished game passes through
  (bot / local / host / client), so it's where history logging hooks in.
- `Palette` members for the themeable colours are `static var` computed properties
  reading `ThemeStore.shared`, which is what lets a recolor apply without touching
  any of the ~189 `Palette.x` call sites. `RootView` hangs `.id(theme.revision)`
  off the store to force the repaint, since static properties publish nothing.
- The lobby is five `LobbyModeCard` banners (Local Game, Host, Join, Game Log,
  Starred Words), each pushing a `Route`. It is deliberately not a `TabView`.
  Local Game and the old Bot Mode are merged — `PlaySetupView` has two
  sliders (Humans, Bots) sharing an 8-player cap instead of separate screens.
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
- [ ] App Store Connect: privacy nutrition label → **Data Not Collected**. Note the
  dictionary lookup now sends a single word to a third-party service; nothing is
  collected *by us*, but the third-party call should be disclosed.
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
- [x] ~~Stop overloading `lastEvent` as a generic "something changed" signal
  (`applyStateDiff` emits a fake `.donated`). Fixed: the catch-all branch no
  longer sets `lastEvent` at all — nothing read it (GameEventFlash already
  treated `.donated` as a no-op), so the state re-assignment above it is
  enough.~~
- [ ] Clarify the bot-turn staleness guard in `scheduleBotTurn`
  (`timerGen == gen || !botPlayerNums.isEmpty` is effectively always-true
  whenever any bot is in the game).
- [x] ~~Randomize the opening word (every game currently starts with "apple").~~
- [x] ~~Manual IP field: use `.numbersAndPunctuation` instead of `.decimalPad`.~~

### ✅ Done
- [x] ~~Merge Bot Mode + Local Play into one `PlaySetupView` behind a single
  lobby banner ("Local Game", `storefront.fill` icon). Two sliders (Humans,
  Bots) share an 8-player cap — Humans floors at 1, Bots floors at 0 and its
  ceiling shrinks as Humans grows. Required `GameEngine.botPlayerNum: Int?` →
  `botPlayerNums: Set<Int>` to support multiple simultaneous bots; back-to-back
  bot turns get a randomized 1-6s pause (vs. the fixed 0.9s human→bot pause)
  so a chain of bots doesn't read as instant, scripted replies. Start is
  disabled below 2 total players — a 1-player game would crash
  `GameEngine.eliminate` (`activePlayers[0]` on an empty array).~~
- [x] ~~Fix the slider tone lingering 2-5s after a fast drag: `Haptics.sliderTick`
  fired `ToneEngine.play()` on every step with no throttling, and
  `ToneEngine` has no queue cancellation, so a fast drag across a wide range
  queued dozens of tones that played back-to-back after the finger lifted.
  Throttled to ~55ms between tones (haptic feedback stays untouched — it
  doesn't queue audibly).~~
- [x] ~~FPS pass, scoped to zero visual risk: `LazyVStack` for the Game Log and
  Starred Words lists (were eager `VStack`s); `.drawingGroup()` on the
  nebula background's three animating blurred blobs only (flattens three
  offscreen blur passes into one Metal-backed layer — deliberately **not**
  applied to anything with `.ultraThinMaterial`, since that would sample a
  rasterized backdrop instead of the real one and risk visibly breaking the
  translucency).~~
- [x] ~~Game history log + starred words. Finished games are recorded at
  `AppModel.showWinner`; words can be starred from the in-game header banner
  or from any past game's word list; starred words support multi-folder
  tagging, deletion, and an online definition + example sentence. Settings
  gained logging on/off, a warned "delete all game logs", an online-lookup
  opt-out, and RGB/HSV editors for the accent and background colours.~~
- [x] ~~Add `README.md` (merged to `main`, PR #1).~~
- [x] ~~Add an in-game **Leave** button (was no way to quit/pause once a game
  started). `QuitButton` with a confirm dialog on every game screen →
  `model.backToLobby()`. Rule polish intentionally skipped.~~
- [x] ~~Add a `GameEngineTests`/`BotAITests` unit test suite (new `MyAppTests`
  target in `Package.swift`/`project.yml`) covering word accept/reject,
  duplicate/forbidden-letter handling, `/skip`, `/donate`, game-over, and a
  bot turn end-to-end. `DictionaryStore.loadForTesting(_:)` is the seam that
  makes this deterministic (no async 370k-word bundle load).~~
