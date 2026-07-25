import XCTest
@testable import MyApp

private func makeEntry(mode: GameMode = .bot, words: [String] = ["cat", "top"],
                       winner: Int = 1, date: Date = Date()) -> GameLogEntry {
    GameLogEntry(date: date, mode: mode, numPlayers: 2, winner: winner, winnerWasBot: false,
                 myPlayerNum: nil, scores: [10, 4], words: words, botDifficulty: nil, note: "")
}

final class GameLogStoreTests: XCTestCase {

    func testRecordPutsNewestFirst() {
        let store = GameLogStore(inMemory: true)

        store.record(makeEntry(words: ["first"]))
        store.record(makeEntry(words: ["second"]))

        XCTAssertEqual(store.entries.count, 2)
        XCTAssertEqual(store.entries.first?.words, ["second"], "the log reads newest-first")
    }

    func testTrimsOldestPastTheCap() {
        let store = GameLogStore(inMemory: true)

        for i in 0..<(GameLogStore.maxEntries + 10) {
            store.record(makeEntry(words: ["word\(i)"]))
        }

        XCTAssertEqual(store.entries.count, GameLogStore.maxEntries)
        XCTAssertEqual(store.entries.first?.words, ["word\(GameLogStore.maxEntries + 9)"],
                       "the newest entry survives")
        XCTAssertFalse(store.entries.contains { $0.words == ["word0"] },
                       "the oldest entry is the one dropped")
    }

    func testDeleteAllEmptiesTheLog() {
        let store = GameLogStore(inMemory: true)
        store.record(makeEntry())
        store.record(makeEntry())

        store.deleteAll()

        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(store.count, 0)
    }

    func testEntryRoundTripsThroughCoding() throws {
        let original = makeEntry(mode: .client, words: ["alpha", "acorn"], winner: 2)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GameLogEntry.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.mode, .client)
        XCTAssertEqual(decoded.words, ["alpha", "acorn"])
        XCTAssertEqual(decoded.winner, 2)
    }
}

final class StarredStoreTests: XCTestCase {

    func testStarNormalizesAndIsIdempotent() {
        let store = StarredStore(inMemory: true)

        store.star("  Nebula  ")
        store.star("nebula")
        store.star("NEBULA")

        XCTAssertEqual(store.words.count, 1, "the same word must not stack up")
        XCTAssertEqual(store.words.first?.word, "nebula")
        XCTAssertTrue(store.isStarred("NeBuLa"), "lookup is case-insensitive too")
    }

    func testToggleStarReportsTheNewState() {
        let store = StarredStore(inMemory: true)

        XCTAssertTrue(store.toggleStar("comet"), "first toggle stars it")
        XCTAssertTrue(store.isStarred("comet"))
        XCTAssertFalse(store.toggleStar("comet"), "second toggle unstars it")
        XCTAssertFalse(store.isStarred("comet"))
    }

    func testEmptyWordIsNotStarred() {
        let store = StarredStore(inMemory: true)

        store.star("   ")

        XCTAssertTrue(store.words.isEmpty)
    }

    func testWordCanBelongToSeveralFoldersAtOnce() {
        let store = StarredStore(inMemory: true)
        let space = store.createFolder(named: "Space")
        let hard = store.createFolder(named: "Hard")
        guard let word = store.star("nebula") else { return XCTFail("star failed") }

        store.setFolder(space.id, on: word, to: true)
        store.setFolder(hard.id, on: word, to: true)

        XCTAssertEqual(store.words(in: space.id).count, 1)
        XCTAssertEqual(store.words(in: hard.id).count, 1)
        XCTAssertEqual(store.words.first?.folderIDs.count, 2)
    }

    func testRemovingFromOneFolderLeavesTheOther() {
        let store = StarredStore(inMemory: true)
        let space = store.createFolder(named: "Space")
        let hard = store.createFolder(named: "Hard")
        guard let word = store.star("nebula") else { return XCTFail("star failed") }
        store.setFolder(space.id, on: word, to: true)
        store.setFolder(hard.id, on: word, to: true)

        store.setFolder(space.id, on: word, to: false)

        XCTAssertTrue(store.words(in: space.id).isEmpty)
        XCTAssertEqual(store.words(in: hard.id).count, 1)
    }

    func testAllViewReturnsEverythingRegardlessOfFolder() {
        let store = StarredStore(inMemory: true)
        let folder = store.createFolder(named: "Space")
        guard let filed = store.star("nebula") else { return XCTFail("star failed") }
        store.star("unfiled")
        store.setFolder(folder.id, on: filed, to: true)

        XCTAssertEqual(store.words(in: nil).count, 2)
        XCTAssertEqual(store.words(in: folder.id).count, 1)
    }

    func testDeletingAFolderKeepsItsWordsStarred() {
        let store = StarredStore(inMemory: true)
        let folder = store.createFolder(named: "Space")
        guard let word = store.star("nebula") else { return XCTFail("star failed") }
        store.setFolder(folder.id, on: word, to: true)

        store.deleteFolder(folder.id)

        XCTAssertTrue(store.folders.isEmpty)
        XCTAssertEqual(store.words.count, 1, "the word survives its folder")
        XCTAssertTrue(store.words.first?.folderIDs.isEmpty ?? false, "but loses the dangling tag")
    }

    func testDeleteRemovesOnlyTheTargetedWord() {
        let store = StarredStore(inMemory: true)
        guard let first = store.star("nebula") else { return XCTFail("star failed") }
        store.star("comet")

        store.delete(first)

        XCTAssertEqual(store.words.count, 1)
        XCTAssertEqual(store.words.first?.word, "comet")
    }

    func testAttachDefinitionStoresItAgainstTheWord() {
        let store = StarredStore(inMemory: true)
        guard let word = store.star("nebula") else { return XCTFail("star failed") }
        let definition = CachedDefinition(
            word: "nebula", phonetic: nil,
            meanings: [.init(partOfSpeech: "noun", definitions: [.init(text: "A cloud in space")])],
            source: "test"
        )

        store.attachDefinition(definition, to: word.id)

        XCTAssertEqual(store.words.first?.cachedDefinition?.source, "test")
        XCTAssertEqual(store.entry(for: "nebula")?.cachedDefinition?.meanings.first?.definitions.first?.text,
                       "A cloud in space")
    }
}
