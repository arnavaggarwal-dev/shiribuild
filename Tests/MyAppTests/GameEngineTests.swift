import XCTest
@testable import MyApp

/// Controlled word list for deterministic chaining:
/// c -> [cat]        (ends t)
/// t -> [tan, tip, top]
/// n -> [nap, nut]
/// p -> [pit, pen, pot]
private let testWords = ["cat", "tan", "tip", "top", "nap", "nut", "pit", "pen", "pot"]

private func makeDict() -> DictionaryStore {
    let dict = DictionaryStore()
    dict.loadForTesting(testWords)
    return dict
}

private func makeEngine(state: GameState, dict: DictionaryStore = makeDict(),
                         numPlayers: Int? = nil, botPlayerNums: Set<Int> = []) -> GameEngine {
    let engine = GameEngine(dict: dict, numPlayers: numPlayers ?? state.numPlayers, botPlayerNums: botPlayerNums)
    engine.state = state
    return engine
}

final class GameEngineTests: XCTestCase {

    func testValidWordIsAcceptedAndAdvancesTurn() {
        let state = GameState(currentPlayer: 1, previousWord: "cat", wordList: ["cat"],
                               scores: [0, 0], activePlayers: [1, 2], forbidden: "z", numPlayers: 2)
        let engine = makeEngine(state: state)

        engine.attemptAction(playerNum: 1, raw: "top")

        XCTAssertEqual(engine.state.wordList, ["cat", "top"])
        XCTAssertEqual(engine.state.previousWord, "top")
        XCTAssertEqual(engine.state.scores[0], 3)
        XCTAssertEqual(engine.state.currentPlayer, 2)
        XCTAssertEqual(engine.lastEvent, .accepted(word: "top", points: 3, player: 1))
    }

    func testWrongStartingLetterIsRejected() {
        let state = GameState(currentPlayer: 1, previousWord: "cat", wordList: ["cat"],
                               scores: [0, 0], activePlayers: [1, 2], forbidden: "z", numPlayers: 2)
        let engine = makeEngine(state: state)

        engine.attemptAction(playerNum: 1, raw: "pen")

        XCTAssertEqual(engine.state.wordList, ["cat"], "a rejected word must not be appended")
        XCTAssertEqual(engine.state.currentPlayer, 1, "turn must not advance on rejection")
        if case .rejected = engine.lastEvent {} else {
            XCTFail("expected .rejected, got \(engine.lastEvent)")
        }
    }

    func testDuplicateWordIsRejected() {
        let state = GameState(currentPlayer: 1, previousWord: "cat", wordList: ["cat", "top"],
                               scores: [3, 0], activePlayers: [1, 2], forbidden: "z", numPlayers: 2)
        let engine = makeEngine(state: state)

        engine.attemptAction(playerNum: 1, raw: "top")

        XCTAssertEqual(engine.state.wordList, ["cat", "top"], "duplicate must not be appended twice")
        XCTAssertEqual(engine.state.currentPlayer, 1)
    }

    func testWordEndingInForbiddenLetterEliminatesPlayer() {
        // 3 players so elimination doesn't also end the game, keeping this
        // test focused on the elimination path alone.
        let state = GameState(currentPlayer: 1, previousWord: "cat", wordList: ["cat"],
                               scores: [0, 0, 0], activePlayers: [1, 2, 3], forbidden: "p", numPlayers: 3)
        let engine = makeEngine(state: state)

        engine.attemptAction(playerNum: 1, raw: "tip")   // starts 't', ends 'p' == forbidden

        XCTAssertEqual(engine.state.activePlayers, [2, 3])
        XCTAssertEqual(engine.state.currentPlayer, 2)
        XCTAssertEqual(engine.lastEvent, .eliminated(player: 1, isBot: false))
        XCTAssertFalse(engine.isGameOver)
    }

    func testSkipEitherPenalizesAdvancesOrEliminates() {
        // doSkip's outcome is randomized (Int.random(0...2)); assert the
        // invariant that holds across all three branches instead of a
        // single deterministic outcome.
        let state = GameState(currentPlayer: 1, previousWord: "cat", wordList: ["cat"],
                               scores: [20, 0], activePlayers: [1, 2], forbidden: "z", numPlayers: 2)
        let engine = makeEngine(state: state)

        engine.attemptAction(playerNum: 1, raw: "/skip")

        if engine.state.activePlayers == [2] {
            // eliminated-via-skip branch
            XCTAssertEqual(engine.lastEvent, .eliminated(player: 1, isBot: false))
        } else {
            XCTAssertEqual(engine.state.currentPlayer, 2, "a non-eliminating skip must still advance the turn")
            switch engine.lastEvent {
            case .skipped(player: 1, penalty: -10): XCTAssertEqual(engine.state.scores[0], 10)
            case .skipped(player: 1, penalty: 0): XCTAssertEqual(engine.state.scores[0], 20)
            default: XCTFail("expected .skipped, got \(engine.lastEvent)")
            }
        }
    }

