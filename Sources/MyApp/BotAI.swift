import SwiftUI
import Network
import Combine
import UIKit
import AVFoundation

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

