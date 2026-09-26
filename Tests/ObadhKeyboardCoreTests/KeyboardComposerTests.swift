import Foundation
import XCTest
@testable import ObadhKeyboardCore

@MainActor
final class KeyboardComposerTests: XCTestCase {
    func testActiveInputRendersAsTextAndCommitsOnce() {
        let composer = KeyboardComposer(engine: FixtureEngine())
        let document = FakeCompositionDocument()
        let compositionController = TextCompositionController()

        composer.append("k")
        compositionController.setComposition(composer.preview, in: document)
        composer.append("a")
        compositionController.setComposition(composer.preview, in: document)
        composer.append("n")
        compositionController.setComposition(composer.preview, in: document)

        XCTAssertEqual(document.text, "কান")
        // Each keystroke appends only the changed suffix — the word is ordinary text.
        XCTAssertEqual(document.operations, [
            .insertText("ক"),
            .insertText("া"),
            .insertText("ন")
        ])

        let committed = composer.commitActiveInput()
        XCTAssertEqual(committed, "কান")
        compositionController.commit(finalText: committed ?? "", trailingText: " ", in: document)

        XCTAssertEqual(document.text, "কান ")
        // The word is already real; commit only appends the space.
        XCTAssertEqual(document.operations, [
            .insertText("ক"),
            .insertText("া"),
            .insertText("ন"),
            .insertText(" ")
        ])
    }

    func testDeterministicOutputStaysDefaultCommitWhenAutocorrectRanksFirst() {
        let engine = AutocorrectFirstFixtureEngine()
        let composer = KeyboardComposer(engine: engine)

        for scalar in "madar" {
            composer.append(String(scalar))
        }

        // Autocorrect candidates arrive asynchronously in the app; here we merge
        // them directly to assert the deterministic entry stays first.
        composer.mergeAutocorrectCandidates(
            engine.compositionSuggestions(for: "madar", limit: composer.autocorrectFetchLimit),
            generation: composer.generation
        )

        XCTAssertEqual(
            composer.activeSuggestions.map(\.text),
            ["মাদার", "তাদের", "থাকার"]
        )
        XCTAssertEqual(composer.activeSuggestions.first?.source, .deterministic)
        XCTAssertEqual(composer.commitActiveInput(), "মাদার")
    }

    func testDeterministicPreviewIsAvailableBeforeAutocorrectMerges() {
        let composer = KeyboardComposer(engine: AutocorrectFirstFixtureEngine())

        for scalar in "madar" {
            composer.append(String(scalar))
        }

        // Before any async merge, only the deterministic preview is present.
        XCTAssertEqual(composer.preview, "মাদার")
        XCTAssertEqual(composer.activeSuggestions.map(\.text), ["মাদার"])
    }

    func testDoubleQPreservesRawInputButDeletesAsOneUnit() {
        let composer = KeyboardComposer(engine: FixtureEngine())

        composer.append("q")
        composer.append("q")
        XCTAssertEqual(composer.romanBuffer, "qq")
        XCTAssertTrue(composer.deleteBackward())
        XCTAssertEqual(composer.romanBuffer, "")
        composer.append("q")
        composer.append("q")
        XCTAssertEqual(composer.romanBuffer, "qq")

        composer.clear()
        for scalar in "aqq" { composer.append(String(scalar)) }
        XCTAssertEqual(composer.romanBuffer, "aqq")

        composer.clear()
        composer.append("q")
        XCTAssertEqual(composer.romanBuffer, "q", "a single q must be untouched")
    }

    func testTqqCanReturnToTqWhenTheEngineSupportsKhandaTaAlias() {
        // Contract test for a future engine alias; the bundled 0.9.3 engine
        // does not implement tq → ৎ. Do not change its transliteration here.
        let composer = KeyboardComposer(engine: KhandaTaAliasFixtureEngine())
        for key in "tqq" { composer.append(String(key)) }
        XCTAssertEqual(composer.preview, "তঁ")
        XCTAssertTrue(composer.deleteBackward())
        XCTAssertEqual(composer.romanBuffer, "tq")
        XCTAssertEqual(composer.preview, "ৎ")
    }

