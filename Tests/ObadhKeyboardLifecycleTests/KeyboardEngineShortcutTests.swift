import XCTest

/// Uses the bundled C engine, not a fixture that reimplements its Roman rules.
@MainActor
final class KeyboardEngineShortcutTests: XCTestCase {
    private func configuredEngine() -> ObadhBridgeClient {
        let engine = ObadhBridgeClient.shared
        let configuration = engine.configureModels(in: Bundle(for: Self.self))
        XCTAssertTrue(configuration.autocorrectAvailable)
        return engine
    }

    func testBundledEngineOwnsChandrabinduAndPreservesCaseAndSingleQ() {
        let engine = configuredEngine()
        for (roman, expected) in [
            ("q", "ক"), ("qq", "ঁ"), ("baqq", "বাঁ"), ("ba^", "বাঁ"),
            ("qqq", "ঁক"), ("qqqq", "ঁঁ"), ("tqq", "তঁ"),
            ("iraq", "ইরাক"), ("Qq", "ক্ক"), ("qQ", "ক্ক"), ("QQ", "ক্ক")
        ] {
            XCTAssertEqual(engine.transliterate(roman), expected, roman)
        }
    }

    func testBackspaceRemovesChandrabinduAsOneInputUnit() {
        let composer = KeyboardComposer(engine: configuredEngine())
        for key in "baqq" { composer.append(String(key)) }
        XCTAssertEqual(composer.preview, "বাঁ")

        XCTAssertTrue(composer.deleteBackward())
        XCTAssertEqual(composer.romanBuffer, "ba")
        XCTAssertEqual(composer.preview, "বা")

        composer.append("q")
        composer.append("q")
        XCTAssertEqual(composer.preview, "বাঁ")
        for expected in ["বা", "ব", ""] {
            XCTAssertTrue(composer.deleteBackward())
            XCTAssertEqual(composer.preview, expected)
        }
        XCTAssertFalse(composer.deleteBackward())
    }

    func testEachTypingPrefixMatchesTheEngine() {
        let engine = configuredEngine()
        for word in ["qq", "baqqd", "tqq", "qqq", "qqqq", "qQ", "Qq", "QQ", "iraq", "ba^"] {
            let composer = KeyboardComposer(engine: engine)
            var prefix = ""
            for key in word {
                prefix.append(key)
                composer.append(String(key))
                XCTAssertEqual(composer.romanBuffer, prefix)
                XCTAssertEqual(composer.preview, engine.transliterate(prefix), prefix)
            }
        }
    }

    func testDeletionRespectsQPairsWithoutSwallowingAdjacentInput() {
        let engine = configuredEngine()
        for (typed, remaining, expected) in [
            ("qq", "", ""), ("qqq", "qq", "ঁ"), ("qqqq", "qq", "ঁ"),
            ("baqqd", "baqq", "বাঁ"), ("baqq", "ba", "বা"),
            ("ba^", "ba", "বা"), ("qQ", "q", "ক"), ("Qq", "Q", "ক"),
            ("QQ", "Q", "ক"), ("iraq", "ira", "ইরা"),
            // The bundled engine has no tq → ৎ alias yet; do not expose its
            // defensive tq → ৎক fallback as a meaningful intermediate form.
            ("tqq", "t", "ত")
        ] {
            let composer = KeyboardComposer(engine: engine)
            for key in typed { composer.append(String(key)) }
            XCTAssertTrue(composer.deleteBackward())
            XCTAssertEqual(composer.romanBuffer, remaining, typed)
            XCTAssertEqual(composer.preview, expected, typed)
        }
    }

    func testRawDoubleQSuggestionsKeepTheSameDeterministicWordAsCaret() {
        let engine = configuredEngine()
        let composer = KeyboardComposer(engine: engine)
        for key in "baqq" { composer.append(String(key)) }
        let candidates = engine.compositionSuggestions(for: composer.romanBuffer, limit: composer.autocorrectFetchLimit)
        XCTAssertEqual(candidates.first, engine.transliterate("ba^"))
        composer.mergeAutocorrectCandidates(candidates, generation: composer.generation)
        XCTAssertEqual(composer.activeSuggestions.first?.text, "বাঁ")
        XCTAssertEqual(composer.commitText, "বাঁ")
    }

    func testCommitAndClearDoNotCarryQIntoTheNextWord() {
        let engine = configuredEngine()
        let composer = KeyboardComposer(engine: engine)
        for key in "baqq" { composer.append(String(key)) }
        XCTAssertEqual(composer.commitActiveInput(), "বাঁ")
        composer.append("q")
        XCTAssertEqual(composer.preview, "ক")
        composer.clear()
        composer.append("q")
        XCTAssertEqual(composer.preview, "ক")
    }
}
