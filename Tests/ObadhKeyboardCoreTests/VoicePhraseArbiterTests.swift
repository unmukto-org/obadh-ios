import XCTest
@testable import ObadhKeyboardCore

final class VoicePhraseArbiterTests: XCTestCase {
    func testRefinedReadingWinsWhenComparableLength() {
        XCTAssertEqual(VoicePhraseArbiter.choose(streaming: "মংড়োর কাছে", refined: "মোংডুর কাছে"), "মোংডুর কাছে")
    }

    /// A much shorter refined reading is a deletion: keep the draft.
    func testShortRefinedReadingIsTreatedAsDeletion() {
        let draft = "এভাবে আমরা আমরা সমাধান করব সুতরাং মনে রাখবে"
        XCTAssertEqual(VoicePhraseArbiter.choose(streaming: draft, refined: "সুতরাং মনে রাখবে"), draft)
    }

    func testMissingOrEmptyReadingsFallBack() {
        XCTAssertEqual(VoicePhraseArbiter.choose(streaming: "ক", refined: nil), "ক")
        XCTAssertEqual(VoicePhraseArbiter.choose(streaming: "ক", refined: "  "), "ক")
        XCTAssertEqual(VoicePhraseArbiter.choose(streaming: "", refined: "খ"), "খ")
    }

    func testNormalizationCollapsesWhitespaceAndComposes() {
        XCTAssertEqual(VoicePhraseArbiter.normalize("  আমি \n  যাব "), "আমি যাব")
        // Compare scalars: String == is canonical equivalence, so it cannot see this.
        // U+09DF (য়) is a composition exclusion, so NFC spells it য + nukta, and both
        // passes' outputs end up in that one spelling.
        XCTAssertEqual(Array(VoicePhraseArbiter.normalize("\u{09DF}").unicodeScalars), ["\u{09AF}", "\u{09BC}"])
        XCTAssertEqual(Array(VoicePhraseArbiter.normalize("\u{0995}\u{09BC}").unicodeScalars), ["\u{0995}", "\u{09BC}"])
    }
}
