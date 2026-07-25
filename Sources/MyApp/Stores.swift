import SwiftUI
import Combine

// MARK: - Persisted models

/// Which backend produced a logged game. Passed explicitly from each call
/// site rather than inferred from `botNum`/`myPlayerNum`, because those two
/// can't tell a local pass-and-play game apart from a LAN client game.
enum GameMode: String, Codable {
    case bot, local, host, client

    var label: String {
        switch self {
        case .bot: return "Bot Mode"
        case .local: return "Local Play"
        case .host: return "Hosted LAN"
        case .client: return "Joined LAN"
        }
    }

    var icon: String {
        switch self {
        case .bot: return "cpu"
        case .local: return "person.2.fill"
        case .host: return "antenna.radiowaves.left.and.right"
        case .client: return "wifi"
        }
    }
}

/// One finished game. `WinnerInfo` (Models.swift) can't be reused here — it
/// carries a `names: (Int) -> String` closure, so it isn't Codable.
struct GameLogEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var mode: GameMode
    var numPlayers: Int
    var winner: Int
    var winnerWasBot: Bool
    var myPlayerNum: Int? = nil
    var scores: [Int]
    var words: [String]
    var botDifficulty: Int? = nil
    var note: String

    func name(for player: Int) -> String {
        winnerWasBot && player == winner ? "🤖 Bot" : "Player \(player)"
    }

    var winnerName: String { winnerWasBot ? "🤖 Bot" : "Player \(winner)" }
}

struct WordFolder: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var dateCreated = Date()
}

/// A starred word. `folderIDs` is a tag model — the same word can sit in any
/// number of folders at once.
struct StarredWord: Codable, Identifiable, Equatable {
    var id = UUID()
    var word: String              // always normalized lowercase
    var dateStarred = Date()
    var folderIDs: [UUID] = []
    var cachedDefinition: CachedDefinition? = nil
}

// MARK: - JSON file persistence

