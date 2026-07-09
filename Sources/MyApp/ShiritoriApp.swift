//
//  ShiritoriApp.swift
//  Shiritori
//
//  Native SwiftUI rebuild of the desktop Shiritori games (shiritori_bot.py /
//  shiritori_net.py). Same rules, same "cosmic nebula" palette, same bot
//  brain — new coat of paint and Bonjour instead of raw sockets.
//
//  SETUP (do this once in Xcode):
//   1. New Project → App → Interface: SwiftUI, Life Cycle: SwiftUI.
//   2. Delete the template ContentView.swift.
//   3. Drag this file + words_dictionary.json into the project (check
//      "Copy items if needed" and your app target).
//   4. Info tab on the target → add:
//        Privacy - Local Network Usage Description  → "Used to find nearby
//          Shiritori games on your Wi-Fi."
//        Bonjour services (array) → "_shiritori._tcp"
//      (Without these two keys, LAN hosting/joining will silently fail on
//      a real device — iOS gates Bonjour behind that permission.)
//   5. Build & run. That's it, no other dependencies.
//

import SwiftUI
import Network
import Combine
import UIKit
import AVFoundation

// MARK: - Palette

/// Exact hex values from the Tkinter build's cosmic nebula theme, so this
/// still feels like the same game.
enum Palette {
    static let bg        = Color(hex: 0x07050F)
    static let card       = Color(hex: 0x0D0818)
    static let card2      = Color(hex: 0x130E24)
    static let border      = Color(hex: 0x2D1B54)
    static let borderActive = Color(hex: 0x6D28D9)
    static let accent      = Color(hex: 0xA855F7)
    static let glow        = Color(hex: 0xC084FC)
    static let red         = Color(hex: 0xF472B6)
    static let redBright   = Color(hex: 0xEC4899)
    static let green       = Color(hex: 0x34D399)
    static let orange      = Color(hex: 0xFB923C)
    static let dim         = Color(hex: 0x5B4D7A)
    static let text        = Color(hex: 0xEDE9FE)
    static let deepOut     = Color(hex: 0x3D0000)
    static let forbiddenBorder = Color(hex: 0x7C2D2D)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

// MARK: - Type scale

/// Small type namespace so the whole app draws from one font family
/// (SF Rounded) instead of ad-hoc sizes scattered through the views.
enum GameFont {
    static func display(_ size: CGFloat = 34) -> Font { .system(size: size, weight: .bold, design: .rounded) }
    static func title(_ size: CGFloat = 22) -> Font { .system(size: size, weight: .bold, design: .rounded) }
    static func headline(_ size: CGFloat = 15) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
    static func body(_ size: CGFloat = 14) -> Font { .system(size: size, weight: .regular, design: .rounded) }
    static func caption(_ size: CGFloat = 11) -> Font { .system(size: size, weight: .medium, design: .rounded) }
    static func mono(_ size: CGFloat = 22) -> Font { .system(size: size, weight: .bold, design: .rounded).monospacedDigit() }
}

// MARK: - Models

/// Mirrors the dict that Python's `_state()` / `_apply_state()` pass around
/// on the wire — one shared shape for local play, bot play, and both ends
/// of a LAN game.
struct GameState: Codable, Equatable {
    var currentPlayer: Int
    var previousWord: String
    var wordList: [String]
    var scores: [Int]
    var activePlayers: [Int]
    var forbidden: String   // single char, kept as String for easy Codable/JSON
    var numPlayers: Int

    static let empty = GameState(currentPlayer: 1, previousWord: "apple", wordList: ["apple"],
                                  scores: [0], activePlayers: [1], forbidden: "z", numPlayers: 1)

    static func fresh(numPlayers: Int) -> GameState {
        let letter = Character(UnicodeScalar(UInt8.random(in: 97...122)))
        return GameState(currentPlayer: 1, previousWord: "apple", wordList: ["apple"],
                          scores: Array(repeating: 0, count: numPlayers),
                          activePlayers: Array(1...numPlayers),
                          forbidden: String(letter), numPlayers: numPlayers)
    }

    var forbiddenChar: Character { forbidden.first ?? "z" }
}

/// What just happened, so the UI can pick an animation/haptic without the
/// engine needing to know anything about SwiftUI.
enum GameEvent: Equatable {
    case none
    case accepted(word: String, points: Int, player: Int)
    case rejected(reason: String)
    case eliminated(player: Int, isBot: Bool)
    case skipped(player: Int, penalty: Int)      // penalty: -10, 0, or Int.min for "eliminated via skip"
    case donated(from: Int, to: Int, amount: Int)
    case botThinking
    case botPlayed(word: String, points: Int)
    case gameOver(winner: Int)
}

/// Wire protocol for LAN play. One loose envelope (mirrors the Python
/// dict-based protocol) rather than a family of tiny structs — every field
/// is optional and only the relevant ones are set per `type`.
struct NetMessage: Codable {
    enum Kind: String, Codable {
        case welcome, tick, gameStart = "game_start", stateUpdate = "state_update"
        case msg, gameEnd = "game_end", action, playerJoined = "player_joined"
    }

    var type: Kind
    var playerNum: Int?
    var numPlayers: Int?
    var timeLeft: Int?
    var text: String?          // key "text"  — used by `msg` (matches Python)
    var msgText: String?       // key "msg"   — used by state_update / game_end (matches Python)
    var color: String?         // "#RRGGBB", same string format the Python build sends
    var winner: Int?
    var word: String?          // used for `action`
    var count: Int?            // used for `player_joined`

    // state snapshot, flattened in when type is game_start / state_update / game_end
    var currentPlayer: Int?
    var previousWord: String?
    var wordList: [String]?
    var scores: [Int]?
    var activePlayers: [Int]?
    var forbidden: String?

    /// Wire keys are snake_case to stay byte-compatible with the dicts in
    /// shiritori_net.py. Note "wordlist" — one word, matching Python's
    /// `_state()`, NOT the "word_list" a generic snake_case strategy makes.
    enum CodingKeys: String, CodingKey {
        case type
        case playerNum = "player_num"
        case numPlayers = "num_players"
        case timeLeft = "time_left"
        case text
        case msgText = "msg"
        case color
        case winner
        case word
        case count
        case currentPlayer = "current_player"
        case previousWord = "previous_word"
        case wordList = "wordlist"
        case scores
        case activePlayers = "active_players"
        case forbidden
    }

    var asState: GameState? {
        guard let currentPlayer, let previousWord, let wordList, let scores,
              let activePlayers, let forbidden, let numPlayers else { return nil }
        return GameState(currentPlayer: currentPlayer, previousWord: previousWord, wordList: wordList,
                          scores: scores, activePlayers: activePlayers, forbidden: forbidden,
                          numPlayers: numPlayers)
    }

    /// Whichever text field this message carries — Python puts it under
    /// "text" for `msg` packets but under "msg" for state envelopes.
    var displayText: String? { text ?? msgText }

    static func stateEnvelope(_ kind: Kind, state: GameState, text: String? = nil,
                               color: Color? = nil, winner: Int? = nil) -> NetMessage {
        NetMessage(type: kind, numPlayers: state.numPlayers, msgText: text, color: color?.toHexString(),
                   winner: winner, currentPlayer: state.currentPlayer, previousWord: state.previousWord,
                   wordList: state.wordList, scores: state.scores, activePlayers: state.activePlayers,
                   forbidden: state.forbidden)
    }
}

extension Color {
    /// Round-trips through UIColor to get sRGB components for wire transfer,
    /// as a "#RRGGBB" string — the exact format the Python build sends.
    func toHexString() -> String {
        let ui = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }

    /// Parses "#RRGGBB" or "RRGGBB" (any case). Returns nil for anything else.
    init?(hexString: String?) {
        guard let hexString else { return nil }
        var s = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self = Color(hex: v)
    }
}

/// Screens the root view can be on. Not a NavigationStack because the app
/// wants full control over cross-fades against the nebula background.
enum Route: Equatable {
    case lobby
    case botSetup
    case localSetup
    case hostSetup
    case joinList
    case waitingHost(total: Int)
    case waitingClient
    case botGame
    case localGame
    case hostGame
    case clientGame
    case winner(WinnerInfo)
    case disconnected
}

struct WinnerInfo: Equatable {
    var winner: Int
    var isBot: Bool
    var scores: [Int]
    var active: [Int]
    var numPlayers: Int
    var wordsPlayed: Int
    var botDifficulty: Int?
    var myPlayerNum: Int?   // set only for LAN games, to say "that's you!"
    var names: (Int) -> String
    var extraNote: String

    static func == (l: WinnerInfo, r: WinnerInfo) -> Bool {
        l.winner == r.winner && l.scores == r.scores && l.active == r.active
    }
}

// MARK: - Dictionary

/// Loads words_dictionary.json once, off the main thread, and builds the
/// same first-letter index the Python bot uses (`WORDS_BY_LETTER`).
final class DictionaryStore: ObservableObject {
    @Published private(set) var isLoaded = false
    @Published private(set) var loadFailed = false
    /// Human-readable trace of what the loader tried and where it ended up.
    /// Shown on the loading screen so failures are visible without a Mac.
    @Published private(set) var diagnostic = ""

    private(set) var wordSet: Set<String> = []
    private(set) var byFirstLetter: [Character: [String]] = [:]

    /// Every place the dictionary might live, depending on how the app was
    /// built (SwiftPM/xtool nested bundle vs. plain-Xcode app root). We try
    /// them all rather than betting on one.
    private func candidateURLs() -> [(String, URL)] {
        var out: [(String, URL)] = []
        if let u = Bundle.main.url(forResource: "words_dictionary", withExtension: "json") {
            out.append(("Bundle.main", u))
        }
        // Bundle.main's resourceURL, joined manually (covers odd bundle layouts).
        if let base = Bundle.main.resourceURL {
            out.append(("main.resourceURL/", base.appendingPathComponent("words_dictionary.json")))
        }
        // The SwiftPM-generated module bundle, if this was an xtool build.
        // Referenced by name so it compiles even in the Xcode target where
        // Bundle.module doesn't exist.
        if let moduleBundleURL = Bundle.main.url(forResource: "MyApp_MyApp", withExtension: "bundle"),
           let b = Bundle(url: moduleBundleURL),
           let u = b.url(forResource: "words_dictionary", withExtension: "json") {
            out.append(("MyApp_MyApp.bundle", u))
        }
        return out
    }

    func load() {
        guard !isLoaded else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            var trace = ""

            let candidates = self.candidateURLs()
            trace += "candidates: \(candidates.count)\n"

            // Also list what's actually sitting in the bundle root, so if
            // none of the candidates hit, we can see what IS there.
            if let base = Bundle.main.resourceURL,
               let items = try? FileManager.default.contentsOfDirectory(atPath: base.path) {
                let jsons = items.filter { $0.hasSuffix(".json") || $0.hasSuffix(".bundle") }
                trace += "in bundle: \(jsons.isEmpty ? "(no .json/.bundle)" : jsons.joined(separator: ", "))\n"
            }

            var chosen: URL?
            for (label, url) in candidates where FileManager.default.fileExists(atPath: url.path) {
                trace += "found via \(label)\n"
                chosen = url
                break
            }

            guard let url = chosen else {
                trace += "RESULT: file not found anywhere"
                self.finish(failed: true, trace: trace)
                return
            }

            guard let data = try? Data(contentsOf: url) else {
                trace += "RESULT: found but couldn't read bytes"
                self.finish(failed: true, trace: trace)
                return
            }
            trace += "read \(data.count / 1024) KB\n"

            guard let jsonObj = try? JSONSerialization.jsonObject(with: data),
                  let raw = jsonObj as? [String: Int] else {
                trace += "RESULT: read \(data.count) bytes but JSON parse failed"
                self.finish(failed: true, trace: trace)
                return
            }

            var set = Set<String>(minimumCapacity: raw.count)
            var byLetter: [Character: [String]] = [:]
            for word in raw.keys where !word.isEmpty {
                set.insert(word)
                byLetter[word[word.startIndex], default: []].append(word)
            }
            trace += "parsed \(set.count) words"
            self.wordSet = set
            self.byFirstLetter = byLetter
            self.finish(failed: false, trace: trace)
        }
    }

