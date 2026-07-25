import Foundation

// MARK: - Definition model

/// One word's definition, normalized across every provider so the UI never
/// has to know which service answered.
struct CachedDefinition: Codable, Equatable {
    var word: String
    var phonetic: String? = nil
    var meanings: [Meaning]
    /// Which provider produced this, for the attribution line and for
    /// working out which source is misbehaving when something looks wrong.
    var source: String
    var fetchedAt = Date()

    struct Meaning: Codable, Equatable {
        var partOfSpeech: String
        var definitions: [Definition]
    }

    struct Definition: Codable, Equatable {
        var text: String
        var example: String? = nil
        var synonyms: [String] = []
    }

    /// Plenty of entries carry no example at all — even on the richest
    /// provider — so the UI asks for "the first one anywhere" rather than
    /// assuming the first definition has it.
    var firstExample: String? {
        for meaning in meanings {
            for definition in meaning.definitions {
                if let ex = definition.example?.trimmingCharacters(in: .whitespacesAndNewlines), !ex.isEmpty {
                    return ex
                }
            }
        }
        return nil
    }

    var isEmpty: Bool {
        meanings.allSatisfy { $0.definitions.isEmpty }
    }
}

// MARK: - Provider protocol

enum DictionaryProviderError: Error {
    /// The provider answered, and is confident it has no such word.
    case notFound
    /// Couldn't reach it, it errored, or it sent something undecodable.
    case unavailable
}

protocol DictionaryProvider {
    /// Shown in the definition sheet's attribution line.
    var name: String { get }
    func fetch(_ word: String) async throws -> CachedDefinition
}

// MARK: - Shared HTTP helper

private enum HTTP {
    /// One slow provider shouldn't hold up the whole chain — if it hasn't
    /// answered in 5s, move on to the next one.
    static let timeout: TimeInterval = 5

    static func get(_ urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw DictionaryProviderError.unavailable }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        // Wikimedia asks API clients to identify themselves; harmless
        // everywhere else, so it goes on every request.
        request.setValue("Shiritori/1.0 (iOS word game; contact via App Store listing)",
                         forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DictionaryProviderError.unavailable }
        if http.statusCode == 404 { throw DictionaryProviderError.notFound }
        guard (200..<300).contains(http.statusCode) else { throw DictionaryProviderError.unavailable }
        return data
    }

    static func encode(_ word: String) -> String {
        word.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? word
    }
}

/// Wiktionary-derived providers return definition text as HTML fragments
/// (links, italics, qualifier spans). Strip it down to plain text.
private func strippingHTML(_ raw: String) -> String {
    var s = raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    let entities = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
                    "&#39;": "'", "&apos;": "'", "&nbsp;": " "]
    for (entity, char) in entities {
        s = s.replacingOccurrences(of: entity, with: char)
    }
    return s.trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Provider 1: dictionaryapi.dev

/// The richest source: definitions, examples, phonetics and synonyms. It's a
/// volunteer-run service with no uptime guarantee, which is the whole reason
/// the fallback chain below it exists.
struct DictionaryAPIDevProvider: DictionaryProvider {
    let name = "dictionaryapi.dev"

    private struct Entry: Decodable {
        var word: String
        var phonetic: String?
        var meanings: [Meaning]?

        struct Meaning: Decodable {
            var partOfSpeech: String?
            var definitions: [Definition]?
        }
        struct Definition: Decodable {
            var definition: String?
            var example: String?
            var synonyms: [String]?
        }
    }

    func fetch(_ word: String) async throws -> CachedDefinition {
        let data = try await HTTP.get("https://api.dictionaryapi.dev/api/v2/entries/en/\(HTTP.encode(word))")
        // A miss returns an error *object* rather than an array, so a decode
        // failure here usually means "no such word", not a broken provider.
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data), let first = entries.first else {
            throw DictionaryProviderError.notFound
        }

