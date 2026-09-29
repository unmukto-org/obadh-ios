import Foundation
import XCTest
@testable import ObadhKeyboardCore

@MainActor
final class VoiceDraftReconcilerTests: XCTestCase {
    private func snapshot(
        _ segments: [VoiceSegment],
        phase: VoiceSessionPhase = .listening,
        dictation: String = "d1"
    ) -> VoiceSessionSnapshot {
        VoiceSessionSnapshot(
            seq: 1, phase: phase, heartbeat: Date(), dictationID: dictation,
            segments: segments, failure: nil
        )
    }

    /// Drive a snapshot through reconciler + writer the way the keyboard does.
    @discardableResult
    private func feed(
        _ snapshot: VoiceSessionSnapshot,
        _ reconciler: inout VoiceDraftReconciler,
        _ document: TextDocumentEditing
    ) -> VoiceDraftWriter.Outcome? {
        guard let step = reconciler.step(for: snapshot) else { return nil }
        let outcome = VoiceDraftWriter().apply(step, in: document)
        switch outcome {
        case .applied: reconciler.didApply(step, snapshot: snapshot)
        case .stale: reconciler.abandonTracked(snapshot: snapshot, contextBefore: document.contextBeforeInput)
        }
        return outcome
    }

    func testPartialsGrowInPlaceThenRefinementReplacesDraft() {
        let document = FakeCompositionDocument(initialText: "আমি")
        var reconciler = VoiceDraftReconciler()
        reconciler.begin(dictationID: "d1", contextBefore: document.contextBeforeInput)

        feed(snapshot([VoiceSegment(id: 0, text: "আজ", isSettled: false)]), &reconciler, document)
        XCTAssertEqual(document.text, "আমি আজ")
        feed(snapshot([VoiceSegment(id: 0, text: "আজ বাজারে", isSettled: false)]), &reconciler, document)
        XCTAssertEqual(document.text, "আমি আজ বাজারে")
        // Appending never deletes.
        XCTAssertFalse(document.operations.contains(.deleteBackward))

        feed(snapshot([VoiceSegment(id: 0, text: "আজ বাজারে যাব।", isSettled: true)], phase: .ready), &reconciler, document)
        XCTAssertEqual(document.text, "আমি আজ বাজারে যাব।")
        XCTAssertEqual(reconciler.trackedText, "")
    }

    func testRefinedWordingReplacesOnlyTheChangedTail() {
        let document = FakeCompositionDocument()
        var reconciler = VoiceDraftReconciler()
        reconciler.begin(dictationID: "d1", contextBefore: "")

        feed(snapshot([VoiceSegment(id: 0, text: "অরবিন কেজরিওয়াল", isSettled: false)]), &reconciler, document)
        feed(snapshot([VoiceSegment(id: 0, text: "অরবিন্দ কেজরিওয়াল", isSettled: true)]), &reconciler, document)
        XCTAssertEqual(document.text, "অরবিন্দ কেজরিওয়াল")
    }

    func testSettledPrefixIsReleasedAndLaterPhrasesAreSpaced() {
        let document = FakeCompositionDocument()
        var reconciler = VoiceDraftReconciler()
        reconciler.begin(dictationID: "d1", contextBefore: "")

        feed(snapshot([
            VoiceSegment(id: 0, text: "প্রথম কথা।", isSettled: true),
            VoiceSegment(id: 1, text: "দ্বিতীয়", isSettled: false)
        ]), &reconciler, document)
        XCTAssertEqual(document.text, "প্রথম কথা। দ্বিতীয়")
        XCTAssertEqual(reconciler.trackedText, " দ্বিতীয়")

        feed(snapshot([
            VoiceSegment(id: 0, text: "প্রথম কথা।", isSettled: true),
            VoiceSegment(id: 1, text: "দ্বিতীয় কথা।", isSettled: true)
        ], phase: .ready), &reconciler, document)
        XCTAssertEqual(document.text, "প্রথম কথা। দ্বিতীয় কথা।")
    }