    private func finish(failed: Bool, trace: String) {
        DispatchQueue.main.async {
            self.diagnostic = trace
            self.loadFailed = failed
            self.isLoaded = true
        }
    }

    func isValid(_ word: String) -> Bool {
        wordSet.isEmpty || wordSet.contains(word)
    }

    /// Bypass a stuck/failed load and let the user play without validation
    /// (empty wordSet ⇒ isValid accepts anything).
    func markReadyUnvalidated() {
        loadFailed = true
        isLoaded = true
    }
}

// MARK: - Bot AI

/// Direct port of `bot_pick_word` from shiritori_bot.py: build a pool where
/// roughly `difficulty`% is drawn from safe (non-suicidal) words and the
/// rest from words that would end in the forbidden letter, then pick at
/// random from that pool — with a 1% chance to go rogue and pick a
/// forbidden-ending word regardless of difficulty.
func botPickWord(start: Character, used: Set<String>, forbidden: Character,
                  difficulty: Int, byFirstLetter: [Character: [String]]) -> String? {
    let candidates = (byFirstLetter[start] ?? []).filter { $0.count > 1 && !used.contains($0) }
    guard !candidates.isEmpty else { return nil }

    let safe = candidates.filter { $0.last != forbidden }
    let danger = candidates.filter { $0.last == forbidden }

    let dangerN = Int((Double(danger.count) * Double(100 - difficulty) / 100).rounded())
    let safeN = Int((Double(safe.count) * Double(difficulty) / 100).rounded())

    var pool = Array(danger.shuffled().prefix(min(dangerN, danger.count)))
    pool += safe.shuffled().prefix(min(safeN, safe.count))
    if pool.isEmpty { pool = !safe.isEmpty ? safe : danger }

    if !danger.isEmpty && Double.random(in: 0..<1) < 0.01 {
        return danger.randomElement()
    }
    return pool.randomElement()
}

// MARK: - Haptics

// MARK: - Tone Engine

/// Generates short one-shot sine-wave "dings" to pair with haptics — an
/// exponential-decay envelope so each tone sounds like a plucked note
/// rather than a harsh buzz. Kept dead simple: no sample files, buffers are
/// synthesized on the fly (they're a few KB and ~0.15s, cost is trivial).
final class ToneEngine {
    static let shared = ToneEngine()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let sampleRate: Double = 44100
    // Every buffer we ever generate uses this exact format. Connecting the
    // graph with `format: nil` lets it inherit whatever the hardware route
    // happens to be at connect time — if that later changes (AirPods
    // connecting/disconnecting mid-game is a real, common case), the graph
    // and the buffers we hand it disagree, and scheduleBuffer raises an
    // NSException that Swift can't catch, crashing the app outright. Using
    // one fixed, explicit format here means CoreAudio handles the
    // conversion to whatever the hardware wants internally instead.
    private lazy var toneFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!

    private init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: toneFormat)
        try? AVAudioSession.sharedInstance().setCategory(.ambient, options: [.mixWithOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        try? engine.start()

        // Route changes (headphones connecting, a call interrupting, etc.)
        // can invalidate the running graph. Rebuild the connection instead
        // of leaving stale state that the next scheduleBuffer call would
        // crash on.
        NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            self?.rebuildConnection()
        }
    }

    private func rebuildConnection() {
        engine.disconnectNodeOutput(player)
        engine.connect(player, to: engine.mainMixerNode, format: toneFormat)
        if !engine.isRunning { try? engine.start() }
    }

    func play(frequency: Double, duration: Double = 0.14, volume: Float = 0.5) {
        guard let buffer = makeBuffer(frequency: frequency, duration: duration, volume: volume) else { return }
        if !engine.isRunning {
            // A missed sound effect is fine. A crash mid-game is not — if
            // the engine can't start (interrupted session, no audio route,
            // etc.), skip this tone entirely rather than schedule a buffer
            // into a graph that isn't ready for it.
            guard (try? engine.start()) != nil, engine.isRunning else { return }
        }
        player.scheduleBuffer(buffer, completionHandler: nil)
        if !player.isPlaying { player.play() }
    }

    /// Two quick notes back to back — used for the "teh-teh" loser cue.
    func playDouble(frequency: Double, gap: Double = 0.11, duration: Double = 0.09, volume: Float = 0.45) {
        play(frequency: frequency, duration: duration, volume: volume)
        DispatchQueue.main.asyncAfter(deadline: .now() + gap) { [weak self] in
            self?.play(frequency: frequency * 0.85, duration: duration, volume: volume)
        }
    }

    private func makeBuffer(frequency: Double, duration: Double, volume: Float) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: toneFormat, frameCapacity: frameCount) else { return nil }
        buffer.frameLength = frameCount
        let data = buffer.floatChannelData![0]
        for i in 0..<Int(frameCount) {
            let t = Double(i) / sampleRate
            let envelope = exp(-7.0 * t)   // fast attack, quick exponential decay
            data[i] = Float(sin(2.0 * .pi * frequency * t)) * volume * Float(envelope)
        }
        return buffer
    }
}

// MARK: - Haptics

enum Haptics {
    /// Every accepted word: success haptic + a bright high-pitched ding.
    /// Pitch is fixed high here (this is "the correct answer" cue, not a
    /// graded one) — the graded/"tougher = higher" pitch lives in sliderTick.
    static func accepted() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        ToneEngine.shared.play(frequency: 880, duration: 0.16, volume: 0.55)
    }

    static func rejected() {
        UINotificationFeedbackGenerator().notificationOccurred(.error)
        ToneEngine.shared.play(frequency: 220, duration: 0.14, volume: 0.4)
    }

    static func warning() {
        let gen = UIImpactFeedbackGenerator(style: .heavy)
        gen.impactOccurred(intensity: 1.0)
    }

    static func winner() {
        let gen = UIImpactFeedbackGenerator(style: .heavy)
        gen.impactOccurred(intensity: 1.0)
        ToneEngine.shared.play(frequency: 660, duration: 0.18, volume: 0.6)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
            ToneEngine.shared.play(frequency: 990, duration: 0.3, volume: 0.6)
        }
    }

    /// Base tap for every button — bumped from .light to .medium at full
    /// intensity so navigation reads as a firmer, more deliberate click.
    static func tap() {
        let gen = UIImpactFeedbackGenerator(style: .medium)
        gen.impactOccurred(intensity: 1.0)
    }

    /// Slider "cascade" tick: fire once per discrete step while dragging.
    /// `fraction` is 0...1 of how far into the range the value sits —
    /// intensity AND pitch both scale up with it, so a slider representing
    /// something getting "tougher" (bot difficulty, player count, etc.)
    /// feels and sounds more intense near the top of its range.
    static func sliderTick(fraction: Double) {
        let f = min(max(fraction, 0), 1)
        let gen = UIImpactFeedbackGenerator(style: f > 0.66 ? .heavy : (f > 0.33 ? .medium : .light))
        gen.impactOccurred(intensity: 0.5 + f * 0.5)
        ToneEngine.shared.play(frequency: 260 + f * 620, duration: 0.06, volume: 0.28)
    }

    /// 2-second "teh-teh… teh-teh…" losing cue: four double-pulses (each a
    /// heavy haptic pair plus a falling two-note chirp) spaced across ~2s.
    static func loser() {
        for i in 0..<4 {
            let delay = Double(i) * 0.5
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                let gen = UIImpactFeedbackGenerator(style: .heavy)
                gen.impactOccurred(intensity: 1.0)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.11) {
                    let gen2 = UIImpactFeedbackGenerator(style: .heavy)
                    gen2.impactOccurred(intensity: 0.85)
                }
                ToneEngine.shared.playDouble(frequency: 180, gap: 0.11, duration: 0.1, volume: 0.4)
            }
        }
    }
}

// MARK: - Shake Effect

/// Classic Apple recipe: a GeometryEffect that offsets horizontally along a
/// decaying sine wave, driven by an animatable "shakes" value so SwiftUI can
/// interpolate it like any other animation.
struct ShakeEffect: GeometryEffect {
    var shakes: CGFloat
    var amplitude: CGFloat = 10

    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let translation = amplitude * sin(shakes * .pi * 2)
        return ProjectionTransform(CGAffineTransform(translationX: translation, y: 0))
    }
}

extension View {
    func shake(_ trigger: Int) -> some View {
        modifier(ShakeModifier(trigger: trigger))
    }
}

private struct ShakeModifier: ViewModifier {
    let trigger: Int
    @State private var shakes: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .modifier(ShakeEffect(shakes: shakes))
            .onChange(of: trigger) { _, _ in
                shakes = 0
                withAnimation(.linear(duration: 0.45)) { shakes = 4 }
            }
    }
}

// MARK: - Small view helpers

/// Frosted floating card used everywhere: lobby tiles, header, score rows.
/// This stays material-based by design, not by toolchain limitation —
/// Apple's Liquid Glass HIG explicitly reserves glass for the functional
/// layer (buttons, controls) and warns against stacking it onto content
/// surfaces like these. See SolidButton/GhostButton for where the real
/// .glassEffect()/.buttonStyle(.glass) API is actually used, gated behind
/// #available(iOS 26, *) so the same IPA works on iOS 17+.
struct GlassCardStyle: ViewModifier {
    var borderColor: Color = Palette.border
    var fill: Color = Palette.card
    var radius: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(fill.opacity(0.72))
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))

                    // Diagonal specular sheen — a soft light-from-above
                    // highlight, the cheapest way to sell "glass" without
                    // the real refraction API.
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.white.opacity(0.10), .clear, .clear],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            )
                        )
                }
            )
            .overlay(
                // Two-tone edge: a bright hairline along the top where
                // light would catch a glass rim, fading to the normal
                // border color — reads as a lit edge rather than a flat
                // outline.
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [borderColor.opacity(0.9), Color.white.opacity(0.35), borderColor.opacity(0.9)],
                                       startPoint: .leading, endPoint: .trailing),
                        lineWidth: 1
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(0.28), radius: 14, x: 0, y: 8)
    }
}

extension View {
    func glassCard(border: Color = Palette.border, fill: Color = Palette.card, radius: CGFloat = 18) -> some View {
        modifier(GlassCardStyle(borderColor: border, fill: fill, radius: radius))
    }

    func glow(_ color: Color, radius: CGFloat = 14, opacity: Double = 0.6) -> some View {
        self.shadow(color: color.opacity(opacity), radius: radius)
    }
}

// MARK: - Nebula Background

private struct Star: Identifiable {
    let id = UUID()
    var x: CGFloat
    var y: CGFloat
    var size: CGFloat
    var twinkleSpeed: Double
    var twinklePhase: Double
    var depth: CGFloat   // 0.2...1.0, drives parallax drift speed
}

/// Deep-space backdrop: soft drifting purple blobs behind a twinkling,
/// slow-parallax star field. Generated once per launch and animated with
/// TimelineView so it costs almost nothing while sitting idle.
struct AnimatedNebulaBackground: View {
    @State private var stars: [Star] = (0..<90).map { _ in
        Star(x: .random(in: 0...1), y: .random(in: 0...1),
             size: .random(in: 1...2.6), twinkleSpeed: .random(in: 0.6...1.8),
             twinklePhase: .random(in: 0...(.pi * 2)), depth: .random(in: 0.2...1))
    }
    @State private var blobsDrift = false

