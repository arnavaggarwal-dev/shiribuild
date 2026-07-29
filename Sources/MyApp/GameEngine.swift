import SwiftUI
import Network
import Combine
import UIKit
import AVFoundation

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

    /// Seats played by the AI. Empty for a pure human game. More than one
    /// seat is fine — the engine is strictly turn-based (only ever one
    /// `currentPlayer` at a time), so multiple bots just means several seats
    /// independently trigger `scheduleBotTurn()` when it becomes their turn;
    /// no concurrent-bot bookkeeping needed.
    let botPlayerNums: Set<Int>
    /// Which seat this device actually controls, if any. nil for bot/local
    /// games (every seat is played on this device); set to the host's seat
    /// (1) for LAN host games, so feedback for a *remote* player's move isn't
    /// shown on — or buzzed on — the host's device.
    let localPlayerNum: Int?
    private let dict: DictionaryStore
    private var timer: Timer?
    private var timerGen = 0
    private var warnedThisTurn = false

    /// Fires after every turn-ending mutation. LANHost hooks this to
    /// broadcast; bot/local play just ignore it.
    var onStateChanged: ((GameState, String, Color) -> Void)?
    var onGameOver: ((Int, String) -> Void)?
    /// Fires once per second while a human turn's clock runs. LANHost relays
    /// it so clients' countdowns track the authoritative host clock instead
    /// of sitting frozen at 30.
    var onTick: ((Int) -> Void)?
    /// Fires when a submitted word/command is rejected, tagged with the seat
    /// it was rejected for. LANHost relays it to just that player's connection
    /// so remote players actually see why their word bounced.
    var onReject: ((Int, String) -> Void)?

    var dangerPoolPercent: Int { 100 - botDifficulty }

    init(dict: DictionaryStore, numPlayers: Int, botPlayerNums: Set<Int> = [], botDifficulty: Int = 50,
         localPlayerNum: Int? = nil) {
        self.dict = dict
        self.botPlayerNums = botPlayerNums
        self.botDifficulty = botDifficulty
        self.localPlayerNum = localPlayerNum
        self.state = .fresh(numPlayers: numPlayers, dict: dict)
    }

    func start() {
        if isBot(state.currentPlayer) {
            scheduleBotTurn(afterBot: false)
        } else {
            startTimer()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        timerGen += 1
    }

    private func isBot(_ p: Int) -> Bool { botPlayerNums.contains(p) }

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
        let moverWasBot = isBot(p)
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
            scheduleBotTurn(afterBot: moverWasBot)
        } else {
            startTimer()
        }
    }

    private func advanceTurn() {
        let moverWasBot = isBot(state.currentPlayer)
        state.currentPlayer = nextPlayer()
        onStateChanged?(state, message, messageColor)
        if isBot(state.currentPlayer) {
            scheduleBotTurn(afterBot: moverWasBot)
        } else {
            startTimer()
        }
    }

    private func reject(_ text: String) {
        let p = state.currentPlayer   // attemptAction guarantees this == the offender
        onReject?(p, text)
        // Only flash/buzz/print the rejection on this device if this device
        // actually controls that seat. In a LAN host game a remote player's
        // bad word is relayed to *their* screen (via onReject) rather than
        // showing on the host's.
        guard localPlayerNum == nil || localPlayerNum == p else { return }
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

    /// `afterBot`: true when the seat that just moved was also a bot. A
    /// human-then-bot transition keeps the short "thinking" pause; two bots
    /// going back-to-back get a randomized 1-6s pause instead, so a chain of
    /// bot turns doesn't read as instant, obviously-scripted replies.
    private func scheduleBotTurn(afterBot: Bool) {
        isBotThinking = true
        lastEvent = .botThinking
        let gen = timerGen
        let delay = afterBot ? Double.random(in: 1...6) : 0.9
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.timerGen == gen || !self.botPlayerNums.isEmpty else { return }
            self.doBotTurn()
        }
    }

    private func doBotTurn() {
        guard !isGameOver, isBot(state.currentPlayer) else { return }
        let botNum = state.currentPlayer
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
        onTick?(timeLeft)   // reset every client's clock at the top of the turn
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
        onTick?(timeLeft)
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

