import XCTest
@testable import MyApp

/// Decoding is exercised against fixture JSON rather than the live services —
/// no network in tests, and the real hosts are unreachable from CI anyway.
final class DictionaryAPITests: XCTestCase {

    // MARK: - CachedDefinition

    func testFirstExampleScansPastDefinitionsThatHaveNone() {
        let definition = CachedDefinition(
            word: "nebula",
            phonetic: nil,
            meanings: [
                .init(partOfSpeech: "noun", definitions: [
                    .init(text: "A cloud in space", example: nil),
                    .init(text: "A haze on the cornea", example: "The nebula clouded her vision."),
                ])
            ],
            source: "test"
        )

        XCTAssertEqual(definition.firstExample, "The nebula clouded her vision.")
    }

    func testFirstExampleIsNilWhenNothingHasOne() {
        let definition = CachedDefinition(
            word: "nebula",
            phonetic: nil,
            meanings: [.init(partOfSpeech: "noun", definitions: [.init(text: "A cloud in space", example: nil)])],
            source: "test"
        )

        XCTAssertNil(definition.firstExample, "the UI relies on nil to show its no-example fallback")
    }

    func testIsEmptyWhenEveryMeaningHasNoDefinitions() {
        let definition = CachedDefinition(
            word: "x", phonetic: nil,
            meanings: [.init(partOfSpeech: "noun", definitions: [])],
            source: "test"
        )
        XCTAssertTrue(definition.isEmpty)
    }

    func testRoundTripsThroughCoding() throws {
        let original = CachedDefinition(
            word: "nebula", phonetic: "/ˈnɛbjʊlə/",
            meanings: [.init(partOfSpeech: "noun",
                             definitions: [.init(text: "A cloud in space", example: "Look at that nebula.", synonyms: ["cloud"])])],
            source: "dictionaryapi.dev"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CachedDefinition.self, from: data)

        XCTAssertEqual(decoded.word, original.word)
        XCTAssertEqual(decoded.firstExample, "Look at that nebula.")
        XCTAssertEqual(decoded.source, "dictionaryapi.dev")
    }

    // MARK: - The fallback chain

    /// Stub provider so chain ordering can be checked without any network.
    private struct StubProvider: DictionaryProvider {
        let name: String
        let outcome: Result<CachedDefinition, DictionaryProviderError>
        /// Records that this provider was actually consulted.
        let onCall: () -> Void

        func fetch(_ word: String) async throws -> CachedDefinition {
            onCall()
            switch outcome {
            case .success(let definition): return definition
            case .failure(let error): throw error
            }
        }
    }

    private func definition(_ source: String) -> CachedDefinition {
        CachedDefinition(word: "test", phonetic: nil,
                         meanings: [.init(partOfSpeech: "noun", definitions: [.init(text: "a thing")])],
                         source: source)
    }

    func testChainReturnsFirstSuccessAndSkipsLaterProviders() async {
        var called: [String] = []
        let service = DictionaryService(providers: [
            StubProvider(name: "one", outcome: .failure(.unavailable)) { called.append("one") },
            StubProvider(name: "two", outcome: .success(definition("two"))) { called.append("two") },
            StubProvider(name: "three", outcome: .success(definition("three"))) { called.append("three") },
        ])

        let result = await service.lookup("test")

        guard case .success(let found) = result else {
            return XCTFail("expected a success from provider two")
        }
        XCTAssertEqual(found.source, "two")
        XCTAssertEqual(called, ["one", "two"], "provider three should never have been consulted")
    }

    func testChainFallsThroughA404ToTheNextProvider() async {
        // Coverage differs between corpora, so a not-found on one source must
        // still try the next rather than giving up.
        let service = DictionaryService(providers: [
            StubProvider(name: "one", outcome: .failure(.notFound)) { },
            StubProvider(name: "two", outcome: .success(definition("two"))) { },
        ])

        let result = await service.lookup("test")

        guard case .success(let found) = result else {
            return XCTFail("a 404 on the first provider should not end the lookup")
        }
        XCTAssertEqual(found.source, "two")
    }

    func testChainReportsNotFoundWhenAnyProviderWasDefinitive() async {
        let service = DictionaryService(providers: [
            StubProvider(name: "one", outcome: .failure(.unavailable)) { },
            StubProvider(name: "two", outcome: .failure(.notFound)) { },
        ])

        let result = await service.lookup("test")

        guard case .failure(let reason) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(reason, .notFound)
    }

    func testChainReportsUnreachableWhenNothingAnswered() async {
        let service = DictionaryService(providers: [
            StubProvider(name: "one", outcome: .failure(.unavailable)) { },
            StubProvider(name: "two", outcome: .failure(.unavailable)) { },
        ])

        let result = await service.lookup("test")

        guard case .failure(let reason) = result else { return XCTFail("expected failure") }
        XCTAssertEqual(reason, .unreachable, "no provider was definitive, so this is an outage not a miss")
    }
}