    var body: some View {
        ZStack {
            Palette.bg.ignoresSafeArea()

            // slow drifting nebula blobs
            GeometryReader { geo in
                ZStack {
                    Circle()
                        .fill(Palette.accent.opacity(0.22))
                        .frame(width: geo.size.width * 0.9)
                        .blur(radius: 90)
                        .offset(x: blobsDrift ? geo.size.width * 0.18 : -geo.size.width * 0.1,
                                y: blobsDrift ? -geo.size.height * 0.12 : geo.size.height * 0.05)
                        .animation(.easeInOut(duration: 14).repeatForever(autoreverses: true), value: blobsDrift)

                    Circle()
                        .fill(Palette.borderActive.opacity(0.28))
                        .frame(width: geo.size.width * 0.7)
                        .blur(radius: 100)
                        .offset(x: blobsDrift ? -geo.size.width * 0.22 : geo.size.width * 0.15,
                                y: blobsDrift ? geo.size.height * 0.35 : geo.size.height * 0.55)
                        .animation(.easeInOut(duration: 18).repeatForever(autoreverses: true), value: blobsDrift)

                    Circle()
                        .fill(Palette.redBright.opacity(0.08))
                        .frame(width: geo.size.width * 0.5)
                        .blur(radius: 80)
                        .offset(x: blobsDrift ? geo.size.width * 0.3 : geo.size.width * 0.05,
                                y: blobsDrift ? geo.size.height * 0.75 : geo.size.height * 0.9)
                        .animation(.easeInOut(duration: 22).repeatForever(autoreverses: true), value: blobsDrift)
                }
            }
            .ignoresSafeArea()

            TimelineView(.animation(minimumInterval: 1.0 / 24, paused: false)) { timeline in
                Canvas { ctx, size in
                    let t = timeline.date.timeIntervalSinceReferenceDate
                    for star in stars {
                        // Downward cascade speed scales with depth (parallax).
                        let speed: CGFloat = 0.035 + star.depth * 0.05
                        let rawY = star.y + CGFloat(t) * speed
                        let wrapCount = Int(rawY)               // how many times this star has looped
                        let y = (rawY.truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1) * size.height

                        // Re-randomize x each time a star completes a loop so
                        // falling stars don't pile up into visible repeating
                        // columns/streaks — deterministic hash of (id, wrapCount)
                        // means no mutable state needed, just a pure function of t.
                        var hasher = Hasher()
                        hasher.combine(star.id)
                        hasher.combine(wrapCount)
                        let hashed = abs(hasher.finalize())
                        let xJitter = CGFloat(hashed % 10_000) / 10_000
                        let x = ((star.x + xJitter * 0.6).truncatingRemainder(dividingBy: 1)) * size.width

                        let twinkle = 0.35 + 0.65 * abs(sin(t * star.twinkleSpeed + star.twinklePhase))
                        let rect = CGRect(x: x, y: y, width: star.size, height: star.size)
                        ctx.opacity = twinkle * Double(star.depth)
                        ctx.fill(Path(ellipseIn: rect), with: .color(Palette.text))
                    }
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
        .onAppear { blobsDrift = true }
    }
}

// MARK: - Buttons

/// Tactile press feedback shared by SolidButton/GhostButton — scales and
/// dims slightly on press with a springy release. This is the "liquid,
/// responsive" feel this project can ship today without the literal
/// Liquid Glass API (see the note on GlassCardStyle above for why).
struct PressableGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .opacity(configuration.isPressed ? 0.85 : 1.0)
            .animation(.spring(response: 0.28, dampingFraction: 0.55), value: configuration.isPressed)
    }
}

/// Solid pill button — primary CTA (Start Game, Play Word, Play Again…).
///
/// Branches at runtime, not at compile time: this is the same binary
/// running on iOS 17 and iOS 26 alike (deployment target stays 17.0). On
/// iOS 26+ it renders with the real Liquid Glass button style; everywhere
/// else it falls back to the material-based look this project already had.
/// This is Apple's own documented pattern for "one IPA, works everywhere."
struct SolidButton: View {
    var title: String
    var systemImage: String? = nil
    var color: Color = Palette.accent
    var height: CGFloat = 50
    var isEnabled: Bool = true
    var action: () -> Void

    var body: some View {
        Group {
            if #available(iOS 26, *) {
                Button {
                    Haptics.tap()
                    action()
                } label: {
                    HStack(spacing: 8) {
                        if let systemImage { Image(systemName: systemImage) }
                        Text(title)
                    }
                    .font(GameFont.headline(15))
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                }
                .buttonStyle(.glassProminent)
                .tint(color)
            } else {
                Button {
                    Haptics.tap()
                    action()
                } label: {
                    HStack(spacing: 8) {
                        if let systemImage { Image(systemName: systemImage) }
                        Text(title)
                    }
                    .font(GameFont.headline(15))
                    .foregroundStyle(Palette.text)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .background(
                        LinearGradient(colors: [color.opacity(0.95), color.opacity(0.7)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .overlay(
                        LinearGradient(colors: [Color.white.opacity(0.22), .clear],
                                       startPoint: .top, endPoint: .center)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                    )
                }
                .buttonStyle(PressableGlassButtonStyle())
            }
        }
        .glow(color, radius: 16, opacity: isEnabled ? 0.45 : 0)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityAddTraits(.isButton)
    }
}

/// Outline "ghost" button — secondary actions (Back, Fullscreen equivalents).
/// Same runtime-branch approach as SolidButton above.
struct GhostButton: View {
    var title: String
    var systemImage: String? = nil
    var color: Color = Palette.dim
    var height: CGFloat = 42
    var action: () -> Void

    var body: some View {
        Group {
            if #available(iOS 26, *) {
                Button {
                    Haptics.tap()
                    action()
                } label: {
                    HStack(spacing: 8) {
                        if let systemImage { Image(systemName: systemImage) }
                        Text(title)
                    }
                    .font(GameFont.headline(13))
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                }
                .buttonStyle(.glass)
                .tint(color)
            } else {
                Button {
                    Haptics.tap()
                    action()
                } label: {
                    HStack(spacing: 8) {
                        if let systemImage { Image(systemName: systemImage) }
                        Text(title)
                    }
                    .font(GameFont.headline(13))
                    .foregroundStyle(color)
                    .frame(maxWidth: .infinity)
                    .frame(height: height)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Palette.card2.opacity(0.6))
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(color, lineWidth: 1)
                    )
                }
                .buttonStyle(PressableGlassButtonStyle())
            }
        }
        .accessibilityAddTraits(.isButton)
    }
}

/// Labeled slider used for player counts / difficulty — big value readout,
/// minimum 44pt track height for comfortable thumb dragging.
struct LabeledSlider: View {
    var label: String
    var valueText: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 1
    var tint: Color = Palette.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(label).font(GameFont.caption()).foregroundStyle(Palette.dim)
                Spacer()
                Text(valueText).font(GameFont.headline(14)).foregroundStyle(Palette.glow)
            }
            Slider(value: $value, in: range, step: step)
                .tint(tint)
                .frame(minHeight: 44)
                .onChange(of: value) { _, newValue in
                    let span = range.upperBound - range.lowerBound
                    let fraction = span > 0 ? (newValue - range.lowerBound) / span : 0
                    Haptics.sliderTick(fraction: fraction)
                }
        }
    }
}

// MARK: - Score Card

struct ScoreCardView: View {
    var playerNum: Int
    var isBot: Bool
    var score: Int
    var isActive: Bool
    var isOut: Bool
    var isMe: Bool = false
    @State private var displayedScore: Int = 0

    private var name: String {
        isBot ? "Bot" : (isMe ? "You" : "Player \(playerNum)")
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(isBot ? Palette.borderActive.opacity(0.35) : Palette.card2)
                    .frame(width: 34, height: 34)
                if isBot {
                    Text("🤖").font(.system(size: 16))
                } else {
                    Text("P\(playerNum)")
                        .font(GameFont.caption(10))
                        .foregroundStyle(isActive ? Palette.glow : Palette.dim)
                }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(GameFont.caption(11))
                    .foregroundStyle(isOut ? Palette.dim : (isActive ? Palette.text : Palette.dim))
                if isOut {
                    Text("out").font(GameFont.caption(9)).foregroundStyle(Palette.redBright)
                }
            }
            Spacer()
            Text("\(displayedScore)")
                .font(GameFont.mono(15))
                .foregroundStyle(isOut ? Palette.redBright : (isActive ? Palette.glow : Palette.dim))
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(isActive ? (isBot ? Palette.borderActive.opacity(0.18) : Palette.accent.opacity(0.14)) : Palette.card2)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isOut ? Palette.deepOut : (isActive ? Palette.accent : Palette.border), lineWidth: isActive ? 1.4 : 1)
        )
        .glow(isActive ? Palette.accent : .clear, radius: 10, opacity: 0.5)
        .saturation(isOut ? 0.35 : 1)
        .opacity(isOut ? 0.55 : 1)
        .blur(radius: isOut ? 0.4 : 0)
        .onAppear { displayedScore = score }
        .onChange(of: score) { _, new in
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) { displayedScore = new }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(score) points\(isOut ? ", eliminated" : (isActive ? ", current turn" : ""))")
    }
}

// MARK: - Word Chain

struct ChainCapsule: View {
    var word: String
    var isNewest: Bool

    var body: some View {
        Text(word)
            .font(GameFont.body(13))
            .foregroundStyle(Palette.text)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isNewest ? Palette.accent.opacity(0.3) : Palette.card2)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(isNewest ? Palette.accent : Palette.border, lineWidth: 1))
    }
}

struct WordChainView: View {
    var words: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(words.enumerated()), id: \.offset) { idx, word in
                        HStack(spacing: 8) {
                            ChainCapsule(word: word, isNewest: idx == words.count - 1)
                                .id(idx)
                            if idx < words.count - 1 {
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Palette.dim)
                            }
                        }
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .opacity))
                    }
                }
                .padding(.horizontal, 4)
                .animation(.spring(response: 0.45, dampingFraction: 0.75), value: words)
            }
            .onChange(of: words.count) { _, _ in
                withAnimation { proxy.scrollTo(words.count - 1, anchor: .trailing) }
            }
        }
    }
}

// MARK: - Circular Timer

struct CircularTimerView: View {
    var timeLeft: Int
    var total: Int = 30

    private var fraction: CGFloat {
        max(0, min(1, CGFloat(timeLeft) / CGFloat(total)))
    }
    private var isUrgent: Bool { timeLeft <= 10 }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Palette.border, lineWidth: 5)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(isUrgent ? Palette.redBright : Palette.accent,
                        style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: 0.9), value: fraction)
            Text("\(max(0, timeLeft))")
                .font(GameFont.mono(18))
                .foregroundStyle(isUrgent ? Palette.redBright : Palette.accent)
        }
        .frame(width: 52, height: 52)
        .accessibilityLabel("\(max(0, timeLeft)) seconds left")
    }
}

// MARK: - Bot Thinking Indicator

struct BouncingDotsView: View {
    @State private var bounce = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Palette.glow)
                    .frame(width: 7, height: 7)
                    .offset(y: bounce ? -5 : 0)
                    .animation(
                        .easeInOut(duration: 0.5)
                        .repeatForever(autoreverses: true)
                        .delay(Double(i) * 0.15),
                        value: bounce
                    )
            }
        }
        .onAppear { bounce = true }
    }
}

// MARK: - Confetti

private struct ConfettiPiece: Identifiable {
    let id = UUID()
    var x: CGFloat
    var delay: Double
    var duration: Double
    var color: Color
    var rotation: Double
    var size: CGFloat
}

struct ConfettiView: View {
    @State private var pieces: [ConfettiPiece] = []
    @State private var fallen = false

