import Foundation
import XCTest
@testable import ObadhKeyboardCore

@MainActor
final class VoiceDraftReconcilerTests: XCTestCase {
    private func snapshot(
        _ text: String,
        stable: Int? = nil,
        final: Bool = false,
        phase: VoiceSessionPhase = .listening,
        dictation: String = "d1"
    ) -> VoiceSessionSnapshot {
        VoiceSessionSnapshot(
            seq: 1, phase: phase, heartbeat: Date(), dictationID: dictation,
            transcript: VoiceTranscript(text: text, stableLength: stable ?? text.count, isFinal: final),
            failure: nil
        )
    }

    /// Drive a snapshot through reconciler + writer the way the keyboard does, with
    /// a persistent mismatch resolved by the fallback.
    @discardableResult
    private func feed(
        _ snapshot: VoiceSessionSnapshot,
        _ reconciler: inout VoiceDraftReconciler,
        _ document: TextDocumentEditing
    ) -> VoiceDraftWriter.Outcome? {
        guard let step = reconciler.step(for: snapshot) else { return nil }
        let outcome = VoiceDraftWriter().apply(step, in: document)
        switch outcome {
        case .applied: reconciler.didApply(step)
        case .stale:
            let insertion = reconciler.fallbackInsertion(for: step)
            if !insertion.isEmpty { document.insertText(insertion) }
        }
        return outcome
    }

    func testCommittedTextOnlyAppendsAndTailIsRewritten() {
        let document = FakeCompositionDocument(initialText: "আমি")
        var reconciler = VoiceDraftReconciler()
        reconciler.begin(dictationID: "d1", contextBefore: document.contextBeforeInput)

        feed(snapshot("আজ", stable: 0), &reconciler, document)
        XCTAssertEqual(document.text, "আমি আজ")
        feed(snapshot("আজ বাজা", stable: 2), &reconciler, document)
        XCTAssertEqual(document.text, "আমি আজ বাজা")
        feed(snapshot("আজ বাজারে", stable: 2), &reconciler, document)
        XCTAssertEqual(document.text, "আমি আজ বাজারে")
        feed(snapshot("আজ বাজারে যাব", final: true, phase: .ready), &reconciler, document)
        XCTAssertEqual(document.text, "আমি আজ বাজারে যাব")
        // Only the tentative tail was ever deleted.
        let deletes = document.operations.filter { $0 == .deleteBackward }.count
        XCTAssertLessThanOrEqual(deletes, " বাজা".unicodeScalars.count)
    }

    func testCompletionOnlyWhenFinalAndReady() {
        var reconciler = VoiceDraftReconciler()
        reconciler.begin(dictationID: "d1", contextBefore: "")
        XCTAssertEqual(reconciler.step(for: snapshot("ক", final: false, phase: .ready))?.completesDictation, false)
        XCTAssertEqual(reconciler.step(for: snapshot("ক", final: true, phase: .finishing))?.completesDictation, false)
        XCTAssertEqual(reconciler.step(for: snapshot("ক", final: true, phase: .ready))?.completesDictation, true)
    }

    func testNoLeadingSpaceAtStartOrAfterWhitespace() {
        for context in ["", "hello ", "line\n"] {
            let document = FakeCompositionDocument(initialText: context)
            var reconciler = VoiceDraftReconciler()
            reconciler.begin(dictationID: "d1", contextBefore: context)
            feed(snapshot("হ্যাঁ"), &reconciler, document)
            XCTAssertEqual(document.text, context + "হ্যাঁ")
        }
    }

    func testForeignDictationIsIgnored() {
        var reconciler = VoiceDraftReconciler()
        reconciler.begin(dictationID: "d1", contextBefore: "")
        XCTAssertNil(reconciler.step(for: snapshot("x", dictation: "old")))
    }

    /// An out-of-date snapshot claiming less committed text must not shrink it.
    func testCommittedNeverShrinks() {
        let document = FakeCompositionDocument()
        var reconciler = VoiceDraftReconciler()
        reconciler.begin(dictationID: "d1", contextBefore: "")
        feed(snapshot("এক দুই তিন", stable: "এক দুই".count), &reconciler, document)
        let committed = reconciler.committed
        feed(snapshot("এক দুই তিন", stable: 2), &reconciler, document)
        XCTAssertEqual(reconciler.committed, committed)
        XCTAssertEqual(document.text, "এক দুই তিন")
    }

