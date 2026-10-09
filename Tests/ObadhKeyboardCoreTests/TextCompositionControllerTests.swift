import Foundation
import XCTest
@testable import ObadhKeyboardCore

@MainActor
final class TextCompositionControllerTests: XCTestCase {
    func testLiteralFaceRewritesUseExactScalarsAcrossDifferentUTF8Lengths() {
        for (initial, face) in [("‘", "':)"), ("৮", "8)"), ("ও", "o:)"), ("é", "e\u{301}:)")] {
            let document = FakeCompositionDocument()
            let controller = TextCompositionController()
            controller.setComposition(initial, in: document)
            controller.setComposition(face, in: document)
            XCTAssertEqual(Array(document.text.unicodeScalars), Array(face.unicodeScalars))
            controller.commit(finalText: "😃", trailingText: " ", in: document)
            XCTAssertEqual(document.text, "😃 ")
        }
    }

    // MARK: - Diff mechanics (Latin: grapheme == scalar, so ops are exact)

    /// Appending re-derives the word but writes only the new suffix — the shared prefix
    /// is left in place, no delete.
    func testAppendWritesOnlyTheNewSuffix() {
        let document = FakeCompositionDocument()
        let controller = TextCompositionController()

        controller.setComposition("cat", in: document)
        controller.setComposition("cats", in: document)

        XCTAssertEqual(document.text, "cats")
        XCTAssertEqual(document.operations, [
            .insertText("cat"),
            .insertText("s")
        ])
    }

    /// A change in the tail deletes only past the common prefix, then inserts the new
    /// tail — not a full delete-and-reinsert.
    func testDivergentTailDeletesOnlyPastTheCommonPrefix() {
        let document = FakeCompositionDocument()
        let controller = TextCompositionController()

        controller.setComposition("cart", in: document)
        controller.setComposition("care", in: document) // last char differs

        XCTAssertEqual(document.text, "care")
        XCTAssertEqual(document.operations, [
            .insertText("cart"),
            .deleteBackward,          // drop 't'
            .insertText("e")          // add 'e'
        ])
    }

    // MARK: - Typing rewrites the word in place (Bangla: assert the result)

    /// Typing a word whose rendering only grows is all appends, no deletes — even when
    /// each new sign joins the previous grapheme cluster. That is the flicker-free path.
    func testTypingBanglaWordIsPureAppends() {
        let document = FakeCompositionDocument()
        let controller = TextCompositionController()

        controller.setComposition("বা", in: document)
        controller.setComposition("বাং", in: document)
        controller.setComposition("বাংল", in: document)
        controller.setComposition("বাংলা", in: document)

        XCTAssertEqual(document.text, "বাংলা")
        XCTAssertEqual(controller.composedText, "বাংলা")
        XCTAssertFalse(
            document.operations.contains(.deleteBackward),
            "a growing word should never delete, got \(document.operations)"
        )
    }

    func testVowelSignReshapeLandsTheCorrectWord() {
        let document = FakeCompositionDocument()
        let controller = TextCompositionController()

        controller.setComposition("কি", in: document)
        controller.setComposition("কী", in: document)

        XCTAssertEqual(document.text, "কী")
    }

    func testBackspaceShortensTheWord() {
        let document = FakeCompositionDocument()
        let controller = TextCompositionController()

        controller.setComposition("বাংলা", in: document)
        controller.setComposition("বাংল", in: document)

        XCTAssertEqual(document.text, "বাংল")
        XCTAssertEqual(controller.composedText, "বাংল")
    }

    func testClearCompositionDeletesTheWholeWord() {
        let document = FakeCompositionDocument(initialText: "আমি ")
        let controller = TextCompositionController()

        controller.setComposition("কান", in: document)
        controller.clearComposition(in: document)

        // The word is gone; the text that preceded it is untouched.
        XCTAssertEqual(document.text, "আমি ")
        XCTAssertFalse(controller.hasActiveComposition)
    }

    // MARK: - Committing