    private let colors = [Palette.accent, Palette.glow, Palette.green, Palette.orange, Palette.redBright]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(pieces) { piece in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(piece.color)
                        .frame(width: piece.size, height: piece.size * 0.4)
                        .rotationEffect(.degrees(fallen ? piece.rotation : 0))
                        .position(x: piece.x * geo.size.width, y: fallen ? geo.size.height + 40 : -20)
                        .animation(
                            .easeIn(duration: piece.duration).delay(piece.delay),
                            value: fallen
                        )
                }
            }
            .onAppear {
                pieces = (0..<60).map { _ in
                    ConfettiPiece(x: .random(in: 0...1), delay: .random(in: 0...0.5),
                                  duration: .random(in: 1.6...2.6), color: colors.randomElement()!,
                                  rotation: .random(in: 180...720), size: .random(in: 6...11))
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { fallen = true }
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Game Engine

/// Authoritative rules engine — direct port of the state machine shared by
/// `ShiritoriBot` (bot.py) and the local-play branch of `ShiritoriApp`
/// (net.py). Used as-is for Bot Mode and Local Pass-and-Play, and wrapped
/// by `LANHost` as the source of truth for network games.
final class GameEngine: ObservableObject {
    @Published var state: GameState
    @Published var message: String = "Chain by the last letter. No repeats. Don't end on the forbidden letter."
    @Published var messageColor: Color = Palette.dim
    @Published var timeLeft: Int = 30
    @Published var isGameOver = false
    @Published var botDifficulty: Int
    @Published var isBotThinking = false
    @Published var lastEvent: GameEvent = .none
    @Published var shakeTrigger = 0

    let botPlayerNum: Int?
    private let dict: DictionaryStore
    private var timer: Timer?
    private var timerGen = 0
    private var warnedThisTurn = false

    /// Fires after every turn-ending mutation. LANHost hooks this to
    /// broadcast; bot/local play just ignore it.
    var onStateChanged: ((GameState, String, Color) -> Void)?
    var onGameOver: ((Int, String) -> Void)?

    var dangerPoolPercent: Int { 100 - botDifficulty }

    init(dict: DictionaryStore, numPlayers: Int, botPlayerNum: Int?, botDifficulty: Int = 50) {
        self.dict = dict
        self.botPlayerNum = botPlayerNum
        self.botDifficulty = botDifficulty
        self.state = .fresh(numPlayers: numPlayers)
    }

    func start() {
        if state.currentPlayer == botPlayerNum {
            scheduleBotTurn()
        } else {
            startTimer()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        timerGen += 1
    }

    private func isBot(_ p: Int) -> Bool { botPlayerNum != nil && p == botPlayerNum }

    private func nextPlayer() -> Int {
        guard let idx = state.activePlayers.firstIndex(of: state.currentPlayer) else { return state.currentPlayer }
        return state.activePlayers[(idx + 1) % state.activePlayers.count]
    }

    // MARK: turn submission (also the entry point LANHost calls for remote players)

    func attemptAction(playerNum: Int, raw rawInput: String) {
        guard !isGameOver else { return }
        guard state.currentPlayer == playerNum else { return }
        let raw = rawInput.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !raw.isEmpty else { return }

        if raw == "/help" {
            setMessage("/skip · /donate <pts> <p> · /wordlist · /help", Palette.accent); return
        }
        if raw == "/rules" {
            setMessage("Chain by last letter. No repeats. Forbidden: '\(state.forbidden)'.", Palette.accent); return
        }
        if raw == "/wordlist" {
            setMessage("Used: " + state.wordList.joined(separator: ", "), Palette.accent); return
        }
        if raw == "/skip" { doSkip(playerNum); return }
        if raw.hasPrefix("/donate") { doDonate(playerNum, raw: raw); return }

        submitWord(playerNum, raw)
    }

    private func submitWord(_ p: Int, _ raw: String) {
        if state.wordList.contains(raw) {
            reject("Already used — pick a different word."); return
        }
        if !dict.isValid(raw) {
            reject("\"\(raw)\" is not a valid English word."); return
        }
        guard let firstChar = raw.first, let prevLast = state.previousWord.last, firstChar == prevLast else {
            let need = state.previousWord.last.map(String.init) ?? ""
            reject("Word must start with \"\(need)\"."); return
        }
        if raw.last == state.forbiddenChar {
            eliminate(p, reason: "Player \(p) is out! Word ended with forbidden '\(state.forbidden)'.")
            return
        }
        state.wordList.append(raw)
        state.scores[p - 1] += raw.count
        state.previousWord = raw
        lastEvent = .accepted(word: raw, points: raw.count, player: p)
        Haptics.accepted()
        setMessage(isBot(p) ? "🤖 Bot played '\(raw)'  (+\(raw.count) pts)" : "Nice! +\(raw.count) pts for Player \(p).",
                   isBot(p) ? Palette.glow : Palette.green)
        advanceTurn()
    }

    private func doSkip(_ p: Int) {
        let name = isBot(p) ? "🤖 Bot" : "Player \(p)"
        let outcome = Int.random(in: 0...2)
        switch outcome {
        case 0:
            state.scores[p - 1] = max(0, state.scores[p - 1] - 10)
            lastEvent = .skipped(player: p, penalty: -10)
            setMessage("\(name) skipped — lost 10 pts!", Palette.orange)
        case 1:
            lastEvent = .skipped(player: p, penalty: 0)
            setMessage("\(name) skipped safely — no penalty.", Palette.green)
        default:
            eliminate(p, reason: "\(name) skipped and got eliminated!")
            return
        }
        advanceTurn()
    }

    private func doDonate(_ p: Int, raw: String) {
        let parts = raw.split(separator: " ")
        guard parts.count == 3, let amt = Int(parts[1]), let target = Int(parts[2]) else {
            reject("/donate <pts> <player>"); return
        }
        guard amt > 0, target >= 1, target <= state.numPlayers, target != p else {
            reject("Invalid target."); return
        }
        guard state.activePlayers.contains(target) else {
            let tname = isBot(target) ? "🤖 Bot" : "Player \(target)"
            reject("\(tname) is already out."); return
        }
        let actual = min(amt, state.scores[p - 1])
        state.scores[p - 1] -= actual
        state.scores[target - 1] += actual
        let tname = isBot(target) ? "🤖 Bot" : "Player \(target)"
        lastEvent = .donated(from: p, to: target, amount: actual)
        setMessage("Player \(p) donated \(actual) pts to \(tname). Turn skipped.", Palette.accent)
        advanceTurn()
    }

    private func eliminate(_ p: Int, reason: String) {
        let color: Color = isBot(p) ? Palette.redBright : Palette.orange
        let next = nextPlayer()
        state.activePlayers.removeAll { $0 == p }
        lastEvent = .eliminated(player: p, isBot: isBot(p))
        Haptics.loser()
        setMessage(reason, color)
        if state.activePlayers.count == 1 {
            stop()
            let winner = state.activePlayers[0]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { [weak self] in
                self?.finish(winner: winner, note: reason)
            }
            return
        }
        state.currentPlayer = next
        onStateChanged?(state, reason, color)
        if isBot(next) {
            scheduleBotTurn()
        } else {
            startTimer()
        }
    }

    private func advanceTurn() {
        state.currentPlayer = nextPlayer()
        onStateChanged?(state, message, messageColor)
        if isBot(state.currentPlayer) {
            scheduleBotTurn()
        } else {
            startTimer()
        }
    }

    private func reject(_ text: String) {
        lastEvent = .rejected(reason: text)
        Haptics.rejected()
        shakeTrigger += 1
        setMessage(text, Palette.red)
    }

    private func setMessage(_ text: String, _ color: Color) {
        message = text
        messageColor = color
    }

    private func finish(winner: Int, note: String) {
        isGameOver = true
        lastEvent = .gameOver(winner: winner)
        Haptics.winner()
        onGameOver?(winner, note)
    }

    // MARK: bot

    private func scheduleBotTurn() {
        isBotThinking = true
        lastEvent = .botThinking
        let gen = timerGen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
            guard let self, self.timerGen == gen || self.botPlayerNum != nil else { return }
            self.doBotTurn()
        }
    }

    private func doBotTurn() {
        guard !isGameOver, let botNum = botPlayerNum, state.currentPlayer == botNum else { return }
        isBotThinking = false
        guard let last = state.previousWord.last,
              let word = botPickWord(start: last, used: Set(state.wordList), forbidden: state.forbiddenChar,
                                      difficulty: botDifficulty, byFirstLetter: dict.byFirstLetter) else {
            doSkip(botNum); return
        }
        if word.last == state.forbiddenChar {
            eliminate(botNum, reason: "🤖 Bot played '\(word)' — ends with forbidden '\(state.forbidden)'! Bot is out.")
            return
        }
        state.wordList.append(word)
        state.scores[botNum - 1] += word.count
        state.previousWord = word
        lastEvent = .botPlayed(word: word, points: word.count)
        setMessage("🤖 Bot played '\(word)'  (+\(word.count) pts)", Palette.glow)
        advanceTurn()
    }

    // MARK: timer

    private func startTimer() {
        timer?.invalidate()
        timerGen += 1
        let gen = timerGen
        timeLeft = 30
        warnedThisTurn = false
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
            guard let self, self.timerGen == gen else { t.invalidate(); return }
            self.tick()
        }
    }

    private func tick() {
        if timeLeft == 5 && !warnedThisTurn {
            warnedThisTurn = true
            Haptics.warning()
        }
        if timeLeft <= 0 {
            timer?.invalidate()
            if !isBot(state.currentPlayer) {
                doSkip(state.currentPlayer)
            }
            return
        }
        timeLeft -= 1
    }
}

// MARK: - Disconnect handling (shared elimination path)

extension GameEngine {
    /// Same consequences as a rule-violation elimination, but triggered by a
    /// dropped connection instead of a bad word. Mirrors `_handle_disconnect`
    /// in shiritori_net.py — no dramatic pause, since there's nothing to see.
    func forceRemove(_ p: Int, note: String) {
        guard state.activePlayers.contains(p) else { return }
        let advancesCurrent = state.currentPlayer == p
        let next = advancesCurrent ? nextPlayer() : state.currentPlayer
        state.activePlayers.removeAll { $0 == p }
        lastEvent = .eliminated(player: p, isBot: false)
        if state.activePlayers.isEmpty {
            stop(); return
        }
        if state.activePlayers.count == 1 {
            stop()
            finish(winner: state.activePlayers[0], note: note)
            return
        }
        state.currentPlayer = next
        setMessage(note, Palette.orange)
        onStateChanged?(state, note, Palette.orange)
        if advancesCurrent {
            startTimer()
        }
    }
}

// MARK: - Wire Framing

/// Length-prefixed JSON over TCP — a 4-byte big-endian size header followed
/// by that many bytes of payload. Same idea as `send_msg`/`recv_msg` in
/// shiritori_net.py, just written by hand instead of relying on an
/// NWProtocolFramer subclass.
enum WireFraming {
    static func encode<T: Encodable>(_ value: T) -> Data? {
        guard let payload = try? JSONEncoder().encode(value) else { return nil }
        let n = UInt32(payload.count)
        let header = Data([UInt8((n >> 24) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 8) & 0xFF), UInt8(n & 0xFF)])
        return header + payload
    }

    private static func decodeLength(_ header: Data) -> Int {
        let b = [UInt8](header)
        guard b.count == 4 else { return 0 }
        return (Int(b[0]) << 24) | (Int(b[1]) << 16) | (Int(b[2]) << 8) | Int(b[3])
    }

    static func receiveLoop(_ connection: NWConnection,
                             onMessage: @escaping (Data) -> Void,
                             onClose: @escaping () -> Void) {
        connection.receive(minimumIncompleteLength: 4, maximumLength: 4) { header, _, _, error in
            guard let header, header.count == 4, error == nil else { onClose(); return }
            let length = decodeLength(header)
            guard length > 0, length < 10_000_000 else { onClose(); return }
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { body, _, _, error2 in
                guard let body, body.count == length, error2 == nil else { onClose(); return }
                onMessage(body)
                receiveLoop(connection, onMessage: onMessage, onClose: onClose)
            }
        }
    }

    static func send(_ msg: NetMessage, on connection: NWConnection) {
        guard let data = encode(msg) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }
}