    /// Hosts show only a window before the cursor; a long dictation outgrows it.
    func testLongDictationInNarrowHostWindow() {
        let document = WindowedDocument(window: 12)
        var reconciler = VoiceDraftReconciler()
        reconciler.begin(dictationID: "d1", contextBefore: "")
        var words: [String] = []
        for word in ["আজ", "আমি", "অফিসে", "যাব", "না", "কারণ", "আমার", "শরীর", "ভালো", "নেই"] {
            words.append(word)
            let text = words.joined(separator: " ")
            let stable = words.dropLast().joined(separator: " ").count
            XCTAssertEqual(feed(snapshot(text, stable: stable), &reconciler, document), .applied)
        }
        feed(snapshot(words.joined(separator: " "), final: true, phase: .ready), &reconciler, document)
        XCTAssertEqual(document.fullText, words.joined(separator: " "))
    }

    /// Hosts that delete one scalar per press still end with the exact text.
    func testScalarDeletingHostLandsExactText() {
        let document = ScalarDeletingDocument()
        var reconciler = VoiceDraftReconciler()
        reconciler.begin(dictationID: "d1", contextBefore: "")
        feed(snapshot("বাংলাদেশ স্বাধীন", stable: "বাংলাদেশ".count), &reconciler, document)
        feed(snapshot("বাংলাদেশ স্বাধীনতা", stable: "বাংলাদেশ".count), &reconciler, document)
        feed(snapshot("বাংলাদেশ স্বাধীনতার", final: true, phase: .ready), &reconciler, document)
        XCTAssertEqual(document.contextBeforeInput, "বাংলাদেশ স্বাধীনতার")
    }

    /// The cursor moved mid-dictation: nothing is deleted, and newly committed words
    /// continue at the cursor rather than being lost.
    func testCursorMoveContinuesAtCursorWithoutDeleting() {
        let document = FakeCompositionDocument()
        var reconciler = VoiceDraftReconciler()
        reconciler.begin(dictationID: "d1", contextBefore: "")
        feed(snapshot("খসড়া", stable: 0), &reconciler, document)
        document.insertText(" typed")
        let outcome = feed(snapshot("খসড়া লেখা চলছে", stable: "খসড়া লেখা".count), &reconciler, document)
        XCTAssertEqual(outcome, .stale)
        XCTAssertEqual(document.text, "খসড়া typedখসড়া লেখা")
        XCTAssertFalse(document.operations.contains(.deleteBackward))
    }

    /// If the document stops ending with the tail mid-delete, deletion stops.
    func testDeletionStopsAtForeignText() {
        let document = FakeCompositionDocument(initialText: "keep ")
        let step = VoiceDraftReconciler.Step(currentText: "ab", desiredText: "xy", retainedText: "xy", committedAfter: 0, completesDictation: false)
        XCTAssertEqual(VoiceDraftWriter().apply(step, in: document), .stale)
        XCTAssertEqual(document.text, "keep ")
    }
}

final class VoiceTranscriptBuilderTests: XCTestCase {
    func testLastWordOfOpenPhraseIsTentative() {
        var builder = VoiceTranscriptBuilder()
        builder.setOpenPhrase("আমি অফি")
        XCTAssertEqual(builder.transcript.text, "আমি অফি")
        XCTAssertEqual(builder.transcript.stableText, "", "nothing agreed yet")
        builder.setOpenPhrase("আমি অফিসে যা")
        XCTAssertEqual(builder.transcript.stableText, "আমি", "অফিসে not yet agreed")
        builder.setOpenPhrase("আমি অফিসে যাব")
        XCTAssertEqual(builder.transcript.stableText, "আমি অফিসে")
    }

    /// Local agreement: a one-off revision is never committed.
    func testOneOffRevisionIsNotCommitted() {
        var builder = VoiceTranscriptBuilder()
        builder.setOpenPhrase("এক দুয় তিন")
        builder.setOpenPhrase("এক দুই তিন চার")
        XCTAssertEqual(builder.transcript.stableText, "এক")
        builder.setOpenPhrase("এক দুই তিন চার পাঁচ")
        XCTAssertEqual(builder.transcript.stableText, "এক দুই তিন চার")
    }

