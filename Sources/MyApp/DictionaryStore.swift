import SwiftUI
import Network
import Combine
import UIKit
import AVFoundation

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

    /// A random opening word for a fresh game, whose last letter isn't the
    /// forbidden one (an opening word landing on it would strand the first
    /// player before they even get a turn). Falls back to nil if the
    /// dictionary hasn't loaded (or failed to), so callers can supply their
    /// own default.
    func randomStartWord(avoidingLastLetter forbidden: Character) -> String? {
        guard !byFirstLetter.isEmpty else { return nil }
        for _ in 0..<10 {
            guard let letter = byFirstLetter.keys.randomElement(),
                  let word = byFirstLetter[letter]?.randomElement(),
                  word.last != forbidden else { continue }
            return word
        }
        return nil
    }

    /// Bypass a stuck/failed load and let the user play without validation
    /// (empty wordSet ⇒ isValid accepts anything).
    func markReadyUnvalidated() {
        loadFailed = true
        isLoaded = true
    }

    /// Test seam: synchronously populate the store with a fixed word list,
    /// bypassing the async bundle load.
    func loadForTesting(_ words: [String]) {
        wordSet = Set(words)
        byFirstLetter = Dictionary(grouping: words, by: { $0.first! })
        isLoaded = true
    }
}