// MARK: - LAN Host

/// Runs the authoritative GameEngine and advertises it over Bonjour. The
/// host device plays as Player 1 directly against `engine` (no loopback
/// connection needed, unlike the Python version) — remote players connect
/// in as players 2...N and their moves arrive as `.action` messages.
final class LANHost: ObservableObject {
    @Published var connectedCount = 1     // host itself counts as seat 1
    @Published var startError: String?
    @Published var gameStarted = false

    let numPlayers: Int
    let engine: GameEngine
    /// Fires once after the engine reports game over — after LANHost has
    /// already broadcast the game_end packet to every client.
    var onGameEnded: ((Int, String) -> Void)?
    private var listener: NWListener?
    private var connections: [Int: NWConnection] = [:]
    private var nextPlayerSlot = 2
    private var remoteJoined = 0
    /// Set before intentionally cancelling connections (stopHosting, or the
    /// host backgrounding the app). NWConnection.cancel() delivers its
    /// .cancelled state update asynchronously — without this guard, that
    /// delayed callback reaches handleDisconnect AFTER teardown started,
    /// forceRemove sees the host as the sole remaining active player, and
    /// spuriously declares the host the winner for leaving the game.
    private var isShuttingDown = false

    init(numPlayers: Int, dict: DictionaryStore) {
        self.numPlayers = numPlayers
        self.engine = GameEngine(dict: dict, numPlayers: numPlayers, botPlayerNum: nil)
        engine.onStateChanged = { [weak self] state, text, color in
            self?.broadcast(.stateEnvelope(.stateUpdate, state: state, text: text, color: color))
        }
        engine.onGameOver = { [weak self] winner, note in
            guard let self else { return }
            self.broadcast(.stateEnvelope(.gameEnd, state: self.engine.state, text: note, winner: winner))
            self.onGameEnded?(winner, note)
        }
    }

    func startHosting(deviceName: String) {
        do {
            let params = NWParameters.tcp
            params.includePeerToPeer = true
            params.allowLocalEndpointReuse = true
            // Fixed port 55731 = PORT in shiritori_net.py, so desktop players
            // can join with just this device's IP. Bonjour advertisement on
            // top keeps iOS↔iOS discovery automatic.
            let l = try NWListener(using: params, on: NWEndpoint.Port(rawValue: 55731)!)
            l.service = NWListener.Service(name: "\(deviceName)'s Shiritori", type: "_shiritori._tcp")
            l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
            l.start(queue: .main)
            listener = l
        } catch {
            startError = "Couldn't start hosting: \(error.localizedDescription)"
        }
    }

    private func accept(_ connection: NWConnection) {
        guard nextPlayerSlot <= numPlayers else { connection.cancel(); return }
        let slot = nextPlayerSlot
        nextPlayerSlot += 1
        remoteJoined += 1
        connections[slot] = connection
        connectedCount = remoteJoined + 1

        connection.stateUpdateHandler = { [weak self] st in
            switch st {
            case .failed, .cancelled: self?.handleDisconnect(slot)
            default: break
            }
        }
        connection.start(queue: .main)
        WireFraming.send(NetMessage(type: .welcome, playerNum: slot, numPlayers: numPlayers), on: connection)
        broadcast(NetMessage(type: .playerJoined, count: connectedCount))

        WireFraming.receiveLoop(connection, onMessage: { [weak self] data in
            self?.handleIncoming(data, from: slot)
        }, onClose: { [weak self] in
            self?.handleDisconnect(slot)
        })

        if remoteJoined == numPlayers - 1 {
            broadcast(.stateEnvelope(.gameStart, state: engine.state))
            gameStarted = true
            engine.start()
        }
    }

    private func handleIncoming(_ data: Data, from slot: Int) {
        guard let msg = try? JSONDecoder().decode(NetMessage.self, from: data),
              msg.type == .action, let word = msg.word else { return }
        engine.attemptAction(playerNum: slot, raw: word)
    }

    private func handleDisconnect(_ slot: Int) {
        guard !isShuttingDown else { return }
        guard connections[slot] != nil else { return }
        connections.removeValue(forKey: slot)
        engine.forceRemove(slot, note: "Player \(slot) disconnected.")
    }

    private func broadcast(_ msg: NetMessage) {
        guard let data = WireFraming.encode(msg) else { return }
        for conn in connections.values {
            conn.send(content: data, completion: .contentProcessed { _ in })
        }
    }

    func stopHosting() {
        isShuttingDown = true
        listener?.cancel(); listener = nil
        for c in connections.values { c.cancel() }
        connections.removeAll()
        engine.stop()
    }
}

// MARK: - LAN Browser (joiner side discovery)

final class LANBrowser: ObservableObject {
    @Published var hosts: [NWBrowser.Result] = []
    private var browser: NWBrowser?

    func start() {
        let params = NWParameters()
        params.includePeerToPeer = true
        let b = NWBrowser(for: .bonjour(type: "_shiritori._tcp", domain: nil), using: params)
        b.browseResultsChangedHandler = { [weak self] results, _ in
            self?.hosts = results.sorted { lhs, rhs in hostDisplayName(lhs) < hostDisplayName(rhs) }
        }
        b.start(queue: .main)
        browser = b
    }

    func stop() {
        browser?.cancel(); browser = nil
        hosts = []
    }
}

func hostDisplayName(_ result: NWBrowser.Result) -> String {
    if case let .service(name, _, _, _) = result.endpoint { return name }
    return "Nearby game"
}

// MARK: - LAN Client (joiner side gameplay)

/// Doesn't run any rules itself — just mirrors whatever GameState the host
/// broadcasts and forwards this player's actions upstream, same division
/// of responsibility as `GameClient` in shiritori_net.py.
final class LANClient: ObservableObject {
    @Published var myPlayerNum: Int?
    @Published var numPlayers: Int = 2
    @Published var state = GameState.empty
    @Published var message = "Waiting for the host…"
    @Published var messageColor: Color = Palette.dim
    @Published var timeLeft = 30
    @Published var connectedWaitingText = "Connecting…"
    @Published var isConnected = false
    @Published var didDisconnect = false
    @Published var gameStarted = false
    @Published var isGameOver = false
    @Published var winner: Int?
    @Published var lastEvent: GameEvent = .none
    @Published var shakeTrigger = 0

    private var connection: NWConnection?

    func connect(to endpoint: NWEndpoint) {
        let conn = NWConnection(to: endpoint, using: .tcp)
        connection = conn
        conn.stateUpdateHandler = { [weak self] st in
            switch st {
            case .ready: self?.isConnected = true
            case .failed, .cancelled: self?.handleClose()
            default: break
            }
        }
        conn.start(queue: .main)
        WireFraming.receiveLoop(conn, onMessage: { [weak self] data in
            self?.handleIncoming(data)
        }, onClose: { [weak self] in
            self?.handleClose()
        })
    }

    func sendAction(_ raw: String) {
        guard let connection else { return }
        WireFraming.send(NetMessage(type: .action, word: raw), on: connection)
    }

    /// A couple of commands are cheap to answer locally without waiting on
    /// a round trip; everything else (including /skip, /donate, and real
    /// words) goes to the host, which is the only one who can validate it.
    func submitCommandOrWord(_ raw: String) {
        let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleaned.isEmpty else { return }
        if cleaned == "/help" {
            message = "/skip · /donate <pts> <p> · /wordlist · /help"; messageColor = Palette.accent; return
        }
        if cleaned == "/wordlist" {
            message = "Used: " + state.wordList.joined(separator: ", "); messageColor = Palette.accent; return
        }
        sendAction(cleaned)
    }

    private func handleIncoming(_ data: Data) {
        guard let msg = try? JSONDecoder().decode(NetMessage.self, from: data) else { return }
        switch msg.type {
        case .welcome:
            myPlayerNum = msg.playerNum
            numPlayers = msg.numPlayers ?? numPlayers
            connectedWaitingText = "You are Player \(msg.playerNum ?? 0) — waiting…"
        case .tick:
            timeLeft = msg.timeLeft ?? timeLeft
        case .gameStart:
            if let s = msg.asState { state = s }
            gameStarted = true
        case .stateUpdate:
            applyStateDiff(msg)
        case .msg:
            message = msg.text ?? ""
            messageColor = Color(hexString: msg.color) ?? Palette.red
            shakeTrigger += 1
        case .gameEnd:
            if let s = msg.asState { state = s }
            if let text = msg.displayText { message = text }
            winner = msg.winner
            isGameOver = true
            lastEvent = .gameOver(winner: msg.winner ?? 0)
            Haptics.winner()
        case .playerJoined:
            connectedWaitingText = "\(msg.count ?? 0)/\(numPlayers) connected"
        case .action:
            break
        }
    }

    /// The host only ever sends the *result* of a move as text + color, so
    /// this infers accepted/eliminated/other by diffing against the last
    /// known state — good enough to pick a matching flash/haptic locally.
    private func applyStateDiff(_ msg: NetMessage) {
        let old = state
        if let s = msg.asState { state = s }
        if let text = msg.displayText { message = text; messageColor = Color(hexString: msg.color) ?? Palette.accent }

        if state.wordList.count > old.wordList.count, let newWord = state.wordList.last {
            lastEvent = .accepted(word: newWord, points: newWord.count, player: old.currentPlayer)
            Haptics.accepted()
        } else if state.activePlayers.count < old.activePlayers.count {
            let removed = old.activePlayers.first { !state.activePlayers.contains($0) } ?? old.currentPlayer
            lastEvent = .eliminated(player: removed, isBot: false)
            Haptics.rejected()
        } else {
            lastEvent = .donated(from: old.currentPlayer, to: 0, amount: 0)
        }
    }

    private func handleClose() {
        guard !didDisconnect else { return }
        didDisconnect = true
        isConnected = false
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
    }
}

// MARK: - App Coordinator

/// Single source of truth for which screen is showing and which game
/// backend (bot / local / LAN host / LAN client) is currently live.
final class AppModel: ObservableObject {
    @Published var route: Route = .lobby

    // setup screen selections, kept as Double for direct Slider binding
    @Published var botHumanCount: Double = 1
    @Published var botDifficultyChoice: Double = 50
    @Published var localPlayerCount: Double = 2
    @Published var hostPlayerCount: Double = 2

    let dict = DictionaryStore()
    let browser = LANBrowser()

    private var cancellables = Set<AnyCancellable>()