    func testEmojiSuggestionsAreExposedSeparatelyFromText() {
        let composer = KeyboardComposer(
            engine: AutocorrectFirstFixtureEngine(),
            emojiSuggester: FixtureEmojiSuggester(["মাদার": ["❤️", "😍", "🥰"]])
        )
        for scalar in "madar" { composer.append(String(scalar)) }

        XCTAssertEqual(composer.preview, "মাদার")
        XCTAssertEqual(composer.activeEmojis, ["❤️", "😍", "🥰"])
        // Emoji are a separate channel; text candidates never contain them.
        XCTAssertEqual(composer.activeSuggestions.first?.source, .deterministic)
        XCTAssertFalse(composer.activeSuggestions.contains { $0.text == "❤️" })
    }

    func testEmojiDoesNotDisturbTextCandidates() {
        let engine = AutocorrectFirstFixtureEngine()
        let composer = KeyboardComposer(engine: engine, emojiSuggester: FixtureEmojiSuggester(["মাদার": ["❤️"]]))
        for scalar in "madar" { composer.append(String(scalar)) }
        composer.mergeAutocorrectCandidates(
            engine.compositionSuggestions(for: "madar", limit: composer.autocorrectFetchLimit),
            generation: composer.generation
        )

        XCTAssertEqual(composer.activeSuggestions.first?.source, .deterministic)
        XCTAssertTrue(composer.activeSuggestions.contains { $0.source == .autocorrect })
        XCTAssertEqual(composer.activeEmojis, ["❤️"])
    }

    func testNoEmojiWithoutAMatch() {
        let composer = KeyboardComposer(engine: FixtureEngine(), emojiSuggester: FixtureEmojiSuggester([:]))
        composer.append("k")
        XCTAssertTrue(composer.activeEmojis.isEmpty)
    }

    func testStaleAutocorrectCandidatesAreIgnored() {
        let composer = KeyboardComposer(engine: FixtureEngine())

        composer.append("k")
        let staleGeneration = composer.generation
        composer.append("a")

        composer.mergeAutocorrectCandidates(["ক্যাব"], generation: staleGeneration)

        XCTAssertEqual(composer.activeSuggestions.map(\.text), ["কা"])
    }

    func testAutosuggestMergeKeepsSessionFirstAndFallsBackToContext() {
        let session = [
            KeyboardSuggestion(text: "আমি", source: .autosuggest),
            KeyboardSuggestion(text: "আমার", source: .autosuggest)
        ]
        let context = [
            KeyboardSuggestion(text: "আমার", source: .autosuggest),
            KeyboardSuggestion(text: "সে", source: .autosuggest),
            KeyboardSuggestion(text: "তুমি", source: .autosuggest)
        ]

        XCTAssertEqual(
            KeyboardComposer.mergeSuggestions(primary: session, fallback: context, limit: 3),
            [
                KeyboardSuggestion(text: "আমি", source: .autosuggest),
                KeyboardSuggestion(text: "আমার", source: .autosuggest),
                KeyboardSuggestion(text: "সে", source: .autosuggest)
            ]
        )
    }
}

private struct KhandaTaAliasFixtureEngine: BanglaTypingEngine {
    func transliterate(_ input: String) -> String {
        switch input {
        case "t": "ত"
        case "tq": "ৎ"
        case "tqq": "তঁ"
        default: ""
        }
    }
    func compositionSuggestions(for romanInput: String, limit: Int) -> [String] { [] }
    func autosuggestSuggestions(for context: String, limit: Int) -> [String] { [] }
}

private struct FixtureEmojiSuggester: BanglaEmojiSuggesting {
    let map: [String: [String]]

    init(_ map: [String: [String]]) {
        self.map = map
    }

    func emojis(for banglaWord: String) -> [String] {
        map[banglaWord] ?? []
    }
}

