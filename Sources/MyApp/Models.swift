import SwiftUI
import Network
import Combine
import UIKit
import AVFoundation

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

    static func fresh(numPlayers: Int, dict: DictionaryStore) -> GameState {
        let letter = Character(UnicodeScalar(UInt8.random(in: 97...122)))
        let start = dict.randomStartWord(avoidingLastLetter: letter) ?? "apple"
        return GameState(currentPlayer: 1, previousWord: start, wordList: [start],
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

/// Screens the root view can be on. Not a NavigationStack because the app
/// wants full control over cross-fades against the nebula background.
enum Route: Equatable {
    case lobby
    /// Setup for the merged Bot+Local mode — two sliders (humans, bots) that
    /// share an 8-player cap, rather than separate bot/local screens.
    case playSetup
    case hostSetup
    case joinList
    case logs
    case starred
    case waitingHost(total: Int)
    case waitingClient
    case playGame
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