    init() {
        // SwiftUI does NOT observe nested ObservableObjects: RootView watches
        // AppModel, but dict is its own ObservableObject, so dict.isLoaded
        // flipping never triggered a re-render — the loading screen sat there
        // forever even though the dictionary had loaded fine. Forward the
        // child's change signal through the parent.
        dict.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    @Published var engine: GameEngine?
    @Published var lanHost: LANHost?
    @Published var lanClient: LANClient?

    func loadDictionary() { dict.load() }
    func forceReady() { dict.markReadyUnvalidated() }

    func backToLobby() {
        engine?.stop()
        lanHost?.stopHosting()
        lanClient?.disconnect()
        browser.stop()
        engine = nil; lanHost = nil; lanClient = nil
        route = .lobby
    }

    /// Called when the app backgrounds. If we're actively hosting a LAN
    /// game, tear it down right now — proactively, while still foreground —
    /// rather than letting the OS suspend us mid-session. Without this, the
    /// connection eventually gets discovered dead only when the app is
    /// reopened, and by then forceRemove sees the host as the sole
    /// remaining player and spuriously declares them the winner for having
    /// left. Ending it here (no winner, just back to lobby) is honest about
    /// what actually happened: the host walked away.
    func handleScenePhaseChange(_ phase: ScenePhase) {
        guard phase == .background, lanHost != nil else { return }
        switch route {
        case .waitingHost, .hostGame:
            backToLobby()
        default:
            break
        }
    }

    // MARK: bot mode

    func startBotGame() {
        let n = Int(botHumanCount) + 1
        let e = GameEngine(dict: dict, numPlayers: n, botPlayerNum: n, botDifficulty: Int(botDifficultyChoice))
        e.onGameOver = { [weak self, weak e] winner, note in
            guard let self, let e else { return }
            self.showWinner(from: e.state, winner: winner, botNum: n, botDifficulty: e.botDifficulty,
                            note: note, myPlayerNum: nil)
        }
        engine = e
        route = .botGame
        e.start()
    }

    // MARK: local pass-and-play

    func startLocalGame() {
        let n = Int(localPlayerCount)
        let e = GameEngine(dict: dict, numPlayers: n, botPlayerNum: nil)
        e.onGameOver = { [weak self, weak e] winner, note in
            guard let self, let e else { return }
            self.showWinner(from: e.state, winner: winner, botNum: nil, botDifficulty: nil,
                            note: note, myPlayerNum: nil)
        }
        engine = e
        route = .localGame
        e.start()
    }

    // MARK: LAN host

    func createLobby() {
        let n = Int(hostPlayerCount)
        let host = LANHost(numPlayers: n, dict: dict)
        host.onGameEnded = { [weak self, weak host] winner, note in
            guard let self, let host else { return }
            self.showWinner(from: host.engine.state, winner: winner, botNum: nil, botDifficulty: nil,
                            note: note, myPlayerNum: 1)
        }
        host.startHosting(deviceName: UIDevice.current.name)
        lanHost = host
        route = .waitingHost(total: n)
    }

    // MARK: LAN join

    func startBrowsing() {
        browser.start()
        route = .joinList
    }

    func join(_ result: NWBrowser.Result) {
        let client = LANClient()
        client.connect(to: result.endpoint)
        lanClient = client
        route = .waitingClient
    }

    /// Joins a desktop (Python) host by typed IP — those hosts don't
    /// advertise over Bonjour, they just listen on the fixed port 55731.
    func joinManual(ip: String) {
        let trimmed = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let client = LANClient()
        client.connect(to: .hostPort(host: NWEndpoint.Host(trimmed),
                                     port: NWEndpoint.Port(rawValue: 55731)!))
        lanClient = client
        route = .waitingClient
    }

    func clientGameEnded() {
        guard let c = lanClient else { return }
        showWinner(from: c.state, winner: c.winner ?? 0, botNum: nil, botDifficulty: nil,
                  note: c.message, myPlayerNum: c.myPlayerNum)
    }

    // MARK: winner screen assembly

    private func showWinner(from state: GameState, winner: Int, botNum: Int?, botDifficulty: Int?,
                             note: String, myPlayerNum: Int?) {
        let info = WinnerInfo(
            winner: winner,
            isBot: botNum != nil && winner == botNum,
            scores: state.scores,
            active: state.activePlayers,
            numPlayers: state.numPlayers,
            wordsPlayed: state.wordList.count,
            botDifficulty: botDifficulty,
            myPlayerNum: myPlayerNum,
            names: { p in (botNum != nil && p == botNum) ? "🤖 Bot" : "Player \(p)" },
            extraNote: note
        )
        route = .winner(info)
    }
}

// MARK: - Loading Screen

struct LoadingView: View {
    @EnvironmentObject var model: AppModel
    @State private var pulse = false
    @State private var showDiagnostic = false

    var body: some View {
        VStack(spacing: 18) {
            Text("✦").font(.system(size: 40)).foregroundStyle(Palette.accent)
                .scaleEffect(pulse ? 1.15 : 0.9)
                .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: pulse)
            Text("SHIRITORI").font(GameFont.title(20)).foregroundStyle(Palette.text).tracking(4)
            BouncingDotsView()
            Text("loading the dictionary…").font(GameFont.caption()).foregroundStyle(Palette.dim)

            // After 3s, surface whatever the loader has recorded so far. If
            // the file can't be found or parsed, the reason shows here on
            // screen instead of the app hanging with no explanation.
            if showDiagnostic && !model.dict.diagnostic.isEmpty {
                Text(model.dict.diagnostic)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Palette.dim)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24).padding(.top, 8)
                Button("Continue anyway") { Haptics.tap(); model.forceReady() }
                    .font(GameFont.caption()).foregroundStyle(Palette.accent).padding(.top, 4)
            }
        }
        .onAppear {
            pulse = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { showDiagnostic = true }
        }
    }
}

// MARK: - Lobby

struct LobbyView: View {
    @EnvironmentObject var model: AppModel
    @State private var showNetworkAlert = false
    @State private var pendingNetworkAction: (() -> Void)?

    private func requireSameNetwork(then action: @escaping () -> Void) {
        pendingNetworkAction = action
        showNetworkAlert = true
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 4) {
                    Text("✦  SHIRITORI  ✦")
                        .font(GameFont.display(30))
                        .foregroundStyle(Palette.accent)
                        .glow(Palette.accent, radius: 18)
                    Text("chain words · survive · dominate")
                        .font(GameFont.caption())
                        .foregroundStyle(Palette.dim)
                }
                .padding(.top, 36)

                LobbyModeCard(
                    title: "Bot Mode", subtitle: "1-7 players + AI",
                    detail: "Play with friends on this device, plus an AI opponent with adjustable difficulty.",
                    icon: "cpu", accent: Palette.borderActive
                ) { model.route = .botSetup }

                LobbyModeCard(
                    title: "Local Play", subtitle: "2-8 players, same device",
                    detail: "Pass the phone or tablet around the table — everyone shares this screen.",
                    icon: "person.2.fill", accent: Palette.accent
                ) { model.route = .localSetup }

                LobbyModeCard(
                    title: "Host a Game", subtitle: "LAN · up to 8 players",
                    detail: "Start a game nearby players can discover and join automatically — no IP address needed.",
                    icon: "antenna.radiowaves.left.and.right", accent: Palette.glow
                ) { requireSameNetwork { model.route = .hostSetup } }

                LobbyModeCard(
                    title: "Join a Game", subtitle: "LAN",
                    detail: "Find a game already being hosted on this Wi-Fi network.",
                    icon: "wifi", accent: Palette.green
                ) { requireSameNetwork { model.startBrowsing() } }

                Spacer(minLength: 20)
            }
            .padding(.horizontal, 22)
        }
        .alert("Same Wi-Fi Required", isPresented: $showNetworkAlert) {
            Button("Got it") { pendingNetworkAction?(); pendingNetworkAction = nil }
            Button("Cancel", role: .cancel) { pendingNetworkAction = nil }
        } message: {
            Text("Everyone needs to be on the same Wi-Fi network to find each other — including if you're using a personal hotspot: every phone or PC playing must be connected to that same hotspot, not their own cellular data.")
        }
    }
}

private struct LobbyModeCard: View {
    var title: String
    var subtitle: String
    var detail: String
    var icon: String
    var accent: Color
    var action: () -> Void

    var body: some View {
        Button(action: { Haptics.tap(); action() }) {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(accent.opacity(0.18))
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .frame(width: 52, height: 52)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(accent.opacity(0.35), lineWidth: 1)
                        )
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(accent)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(title).font(GameFont.headline(16)).foregroundStyle(Palette.text)
                        Spacer()
                        Text(subtitle).font(GameFont.caption(10)).foregroundStyle(Palette.dim)
                    }
                    Text(detail).font(GameFont.body(12)).foregroundStyle(Palette.dim)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.dim)
            }
            .padding(16)
            .glassCard(border: Palette.border)
        }
        .buttonStyle(PressableGlassButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail)")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - Setup Screens

private func difficultyLabel(_ d: Int) -> String {
    switch d {
    case ...20: return "easy — short common words"
    case ...40: return "medium-easy"
    case ...60: return "medium"
    case ...80: return "hard — long/rare words"
    default: return "expert — maximum complexity"
    }
}

private func difficultyColor(_ d: Int) -> Color {
    switch d {
    case ...33: return Palette.green
    case ...66: return Palette.orange
    default: return Palette.redBright
    }
}

private struct SetupScaffold<Content: View>: View {
    var title: String
    var startTitle: String
    var startEnabled: Bool = true
    var onStart: () -> Void
    var onBack: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text(title)
                    .font(GameFont.title(24))
                    .foregroundStyle(Palette.accent)
                    .padding(.top, 40)

                VStack(spacing: 22) { content }
                    .padding(20)
                    .glassCard()

                SolidButton(title: startTitle, isEnabled: startEnabled, action: onStart)
                GhostButton(title: "Back", systemImage: "chevron.left", action: onBack)
                Spacer(minLength: 20)
            }
            .padding(.horizontal, 24)
        }
    }
}

struct BotSetupView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        SetupScaffold(
            title: "Bot Mode",
            startTitle: "Start Game",
            onStart: { model.startBotGame() },
            onBack: { model.route = .lobby }
        ) {
            LabeledSlider(label: "Human players", valueText: "\(Int(model.botHumanCount))",
                         value: $model.botHumanCount, range: 1...7, step: 1)
            Text("The bot always joins as an extra player.")
                .font(GameFont.caption()).foregroundStyle(Palette.dim)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider().overlay(Palette.border)

            LabeledSlider(label: "Bot difficulty", valueText: "\(Int(model.botDifficultyChoice))",
                         value: $model.botDifficultyChoice, range: 1...100, step: 1,
                         tint: difficultyColor(Int(model.botDifficultyChoice)))
            HStack {
                Text("1 Easy").foregroundStyle(Palette.green)
                Spacer()
                Text("50 Medium").foregroundStyle(Palette.orange)
                Spacer()
                Text("100 Expert").foregroundStyle(Palette.redBright)
            }
            .font(GameFont.caption(10))
            Text(difficultyLabel(Int(model.botDifficultyChoice)))
                .font(GameFont.caption(10)).foregroundStyle(Palette.dim)
        }
    }
}