        let meanings: [CachedDefinition.Meaning] = (first.meanings ?? []).compactMap { m in
            let defs: [CachedDefinition.Definition] = (m.definitions ?? []).compactMap { d in
                guard let text = d.definition?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
                return CachedDefinition.Definition(text: text, example: d.example, synonyms: d.synonyms ?? [])
            }
            guard !defs.isEmpty else { return nil }
            return CachedDefinition.Meaning(partOfSpeech: m.partOfSpeech ?? "", definitions: defs)
        }

        let result = CachedDefinition(word: first.word, phonetic: first.phonetic, meanings: meanings, source: name)
        guard !result.isEmpty else { throw DictionaryProviderError.notFound }
        return result
    }
}

// MARK: - Provider 2: freedictionaryapi.com

/// Wiktionary-sourced but a completely separate backend from provider 1, so
/// an outage there doesn't take this down too.
///
/// NOTE: this schema is transcribed from the service's documentation and has
/// not been exercised against the live host (the build container blocks
/// outbound access to it). Every field is optional and a decode failure just
/// falls through to the next provider, so a schema drift degrades to "skip"
/// rather than breaking lookups — but it does need verifying on device.
struct FreeDictionaryAPIProvider: DictionaryProvider {
    let name = "freedictionaryapi.com"

    private struct Response: Decodable {
        var word: String?
        var entries: [Entry]?

        struct Entry: Decodable {
            var partOfSpeech: String?
            var senses: [Sense]?
            var pronunciations: [Pronunciation]?
        }
        struct Sense: Decodable {
            var definition: String?
            var examples: [String]?
        }
        struct Pronunciation: Decodable {
            var text: String?
        }
    }

    func fetch(_ word: String) async throws -> CachedDefinition {
        let data = try await HTTP.get("https://freedictionaryapi.com/api/v1/entries/en/\(HTTP.encode(word))")
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw DictionaryProviderError.unavailable
        }

        let meanings: [CachedDefinition.Meaning] = (response.entries ?? []).compactMap { entry in
            let defs: [CachedDefinition.Definition] = (entry.senses ?? []).compactMap { sense in
                guard let text = sense.definition?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
                return CachedDefinition.Definition(text: strippingHTML(text),
                                                    example: sense.examples?.first.map(strippingHTML))
            }
            guard !defs.isEmpty else { return nil }
            return CachedDefinition.Meaning(partOfSpeech: entry.partOfSpeech ?? "", definitions: defs)
        }

        let phonetic = response.entries?.compactMap { $0.pronunciations?.first?.text }.first
        let result = CachedDefinition(word: response.word ?? word, phonetic: phonetic,
                                       meanings: meanings, source: name)
        guard !result.isEmpty else { throw DictionaryProviderError.notFound }
        return result
    }
}

// MARK: - Provider 3: Wiktionary REST

/// Runs on Wikimedia's own infrastructure, so it's the most reliable host in
/// the chain. Response is keyed by language code and the text arrives as HTML.
struct WiktionaryProvider: DictionaryProvider {
    let name = "Wiktionary"

    private struct Section: Decodable {
        var partOfSpeech: String?
        var definitions: [Definition]?

        struct Definition: Decodable {
            var definition: String?
            var examples: [String]?
        }
    }

    func fetch(_ word: String) async throws -> CachedDefinition {
        let data = try await HTTP.get("https://en.wiktionary.org/api/rest_v1/page/definition/\(HTTP.encode(word))")
        guard let byLanguage = try? JSONDecoder().decode([String: [Section]].self, from: data) else {
            throw DictionaryProviderError.unavailable
        }
        guard let sections = byLanguage["en"], !sections.isEmpty else {
            // The page exists but has no English entry.
            throw DictionaryProviderError.notFound
        }

        let meanings: [CachedDefinition.Meaning] = sections.compactMap { section in
            let defs: [CachedDefinition.Definition] = (section.definitions ?? []).compactMap { d in
                guard let raw = d.definition else { return nil }
                let text = strippingHTML(raw)
                guard !text.isEmpty else { return nil }
                return CachedDefinition.Definition(text: text,
                                                    example: d.examples?.first.map(strippingHTML))
            }
            guard !defs.isEmpty else { return nil }
            return CachedDefinition.Meaning(partOfSpeech: section.partOfSpeech ?? "", definitions: defs)
        }

        let result = CachedDefinition(word: word, phonetic: nil, meanings: meanings, source: name)
        guard !result.isEmpty else { throw DictionaryProviderError.notFound }
        return result
    }
}