    func testNoLeadingSpaceAtStartOrAfterWhitespace() {
        for context in ["", "hello ", "line\n"] {
            let document = FakeCompositionDocument(initialText: context)
            var reconciler = VoiceDraftReconciler()
            reconciler.begin(dictationID: "d1", contextBefore: context)
            feed(snapshot([VoiceSegment(id: 0, text: "হ্যাঁ", isSettled: false)]), &reconciler, document)
            XCTAssertEqual(document.text, context + "হ্যাঁ")
        }
    }

    func testForeignDictationIsIgnored() {
        let document = FakeCompositionDocument()
        var reconciler = VoiceDraftReconciler()
        reconciler.begin(dictationID: "d1", contextBefore: "")
        XCTAssertNil(reconciler.step(for: snapshot([VoiceSegment(id: 0, text: "x", isSettled: false)], dictation: "old")))
        XCTAssertEqual(document.text, "")
    }

    /// The user moved the cursor mid-dictation: we must never delete what is now
    /// before the cursor, and later phrases continue at the new position.
    func testLostTrackNeverDeletesForeignText() {
        let document = FakeCompositionDocument()
        var reconciler = VoiceDraftReconciler()
        reconciler.begin(dictationID: "d1", contextBefore: "")
        feed(snapshot([VoiceSegment(id: 0, text: "খসড়া", isSettled: false)]), &reconciler, document)

        document.insertText(" typed")  // the host text changed under us
        let outcome = feed(snapshot([VoiceSegment(id: 0, text: "চূড়ান্ত", isSettled: true)]), &reconciler, document)
        XCTAssertEqual(outcome, .stale)
        XCTAssertEqual(document.text, "খসড়া typed")

        feed(snapshot([
            VoiceSegment(id: 0, text: "চূড়ান্ত", isSettled: true),
            VoiceSegment(id: 1, text: "নতুন", isSettled: false)
        ]), &reconciler, document)
        XCTAssertEqual(document.text, "খসড়া typed নতুন")
    }

    /// Hosts that delete one scalar per press must still end with exactly the
    /// refined text (no half-removed conjuncts).
    func testScalarDeletingHostLandsExactText() {
        let document = ScalarDeletingDocument()
        var reconciler = VoiceDraftReconciler()
        reconciler.begin(dictationID: "d1", contextBefore: "")
        feed(snapshot([VoiceSegment(id: 0, text: "বাংলাদেশ স্বাধীন", isSettled: false)]), &reconciler, document)
        feed(snapshot([VoiceSegment(id: 0, text: "বাংলাদেশ স্বাধীনতা", isSettled: false)]), &reconciler, document)
        feed(snapshot([VoiceSegment(id: 0, text: "বাংলাদেশের স্বাধীনতা", isSettled: true)], phase: .ready), &reconciler, document)
        XCTAssertEqual(document.contextBeforeInput, "বাংলাদেশের স্বাধীনতা")
    }

    /// Hosts expose only a window before the cursor. A draft longer than the window
    /// must still be rewritten in place, not abandoned.
    func testLongDraftInNarrowHostWindowStillRewrites() {
        let document = WindowedDocument(window: 40)
        var reconciler = VoiceDraftReconciler()
        reconciler.begin(dictationID: "d1", contextBefore: "")
        let long = "আজ আমি অফিসে যাব না কারণ আমার শরীর ভালো লাগছে না তাই বাসায় থাকব"
        XCTAssertEqual(feed(snapshot([VoiceSegment(id: 0, text: long, isSettled: false)]), &reconciler, document), .applied)
        let corrected = long + " আজকে"
        XCTAssertEqual(feed(snapshot([VoiceSegment(id: 0, text: corrected, isSettled: false)]), &reconciler, document), .applied)
        let reworded = "আজ আমি অফিসে যাব না কারণ আমার শরীর ভালো লাগছে না তাই বাসায় থাকবো"
        XCTAssertEqual(feed(snapshot([VoiceSegment(id: 0, text: reworded, isSettled: true)], phase: .ready), &reconciler, document), .applied)
        XCTAssertEqual(document.fullText, reworded)
    }