    func testCommitWithTrailingSpaceKeepsTheWord() {
        let document = FakeCompositionDocument()
        let controller = TextCompositionController()

        controller.setComposition("কান", in: document)
        controller.commit(finalText: "কান", trailingText: " ", in: document)

        XCTAssertEqual(document.text, "কান ")
        XCTAssertFalse(controller.hasActiveComposition)
        // The word is already correct; commit only appends the space.
        XCTAssertEqual(document.operations, [
            .insertText("কান"),
            .insertText(" ")
        ])
    }

    /// The autocorrect path: space commits a different word than what is shown, replacing
    /// it in place, then the space.
    func testCommitReplacesWithCorrectionThenTrailingSpace() {
        let document = FakeCompositionDocument()
        let controller = TextCompositionController()

        controller.setComposition("বানহ্লা", in: document)
        controller.commit(finalText: "বাংলা", trailingText: " ", in: document)

        XCTAssertEqual(document.text, "বাংলা ")
        XCTAssertFalse(controller.hasActiveComposition)
    }

    func testCommitSentencePunctuationKeepsTheWord() {
        let document = FakeCompositionDocument()
        let controller = TextCompositionController()

        controller.setComposition("গাই", in: document)
        controller.commit(finalText: "গাই", trailingText: "।", in: document)

        XCTAssertEqual(document.text, "গাই।")
        XCTAssertEqual(document.operations, [
            .insertText("গাই"),
            .insertText("।")
        ])
    }

    /// The reported bug: committing a correction over a typed word must replace it whole,
    /// not leave a fragment (`বানহবাংলা`). Preceding text must survive.
    func testCommitCorrectionReplacesTheWholeWord() {
        let document = FakeCompositionDocument(initialText: "আমি ")
        let controller = TextCompositionController()

        controller.setComposition("বানহ্লা", in: document)
        controller.commit(finalText: "বাংলা", trailingText: " ", in: document)

        XCTAssertEqual(document.text, "আমি বাংলা ")
    }

    /// Same replacement, but on a host that deletes one scalar per press instead of one
    /// grapheme — the granularity mismatch that produced the fragment. Deleting against
    /// the live document (not our own count) must still land it exactly.
    func testCorrectionReplacementSurvivesScalarGranularDeletion() {
        let document = ScalarDeletingDocument(initialText: "আমি ")
        let controller = TextCompositionController()

        controller.setComposition("বানহ্লা", in: document)
        controller.commit(finalText: "বাংলা", trailingText: " ", in: document)

        XCTAssertEqual(document.text, "আমি বাংলা ")
    }

    /// And an ordinary reshape survives the same coarse/fine mismatch.
    func testReshapeSurvivesScalarGranularDeletion() {
        let document = ScalarDeletingDocument()
        let controller = TextCompositionController()

        controller.setComposition("কি", in: document)
        controller.setComposition("কী", in: document)

        XCTAssertEqual(document.text, "কী")
    }

    /// Re-editing a committed word the cursor sits in: the word before the cursor is
    /// swapped for the chosen alternative, and surrounding text is untouched.
    func testReplaceWordBeforeCursorSwapsInPlace() {
        // Cursor already moved to the word's end: "আমার বলার কি|" with " চিলোনা" after.
        let document = FakeCompositionDocument(initialText: "আমার বলার কি")
        let controller = TextCompositionController()

        controller.replaceWordBeforeCursor("কি", with: "কী", in: document)

        XCTAssertEqual(document.text, "আমার বলার কী")
    }

    /// Same, on a host that deletes by scalar — the granularity that broke corrections.
    func testReplaceWordBeforeCursorSurvivesScalarGranularDeletion() {
        let document = ScalarDeletingDocument(initialText: "আমি বানহ্লা")
        let controller = TextCompositionController()

        controller.replaceWordBeforeCursor("বানহ্লা", with: "বাংলা", in: document)

        XCTAssertEqual(document.text, "আমি বাংলা")
    }