private struct FixtureEngine: BanglaTypingEngine {
    func transliterate(_ input: String) -> String {
        switch input {
        case "k":
            "ক"
        case "ka":
            "কা"
        case "kan":
            "কান"
        default:
            ""
        }
    }

    func compositionSuggestions(for romanInput: String, limit: Int) -> [String] {
        switch romanInput {
        case "k":
            ["ক"]
        case "ka":
            ["কা"]
        case "kan":
            ["কান"]
        default:
            []
        }
    }

    func autosuggestSuggestions(for context: String, limit: Int) -> [String] {
        []
    }
}

extension KeyboardComposerTests {
    /// A colon typed mid-word stays in the roman buffer and reaches the engine, so
    /// bisarga renders. The keyboard routes it here rather than through the literal
    /// symbol path, which would commit the word first.
    func testColonJoinsTheCompositionSoBisargaRenders() {
        let composer = KeyboardComposer(engine: BisargaFixtureEngine())
        for scalar in "du" { composer.append(String(scalar)) }
        XCTAssertEqual(composer.preview, "দু")

        composer.append(":")
        XCTAssertEqual(composer.romanBuffer, "du:")
        XCTAssertEqual(composer.preview, "দুঃ")

        for scalar in "kho" { composer.append(String(scalar)) }
        XCTAssertEqual(composer.romanBuffer, "du:kho")
        XCTAssertEqual(composer.preview, "দুঃখ")
    }

    /// Builds a composer at a word with a deterministic + one autocorrect candidate.
    private func composerWithCorrection() -> KeyboardComposer {
        let composer = KeyboardComposer(engine: BanhlaFixtureEngine())
        for scalar in "banhla" { composer.append(String(scalar)) }
        composer.mergeAutocorrectCandidates(
            ["বাংলা", "বনিহালা"], generation: composer.generation
        )
        return composer
    }

    /// A correction the gate accepts on its own terms: a confident channel, a
    /// one-unit slip, and a common enough word. These tests are about what the
    /// COMPOSER does with a gate decision — the policy itself is AutoInsertGate's
    /// to test — so the correction is held constant and the baseline is what moves.
    private func confidentCorrection(
        _ text: String,
        frequency: UInt64 = 5_000
    ) -> DetailedCorrection {
        DetailedCorrection(
            text: text,
            source: DetailedCorrection.Source.editDistance,
            editCost: 1,
            romanRepairCost: nil,
            frequency: frequency
        )
    }

    /// Feature off: no target, so space commits exactly what is shown.
    func testNoAutocorrectTargetWhenFeatureOff() {
        let composer = composerWithCorrection()
        composer.resolveAutocorrectTarget(
            autoInsertEnabled: false,
            baselineFrequency: 0,
            detailedCorrections: [confidentCorrection("বাংলা")],
            isProtectedWord: { _ in false }
        )
        XCTAssertNil(composer.autocorrectTarget)
        XCTAssertEqual(composer.commitText, composer.preview) // the deterministic
    }

    /// Feature on, typed word isn't in the lexicon at all (baseline frequency 0),
    /// a correction exists: space commits the correction, and the shown
    /// deterministic word is what gets quoted.
    func testAutocorrectTargetIsTheTopCorrectionForAnUnknownWord() {
        let composer = composerWithCorrection()
        composer.resolveAutocorrectTarget(
            autoInsertEnabled: true,
            baselineFrequency: 0,
            detailedCorrections: [confidentCorrection("বাংলা")],
            isProtectedWord: { _ in false }
        )
        XCTAssertEqual(composer.autocorrectTarget, "বাংলা")
        XCTAssertEqual(composer.commitText, "বাংলা")
    }

    /// The typed word is itself a common lexicon word: the frequency-ratio rule
    /// declines, so it is not second-guessed even with the feature on.
    func testNoTargetWhenShownWordIsACommonLexiconWord() {
        let composer = composerWithCorrection()
        composer.resolveAutocorrectTarget(
            autoInsertEnabled: true,
            baselineFrequency: 5_000,
            detailedCorrections: [confidentCorrection("বাংলা")],
            isProtectedWord: { _ in false }
        )
        XCTAssertNil(composer.autocorrectTarget)
    }