struct LocalSetupView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        SetupScaffold(
            title: "Local Game",
            startTitle: "Start Game",
            onStart: { model.startLocalGame() },
            onBack: { model.route = .lobby }
        ) {
            LabeledSlider(label: "Number of players", valueText: "\(Int(model.localPlayerCount))",
                         value: $model.localPlayerCount, range: 2...8, step: 1)
            Text("Pass the device to whoever's turn it is.")
                .font(GameFont.caption()).foregroundStyle(Palette.dim)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct HostSetupView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        SetupScaffold(
            title: "Host a Game",
            startTitle: "Create Lobby",
            onStart: { model.createLobby() },
            onBack: { model.route = .lobby }
        ) {
            LabeledSlider(label: "Number of players", valueText: "\(Int(model.hostPlayerCount))",
                         value: $model.hostPlayerCount, range: 2...8, step: 1)
            Text("Nearby players will see your game appear automatically — nothing to type.")
                .font(GameFont.caption()).foregroundStyle(Palette.dim)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Join

struct JoinListView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var browser: LANBrowser
    @State private var manualIP = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Text("Join a Game").font(GameFont.title(24)).foregroundStyle(Palette.accent)
                    .padding(.top, 40)

                if browser.hosts.isEmpty {
                    VStack(spacing: 14) {
                        BouncingDotsView()
                        Text("Looking for nearby games…")
                            .font(GameFont.body(13)).foregroundStyle(Palette.dim)
                        Text("Make sure the host has created a lobby and you're on the same Wi-Fi.")
                            .font(GameFont.caption()).foregroundStyle(Palette.dim)
                            .multilineTextAlignment(.center)
                    }
                    .padding(30)
                    .glassCard()
                } else {
                    VStack(spacing: 10) {
                        ForEach(browser.hosts, id: \.self) { result in
                            Button {
                                Haptics.tap()
                                model.join(result)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "antenna.radiowaves.left.and.right")
                                        .foregroundStyle(Palette.glow)
                                    Text(hostDisplayName(result))
                                        .font(GameFont.headline(14)).foregroundStyle(Palette.text)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Palette.dim)
                                }
                                .padding(14)
                                .glassCard(border: Palette.borderActive)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Desktop (PC) hosts don't show up in the list above — they
                // don't broadcast Bonjour. Typing their IP reaches them on
                // the shared fixed port instead.
                VStack(alignment: .leading, spacing: 10) {
                    Text("Join a PC game by IP")
                        .font(GameFont.headline(13)).foregroundStyle(Palette.text)
                    Text("Desktop hosts don't appear in the list — enter the IP shown on their screen.")
                        .font(GameFont.caption()).foregroundStyle(Palette.dim)
                    HStack(spacing: 10) {
                        TextField("192.168.1.42", text: $manualIP)
                            .font(GameFont.body(14)).foregroundStyle(Palette.text)
                            .keyboardType(.decimalPad)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Palette.card2))
                            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Palette.border, lineWidth: 1))
                        Button {
                            Haptics.tap()
                            model.joinManual(ip: manualIP)
                        } label: {
                            Text("Join")
                                .font(GameFont.headline(14)).foregroundStyle(Palette.text)
                                .padding(.horizontal, 18).padding(.vertical, 10)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Palette.borderActive))
                        }
                        .buttonStyle(.plain)
                        .disabled(manualIP.trimmingCharacters(in: .whitespaces).isEmpty)
                        .opacity(manualIP.trimmingCharacters(in: .whitespaces).isEmpty ? 0.4 : 1)
                    }
                }
                .padding(16)
                .glassCard()

                GhostButton(title: "Back", systemImage: "chevron.left") {
                    browser.stop()
                    model.route = .lobby
                }
                Spacer(minLength: 20)
            }
            .padding(.horizontal, 24)
        }
    }
}

// MARK: - Waiting Rooms

struct HostWaitingRoomView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var host: LANHost
    var total: Int

    /// The device's local IPv4 that other players can actually reach.
    /// Priority: en0 (Wi-Fi client) → bridge100 (this phone IS the hotspot;
    /// host is always 172.20.10.1 there) → any other private-LAN interface.
    /// Cellular (pdp_ip*), VPN (utun*/ipsec*), and Apple p2p (awdl0/llw0)
    /// interfaces are excluded: those addresses look valid but are
    /// unreachable by LAN peers, which sends PC players into a dead end.
    private var wifiIPv4: String? {
        var byName: [String: String] = [:]
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            guard !ip.hasPrefix("169.254") else { continue }
            byName[String(cString: ifa.ifa_name)] = ip
        }
        if let wifi = byName["en0"] { return wifi }
        if let hotspot = byName["bridge100"] { return hotspot }
        // Last resort: any remaining interface that isn't cellular/VPN/p2p.
        let unreachablePrefixes = ["pdp_ip", "utun", "ipsec", "awdl", "llw"]
        for (name, ip) in byName where !unreachablePrefixes.contains(where: { name.hasPrefix($0) }) {
            return ip
        }
        return nil
    }

    var body: some View {
        VStack(spacing: 22) {
            Text("Lobby").font(GameFont.title(24)).foregroundStyle(Palette.accent)
            Text("Waiting for players…").font(GameFont.caption()).foregroundStyle(Palette.dim)

            VStack(spacing: 10) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 26)).foregroundStyle(Palette.glow)
                Text("Broadcasting nearby").font(GameFont.caption(11)).foregroundStyle(Palette.dim)
                Text("\(host.connectedCount)/\(total) connected")
                    .font(GameFont.mono(24)).foregroundStyle(Palette.accent)
            }
            .padding(28)
            .glassCard()

            // Desktop players can't see the Bonjour broadcast — they type
            // this into their PC client to join.
            VStack(spacing: 6) {
                Text("PC players join with").font(GameFont.caption(11)).foregroundStyle(Palette.dim)
                if let ip = wifiIPv4 {
                    Text(ip).font(GameFont.mono(20)).foregroundStyle(Palette.text)
                        .textSelection(.enabled)
                } else {
                    Text("No Wi-Fi address found — check Wi-Fi is on")
                        .font(GameFont.caption()).foregroundStyle(Palette.redBright)
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
            .glassCard()

            if let err = host.startError {
                Text(err).font(GameFont.caption()).foregroundStyle(Palette.redBright)
                    .multilineTextAlignment(.center)
            } else {
                BouncingDotsView()
                Text("Game starts automatically once everyone's in.")
                    .font(GameFont.caption()).foregroundStyle(Palette.dim)
            }

            GhostButton(title: "Cancel", systemImage: "xmark") { model.backToLobby() }
        }
        .padding(.horizontal, 30)
        .onChange(of: host.gameStarted) { _, started in
            if started { model.route = .hostGame }
        }
    }
}

struct ClientWaitingRoomView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var client: LANClient

    var body: some View {
        VStack(spacing: 22) {
            Text("Lobby").font(GameFont.title(24)).foregroundStyle(Palette.accent)
            VStack(spacing: 10) {
                BouncingDotsView()
                Text(client.connectedWaitingText)
                    .font(GameFont.headline(14)).foregroundStyle(Palette.glow)
            }
            .padding(28)
            .glassCard()
            Text("Game starts when all players join.").font(GameFont.caption()).foregroundStyle(Palette.dim)
            GhostButton(title: "Cancel", systemImage: "xmark") { model.backToLobby() }
        }
        .padding(.horizontal, 30)
        .onChange(of: client.gameStarted) { _, started in
            if started { model.route = .clientGame }
        }
        .onChange(of: client.didDisconnect) { _, disconnected in
            if disconnected { model.route = .disconnected }
        }
    }
}

// MARK: - Disconnected

struct DisconnectedView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            Text("✦").font(.system(size: 40)).foregroundStyle(Palette.red)
            Text("Disconnected").font(GameFont.title(20)).foregroundStyle(Palette.redBright)
            Text("Connection to the host was lost.")
                .font(GameFont.body(13)).foregroundStyle(Palette.dim)
            SolidButton(title: "Back to Lobby", action: { model.backToLobby() })
                .padding(.top, 10)
        }
        .padding(30)
        .glassCard()
        .padding(.horizontal, 40)
    }
}

// MARK: - Shared Game UI Pieces

/// Brief full-screen tint on accept/reject so a move reads instantly even
/// out of the corner of your eye — pairs with the screen shake on rejects.
private struct GameEventFlash: ViewModifier {
    var event: GameEvent
    @State private var flashColor = Color.clear
    @State private var flashOpacity = 0.0

    func body(content: Content) -> some View {
        content
            .overlay(flashColor.opacity(flashOpacity).allowsHitTesting(false).ignoresSafeArea())
            .onChange(of: event) { _, new in
                let color: Color?
                switch new {
                case .accepted, .botPlayed: color = Palette.green
                case .rejected, .eliminated: color = Palette.redBright
                default: color = nil
                }
                guard let color else { return }
                flashColor = color
                withAnimation(.easeOut(duration: 0.12)) { flashOpacity = 0.16 }
                withAnimation(.easeOut(duration: 0.5).delay(0.12)) { flashOpacity = 0 }
            }
    }
}

extension View {
    func gameEventFlash(_ event: GameEvent) -> some View { modifier(GameEventFlash(event: event)) }
}

struct GameHeaderCard: View {
    var currentWord: String
    var turnLabel: String
    var isBotThinking: Bool
    var forbiddenLetter: String
    var timeLeft: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    if isBotThinking {
                        HStack(spacing: 6) {
                            Text("🤖 Bot is thinking").font(GameFont.caption()).foregroundStyle(Palette.dim)
                            BouncingDotsView()
                        }
                    } else {
                        Text(turnLabel).font(GameFont.caption()).foregroundStyle(Palette.dim)
                    }
                    Text(currentWord)
                        .font(GameFont.display(32))
                        .foregroundStyle(Palette.glow)
                        .glow(Palette.glow, radius: 12, opacity: 0.35)
                        .contentTransition(.numericText())
                        .accessibilityLabel("Current word: \(currentWord)")
                }
                Spacer()
                HStack(spacing: 8) {
                    CircularTimerView(timeLeft: timeLeft)
                    VStack(spacing: 2) {
                        Text("forbidden").font(GameFont.caption(9)).foregroundStyle(Palette.red)
                        Text(forbiddenLetter.uppercased())
                            .font(GameFont.mono(20)).foregroundStyle(Palette.red)
                    }
                    .frame(width: 52, height: 52)
                    .glassCard(border: Palette.forbiddenBorder, fill: Palette.card2, radius: 12)
                }
            }
            if let last = currentWord.last {
                Text("Next word must start with \u{201C}\(String(last))\u{201D}")
                    .font(GameFont.caption()).foregroundStyle(Palette.dim)
            }
        }
        .padding(16)
        .glassCard()
    }
}

struct InputCard: View {
    @Binding var text: String
    var isEnabled: Bool
    var message: String
    var messageColor: Color
    var onSubmit: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            TextField("Type your word…", text: $text)
                .font(GameFont.body(15))
                .foregroundStyle(Palette.text)
                .padding(.horizontal, 14)
                .frame(height: 46)
                .background(Palette.card2)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Palette.border, lineWidth: 1))
                .disabled(!isEnabled)
                .opacity(isEnabled ? 1 : 0.5)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.done)
                .onSubmit(onSubmit)
                .accessibilityLabel("Word input")
                .accessibilityHint(isEnabled ? "Type a word and submit" : "Not your turn")

            SolidButton(title: "Play Word", systemImage: "arrow.up.circle.fill",
                       isEnabled: isEnabled && !text.trimmingCharacters(in: .whitespaces).isEmpty,
                       action: onSubmit)

            if !message.isEmpty {
                Text(message)
                    .font(GameFont.caption(11))
                    .foregroundStyle(messageColor)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: message)
            }
        }
        .padding(14)
        .glassCard()
    }
}

struct ChainCard: View {
    var words: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Word chain").font(GameFont.caption()).foregroundStyle(Palette.dim)
                Spacer()
                Text("\(words.count)").font(GameFont.headline(12)).foregroundStyle(Palette.accent)
            }
            WordChainView(words: words)
        }
        .padding(14)
        .glassCard()
    }
}

struct ScoreStrip: View {
    var numPlayers: Int
    var scores: [Int]
    var activePlayers: [Int]
    var currentPlayer: Int
    var botPlayerNum: Int?
    var myPlayerNum: Int?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(1...max(numPlayers, 1), id: \.self) { p in
                    ScoreCardView(
                        playerNum: p,
                        isBot: p == botPlayerNum,
                        score: p - 1 < scores.count ? scores[p - 1] : 0,
                        isActive: p == currentPlayer && activePlayers.contains(p),
                        isOut: !activePlayers.contains(p),
                        isMe: p == myPlayerNum
                    )
                    .frame(width: 148)
                }
            }
            .padding(.vertical, 2)
        }
    }
}