    /// Safety: if the word isn't actually before the cursor (stale), do nothing.
    func testReplaceWordBeforeCursorNoOpsWhenWordNotAtCursor() {
        let document = FakeCompositionDocument(initialText: "আমার বলার")
        let controller = TextCompositionController()

        controller.replaceWordBeforeCursor("কি", with: "কী", in: document)

        XCTAssertEqual(document.text, "আমার বলার")
    }

    func testTappedSuggestionReplacesTheWordWithoutTrailingSpace() {
        let document = FakeCompositionDocument()
        let controller = TextCompositionController()

        controller.setComposition("সুশিল", in: document)
        controller.commitSuggestion("সুশীল", in: document)

        XCTAssertEqual(document.text, "সুশীল")
        XCTAssertFalse(controller.hasActiveComposition)
    }

    // MARK: - Cursor moves / external edits never corrupt text

    /// The heart of the fix: moving the cursor away just drops tracking. The word stays,
    /// the document is untouched, and there is no marked region to trap the cursor.
    func testResetHostStateKeepsTextAndTouchesNothing() {
        let document = FakeCompositionDocument()
        let controller = TextCompositionController()

        controller.setComposition("নিউ", in: document)
        controller.resetHostState()

        XCTAssertEqual(document.text, "নিউ")
        XCTAssertFalse(controller.hasActiveComposition)
        XCTAssertEqual(document.operations, [.insertText("নিউ")])
    }

    /// After the cursor moves, a fresh word is inserted at the new location without
    /// disturbing the earlier one.
    func testCompositionAfterCursorMoveStartsFresh() {
        let document = FakeCompositionDocument(initialText: "আমি ")
        let controller = TextCompositionController()

        controller.setComposition("বাংলা", in: document)
        controller.resetHostState() // cursor moved away
        controller.setComposition("ক", in: document)

        XCTAssertEqual(document.text, "আমি বাংলাক")
    }

    /// Guard: if our tracked word is no longer at the cursor (a move we never observed),
    /// we must NOT delete whatever is now there — we insert fresh instead.
    func testStaleTrackingDoesNotDeleteForeignText() {
        let document = FakeCompositionDocument()
        let controller = TextCompositionController()

        controller.setComposition("বাংলা", in: document)
        // Simulate the host/user changing the surrounding text out from under us without
        // a callback: the tracked "বাংলা" is no longer the suffix at the cursor.
        document.insertText(" আমার")

        controller.setComposition("ক", in: document)

        // "বাংলা আমার" is preserved; only the new letter is appended.
        XCTAssertEqual(document.text, "বাংলা আমারক")
    }

    // MARK: - Boundaries (unchanged behaviour)

    func testNextWordSuggestionInsertsReadableBoundary() {
        let document = FakeCompositionDocument(initialText: "আমি")
        let controller = TextCompositionController()

        controller.commitNextWordSuggestion("ভালো", in: document)

        XCTAssertEqual(document.text, "আমি ভালো ")
        XCTAssertEqual(document.operations, [
            .insertText(" "),
            .insertText("ভালো"),
            .insertText(" ")
        ])
    }

    func testNextWordSuggestionDoesNotDoubleLeadingSpace() {
        let document = FakeCompositionDocument(initialText: "আমি ")
        let controller = TextCompositionController()

        controller.commitNextWordSuggestion("ভালো", in: document)

        XCTAssertEqual(document.text, "আমি ভালো ")
        XCTAssertEqual(document.operations, [
            .insertText("ভালো"),
            .insertText(" ")
        ])
    }

    func testEverySpaceKeyInsertsASpace() {
        // The space key is explicit intent: two idle taps type two spaces, exactly
        // like native. (The old whitespace guard swallowed the second one, which
        // read as "nothing happens" when adding a space mid-sentence. The dari
        // double-tap shortcut is the keyboard controller's, and time-gated.)
        let document = FakeCompositionDocument()
        let controller = TextCompositionController()

        controller.insertSpace(in: document)
        controller.insertSpace(in: document)

        XCTAssertEqual(document.text, "  ")
        XCTAssertEqual(document.operations, [.insertText(" "), .insertText(" ")])
    }
}
