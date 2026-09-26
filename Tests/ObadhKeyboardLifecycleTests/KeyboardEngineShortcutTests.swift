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

    func testIOSKhandaTaShortcutRendersWholeWords() {
        let engine = configuredEngine()
        for (typed, expected) in [
            ("tq", "ৎ"), ("Tq", "ৎ"), ("sotq", "সৎ"),
            ("utqsob", "উৎসব"), ("bidyutq", "বিদ্যুৎ"),
            ("tqq", "তঁ"), ("baqq", "বাঁ"), ("tt", "ত্ত"),
            ("iraq", "ইরাক"), ("qatar", "কাতার")
        ] {
            let composer = KeyboardComposer(engine: engine)
            for key in typed { composer.append(String(key)) }
            XCTAssertEqual(composer.preview, expected, typed)
            XCTAssertEqual(composer.commitActiveInput(), expected, typed)
        }
    }

    func testTqAndTqqTransitionInBothDirections() {
        let composer = KeyboardComposer(engine: configuredEngine())
        for (key, expected) in [("t", "ত"), ("q", "ৎ"), ("q", "তঁ"), ("q", "তঁক")] {
            composer.append(key)
            XCTAssertEqual(composer.preview, expected)
        }
        for (remaining, expected) in [("tqq", "তঁ"), ("tq", "ৎ"), ("t", "ত"), ("", "")] {
            XCTAssertTrue(composer.deleteBackward())
            XCTAssertEqual(composer.romanBuffer, remaining)
            XCTAssertEqual(composer.preview, expected)
        }
        composer.append("q")
        XCTAssertEqual(composer.preview, "ক", "No modifier state may survive deletion")
    }

    func testShortcutCorrectionQueriesMatchExplicitEngineSignal() {
        let engine = configuredEngine()
        for (raw, canonical) in [("sotq", "sot``"), ("utqsob", "ut``sob"), ("bidyutq", "bidyut``")] {
            let composer = KeyboardComposer(engine: engine)
            for key in raw { composer.append(String(key)) }
            XCTAssertEqual(composer.romanBuffer, raw)
            XCTAssertEqual(composer.engineInput, canonical)
            XCTAssertEqual(engine.compositionSuggestions(for: composer.engineInput, limit: 4),
                           engine.compositionSuggestions(for: canonical, limit: 4))
            XCTAssertEqual(engine.detailedCorrections(for: composer.engineInput, limit: 4),
                           engine.detailedCorrections(for: canonical, limit: 4))
        }
    }

    func testControllerUsesCanonicalInputForAsyncSuggestions() async throws {
        let controller = KeyboardViewController()
        controller.loadViewIfNeeded()
        controller.beginAppearanceTransition(true, animated: false)
        controller.endAppearanceTransition()
        defer {
            controller.beginAppearanceTransition(false, animated: false)
            controller.endAppearanceTransition()
        }
        controller.handleDebugCommand("tap", argument: "s,o,t,q")
        let composer = try XCTUnwrap(Mirror(reflecting: controller).children
            .first { $0.label == "composer" || $0.label == "$__lazy_storage_$_composer" }?.value as? KeyboardComposer)
        XCTAssertEqual(composer.preview, "সৎ")
        let expected = KeyboardComposer(engine: configuredEngine())
        expected.append("sot``")
        expected.mergeAutocorrectCandidates(
            configuredEngine().compositionSuggestions(for: "sot``", limit: expected.autocorrectFetchLimit),
            generation: expected.generation)
        XCTAssertGreaterThan(expected.activeSuggestions.count, 1, "Exercise async candidates, not just preview")
        for _ in 0..<100 {
            if composer.activeSuggestions == expected.activeSuggestions { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(composer.activeSuggestions, expected.activeSuggestions)
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
        for word in ["tq", "Tq", "utqsob", "qq", "baqqd", "tqq", "qqq", "qqqq", "qQ", "Qq", "QQ", "iraq", "ba^"] {
            let composer = KeyboardComposer(engine: engine)
            var prefix = ""
            for key in word {
                prefix.append(key)
                composer.append(String(key))
                XCTAssertEqual(composer.romanBuffer, prefix)
                XCTAssertEqual(composer.preview, engine.transliterate(composer.engineInput), prefix)
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
            ("tqq", "tq", "ৎ"), ("tq", "t", "ত")
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
        let candidates = engine.compositionSuggestions(for: composer.engineInput, limit: composer.autocorrectFetchLimit)
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