/// The rest of the app keeps preferences in UserDefaults (`AppSettings`,
/// `PrivacyDisclaimer`). Game history is different: it's unbounded and stores
/// every word of every game, which is the wrong shape for a plist that gets
/// read into memory wholesale at launch. These land in Application Support as
/// plain JSON instead.
enum AppFiles {
    private static var directory: URL? {
        guard let base = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                       in: .userDomainMask,
                                                       appropriateFor: nil, create: true) else { return nil }
        let dir = base.appendingPathComponent("Shiritori", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    static func url(_ name: String) -> URL? {
        directory?.appendingPathComponent(name)
    }

    static func load<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let url = url(name), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func save<T: Encodable>(_ value: T, to name: String) {
        guard let url = url(name), let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func delete(_ name: String) {
        guard let url = url(name) else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

/// Writes happen off the main thread so a large history file can't stutter a
/// turn transition. Serial, so saves can't interleave and corrupt the file.
private let storeWriteQueue = DispatchQueue(label: "com.arnavaggarwal.shiritori.store")

// MARK: - Game log

final class GameLogStore: ObservableObject {
    static let shared = GameLogStore()

    /// Newest first. Capped so a heavy player's history can't grow without
    /// bound — the oldest games fall off rather than the app slowly bloating.
    static let maxEntries = 500

    private static let defaultFileName = "game_log.v1.json"

    @Published private(set) var entries: [GameLogEntry] = []

    /// nil means "never touch disk" — used by tests so they don't stomp on
    /// the real history file or leak state between cases.
    private let fileName: String?

    private init() {
        fileName = Self.defaultFileName
        entries = AppFiles.load([GameLogEntry].self, from: Self.defaultFileName) ?? []
    }

    /// Test seam: an isolated, in-memory store.
    init(inMemory: Bool) {
        fileName = nil
        entries = []
    }

    var count: Int { entries.count }

    func record(_ entry: GameLogEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
        persist()
    }

    func deleteAll() {
        entries = []
        if let fileName { AppFiles.delete(fileName) }
    }

    private func persist() {
        guard let fileName else { return }
        let snapshot = entries
        storeWriteQueue.async { AppFiles.save(snapshot, to: fileName) }
    }
}

// MARK: - Starred words

final class StarredStore: ObservableObject {
    static let shared = StarredStore()

    private static let defaultWordsFile = "starred_words.v1.json"
    private static let defaultFoldersFile = "word_folders.v1.json"

    @Published private(set) var words: [StarredWord] = []
    @Published private(set) var folders: [WordFolder] = []

    /// nil means "never touch disk" — see `GameLogStore` for why.
    private let wordsFile: String?
    private let foldersFile: String?

    private init() {
        wordsFile = Self.defaultWordsFile
        foldersFile = Self.defaultFoldersFile
        words = AppFiles.load([StarredWord].self, from: Self.defaultWordsFile) ?? []
        folders = AppFiles.load([WordFolder].self, from: Self.defaultFoldersFile) ?? []
    }

    /// Test seam: an isolated, in-memory store.
    init(inMemory: Bool) {
        wordsFile = nil
        foldersFile = nil
    }

    // MARK: starring

    private func normalize(_ word: String) -> String {
        word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func isStarred(_ word: String) -> Bool {
        let w = normalize(word)
        return words.contains { $0.word == w }
    }

    func entry(for word: String) -> StarredWord? {
        let w = normalize(word)
        return words.first { $0.word == w }
    }

    /// Stars the word if it isn't already. Starring twice is a no-op rather
    /// than a duplicate row.
    @discardableResult
    func star(_ word: String) -> StarredWord? {
        let w = normalize(word)
        guard !w.isEmpty else { return nil }
        if let existing = words.first(where: { $0.word == w }) { return existing }
        let entry = StarredWord(word: w)
        words.insert(entry, at: 0)
        persistWords()
        return entry
    }

    func unstar(_ word: String) {
        let w = normalize(word)
        words.removeAll { $0.word == w }
        persistWords()
    }

    /// Returns the new starred state, so callers can drive a haptic/animation.
    @discardableResult
    func toggleStar(_ word: String) -> Bool {
        if isStarred(word) {
            unstar(word)
            return false
        }
        star(word)
        return true
    }

    func delete(_ entry: StarredWord) {
        words.removeAll { $0.id == entry.id }
        persistWords()
    }

    // MARK: folders

    @discardableResult
    func createFolder(named name: String) -> WordFolder {
        let folder = WordFolder(name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        folders.append(folder)
        persistFolders()
        return folder
    }

    func renameFolder(_ id: UUID, to name: String) {
        guard let idx = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[idx].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        persistFolders()
    }

    /// Deleting a folder never deletes the words filed under it — it just
    /// drops the tag, so the words fall back to the "All" view.
    func deleteFolder(_ id: UUID) {
        folders.removeAll { $0.id == id }
        for i in words.indices {
            words[i].folderIDs.removeAll { $0 == id }
        }
        persistFolders()
        persistWords()
    }

    func isInFolder(_ entry: StarredWord, folder: UUID) -> Bool {
        entry.folderIDs.contains(folder)
    }

    func setFolder(_ folderID: UUID, on entry: StarredWord, to member: Bool) {
        guard let idx = words.firstIndex(where: { $0.id == entry.id }) else { return }
        if member {
            guard !words[idx].folderIDs.contains(folderID) else { return }
            words[idx].folderIDs.append(folderID)
        } else {
            words[idx].folderIDs.removeAll { $0 == folderID }
        }
        persistWords()
    }

    /// nil folder == the "All" view.
    func words(in folderID: UUID?) -> [StarredWord] {
        guard let folderID else { return words }
        return words.filter { $0.folderIDs.contains(folderID) }
    }

    // MARK: definitions

    func attachDefinition(_ definition: CachedDefinition, to wordID: UUID) {
        guard let idx = words.firstIndex(where: { $0.id == wordID }) else { return }
        words[idx].cachedDefinition = definition
        persistWords()
    }

    // MARK: persistence

    private func persistWords() {
        guard let wordsFile else { return }
        let snapshot = words
        storeWriteQueue.async { AppFiles.save(snapshot, to: wordsFile) }
    }

    private func persistFolders() {
        guard let foldersFile else { return }
        let snapshot = folders
        storeWriteQueue.async { AppFiles.save(snapshot, to: foldersFile) }
    }
}