    func testClosedPhrasesAreFullyCommitted() {
        var builder = VoiceTranscriptBuilder()
        builder.setOpenPhrase("না আমি")
        builder.closeOpenPhrase(final: "না আমি যাব না")
        XCTAssertEqual(builder.transcript.text, "না আমি যাব না")
        XCTAssertEqual(builder.transcript.stableLength, builder.transcript.text.count)
        builder.setOpenPhrase("কাল")
        builder.setOpenPhrase("কাল")
        XCTAssertEqual(builder.transcript.text, "না আমি যাব না কাল")
        XCTAssertEqual(builder.transcript.stableText, "না আমি যাব না")
    }

    /// A revision of an already committed word is ignored: the keyboard has appended
    /// it and must never be asked to change it.
    func testFrozenWordsNeverChange() {
        var builder = VoiceTranscriptBuilder()
        builder.setOpenPhrase("এক দুই তিন")
        builder.setOpenPhrase("এক দুই তিন চার")      // "এক দুই তিন" agreed and frozen
        builder.setOpenPhrase("এক দুয় তিন চার পাঁচ")  // revises a frozen word
        XCTAssertEqual(builder.transcript.text, "এক দুই তিন চার পাঁচ")
    }

    /// A pause commits everything; the recognizer's text keeps growing from there.
    func testPauseCommitsWithoutResettingTheStream() {
        var builder = VoiceTranscriptBuilder()
        builder.setOpenPhrase("আমি কাল")
        builder.commitAll()
        XCTAssertEqual(builder.transcript.stableText, "আমি কাল")
        builder.setOpenPhrase("আমি কাল অফি")
        XCTAssertEqual(builder.transcript.text, "আমি কাল অফি")
        XCTAssertEqual(builder.transcript.stableText, "আমি কাল")
    }

    func testFinishCommitsEverything() {
        var builder = VoiceTranscriptBuilder()
        builder.setOpenPhrase("শেষ কথা")
        builder.finish()
        XCTAssertTrue(builder.transcript.isFinal)
        XCTAssertEqual(builder.transcript.stableLength, "শেষ কথা".count)
    }
}

final class VoiceAudioRingTests: XCTestCase {
    func testReadsBackByAbsoluteIndexAcrossWrap() {
        let ring = VoiceAudioRing(seconds: 1, sampleRate: 10)
        ring.write((0..<7).map(Float.init))
        ring.write((7..<15).map(Float.init))
        XCTAssertEqual(ring.writeIndex, 15)
        XCTAssertEqual(ring.oldestIndex, 5)
        let read = ring.read(from: 8, maxCount: 100)
        XCTAssertEqual(read.samples, (8..<15).map(Float.init))
        XCTAssertEqual(read.next, 15)
    }

    func testReadingOverwrittenAudioStartsAtOldest() {
        let ring = VoiceAudioRing(seconds: 1, sampleRate: 10)
        ring.write((0..<25).map(Float.init))
        let read = ring.read(from: 2, maxCount: 3)
        XCTAssertEqual(read.start, 15)
        XCTAssertEqual(read.samples, [15, 16, 17])
    }

    func testDiscardedAudioCannotBeRead() {
        let ring = VoiceAudioRing(seconds: 1, sampleRate: 10)
        ring.write((1...8).map(Float.init))
        ring.discard(before: 6)
        XCTAssertEqual(ring.oldestIndex, 6)
        let read = ring.read(from: 0, maxCount: 10)
        XCTAssertEqual(read.start, 6)
        XCTAssertEqual(read.samples, [7, 8])
    }

    func testChunkedReadsCoverEverythingOnce() {
        let ring = VoiceAudioRing(seconds: 2, sampleRate: 100)
        var cursor: Int64 = 0
        var seen: [Float] = []
        for block in 0..<10 {
            ring.write((0..<37).map { Float(block * 37 + $0) })
            let read = ring.read(from: cursor, maxCount: 50)
            seen += read.samples
            cursor = read.next
        }
        seen += ring.read(from: cursor, maxCount: 1000).samples
        XCTAssertEqual(seen, (0..<370).map(Float.init))
    }
}

/// A host that, like real ones, shows only the last `window` characters before the
/// cursor.
@MainActor
final class WindowedDocument: TextDocumentEditing {
    private(set) var fullText = ""
    let window: Int
    init(window: Int) { self.window = window }
    var contextBeforeInput: String? { String(fullText.suffix(window)) }
    func insertText(_ text: String) { fullText.append(text) }
    func deleteBackward() { if !fullText.isEmpty { fullText.removeLast() } }
}