// MARK: - Provider 4: Datamuse

/// Last resort. Keyless, very stable, and backed by WordNet + Wiktionary —
/// but it returns no example sentences at all, so the UI will show the
/// "no example" fallback for anything that gets this far.
struct DatamuseProvider: DictionaryProvider {
    let name = "Datamuse"

    private struct Result: Decodable {
        var word: String?
        var defs: [String]?
    }

    /// Datamuse prefixes each definition with a short part-of-speech code and
    /// a tab, e.g. "n\tA cloud of gas and dust in space".
    private static let posNames = ["n": "noun", "v": "verb", "adj": "adjective",
                                   "adv": "adverb", "u": ""]

    func fetch(_ word: String) async throws -> CachedDefinition {
        let data = try await HTTP.get("https://api.datamuse.com/words?sp=\(HTTP.encode(word))&md=d&max=1")
        guard let results = try? JSONDecoder().decode([Result].self, from: data) else {
            throw DictionaryProviderError.unavailable
        }
        guard let first = results.first, let defs = first.defs, !defs.isEmpty else {
            throw DictionaryProviderError.notFound
        }

        // Group the flat list back under its part of speech.
        var grouped: [(pos: String, texts: [String])] = []
        for entry in defs {
            let parts = entry.components(separatedBy: "\t")
            let pos = parts.count > 1 ? (Self.posNames[parts[0]] ?? parts[0]) : ""
            let text = (parts.count > 1 ? parts.dropFirst().joined(separator: " ") : entry)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if let idx = grouped.firstIndex(where: { $0.pos == pos }) {
                grouped[idx].texts.append(text)
            } else {
                grouped.append((pos, [text]))
            }
        }

        let meanings = grouped.map { group in
            CachedDefinition.Meaning(partOfSpeech: group.pos,
                                      definitions: group.texts.map { CachedDefinition.Definition(text: $0) })
        }

        let result = CachedDefinition(word: first.word ?? word, phonetic: nil, meanings: meanings, source: name)
        guard !result.isEmpty else { throw DictionaryProviderError.notFound }
        return result
    }
}

// MARK: - The chain

enum DictionaryLookupFailure: Error, Equatable {
    /// At least one provider answered definitively that the word isn't there.
    case notFound
    /// Nothing could be reached at all.
    case unreachable

    var message: String {
        switch self {
        case .notFound: return "No definition found for this word."
        case .unreachable: return "Couldn't reach a dictionary right now."
        }
    }
}

/// Tries each provider in order and returns the first usable answer.
///
/// It falls through on a 404 as well as on transport errors, because coverage
/// genuinely differs between these corpora — a word missing from one source is
/// often present in the next.
final class DictionaryService {
    static let shared = DictionaryService()

    let providers: [DictionaryProvider]

    init(providers: [DictionaryProvider] = [
        DictionaryAPIDevProvider(),
        FreeDictionaryAPIProvider(),
        WiktionaryProvider(),
        DatamuseProvider(),
    ]) {
        self.providers = providers
    }

    func lookup(_ word: String) async -> Swift.Result<CachedDefinition, DictionaryLookupFailure> {
        var sawDefinitiveMiss = false

        for provider in providers {
            do {
                let definition = try await provider.fetch(word)
                return .success(definition)
            } catch DictionaryProviderError.notFound {
                sawDefinitiveMiss = true
            } catch {
                continue
            }
        }

        return .failure(sawDefinitiveMiss ? .notFound : .unreachable)
    }
}