    func testDonateTransfersPointsAndAdvancesTurn() {
        let state = GameState(currentPlayer: 1, previousWord: "cat", wordList: ["cat"],
                               scores: [50, 0, 0], activePlayers: [1, 2, 3], forbidden: "z", numPlayers: 3)
        let engine = makeEngine(state: state)

        engine.attemptAction(playerNum: 1, raw: "/donate 20 2")

        XCTAssertEqual(engine.state.scores, [30, 20, 0])
        XCTAssertEqual(engine.state.currentPlayer, 2)
        XCTAssertEqual(engine.lastEvent, .donated(from: 1, to: 2, amount: 20))
    }

    func testDonateRejectsInvalidTarget() {
        let state = GameState(currentPlayer: 1, previousWord: "cat", wordList: ["cat"],
                               scores: [50, 0], activePlayers: [1, 2], forbidden: "z", numPlayers: 2)
        let engine = makeEngine(state: state)

        engine.attemptAction(playerNum: 1, raw: "/donate 20 1")   // can't donate to self

        XCTAssertEqual(engine.state.scores, [50, 0])
        XCTAssertEqual(engine.state.currentPlayer, 1, "an invalid /donate must not advance the turn")
    }

    func testGameEndsWhenOnlyOnePlayerRemains() {
        let state = GameState(currentPlayer: 1, previousWord: "cat", wordList: ["cat"],
                               scores: [0, 0], activePlayers: [1, 2], forbidden: "p", numPlayers: 2)
        let engine = makeEngine(state: state)

        let gameOverExpectation = expectation(description: "onGameOver fires")
        engine.onGameOver = { winner, _ in
            XCTAssertEqual(winner, 2)
            gameOverExpectation.fulfill()
        }

        engine.attemptAction(playerNum: 1, raw: "tip")   // eliminates player 1, leaving only player 2

        XCTAssertEqual(engine.state.activePlayers, [2])
        waitForExpectations(timeout: 3.0)
        XCTAssertTrue(engine.isGameOver)
    }

    func testBotTurnPlaysAValidWordAndAdvances() {
        let state = GameState(currentPlayer: 2, previousWord: "cat", wordList: ["cat"],
                               scores: [0, 0], activePlayers: [1, 2], forbidden: "z", numPlayers: 2)
        let engine = makeEngine(state: state, botPlayerNums: [2])

        let botPlayedExpectation = expectation(description: "bot plays its turn")
        engine.onStateChanged = { newState, _, _ in
            if newState.wordList.count == 2 { botPlayedExpectation.fulfill() }
        }

        engine.start()
        waitForExpectations(timeout: 3.0)

        XCTAssertEqual(engine.state.wordList.count, 2)
        XCTAssertTrue(["tan", "tip", "top"].contains(engine.state.wordList[1]))
        XCTAssertEqual(engine.state.currentPlayer, 1)
    }

    /// Multiple simultaneous bot seats: two bots in a row should both take
    /// their turn without any human input, ending back on the human seat.
    /// The bot-to-bot transition uses a randomized 1-6s pause (vs. the fixed
    /// 0.9s human-to-bot pause), so this test's timeout is generous.
    func testConsecutiveBotTurnsBothPlay() {
        let state = GameState(currentPlayer: 2, previousWord: "cat", wordList: ["cat"],
                               scores: [0, 0, 0], activePlayers: [1, 2, 3], forbidden: "z", numPlayers: 3)
        let engine = makeEngine(state: state, botPlayerNums: [2, 3])

        let bothBotsPlayed = expectation(description: "both bots play their turn")
        engine.onStateChanged = { newState, _, _ in
            if newState.wordList.count == 3 { bothBotsPlayed.fulfill() }
        }

        engine.start()
        waitForExpectations(timeout: 12.0)

        XCTAssertEqual(engine.state.wordList.count, 3)
        XCTAssertEqual(engine.state.currentPlayer, 1, "turn should land back on the human seat")
    }
}