    /// If the document stops ending with our draft mid-delete, deletion stops: text
    /// that is not ours is never removed.
    func testDeletionStopsAtForeignText() {
        let document = FakeCompositionDocument(initialText: "keep ")
        let writer = VoiceDraftWriter()
        let step = VoiceDraftReconciler.Step(currentText: "ab", desiredText: "xy", retainedText: "xy", completesDictation: false)
        XCTAssertEqual(writer.apply(step, in: document), .stale, "document does not end with the draft")
        XCTAssertEqual(document.text, "keep ")
    }

    func testEmptyStreamingSegmentsAddNothing() {
        let document = FakeCompositionDocument(initialText: "ক")
        var reconciler = VoiceDraftReconciler()
        reconciler.begin(dictationID: "d1", contextBefore: "ক")
        feed(snapshot([VoiceSegment(id: 0, text: "  ", isSettled: true)], phase: .ready), &reconciler, document)
        XCTAssertEqual(document.text, "ক")
    }

    func testCompletionIsReportedOnlyWhenAllSettledAndIdle() {
        var reconciler = VoiceDraftReconciler()
        reconciler.begin(dictationID: "d1", contextBefore: "")
        let listening = snapshot([VoiceSegment(id: 0, text: "a", isSettled: true)], phase: .listening)
        XCTAssertEqual(reconciler.step(for: listening)?.completesDictation, false)
        let finishing = snapshot([VoiceSegment(id: 0, text: "a", isSettled: false)], phase: .finishing)
        XCTAssertEqual(reconciler.step(for: finishing)?.completesDictation, false)
        let ready = snapshot([VoiceSegment(id: 0, text: "a", isSettled: true)], phase: .ready)
        XCTAssertEqual(reconciler.step(for: ready)?.completesDictation, true)
    }
}

final class VoiceSessionProtocolTests: XCTestCase {
    func testWarmthNeedsLivePhaseAndFreshHeartbeat() {
        let now = Date()
        var snapshot = VoiceSessionSnapshot.empty
        snapshot.phase = .ready
        snapshot.heartbeat = now.addingTimeInterval(-1)
        XCTAssertTrue(snapshot.isWarm(now: now))
        snapshot.heartbeat = now.addingTimeInterval(-10)
        XCTAssertFalse(snapshot.isWarm(now: now))
        snapshot.heartbeat = now
        snapshot.phase = .idle
        XCTAssertFalse(snapshot.isWarm(now: now))
    }

    func testMessagesRoundTrip() throws {
        let snapshot = VoiceSessionSnapshot(
            seq: 42, phase: .listening, heartbeat: Date(timeIntervalSince1970: 1_000),
            dictationID: "abc", segments: [VoiceSegment(id: 3, text: "হ্যালো", isSettled: false)],
            failure: .interrupted, isAudioFlowing: true, isRecognizerReady: true
        )
        let data = try VoiceMessageFile.encode(snapshot)
        XCTAssertEqual(VoiceMessageFile.decode(VoiceSessionSnapshot.self, from: data), snapshot)
    }

    func testVoiceURLCarriesDictationID() {
        let url = VoiceSessionChannel.voiceURL(dictationID: "xyz")
        XCTAssertEqual(url.absoluteString, "obadh://voice?d=xyz")
    }

    func testLevelPageRoundTripsBetweenWriterAndReader() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("levels-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try XCTUnwrap(VoiceLevelWriter(url: url))
        let reader = try XCTUnwrap(VoiceLevelReader(url: url))
        XCTAssertEqual(reader.read().level, 0)
        let bands: [Float] = (0..<VoiceLevelFrame.bandCount).map { Float($0) / 20 }
        bands.withUnsafeBufferPointer { writer.write(level: 0.5, isSpeech: true, bands: $0) }
        let frame = reader.read()
        XCTAssertEqual(frame.level, 0.5)
        XCTAssertTrue(frame.isSpeech)
        XCTAssertEqual(frame.bands, bands)
        XCTAssertEqual(frame.counter, 1)
        [Float](repeating: .nan, count: 12).withUnsafeBufferPointer { writer.write(level: 7, isSpeech: false, bands: $0) }
        XCTAssertEqual(reader.read().level, 1, "reader clamps")
        XCTAssertEqual(reader.read().bands.first, 0, "reader drops non-finite")
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