struct DifficultyLiveCard: View {
    @Binding var difficulty: Double
    var dangerPoolPercent: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("🤖 Difficulty").font(GameFont.caption()).foregroundStyle(Palette.glow)
                Spacer()
                Text("\(Int(difficulty))").font(GameFont.headline(12)).foregroundStyle(Palette.glow)
            }
            Slider(value: $difficulty, in: 1...100, step: 1)
                .tint(difficultyColor(Int(difficulty)))
                .onChange(of: difficulty) { _, newValue in
                    Haptics.sliderTick(fraction: (newValue - 1) / 99)
                }
            Text(difficultyLabel(Int(difficulty))).font(GameFont.caption(10)).foregroundStyle(Palette.dim)
            Text("Danger pool: \(dangerPoolPercent)%").font(GameFont.caption(10)).foregroundStyle(Palette.dim)
        }
        .padding(14)
        .glassCard()
    }
}

struct NotepadCard: View {
    @EnvironmentObject var model: AppModel
    @State private var words: [String] = []
    @State private var entry = ""
    @State private var note = ""
    @State private var noteColor = Palette.dim
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Notepad").font(GameFont.caption()).foregroundStyle(Palette.text)
                Spacer()
                Text("jot words").font(GameFont.caption(9)).foregroundStyle(Palette.dim)
            }
            if !words.isEmpty {
                ScrollView {
                    Text(words.joined(separator: "\n"))
                        .font(GameFont.body(12)).foregroundStyle(Palette.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 70)
                .padding(8)
                .background(Palette.card2)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            HStack(spacing: 8) {
                TextField("word → save", text: $entry)
                    .font(GameFont.body(13))
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .background(Palette.card2)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($focused)
                    .onSubmit(save)
                Button(action: { Haptics.tap(); save() }) {
                    Image(systemName: "plus.circle.fill").foregroundStyle(Palette.accent)
                        .font(.system(size: 22))
                }
            }
            if !note.isEmpty {
                Text(note).font(GameFont.caption(10)).foregroundStyle(noteColor)
            }
        }
        .padding(14)
        .glassCard()
    }

    private func save() {
        let raw = entry.trimmingCharacters(in: .whitespaces).lowercased()
        entry = ""
        guard !raw.isEmpty else { focused = true; return }
        if !model.dict.isValid(raw) {
            note = "\"\(raw)\" — not a word"; noteColor = Palette.red
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { note = "" }
            focused = true; return
        }
        words.append(raw)
        note = "\"\(raw)\" saved ✓"; noteColor = Palette.green
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { note = "" }
        focused = true
    }
}

struct CommandsCard: View {
    var body: some View {
        VStack(spacing: 4) {
            Text("commands").font(GameFont.caption(9)).foregroundStyle(Palette.dim)
            ForEach(["/skip", "/donate <pts> <p>", "/wordlist", "/help"], id: \.self) { cmd in
                Text(cmd).font(GameFont.caption(10)).foregroundStyle(Palette.accent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .glassCard()
    }
}

// MARK: - Game Screen (bot / local / LAN host)

struct GameView: View {
    @ObservedObject var engine: GameEngine
    var myPlayerNum: Int?
    @State private var text = ""

    private var inputEnabled: Bool {
        engine.state.currentPlayer != engine.botPlayerNum &&
        (myPlayerNum == nil || engine.state.currentPlayer == myPlayerNum)
    }

    private var turnLabel: String {
        if let myPlayerNum, engine.state.currentPlayer == myPlayerNum { return "✦ Your turn!" }
        return "Player \(engine.state.currentPlayer)'s turn"
    }

    private var difficultyBinding: Binding<Double> {
        Binding(get: { Double(engine.botDifficulty) }, set: { engine.botDifficulty = Int($0) })
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                GameHeaderCard(currentWord: engine.state.previousWord, turnLabel: turnLabel,
                              isBotThinking: engine.isBotThinking, forbiddenLetter: engine.state.forbidden,
                              timeLeft: engine.timeLeft)

                InputCard(text: $text, isEnabled: inputEnabled, message: engine.message,
                         messageColor: engine.messageColor, onSubmit: submit)

                ChainCard(words: engine.state.wordList)

                ScoreStrip(numPlayers: engine.state.numPlayers, scores: engine.state.scores,
                          activePlayers: engine.state.activePlayers, currentPlayer: engine.state.currentPlayer,
                          botPlayerNum: engine.botPlayerNum, myPlayerNum: myPlayerNum)

                if engine.botPlayerNum != nil {
                    DifficultyLiveCard(difficulty: difficultyBinding, dangerPoolPercent: engine.dangerPoolPercent)
                }

                NotepadCard()
                CommandsCard()
            }
            .frame(maxWidth: 640)
            .padding(16)
        }
        .shake(engine.shakeTrigger)
        .gameEventFlash(engine.lastEvent)
        .scrollDismissesKeyboard(.interactively)
    }

    private func submit() {
        let raw = text
        text = ""
        engine.attemptAction(playerNum: engine.state.currentPlayer, raw: raw)
    }
}

enum EngineGameMode { case bot, local, host }

struct EngineGameScreen: View {
    @EnvironmentObject var model: AppModel
    var mode: EngineGameMode

    var body: some View {
        switch mode {
        case .bot:
            if let e = model.engine { GameView(engine: e, myPlayerNum: nil) }
        case .local:
            if let e = model.engine { GameView(engine: e, myPlayerNum: nil) }
        case .host:
            if let h = model.lanHost { GameView(engine: h.engine, myPlayerNum: 1) }
        }
    }
}

// MARK: - Game Screen (LAN client)

struct ClientGameScreen: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let client = model.lanClient {
            ClientGameView(client: client)
        }
    }
}

struct ClientGameView: View {
    @ObservedObject var client: LANClient
    @EnvironmentObject var model: AppModel
    @State private var text = ""

    private var inputEnabled: Bool {
        client.myPlayerNum != nil && client.state.currentPlayer == client.myPlayerNum
    }

    private var turnLabel: String {
        inputEnabled ? "✦ Your turn!" : "Player \(client.state.currentPlayer)'s turn"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                GameHeaderCard(currentWord: client.state.previousWord, turnLabel: turnLabel,
                              isBotThinking: false, forbiddenLetter: client.state.forbidden,
                              timeLeft: client.timeLeft)

                InputCard(text: $text, isEnabled: inputEnabled, message: client.message,
                         messageColor: client.messageColor, onSubmit: submit)

                ChainCard(words: client.state.wordList)

                ScoreStrip(numPlayers: client.state.numPlayers, scores: client.state.scores,
                          activePlayers: client.state.activePlayers, currentPlayer: client.state.currentPlayer,
                          botPlayerNum: nil, myPlayerNum: client.myPlayerNum)

                NotepadCard()
                CommandsCard()
            }
            .frame(maxWidth: 640)
            .padding(16)
        }
        .shake(client.shakeTrigger)
        .gameEventFlash(client.lastEvent)
        .scrollDismissesKeyboard(.interactively)
        .onChange(of: client.isGameOver) { _, over in
            if over { model.clientGameEnded() }
        }
        .onChange(of: client.didDisconnect) { _, disconnected in
            if disconnected { model.route = .disconnected }
        }
    }

    private func submit() {
        let raw = text
        text = ""
        client.submitCommandOrWord(raw)
    }
}

// MARK: - Winner Screen

struct WinnerView: View {
    @EnvironmentObject var model: AppModel
    var info: WinnerInfo
    @State private var appear = false

    private var winnerIsMe: Bool { info.myPlayerNum != nil && info.myPlayerNum == info.winner }

    var body: some View {
        ZStack {
            ConfettiView()
            ScrollView {
                VStack(spacing: 18) {
                    Text("✦")
                        .font(.system(size: 46))
                        .foregroundStyle(info.isBot ? Palette.glow : Palette.accent)
                        .scaleEffect(appear ? 1 : 0.4)
                        .padding(.top, 40)
                    Text("Game Over").font(GameFont.title(24)).foregroundStyle(Palette.text)
                    Text(winnerText)
                        .font(GameFont.headline(16))
                        .foregroundStyle(info.isBot ? Palette.glow : (winnerIsMe ? Palette.glow : Palette.accent))
                        .multilineTextAlignment(.center)

                    VStack(alignment: .leading, spacing: 10) {
                        Text("Final Scores").font(GameFont.caption()).foregroundStyle(Palette.dim)
                        ForEach(sortedPlayers, id: \.self) { p in
                            HStack {
                                Text(rowLabel(p))
                                    .font(GameFont.body(13))
                                    .fontWeight(p == info.winner ? .bold : .regular)
                                Spacer()
                                Text("\(safeScore(p)) pts").font(GameFont.mono(14))
                            }
                            .foregroundStyle(rowColor(p))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Palette.card2)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        HStack(spacing: 4) {
                            Text("Words played: \(info.wordsPlayed)")
                            if let d = info.botDifficulty { Text("· Bot difficulty: \(d)/100") }
                        }
                        .font(GameFont.caption(10)).foregroundStyle(Palette.dim)
                    }
                    .padding(16)
                    .glassCard()

                    SolidButton(title: "Play Again", systemImage: "arrow.counterclockwise") {
                        model.backToLobby()
                    }
                }
                .frame(maxWidth: 560)
                .padding(.horizontal, 24)
                .padding(.bottom, 30)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.6)) { appear = true }
        }
    }

    private var winnerText: String {
        let base = info.isBot ? "🤖 Bot wins!" : "\(info.names(info.winner)) wins!"
        return winnerIsMe ? "\(base) That's you!" : base
    }

    private var sortedPlayers: [Int] {
        Array(1...max(info.numPlayers, 1)).sorted { safeScore($0) > safeScore($1) }
    }

    private func safeScore(_ p: Int) -> Int { p - 1 < info.scores.count ? info.scores[p - 1] : 0 }

    private func rowLabel(_ p: Int) -> String {
        var label = info.names(p)
        if p == info.myPlayerNum { label += " (you)" }
        if !info.active.contains(p) { label += " · out" }
        if p == info.winner { label += " 🏆" }
        return label
    }

    private func rowColor(_ p: Int) -> Color {
        if p == info.winner { return info.isBot ? Palette.glow : Palette.accent }
        if !info.active.contains(p) { return Palette.redBright }
        return Palette.dim
    }
}

// MARK: - Root

struct RootView: View {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var showPrivacyDisclaimer = !PrivacyDisclaimer.hasBeenSeen

    var body: some View {
        ZStack {
            AnimatedNebulaBackground()
            Group {
                if !model.dict.isLoaded {
                    LoadingView()
                } else {
                    routedContent
                }
            }
            if showPrivacyDisclaimer {
                PrivacyDisclaimerView { showPrivacyDisclaimer = false }
            }
        }
        .environmentObject(model)
        .preferredColorScheme(.dark)
        .onAppear { model.loadDictionary() }
        .onChange(of: scenePhase) { _, phase in model.handleScenePhaseChange(phase) }
    }

    @ViewBuilder
    private var routedContent: some View {
        switch model.route {
        case .lobby: LobbyView()
        case .botSetup: BotSetupView()
        case .localSetup: LocalSetupView()
        case .hostSetup: HostSetupView()
        case .joinList: JoinListView(browser: model.browser)
        case .waitingHost(let total):
            if let host = model.lanHost { HostWaitingRoomView(host: host, total: total) }
        case .waitingClient:
            if let client = model.lanClient { ClientWaitingRoomView(client: client) }
        case .botGame: EngineGameScreen(mode: .bot)
        case .localGame: EngineGameScreen(mode: .local)
        case .hostGame: EngineGameScreen(mode: .host)
        case .clientGame: ClientGameScreen()
        case .winner(let info): WinnerView(info: info)
        case .disconnected: DisconnectedView()
        }
    }
}

// MARK: - App Entry

@main
struct ShiritoriGameApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