    /// A lexicon word so much rarer than the correction that the user almost
    /// surely meant the common one — the case that fixes manus→মানুষ. The composer
    /// must pass the baseline through rather than treating "is a word" as final.
    func testTargetOverridesALexiconWordThatIsFarRarer() {
        let composer = composerWithCorrection()
        composer.resolveAutocorrectTarget(
            autoInsertEnabled: true,
            baselineFrequency: 10,
            detailedCorrections: [confidentCorrection("বাংলা")],
            isProtectedWord: { _ in false }
        )
        XCTAssertEqual(composer.autocorrectTarget, "বাংলা")
    }

    /// A word the user has established is protected: no correction.
    func testNoTargetWhenShownWordIsProtected() {
        let composer = composerWithCorrection()
        composer.resolveAutocorrectTarget(
            autoInsertEnabled: true,
            baselineFrequency: 0,
            detailedCorrections: [confidentCorrection("বাংলা")],
            isProtectedWord: { $0 == composer.preview }
        )
        XCTAssertNil(composer.autocorrectTarget)
    }

    /// Only corrections the bar is actually showing may be committed: the strip has
    /// to display what space will insert.
    func testNoTargetWhenTheCorrectionIsNotOffered() {
        let composer = composerWithCorrection()
        composer.resolveAutocorrectTarget(
            autoInsertEnabled: true,
            baselineFrequency: 0,
            detailedCorrections: [confidentCorrection("অন্যকিছু")],
            isProtectedWord: { _ in false }
        )
        XCTAssertNil(composer.autocorrectTarget)
    }

    /// A keystroke invalidates a resolved target until fresh candidates re-resolve it.
    func testTargetClearsWhenTheBufferChanges() {
        let composer = composerWithCorrection()
        composer.resolveAutocorrectTarget(
            autoInsertEnabled: true,
            baselineFrequency: 0,
            detailedCorrections: [confidentCorrection("বাংলা")],
            isProtectedWord: { _ in false }
        )
        XCTAssertNotNil(composer.autocorrectTarget)

        composer.append("x")
        XCTAssertNil(composer.autocorrectTarget)
    }
}

/// Bisarga is typed as a colon inside a word: `du` `:` `kho` is দুঃখ. The colon
/// therefore has to reach the engine as part of the roman token — if anything
/// commits the composition when it is pressed, the engine sees `du` and a separate
/// `:`, and bisarga becomes unreachable from this keyboard entirely.
private struct BisargaFixtureEngine: BanglaTypingEngine {
    func transliterate(_ input: String) -> String {
        switch input {
        case "du:kho": "দুঃখ"
        case "du:": "দুঃ"
        case "du": "দু"
        default: ""
        }
    }

    func compositionSuggestions(for romanInput: String, limit: Int) -> [String] { [] }
    func autosuggestSuggestions(for context: String, limit: Int) -> [String] { [] }
}

private struct BanhlaFixtureEngine: BanglaTypingEngine {
    func transliterate(_ input: String) -> String {
        input == "banhla" ? "বানহ্লা" : (input.isEmpty ? "" : "বানহ্লা")
    }

    func compositionSuggestions(for romanInput: String, limit: Int) -> [String] {
        romanInput == "banhla" ? ["বাংলা", "বনিহালা"] : []
    }

    func autosuggestSuggestions(for context: String, limit: Int) -> [String] { [] }
}

private struct AutocorrectFirstFixtureEngine: BanglaTypingEngine {
    func transliterate(_ input: String) -> String {
        input == "madar" ? "মাদার" : ""
    }

    func compositionSuggestions(for romanInput: String, limit: Int) -> [String] {
        romanInput == "madar" ? ["তাদের", "মাদার", "থাকার", "খাবার"] : []
    }

    func autosuggestSuggestions(for context: String, limit: Int) -> [String] {
        []
    }
}
