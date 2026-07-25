import XCTest
@testable import MyApp

final class BotAITests: XCTestCase {

    func testPicksAWordStartingWithTheRequiredLetterAndNotAlreadyUsed() {
        let byFirstLetter: [Character: [String]] = ["t": ["top", "tin", "tip"]]

        for _ in 0..<20 {
            guard let word = botPickWord(start: "t", used: ["top"], forbidden: "z",
                                          difficulty: 100, byFirstLetter: byFirstLetter) else {
                XCTFail("expected a candidate word")
                continue
            }
            XCTAssertEqual(word.first, "t")
            XCTAssertNotEqual(word, "top", "must not replay an already-used word")
        }
    }

    func testReturnsNilWhenNoCandidatesForStartingLetter() {
        let byFirstLetter: [Character: [String]] = ["t": ["top"]]

        let word = botPickWord(start: "z", used: [], forbidden: "x",
                                difficulty: 50, byFirstLetter: byFirstLetter)

        XCTAssertNil(word)
    }

    func testReturnsNilWhenEveryCandidateIsAlreadyUsed() {
        let byFirstLetter: [Character: [String]] = ["t": ["top", "tin"]]

        let word = botPickWord(start: "t", used: ["top", "tin"], forbidden: "z",
                                difficulty: 50, byFirstLetter: byFirstLetter)

        XCTAssertNil(word)
    }
}
